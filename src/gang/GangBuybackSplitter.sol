// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IGangPadBondView, IBondPair, IBondToken} from "./GangBond.sol";
import {IGangPad} from "./interfaces/IGangPad.sol";
import {IGangPadHandler} from "./interfaces/IGangPadDeps.sol";

/// @title GangBuybackSplitter (dev 税按比例回购销毁)
/// @notice The tax recipient of one V3 (curve) token: the quote the tax handler pays it is split, `buybackBps` of it
///         bought back from the token's pair and sent to 0xdead, the rest to the dev. Set up in four steps:
///         1. it is deployed for the dev (`pad`, `dev`, starting `buybackBps`), by script/DeployGangBuybackSplitter;
///         2. the platform checks it with that script (the real pad, this code) and `list`s it on the tax handler (a
///            recipient other than the creator must be listed) — the pad is a constructor input, so a splitter over a
///            fake pad would buy from a fake pair: only a checked one may be listed;
///         3. the dev creates the token with it as `recipient`;
///         4. anyone `bind`s the token (once; the token's creator must be the dev and its recipient this contract —
///            permissionless so a dev can't leave it unbound and `sweep` the quote).
///         Before graduation nothing arrives (the pool tax starts at the pair), so binding right after create is enough.
///         Quote arriving is split only when something touches it (`split`, `burnChunk`, a ratio change), at the ratio
///         of that moment: every ratio change splits first, so quote that arrived before it keeps the old ratio.
///         Ratio changes (dev only): a higher buyback share applies at once; a lower one runs LOWER_NOTICE after it is
///         asked for (`applyBuybackBps`, anyone), so holders see a cut coming, and lapses unless applied within
///         CUT_TTL after that. Asking for the current ratio cancels a pending cut.
///         The dev's part is pushed at the split; a push that fails (a quote that blacklists the dev) is owed
///         (`devOwed`, `releaseDev`), so it never holds up the buy-back. A quote balance that shrinks under what is
///         held (a seized or rebased balance) is taken from both held parts in proportion at the next split, so the
///         splitter keeps working on what it still has.
///         The buy-back is GangBond's: anyone (the keeper on a cron) calls `burnChunk`; one chunk per block, at most
///         CHUNK_MAX_BPS of the pair's quote reserve, and none while the spot price is more than MAX_PRICE_RISE_BPS
///         above the pair's own TWAP — so whoever calls it can't sandwich it, and `minTokensOut` is optional.
/// @dev Not upgradeable, no owner. Reads the pad's and the handler's public views and trades only with the token's
///      pair; needs no role from the pad, token, vault or handler. Any other token that names this contract as its
///      recipient (a listed address is open to every creator) only adds quote: in the bound quote it is split like
///      the rest, in any other asset `sweep` sends it to the dev.
contract GangBuybackSplitter is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    /// @notice A lower buyback share applies this long after the dev asks for it.
    uint64 public constant LOWER_NOTICE = 3 days;
    /// @notice A cut not applied within this long after it is due lapses (an old notice can't be used much later).
    uint64 public constant CUT_TTL = 7 days;
    /// @notice One buy-back chunk spends at most this share of the pair's quote reserve (as GangBond / the handler).
    uint256 public constant CHUNK_MAX_BPS = 50;
    /// @notice The buy-back compares the spot price with the pair's average over at least this long.
    uint32 public constant TWAP_WINDOW = 10 minutes;
    /// @notice No buy-back while the spot price is more than this above that average.
    uint256 public constant MAX_PRICE_RISE_BPS = 200;
    /// @dev Pancake V2 fee (9975/10000 = 0.25%).
    uint256 public constant DEX_FEE_NUM = 9975;
    uint256 public constant DEX_FEE_DEN = 10_000;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    uint8 internal constant KIND_CURVE = 1;

    address public immutable pad;
    address public immutable taxHandler;
    address public immutable dev;

    /// @notice The bound token and its quote (0 until `bind`).
    address public token;
    bool internal _tokenIs0;
    address public quote;
    /// @notice The token's pair, cached at the first buy-back after graduation.
    address public pair;
    /// @notice Share of the incoming quote spent on the buy-back.
    uint16 public buybackBps;
    /// @notice A requested lower share and when it may apply (`pendingAt` 0 = none; lapsed after CUT_TTL past it).
    uint16 public pendingBps;
    uint64 public pendingAt;
    /// @notice Quote set aside for the buy-back and not spent yet.
    uint256 public buybackLeft;
    /// @notice The dev's part whose push failed, held here until `releaseDev`.
    uint256 public devOwed;
    uint256 public lastBurnBlock;

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
    event Split(uint256 incoming, uint256 toBuyback, uint256 toDev);
    event DevOwed(uint256 amount);
    event DevReleased(uint256 amount);
    /// @notice The quote balance fell below what was held; `buybackLeft` and `devOwed` shrank by `amount` in proportion.
    event Shortfall(uint256 amount);
    event BuybackBpsSet(uint16 oldBps, uint16 newBps);
    event BuybackBpsProposed(uint16 newBps, uint64 at);
    event BuybackBpsProposalCancelled(uint16 newBps);
    event BoughtBack(uint256 quoteIn, uint256 burned, uint256 left);
    event Swept(address indexed asset, uint256 amount);

    error ZeroAddress();
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
    error NothingToBurn();
    error BurnedThisBlock();
    error NotTradable();
    error Slippage();
    error NotSweepable();

    modifier onlyDev() {
        if (msg.sender != dev) revert NotDev();
        _;
    }

    constructor(address pad_, address dev_, uint16 buybackBps_) {
        if (pad_ == address(0) || dev_ == address(0)) revert ZeroAddress();
        if (buybackBps_ > BPS) revert BadBps();
        pad = pad_;
        taxHandler = IGangPad(pad_).taxHandler();
        dev = dev_;
        buybackBps = buybackBps_;
        emit BuybackBpsSet(0, buybackBps_);
    }

    // ---------------------------------------------------------------- dev
    /// @notice A share at or above the current one applies now (and cancels a pending cut); a lower one is pending
    ///         until LOWER_NOTICE from now (asking again replaces it and restarts the notice).
    function setBuybackBps(uint16 newBps) external onlyDev nonReentrant {
        if (newBps > BPS) revert BadBps();
        if (newBps >= buybackBps) {
            _split();
            _cancelPending();
            emit BuybackBpsSet(buybackBps, newBps);
            buybackBps = newBps;
            return;
        }
        uint64 at = uint64(block.timestamp) + LOWER_NOTICE;
        pendingBps = newBps;
        pendingAt = at;
        emit BuybackBpsProposed(newBps, at);
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
    function applyBuybackBps() external nonReentrant {
        uint64 at = pendingAt;
        if (at == 0) revert NoProposal();
        if (block.timestamp < at) revert NotDue();
        if (!_cutLive()) revert CutLapsed();
        _split();
        uint16 newBps = pendingBps;
        pendingAt = 0;
        pendingBps = 0;
        emit BuybackBpsSet(buybackBps, newBps);
        buybackBps = newBps;
    }

    /// @notice Split the quote that arrived since the last split: the buyback share set aside, the rest to the dev.
    function split() external nonReentrant {
        _split();
    }

    /// @notice Split first (a shortfall is shared before anything leaves), then push the dev's owed part (reverts while
    ///         the dev still can't receive, so nothing owed is lost).
    function releaseDev() external nonReentrant returns (uint256 amount) {
        _split();
        amount = devOwed;
        if (amount == 0) revert NothingOwed();
        devOwed = 0;
        IERC20(quote).safeTransfer(dev, amount);
        emit DevReleased(amount);
    }

    /// @notice Split what arrived, then spend one chunk of the buy-back on the token, straight from its pair, and send
    ///         what arrives (after the buy tax) to 0xdead. One chunk per block, at most CHUNK_MAX_BPS of the pair's
    ///         quote reserve. Returns (0, 0) without buying while the price check is not ready: the first call only
    ///         records an observation; later ones wait until TWAP_WINDOW has passed since it, and skip while the spot
    ///         price is more than MAX_PRICE_RISE_BPS above the average. After more than 2 × TWAP_WINDOW without a call
    ///         the observations start over (that call records only). Reverts NotTradable before graduation.
    /// @param minTokensOut Least tokens to burn (after the buy tax); checked only when a chunk is bought.
    function burnChunk(uint256 minTokensOut) external nonReentrant returns (uint256 quoteIn, uint256 burned) {
        _split();
        uint256 left = buybackLeft;
        if (left == 0) revert NothingToBurn();
        if (lastBurnBlock == block.number) revert BurnedThisBlock();
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
        if (!ok) return (0, 0);
        quoteIn = _chunkOf(left, rQ);
        if (quoteIn == 0) return (0, 0);

        lastBurnBlock = block.number;
        left -= quoteIn;
        buybackLeft = left;
        uint256 out = _amountOut(quoteIn, rQ, rT);
        IERC20(quote).safeTransfer(p, quoteIn);
        // a chunk too small to buy one token unit is left in the pair as a donation (only ever a last dust chunk)
        if (out != 0) {
            // bought here, not straight to 0xdead: the token exempts 0xdead from its tax, and the buy-back is a pool
            // buy like any other (the buy tax pays the platform and the holders)
            uint256 before = IERC20(token).balanceOf(address(this));
            if (tokenIs0) IBondPair(p).swap(out, 0, address(this), "");
            else IBondPair(p).swap(0, out, address(this), "");
            burned = IERC20(token).balanceOf(address(this)) - before;
            if (burned < minTokensOut) revert Slippage();
            IERC20(token).safeTransfer(DEAD, burned);
        }
        emit BoughtBack(quoteIn, burned, left);
    }

    /// @notice Bound only: send the whole balance of any asset but the bound quote to the dev (another token's tax
    ///         paid here in another quote, a stray transfer).
    function sweep(address asset) external nonReentrant {
        if (quote == address(0)) revert NotBound();
        if (asset == quote) revert NotSweepable();
        uint256 amount = IERC20(asset).balanceOf(address(this));
        IERC20(asset).safeTransfer(dev, amount);
        emit Swept(asset, amount);
    }

    // ---------------------------------------------------------------- views
    /// @notice Quote that arrived and is not split yet.
    function unsplit() public view returns (uint256) {
        if (quote == address(0)) return 0;
        uint256 bal = IERC20(quote).balanceOf(address(this));
        uint256 held = buybackLeft + devOwed;
        return bal > held ? bal - held : 0;
    }

    /// @notice The requested cut, if it can still apply: `live` from the request until CUT_TTL past `at` (it applies
    ///         from `at`); a lapsed or no request reads (false, 0, 0).
    function pendingCut() external view returns (bool live, uint16 bps, uint64 at) {
        if (!_cutLive()) return (false, 0, 0);
        return (true, pendingBps, pendingAt);
    }

    /// @notice What `burnChunk` would do now: whether it buys, the quote it spends and the tokens it burns.
    function previewBurn() external view returns (bool ready, uint256 quoteIn, uint256 tokensOut) {
        uint256 left = _buybackAfterSplit();
        if (left == 0 || lastBurnBlock == block.number) return (false, 0, 0);
        address p = pair;
        bool tokenIs0 = _tokenIs0;
        if (p == address(0)) {
            bool live;
            (,,,,,, live,,,, p,) = IGangPadBondView(pad).curves(token);
            if (!live) return (false, 0, 0);
            tokenIs0 = IBondPair(p).token0() == token;
        }
        (uint256 rT, uint256 rQ, uint256 cum) = _pairState(p, tokenIs0);
        (, ready) = _twapCheck(_twap, cum, rT, rQ);
        if (!ready) return (false, 0, 0);
        quoteIn = _chunkOf(left, rQ);
        if (quoteIn == 0) return (false, 0, 0);
        uint256 out = _amountOut(quoteIn, rQ, rT);
        tokensOut = out - (out * IBondToken(token).buyTaxBps()) / BPS;
    }

    // ---------------------------------------------------------------- internal
    function _split() internal {
        if (quote == address(0)) return;
        uint256 bal = IERC20(quote).balanceOf(address(this));
        uint256 owed = devOwed;
        uint256 held = buybackLeft + owed;
        if (bal < held) {
            // both held parts lose in proportion (the dev's rounded down)
            owed = (owed * bal) / held;
            devOwed = owed;
            buybackLeft = bal - owed;
            emit Shortfall(held - bal);
            return;
        }
        uint256 incoming = bal - held;
        if (incoming == 0) return;
        uint256 toBuyback = (incoming * buybackBps) / BPS;
        uint256 toDev = incoming - toBuyback;
        buybackLeft += toBuyback;
        if (toDev != 0 && !_tryTransfer(quote, dev, toDev)) {
            devOwed += toDev;
            emit DevOwed(toDev);
        }
        emit Split(incoming, toBuyback, toDev);
    }

    /// @dev `buybackLeft` as `_split` would leave it now (a shortfall shared, or the unsplit quote's share added).
    function _buybackAfterSplit() internal view returns (uint256) {
        if (quote == address(0)) return buybackLeft;
        uint256 bal = IERC20(quote).balanceOf(address(this));
        uint256 owed = devOwed;
        uint256 held = buybackLeft + owed;
        if (bal < held) return bal - (owed * bal) / held;
        return buybackLeft + ((bal - held) * buybackBps) / BPS;
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
        if (_cutLive()) emit BuybackBpsProposalCancelled(pendingBps);
        pendingAt = 0;
        pendingBps = 0;
    }

    function _cutLive() internal view returns (bool) {
        uint64 at = pendingAt;
        return at != 0 && block.timestamp <= at + CUT_TTL;
    }

    // GangBond's buy-back math, copied so the deployed GangBond stays untouched: `_pairState`, `_twapCheck`,
    // `_chunkOf` and `_amountOut` must stay identical to GangBond's — change both together.

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

    /// @dev GangBond's check: roll the observations forward and say whether a chunk may be bought now — there is an
    ///      average over TWAP_WINDOW to 2 × TWAP_WINDOW and the spot price is at most MAX_PRICE_RISE_BPS above it. A
    ///      newest observation older than 2 × TWAP_WINDOW restarts both.
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
