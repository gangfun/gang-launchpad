// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IGangPadBondView, IBondPair, IBondToken} from "./GangBond.sol";
import {IGangPad} from "./interfaces/IGangPad.sol";
import {IGangPadHandler} from "./interfaces/IGangPadDeps.sol";
import {IGangRecipientModule} from "./interfaces/IGangRecipientModule.sol";

interface ILpPair {
    function mint(address to) external returns (uint256 liquidity);
    function totalSupply() external view returns (uint256);
}

/// @title GangLiquiditySplitter (dev 税按比例自动加池子)
/// @notice The tax recipient of one V3 (curve) token: the quote the tax handler pays it is split, `lpBps` of it added
///         to the token's pair as liquidity whose LP goes to 0xdead (locked for good, like the graduation LP), the rest
///         to the dev's `payee` (the dev unless it names another address; the dev can change it at any time). A clone,
///         set up as GangBuybackSplitter is: the factory clones and lists it (`create(bps, salt, payee)`, the CLI's
///         `--lp`), the dev creates the token with it as `recipient`, anyone `bind`s it.
///         Everything but the chunk itself is GangBuybackSplitter v4's, unchanged: the split (at the ratio of the
///         moment, every ratio change splits first), ratio changes (a raise at once, a cut LOWER_NOTICE after it is
///         asked for, lapsing CUT_TTL after that), the dev's part pushed to the payee or owed, a shortfall shared in
///         proportion, `sweep` of other assets, and the pace and price guard of a chunk: one per CHUNK_GAP, at most
///         CHUNK_MAX_BPS of the pair's quote reserve, none while the spot price is more than MAX_PRICE_RISE_BPS above
///         the pair's own TWAP.
///         A chunk (`addChunk`, the keeper's `work`): half of it buys the token from the pair (a pool buy: the buy tax
///         applies); all of that goes back into the pair (a transfer into the pair: the sell tax applies, and the
///         handler may sell a chunk of its tax first); then the quote matching the tokens that arrived, at the pair's
///         reserves of that moment, follows, at most the chunk's other half, and the pair mints the LP to 0xdead.
///         The two taxes leave fewer tokens than half the chunk buys, so part of the other half stays for the next
///         chunk: each step is priced on what the pair actually holds, never on a forecast.
/// @dev Not upgradeable (an EIP-1167 clone of a fixed implementation), no owner. Trades only with the token's pair;
///      needs no role from the pad, token, vault or handler. The pair's LP is (nearly) all 0xdead's, so tokens or
///      quote left in the pair (a dust chunk, a rounding) only deepen the pool for good.
contract GangLiquiditySplitter is IGangRecipientModule, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    /// @notice A lower LP share applies this long after the dev asks for it.
    uint64 public constant LOWER_NOTICE = 3 days;
    /// @notice A cut not applied within this long after it is due lapses.
    uint64 public constant CUT_TTL = 7 days;
    /// @notice One chunk (both halves) spends at most this share of the pair's quote reserve.
    uint256 public constant CHUNK_MAX_BPS = 50;
    /// @notice The chunk compares the spot price with the pair's average over at least this long.
    uint32 public constant TWAP_WINDOW = 10 minutes;
    /// @notice At most one chunk per this long (as GangBuybackSplitter v3+, GangBond audit 2026-10-29 H-1).
    uint64 public constant CHUNK_GAP = 4 minutes;
    /// @notice No chunk while the spot price is more than this above that average.
    uint256 public constant MAX_PRICE_RISE_BPS = 200;
    /// @dev Pancake V2 fee (9975/10000 = 0.25%).
    uint256 public constant DEX_FEE_NUM = 9975;
    uint256 public constant DEX_FEE_DEN = 10_000;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    /// @notice `previewWork`'s `minOut`: the previewed buy less this, for a trade earlier in the same block.
    uint256 public constant WORK_SLIPPAGE_BPS = 100;
    /// @notice `previewWork` is not due while the LP part holds less than this share of the pair's quote reserve.
    uint256 public constant WORK_MIN_BPS = 5;
    bytes32 public constant MODULE_TYPE = "lp-burn-v1";

    uint8 internal constant KIND_CURVE = 1;

    address public immutable pad;
    address public immutable taxHandler;
    /// @notice The factory that deployed the implementation: the only caller of a clone's `initialize`.
    address public immutable factory;
    address internal immutable _self;

    /// @notice The dev (set once by the factory): changes the ratio and the payee.
    address public dev;
    /// @notice Where the dev's part goes (the dev unless it named another address).
    address public payee;
    /// @notice The bound token and its quote (0 until `bind`).
    address public token;
    bool internal _tokenIs0;
    address public quote;
    /// @notice The token's pair, cached at the first chunk after graduation.
    address public pair;
    /// @notice Share of the incoming quote added to the pool.
    uint16 public lpBps;
    /// @notice A requested lower share and when it may apply (`pendingAt` 0 = none; lapsed after CUT_TTL past it).
    uint16 public pendingBps;
    uint64 public pendingAt;
    /// @notice Quote set aside for the pool and not added yet.
    uint256 public lpLeft;
    /// @notice The dev's part whose push to the payee failed, held here until `releaseDev`.
    uint256 public devOwed;
    /// @notice When the last chunk was added (0: none yet).
    uint64 public lastAddAt;

    /// @dev The token's quote-per-token cumulative price (UQ112x112 × seconds, wrapping) at `at`.
    struct Obs {
        uint256 cumulative;
        uint32 at;
    }

    /// @dev Two observations: the average is taken from `old`, which is always at least TWAP_WINDOW back once ready.
    struct Twap {
        Obs old;
        Obs recent;
    }

    Twap internal _twap;

    event Bound(address indexed token, address indexed quote);
    event Split(uint256 incoming, uint256 toLp, uint256 toDev);
    event DevOwed(uint256 amount);
    event DevReleased(uint256 amount);
    /// @notice The quote balance fell below what was held; `lpLeft` and `devOwed` shrank by `amount` in proportion.
    event Shortfall(uint256 amount);
    event LpBpsSet(uint16 oldBps, uint16 newBps);
    event LpBpsProposed(uint16 newBps, uint64 at);
    event LpBpsProposalCancelled(uint16 newBps);
    /// @notice One chunk: `quoteIn` quote spent (the buy and the deposit), `tokensIn` tokens the pair received back,
    ///         `liquidity` LP minted to 0xdead, `left` still set aside.
    event LiquidityAdded(uint256 quoteIn, uint256 tokensIn, uint256 liquidity, uint256 left);
    event Swept(address indexed asset, uint256 amount);
    event PayeeSet(address indexed oldPayee, address indexed newPayee);

    error ZeroAddress();
    error NotClone();
    error NotFactory();
    error AlreadyInitialized();
    error BadBps();
    error NotDev();
    error AlreadyBound();
    error NotBound();
    error NotCurve();
    error NotCreator();
    error NotRecipient();
    error NoProposal();
    error NotDue();
    error CutLapsed();
    error NothingOwed();
    error NothingToAdd();
    error AddTooSoon();
    error NotTradable();
    error Slippage();
    error NotSweepable();
    error BadPayee();

    modifier onlyDev() {
        if (msg.sender != dev) revert NotDev();
        _;
    }

    /// @dev The implementation, deployed by the factory; it is never initialized itself.
    constructor(address pad_) {
        if (pad_ == address(0)) revert ZeroAddress();
        pad = pad_;
        taxHandler = IGangPad(pad_).taxHandler();
        factory = msg.sender;
        _self = address(this);
    }

    /// @notice A clone's setup, by the factory in the tx that clones it (`payee_` 0 = the dev).
    function initialize(address dev_, uint16 lpBps_, address payee_) external {
        if (address(this) == _self) revert NotClone();
        if (msg.sender != factory) revert NotFactory();
        if (dev != address(0)) revert AlreadyInitialized();
        if (dev_ == address(0)) revert ZeroAddress();
        if (lpBps_ > BPS) revert BadBps();
        address to = payee_ == address(0) ? dev_ : payee_;
        if (to == address(this)) revert BadPayee();
        dev = dev_;
        payee = to;
        lpBps = lpBps_;
        emit LpBpsSet(0, lpBps_);
        emit PayeeSet(address(0), to);
    }

    function moduleType() external pure returns (bytes32) {
        return MODULE_TYPE;
    }

    // ---------------------------------------------------------------- dev
    /// @notice A share at or above the current one applies now (and cancels a pending cut); a lower one is pending
    ///         until LOWER_NOTICE from now (asking again replaces it and restarts the notice).
    function setLpBps(uint16 newBps) external onlyDev nonReentrant {
        if (newBps > BPS) revert BadBps();
        if (newBps >= lpBps) {
            _split();
            _cancelPending();
            emit LpBpsSet(lpBps, newBps);
            lpBps = newBps;
            return;
        }
        uint64 at = uint64(block.timestamp) + LOWER_NOTICE;
        pendingBps = newBps;
        pendingAt = at;
        emit LpBpsProposed(newBps, at);
    }

    /// @notice Send the dev's part to `newPayee` from now on (at once: it is the dev's own share). Quote that arrived
    ///         before is split first and goes to the old payee; what is owed (`devOwed`) goes to the new one.
    function setPayee(address newPayee) external onlyDev nonReentrant {
        if (newPayee == address(0)) revert ZeroAddress();
        // paying itself would loop the dev's part back into the next split
        if (newPayee == address(this)) revert BadPayee();
        _split();
        emit PayeeSet(payee, newPayee);
        payee = newPayee;
    }

    // ---------------------------------------------------------------- anyone
    /// @notice Bind the dev's token (once): a V3 token the dev created with this contract as its tax recipient.
    function bind(address token_) external {
        if (token != address(0)) revert AlreadyBound();
        if (IGangPadBondView(pad).kindOf(token_) != KIND_CURVE) revert NotCurve();
        (address creator, address quote_,,,,,,,,,,) = IGangPadBondView(pad).curves(token_);
        if (creator != dev) revert NotCreator();
        (, address recipient) = IGangPadHandler(taxHandler).routeOf(token_);
        if (recipient != address(this)) revert NotRecipient();
        token = token_;
        quote = quote_;
        emit Bound(token_, quote_);
    }

    /// @notice A requested cut, LOWER_NOTICE on: quote that arrived before it is split at the old share first.
    function applyLpBps() external nonReentrant {
        uint64 at = pendingAt;
        if (at == 0) revert NoProposal();
        if (block.timestamp < at) revert NotDue();
        if (!_cutLive()) revert CutLapsed();
        _split();
        uint16 newBps = pendingBps;
        pendingAt = 0;
        pendingBps = 0;
        emit LpBpsSet(lpBps, newBps);
        lpBps = newBps;
    }

    /// @notice Split the quote that arrived since the last split: the LP share set aside, the rest to the dev.
    function split() external nonReentrant {
        _split();
    }

    /// @notice Split first (a shortfall is shared before anything leaves), then push the dev's owed part to the payee
    ///         (reverts while the payee still can't receive, so nothing owed is lost).
    function releaseDev() external nonReentrant returns (uint256 amount) {
        _split();
        amount = devOwed;
        if (amount == 0) revert NothingOwed();
        devOwed = 0;
        IERC20(quote).safeTransfer(payee, amount);
        emit DevReleased(amount);
    }

    /// @notice Split what arrived, then add one chunk of the LP part to the pair (see the contract notes): one per
    ///         CHUNK_GAP (sooner reverts AddTooSoon), at most CHUNK_MAX_BPS of the pair's quote reserve. Returns zeros
    ///         without trading while the price check is not ready (as GangBuybackSplitter's `burnChunk`). Reverts
    ///         NotTradable before graduation.
    /// @param minTokensOut Least tokens the buy half brings in (after the buy tax), scaled to the share of it the pair
    ///        received (a quote taxing the transfer delivers less); checked only when a chunk is added.
    /// @return quoteIn Quote spent (the buy and the deposit); the rest of the chunk stays set aside.
    /// @return tokensIn Tokens the pair received back (after the sell tax).
    /// @return liquidity LP minted to 0xdead.
    function addChunk(uint256 minTokensOut)
        external
        nonReentrant
        returns (uint256 quoteIn, uint256 tokensIn, uint256 liquidity)
    {
        return _addChunk(minTokensOut);
    }

    /// @notice IGangRecipientModule's step: `addChunk(minOut)`.
    function work(uint256 minOut) external nonReentrant {
        _addChunk(minOut);
    }

    function _addChunk(uint256 minTokensOut) internal returns (uint256 quoteIn, uint256 tokensIn, uint256 liquidity) {
        _split();
        uint256 left = lpLeft;
        if (left == 0) revert NothingToAdd();
        if (_tooSoon()) revert AddTooSoon();
        address p = pair;
        bool tokenIs0 = _tokenIs0;
        if (p == address(0)) {
            bool live;
            (,,,,,, live,,,, p,) = IGangPadBondView(pad).curves(token);
            if (!live) revert NotTradable();
            tokenIs0 = IBondPair(p).token0() == token;
            pair = p;
            _tokenIs0 = tokenIs0;
        }
        (uint256 rT, uint256 rQ, uint256 cum) = _pairState(p, tokenIs0);
        Twap memory w = _twap;
        uint32 seen = w.recent.at;
        (Twap memory next, bool ok) = _twapCheck(w, cum, rT, rQ);
        // every roll or restart moves `recent` to now: write only then
        if (next.recent.at != seen) _twap = next;
        if (!ok) return (0, 0, 0);
        uint256 chunk = _chunkOf(left, rQ);
        uint256 half = chunk / 2;
        if (half == 0) return (0, 0, 0);
        lastAddAt = uint64(block.timestamp);

        // 1. buy with half, priced on what the pair received (as GangBuybackSplitter v4)
        IERC20(quote).safeTransfer(p, half);
        quoteIn = half;
        uint256 got;
        {
            uint256 bal = IERC20(quote).balanceOf(p);
            got = bal > rQ ? bal - rQ : 0;
        }
        uint256 out = _amountOut(got, rQ, rT);
        if (out != 0) {
            uint256 bought = IERC20(token).balanceOf(address(this));
            if (tokenIs0) IBondPair(p).swap(out, 0, address(this), "");
            else IBondPair(p).swap(0, out, address(this), "");
            bought = IERC20(token).balanceOf(address(this)) - bought;
            if (bought * half < minTokensOut * got) revert Slippage();

            // 2. all of it back into the pair: the sell tax applies, and the handler may sell a chunk of its tax
            //    first (it moves the reserves), so the quote to match is read after
            IERC20(token).safeTransfer(p, bought);
            (uint112 r0, uint112 r1,) = IBondPair(p).getReserves();
            (rT, rQ) = tokenIs0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
            uint256 tBal = IERC20(token).balanceOf(p);
            tokensIn = tBal > rT ? tBal - rT : 0;

            // 3. the quote matching what arrived, at those reserves (rounded up), at most the other half
            uint256 match_ = rT == 0 ? 0 : (tokensIn * rQ + rT - 1) / rT;
            uint256 room = chunk - half;
            if (match_ > room) match_ = room;
            uint256 supply = ILpPair(p).totalSupply();
            // a mint of 0 LP reverts in the pair: then the tokens stay in it (a donation, dust only)
            if (match_ != 0 && (tokensIn * supply) / rT != 0 && (match_ * supply) / rQ != 0) {
                IERC20(quote).safeTransfer(p, match_);
                quoteIn += match_;
                liquidity = ILpPair(p).mint(DEAD);
            }
        }
        // a buy of 0 tokens (a dust chunk) leaves its quote in the pair as a donation
        left -= quoteIn;
        lpLeft = left;
        emit LiquidityAdded(quoteIn, tokensIn, liquidity, left);
    }

    /// @notice Bound only: send the whole balance of any asset but the bound quote to the payee (another token's tax
    ///         paid here in another quote, a stray transfer).
    function sweep(address asset) external nonReentrant {
        if (quote == address(0)) revert NotBound();
        if (asset == quote) revert NotSweepable();
        uint256 amount = IERC20(asset).balanceOf(address(this));
        IERC20(asset).safeTransfer(payee, amount);
        emit Swept(asset, amount);
    }

    // ---------------------------------------------------------------- views
    /// @notice Quote that arrived and is not split yet.
    function unsplit() public view returns (uint256) {
        if (quote == address(0)) return 0;
        uint256 bal = IERC20(quote).balanceOf(address(this));
        uint256 held = lpLeft + devOwed;
        return bal > held ? bal - held : 0;
    }

    /// @notice The requested cut, if it can still apply: `live` from the request until CUT_TTL past `at` (it applies
    ///         from `at`); a lapsed or no request reads (false, 0, 0).
    function pendingCut() external view returns (bool live, uint16 bps, uint64 at) {
        if (!_cutLive()) return (false, 0, 0);
        return (true, pendingBps, pendingAt);
    }

    /// @notice What `addChunk` would do now: whether it trades, the chunk (both halves at most) and the tokens its buy
    ///         half brings in after the buy tax.
    function previewAdd() external view returns (bool ready, uint256 chunk, uint256 tokensOut) {
        (ready, chunk, tokensOut,,) = _preview();
    }

    /// @notice Due when `addChunk` would add a chunk (`minOut` = its buy less WORK_SLIPPAGE_BPS) or, while the price
    ///         check is not ready, when the call would record or roll the TWAP observation (`minOut` 0). Not due with
    ///         less than WORK_MIN_BPS of the pair's quote reserve set aside, before graduation, or within CHUNK_GAP of
    ///         the last chunk.
    function previewWork() external view returns (bool due, uint256 minOut) {
        (bool ready,, uint256 tokensOut, bool moves, bool small) = _preview();
        if (small) return (false, 0);
        if (ready) return (true, (tokensOut * (BPS - WORK_SLIPPAGE_BPS)) / BPS);
        return (moves, 0);
    }

    // ---------------------------------------------------------------- internal
    function _preview() internal view returns (bool ready, uint256 chunk, uint256 tokensOut, bool moves, bool small) {
        uint256 left = _lpAfterSplit();
        if (left == 0 || _tooSoon()) return (false, 0, 0, false, true);
        address p = pair;
        bool tokenIs0 = _tokenIs0;
        if (p == address(0)) {
            bool live;
            (,,,,,, live,,,, p,) = IGangPadBondView(pad).curves(token);
            if (!live) return (false, 0, 0, false, true);
            tokenIs0 = IBondPair(p).token0() == token;
        }
        (uint256 rT, uint256 rQ, uint256 cum) = _pairState(p, tokenIs0);
        small = left * BPS < rQ * WORK_MIN_BPS;
        Twap memory w = _twap;
        uint32 seen = w.recent.at;
        Twap memory next;
        (next, ready) = _twapCheck(w, cum, rT, rQ);
        moves = next.recent.at != seen;
        if (!ready) return (false, 0, 0, moves, small);
        chunk = _chunkOf(left, rQ);
        if (chunk / 2 == 0) return (false, 0, 0, moves, small);
        uint256 out = _amountOut(chunk / 2, rQ, rT);
        tokensOut = out - (out * IBondToken(token).buyTaxBps()) / BPS;
    }

    function _split() internal {
        if (quote == address(0)) return;
        uint256 bal = IERC20(quote).balanceOf(address(this));
        uint256 owed = devOwed;
        uint256 held = lpLeft + owed;
        if (bal < held) {
            // both held parts lose in proportion (the dev's rounded down)
            owed = (owed * bal) / held;
            devOwed = owed;
            lpLeft = bal - owed;
            emit Shortfall(held - bal);
            return;
        }
        uint256 incoming = bal - held;
        if (incoming == 0) return;
        uint256 toLp = (incoming * lpBps) / BPS;
        uint256 toDev = incoming - toLp;
        lpLeft += toLp;
        if (toDev != 0 && !_tryTransfer(quote, payee, toDev)) {
            devOwed += toDev;
            emit DevOwed(toDev);
        }
        emit Split(incoming, toLp, toDev);
    }

    /// @dev `lpLeft` as `_split` would leave it now (a shortfall shared, or the unsplit quote's share added).
    function _lpAfterSplit() internal view returns (uint256) {
        if (quote == address(0)) return lpLeft;
        uint256 bal = IERC20(quote).balanceOf(address(this));
        uint256 owed = devOwed;
        uint256 held = lpLeft + owed;
        if (bal < held) return bal - (owed * bal) / held;
        return lpLeft + ((bal - held) * lpBps) / BPS;
    }

    /// @dev As the tax handler's: a transfer that reports failure instead of reverting.
    function _tryTransfer(address asset, address to, uint256 amount) internal returns (bool) {
        (bool ok, bytes memory ret) = asset.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!ok) return false;
        if (ret.length == 0) return asset.code.length > 0;
        return ret.length >= 32 && abi.decode(ret, (bool));
    }

    /// @dev A lapsed request is cleared without a cancel event (it was already dead).
    function _cancelPending() internal {
        if (pendingAt == 0) return;
        if (_cutLive()) emit LpBpsProposalCancelled(pendingBps);
        pendingAt = 0;
        pendingBps = 0;
    }

    /// @dev A chunk was added less than CHUNK_GAP ago (none yet: never too soon).
    function _tooSoon() internal view returns (bool) {
        uint64 last = lastAddAt;
        return last != 0 && block.timestamp < last + CHUNK_GAP;
    }

    function _cutLive() internal view returns (bool) {
        uint64 at = pendingAt;
        return at != 0 && block.timestamp <= at + CUT_TTL;
    }

    // GangBond's buy-back math (as GangBuybackSplitter): `_pairState`, `_twapCheck`, `_chunkOf` and `_amountOut` must
    // stay identical to GangBond's — change them together.

    /// @dev Reserves (token side, quote side) and the quote-per-token cumulative price as of this block.
    function _pairState(address p, bool tokenIs0) internal view returns (uint256 rT, uint256 rQ, uint256 cum) {
        (uint112 r0, uint112 r1, uint32 last) = IBondPair(p).getReserves();
        (rT, rQ) = tokenIs0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        cum = tokenIs0 ? IBondPair(p).price0CumulativeLast() : IBondPair(p).price1CumulativeLast();
        uint32 now32 = uint32(block.timestamp);
        // Uniswap V2 oracle arithmetic: the cumulative and the uint32 clock wrap by design
        unchecked {
            if (last != now32 && rT != 0) cum += ((rQ << 112) / rT) * uint32(now32 - last);
        }
    }

    /// @dev Roll the observations forward and say whether a chunk may be added now — there is an average over
    ///      TWAP_WINDOW to 2 × TWAP_WINDOW and the spot price is at most MAX_PRICE_RISE_BPS above it. A newest
    ///      observation older than 2 × TWAP_WINDOW restarts both.
    function _twapCheck(Twap memory w, uint256 cum, uint256 rT, uint256 rQ) internal view returns (Twap memory, bool) {
        uint32 now32 = uint32(block.timestamp);
        uint32 elapsed;
        uint256 avg;
        unchecked {
            if (w.recent.at == 0 || now32 - w.recent.at > 2 * TWAP_WINDOW) {
                w.recent = Obs(cum, now32);
                w.old = w.recent;
                return (w, false);
            }
            if (now32 - w.recent.at >= TWAP_WINDOW) {
                w.old = w.recent;
                w.recent = Obs(cum, now32);
            }
            elapsed = now32 - w.old.at;
            if (elapsed < TWAP_WINDOW || rT == 0 || rQ == 0) return (w, false);
            avg = (cum - w.old.cumulative) / elapsed;
        }
        uint256 spot = (rQ << 112) / rT;
        return (w, spot * BPS <= avg * (BPS + MAX_PRICE_RISE_BPS));
    }

    function _chunkOf(uint256 left, uint256 rQ) internal pure returns (uint256) {
        uint256 max = (rQ * CHUNK_MAX_BPS) / BPS;
        return left < max ? left : max;
    }

    /// @dev Pancake V2 getAmountOut (0 for an empty side).
    function _amountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint256) {
        if (reserveIn == 0 || reserveOut == 0) return 0;
        uint256 inWithFee = amountIn * DEX_FEE_NUM;
        return (inWithFee * reserveOut) / (reserveIn * DEX_FEE_DEN + inWithFee);
    }
}
