// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IGangBond} from "./interfaces/IGangBond.sol";

/// @dev What GangBond reads from GangLaunchpad: the kind, and the creator / quote / pair of a curve or a sale (the
///      public getters' tuple layouts, as GangRouter and the CLI decode them).
interface IGangPadBondView {
    function kindOf(address token) external view returns (uint8);
    function curves(address token)
        external
        view
        returns (
            address creator,
            address quote,
            uint128 realQuote,
            uint128 sold,
            uint128 gradAmt,
            uint128 virtualQuote,
            bool graduated,
            uint16 buyTaxBps,
            uint16 sellTaxBps,
            uint16 dividendBps,
            address pair,
            address refPair
        );
    function sales(address token)
        external
        view
        returns (
            address creator,
            uint64 progressAt,
            uint16 capShares,
            uint16 holdBps,
            address quote,
            uint16 sold,
            bool launched,
            uint16 mintFeeBps,
            uint16 exitFeeBps,
            address gate,
            uint128 sharePrice,
            address pair,
            address refPool,
            uint16 markSold
        );
}

interface IBondPair {
    function token0() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IBondToken {
    function buyTaxBps() external view returns (uint16);
    function sellTaxBps() external view returns (uint16);
}

interface IWBNBDeposit {
    function deposit() external payable;
}

/// @title GangBond (Agent 押金承诺)
/// @notice A creator of a GangLaunchpad token posts a bond in the token's quote and promises its creating address holds
///         at least `holdAmount` tokens. The bond can be posted any time after create — on the curve / during the 打新
///         sale too — and the promise holds from the post. Its deadline is `duration` after the token reaches its
///         Pancake pair (V3 graduation / 打新 launch): anyone `start`s the clock then (every other write does it too).
///         Endings:
///         - `settle` (anyone, at or after the deadline, while the balance still meets the promise): the whole bond goes
///           back to the creator;
///         - `report` (anyone, any time before settle, once the balance is below the promise — on the curve too): 1% to
///           the reporter (none when the creator reports itself), the rest bought back from the token's pair in small
///           chunks (`burnChunk`) and sent to 0xdead. Slashed before the pair: the buy-back waits for it; still no pair
///           MAX_WAIT after the post, the rest goes to 0xdead as quote;
///         - `refund` (creator, in two steps): posted before the pair and still no pair MAX_WAIT after the post, the
///           creator `requestRefund`s; REFUND_NOTICE later, still no pair and the promise kept, `refund` returns the
///           whole bond. The promise binds through the notice, and a graduation / launch during it cancels the request
///           (the clock starts instead), so the bond can't be pulled unseen right before the pair. No other early
///           withdrawal.
///         The time after the deadline and before `settle` still counts: a creator that sold before the deadline must
///         buy back before it can settle, and can be reported meanwhile.
/// @dev Not upgradeable, no owner. Reads only the pad's and the token's public views and trades only with the token's
///      pair (the pad's `curves` / `sales` pair: an untaxed V3 token never sets `token.pair()`). Changes nothing in the
///      pad, token, vault or tax handler and needs no role from them, so the pad can't tell it about a graduation: the
///      clock starts at the first `start` (or other write) after it, which the keeper sends right away — a late start
///      only makes the creator's commitment end later. The coverage views use the pair's spot reserves and never decide
///      where a bond goes; the buy-back checks the spot price against the pair's own TWAP.
contract GangBond is IGangBond, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    uint256 public constant BPS = 10_000;
    uint64 public constant MIN_DURATION = 7 days;
    uint64 public constant MAX_DURATION = 90 days;
    /// @notice Posted before the pair: how long the bond waits for it before `requestRefund` / the quote burn.
    uint64 public constant MAX_WAIT = 30 days;
    /// @notice A requested refund runs this long after the request (the promise binds meanwhile; buyers see it coming).
    uint64 public constant REFUND_NOTICE = 3 days;
    /// @notice Reporter's share of the bond.
    uint256 public constant REPORTER_BPS = 100;
    /// @notice One buy-back chunk spends at most this share of the pair's quote reserve (as the tax handler's chunks).
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
    uint8 internal constant KIND_FAIR = 2;

    address public immutable pad;
    address public immutable wbnb;

    /// @dev A token's pair and side, fixed once it graduated / launched (cached the first time GangBond sees it live).
    struct Market {
        address pair;
        bool tokenIs0;
    }

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

    struct History {
        uint32 posted;
        uint32 honored;
        uint32 slashed;
    }

    mapping(address token => Bond) internal _bonds;
    mapping(address token => Market) public marketOf;
    mapping(address token => Twap) internal _twaps;
    mapping(address token => uint256) public lastBurnBlock;
    mapping(address creator => History) internal _history;

    constructor(address pad_, address wbnb_) {
        if (pad_ == address(0) || wbnb_ == address(0)) revert ZeroAddress();
        pad = pad_;
        wbnb = wbnb_;
    }

    // ---------------------------------------------------------------- creator
    /// @notice Post a bond: `amount` of the token's quote (WBNB quote: native BNB as msg.value works too), promising
    ///         the creator holds at least `holdAmount` tokens from now until `duration` (7–90 days) after the token
    ///         reaches its pair — from now when it already has.
    function post(address token, uint256 amount, uint256 holdAmount, uint64 duration) external payable nonReentrant {
        (address creator, address quote, address pair, bool live) = _padView(token);
        if (msg.sender != creator) revert NotCreator();
        Bond storage b = _bonds[token];
        if (b.state == State.Active || b.burnLeft != 0) revert BondLive();
        if (amount == 0) revert ZeroAmount();
        if (duration < MIN_DURATION || duration > MAX_DURATION) revert BadDuration();
        if (holdAmount == 0 || holdAmount > IERC20(token).balanceOf(creator)) revert BadHold();
        uint64 deadline;
        if (live) {
            _cacheMarket(token, pair);
            deadline = uint64(block.timestamp) + duration;
        }

        uint32 round = b.round + 1;
        _bonds[token] = Bond({
            creator: creator,
            postedAt: uint64(block.timestamp),
            round: round,
            quote: quote,
            state: State.Active,
            deadline: deadline,
            duration: duration,
            refundAt: 0,
            amount: amount.toUint128(),
            holdAmount: holdAmount.toUint128(),
            burnLeft: 0
        });
        _history[creator].posted++;
        _pull(quote, amount);
        emit BondPosted(token, creator, round, quote, amount, holdAmount, duration, deadline);
    }

    /// @notice Add to the bond (it can never be reduced).
    function topUp(address token, uint256 amount) external payable nonReentrant {
        Bond storage b = _activeOf(token);
        if (msg.sender != b.creator) revert NotCreator();
        if (amount == 0) revert ZeroAmount();
        _begin(token, b);
        uint128 total = (uint256(b.amount) + amount).toUint128();
        b.amount = total;
        _pull(b.quote, amount);
        emit BondToppedUp(token, b.round, amount, total);
    }

    /// @notice Raise the promised holding, up to what the creator holds now.
    function raiseHold(address token, uint256 newHoldAmount) external nonReentrant {
        Bond storage b = _activeOf(token);
        if (msg.sender != b.creator) revert NotCreator();
        if (newHoldAmount < b.holdAmount || newHoldAmount > IERC20(token).balanceOf(b.creator)) revert BadHold();
        _begin(token, b);
        b.holdAmount = newHoldAmount.toUint128();
        emit HoldRaised(token, b.round, newHoldAmount);
    }

    /// @notice Lengthen the commitment by `by` seconds: before the pair, the duration (at most MAX_DURATION in all);
    ///         after it, the deadline (at most MAX_DURATION from now).
    function extend(address token, uint64 by) external nonReentrant {
        Bond storage b = _activeOf(token);
        if (msg.sender != b.creator) revert NotCreator();
        if (by == 0) revert BadDuration();
        _begin(token, b);
        if (b.deadline == 0) {
            if (b.duration + by > MAX_DURATION) revert BadDuration();
        } else {
            if (b.deadline + by > block.timestamp + MAX_DURATION) revert BadDuration();
            b.deadline += by;
        }
        b.duration += by;
        emit BondExtended(token, b.round, b.duration, b.deadline);
    }

    // ---------------------------------------------------------------- anyone
    /// @notice The token reached its pair: start the clock of a bond posted before it (deadline = now + duration).
    ///         Nothing to do once started; every other write starts it too.
    function start(address token) external nonReentrant {
        Bond storage b = _activeOf(token);
        if (b.deadline != 0) return;
        _begin(token, b);
        if (b.deadline == 0) revert NotTradable();
    }

    /// @notice The creator holds less than promised: slash the bond. 1% to the caller (none when the caller is the
    ///         creator), the rest is left for `burnChunk`. Works before the pair too.
    function report(address token) external nonReentrant {
        Bond storage b = _activeOf(token);
        uint256 bal = IERC20(token).balanceOf(b.creator);
        if (bal >= b.holdAmount) revert NotViolated();
        _begin(token, b);
        uint256 reward = msg.sender == b.creator ? 0 : (uint256(b.amount) * REPORTER_BPS) / BPS;
        uint128 left = b.amount - uint128(reward);
        b.state = State.Slashed;
        b.burnLeft = left;
        delete _twaps[token]; // a past round's observations: the first burnChunk records afresh
        _history[b.creator].slashed++;
        if (reward != 0) IERC20(b.quote).safeTransfer(msg.sender, reward);
        emit BondReported(token, b.round, msg.sender, bal, reward, left);
    }

    /// @notice At or after the deadline, while the creator still holds what it promised: the bond goes back to the
    ///         creator (never to the caller).
    function settle(address token) external nonReentrant {
        Bond storage b = _activeOf(token);
        _begin(token, b);
        if (b.deadline == 0) revert NotTradable();
        if (block.timestamp < b.deadline) revert NotDue();
        if (IERC20(token).balanceOf(b.creator) < b.holdAmount) revert Violated();
        // the pair holding fewer tokens than its reserve = mid flash swap: tokens borrowed from it must not pass
        Market memory m = marketOf[token];
        (uint112 r0, uint112 r1,) = IBondPair(m.pair).getReserves();
        if (IERC20(token).balanceOf(m.pair) < (m.tokenIs0 ? r0 : r1)) revert FlashSwapActive();
        b.state = State.Settled;
        _history[b.creator].honored++;
        IERC20(b.quote).safeTransfer(b.creator, b.amount);
        emit BondSettled(token, b.round, b.creator, b.amount);
    }

    /// @notice Posted before the pair and still no pair MAX_WAIT after the post: the creator asks for the bond back.
    ///         It can run REFUND_NOTICE from now; until then the promise binds, and the pair coming cancels it.
    function requestRefund(address token) external nonReentrant {
        Bond storage b = _activeOf(token);
        if (msg.sender != b.creator) revert NotCreator();
        _requireNoPair(token, b);
        if (b.refundAt != 0) revert AlreadyRequested();
        if (block.timestamp < b.postedAt + MAX_WAIT) revert NotDue();
        if (IERC20(token).balanceOf(b.creator) < b.holdAmount) revert Violated();
        uint64 at = uint64(block.timestamp) + REFUND_NOTICE;
        b.refundAt = at;
        emit RefundRequested(token, b.round, at);
    }

    /// @notice A requested refund, REFUND_NOTICE on, still no pair and the promise kept: the bond goes back to the
    ///         creator. Not counted as honored.
    function refund(address token) external nonReentrant {
        Bond storage b = _activeOf(token);
        if (msg.sender != b.creator) revert NotCreator();
        _requireNoPair(token, b);
        if (b.refundAt == 0) revert NoRefundRequest();
        if (block.timestamp < b.refundAt) revert NotDue();
        if (IERC20(token).balanceOf(b.creator) < b.holdAmount) revert Violated();
        b.state = State.Refunded;
        IERC20(b.quote).safeTransfer(b.creator, b.amount);
        emit BondRefunded(token, b.round, b.creator, b.amount);
    }

    /// @notice Spend one chunk of a slashed bond on the token, straight from its pair, and send what arrives (after the
    ///         buy tax) to 0xdead. One chunk per token per block, at most CHUNK_MAX_BPS of the pair's quote reserve.
    ///         Returns (0, 0) without buying while the price check is not ready: the first call after a slash only
    ///         records an observation; later ones wait until TWAP_WINDOW has passed since it, and skip while the spot
    ///         price is more than MAX_PRICE_RISE_BPS above the average. After more than 2 × TWAP_WINDOW without a call
    ///         the observations start over (that call records only), so the average never spans a long idle stretch.
    ///         Slashed before the pair: reverts NotTradable until it comes; still none MAX_WAIT after the post, the whole
    ///         rest goes to 0xdead as quote (`burned` 0).
    /// @param minTokensOut Least tokens to burn (after the buy tax); checked only when a chunk is bought.
    function burnChunk(address token, uint256 minTokensOut)
        external
        nonReentrant
        returns (uint256 quoteIn, uint256 burned)
    {
        Bond storage b = _bonds[token];
        if (b.state != State.Slashed || b.burnLeft == 0) revert NothingToBurn();
        if (lastBurnBlock[token] == block.number) revert BurnedThisBlock();
        Market memory m = marketOf[token];
        if (m.pair == address(0)) {
            (,, address pair, bool live) = _padView(token);
            if (!live) {
                if (block.timestamp < b.postedAt + MAX_WAIT) revert NotTradable();
                quoteIn = b.burnLeft;
                b.burnLeft = 0;
                IERC20(b.quote).safeTransfer(DEAD, quoteIn);
                emit BondBurned(token, b.round, quoteIn, 0, 0);
                return (quoteIn, 0);
            }
            m = _cacheMarket(token, pair);
        }
        (uint256 rT, uint256 rQ, uint256 cum) = _pairState(m);
        Twap memory w = _twaps[token];
        uint32 seen = w.recent.at;
        (Twap memory next, bool ok) = _twapCheck(w, cum, rT, rQ);
        // every roll or restart moves `recent` to now: write only then
        if (next.recent.at != seen) _twaps[token] = next;
        if (!ok) return (0, 0);
        quoteIn = _chunkOf(b.burnLeft, rQ);
        if (quoteIn == 0) return (0, 0);

        lastBurnBlock[token] = block.number;
        uint128 left = b.burnLeft - uint128(quoteIn);
        b.burnLeft = left;
        uint256 out = _amountOut(quoteIn, rQ, rT);
        IERC20(b.quote).safeTransfer(m.pair, quoteIn);
        // a chunk too small to buy one token unit is left in the pair as a donation (only ever a last dust chunk)
        if (out != 0) {
            uint256 before = IERC20(token).balanceOf(address(this));
            if (m.tokenIs0) IBondPair(m.pair).swap(out, 0, address(this), "");
            else IBondPair(m.pair).swap(0, out, address(this), "");
            burned = IERC20(token).balanceOf(address(this)) - before;
            if (burned < minTokensOut) revert Slippage();
            IERC20(token).safeTransfer(DEAD, burned);
        }
        emit BondBurned(token, b.round, quoteIn, burned, left);
    }

    // ---------------------------------------------------------------- views
    function bondOf(address token) external view returns (Bond memory) {
        return _bonds[token];
    }

    function isViolated(address token) external view returns (bool) {
        Bond storage b = _bonds[token];
        return b.state == State.Active && IERC20(token).balanceOf(b.creator) < b.holdAmount;
    }

    /// @inheritdoc IGangBond
    function isLive(address token) external view returns (bool live) {
        (,,, live) = _padView(token);
    }

    /// @notice What the creator would get selling its promised holding into the pair now (Active bonds of a token on its
    ///         pair; 0 otherwise — before the pair there is no market to sell into).
    function dumpValue(address token) public view returns (uint256 quoteOut) {
        Bond storage b = _bonds[token];
        if (b.state != State.Active) return 0;
        (Market memory m, bool live) = _liveMarket(token);
        if (!live) return 0;
        return _dump(token, m, b.holdAmount);
    }

    /// @notice Bond ÷ dumpValue in bps (Active bonds of a token on its pair; 0 otherwise). Above 10_000: dumping the
    ///         holding loses money.
    function coverageBps(address token) external view returns (uint256) {
        Bond storage b = _bonds[token];
        if (b.state != State.Active) return 0;
        (Market memory m, bool live) = _liveMarket(token);
        if (!live) return 0;
        uint256 dv = _dump(token, m, b.holdAmount);
        if (dv == 0) return type(uint256).max;
        return (uint256(b.amount) * BPS) / dv;
    }

    function historyOf(address creator) external view returns (uint32 posted, uint32 honored, uint32 slashed) {
        History memory h = _history[creator];
        return (h.posted, h.honored, h.slashed);
    }

    /// @inheritdoc IGangBond
    function quoteDump(address token, uint256 holdAmount) public view returns (uint256 quoteOut) {
        (Market memory m, bool live) = _liveMarket(token);
        if (!live) revert NotTradable();
        return _dump(token, m, holdAmount);
    }

    /// @inheritdoc IGangBond
    function previewBurn(address token) external view returns (bool ready, uint256 quoteIn, uint256 tokensOut) {
        Bond storage b = _bonds[token];
        if (b.state != State.Slashed || b.burnLeft == 0 || lastBurnBlock[token] == block.number) return (false, 0, 0);
        (Market memory m, bool live) = _liveMarket(token);
        if (!live) {
            if (block.timestamp < b.postedAt + MAX_WAIT) return (false, 0, 0);
            return (true, b.burnLeft, 0);
        }
        (uint256 rT, uint256 rQ, uint256 cum) = _pairState(m);
        (, ready) = _twapCheck(_twaps[token], cum, rT, rQ);
        if (!ready) return (false, 0, 0);
        quoteIn = _chunkOf(b.burnLeft, rQ);
        if (quoteIn == 0) return (false, 0, 0);
        uint256 out = _amountOut(quoteIn, rQ, rT);
        tokensOut = out - (out * IBondToken(token).buyTaxBps()) / BPS;
    }

    // ---------------------------------------------------------------- internal
    function _activeOf(address token) internal view returns (Bond storage b) {
        b = _bonds[token];
        if (b.state != State.Active) revert NotActive();
    }

    /// @dev Start the clock of a pending bond once its token is on the pair (deadline = now + duration); a requested
    ///      refund is void from then.
    function _begin(address token, Bond storage b) internal {
        if (b.deadline != 0) return;
        (,, address pair, bool live) = _padView(token);
        if (!live) return;
        _cacheMarket(token, pair);
        uint64 deadline = uint64(block.timestamp) + b.duration;
        b.deadline = deadline;
        b.refundAt = 0;
        emit BondStarted(token, b.round, deadline);
    }

    /// @dev A refund needs the bond still pending and the token still off its pair.
    function _requireNoPair(address token, Bond storage b) internal view {
        if (b.deadline != 0) revert AlreadyLive();
        (,,, bool live) = _padView(token);
        if (live) revert AlreadyLive();
    }

    /// @dev The creator, quote and pair of a pad token, and whether it is on its pair yet (V3 graduated / 打新
    ///      launched; the pair is 0 before that).
    function _padView(address token) internal view returns (address creator, address quote, address pair, bool live) {
        uint8 kind = IGangPadBondView(pad).kindOf(token);
        if (kind == KIND_CURVE) {
            (creator, quote,,,,, live,,,, pair,) = IGangPadBondView(pad).curves(token);
        } else if (kind == KIND_FAIR) {
            (creator,,,, quote,, live,,,,, pair,,) = IGangPadBondView(pad).sales(token);
        } else {
            revert UnknownToken();
        }
    }

    function _cacheMarket(address token, address pair) internal returns (Market memory m) {
        m = marketOf[token];
        if (m.pair != address(0)) return m;
        m = Market(pair, IBondPair(pair).token0() == token);
        marketOf[token] = m;
    }

    /// @dev The token's market when it is on its pair (cached, or read from the pad without caching).
    function _liveMarket(address token) internal view returns (Market memory m, bool live) {
        m = marketOf[token];
        if (m.pair != address(0)) return (m, true);
        (,, address pair, bool l) = _padView(token);
        if (!l) return (m, false);
        return (Market(pair, IBondPair(pair).token0() == token), true);
    }

    function _dump(address token, Market memory m, uint256 holdAmount) internal view returns (uint256) {
        (uint256 rT, uint256 rQ,) = _pairState(m);
        uint256 xIn = holdAmount - (holdAmount * IBondToken(token).sellTaxBps()) / BPS;
        return _amountOut(xIn, rT, rQ);
    }

    /// @dev Reserves (token side, quote side) and the quote-per-token cumulative price as of this block.
    function _pairState(Market memory m) internal view returns (uint256 rT, uint256 rQ, uint256 cum) {
        (uint112 r0, uint112 r1, uint32 last) = IBondPair(m.pair).getReserves();
        (rT, rQ) = m.tokenIs0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        cum = m.tokenIs0 ? IBondPair(m.pair).price0CumulativeLast() : IBondPair(m.pair).price1CumulativeLast();
        uint32 now32 = uint32(block.timestamp);
        // Uniswap V2 oracle arithmetic: the cumulative and the uint32 clock wrap by design
        unchecked {
            if (last != now32 && rT != 0) cum += ((rQ << 112) / rT) * uint32(now32 - last);
        }
    }

    /// @dev Roll the observations forward and say whether a chunk may be bought now: there is an average over
    ///      TWAP_WINDOW to 2 × TWAP_WINDOW and the spot price is at most MAX_PRICE_RISE_BPS above it. A newest observation
    ///      older than 2 × TWAP_WINDOW (no call for a while) restarts both: an average over a long idle stretch would
    ///      let a price that fell since then be pushed back up and sold into the buy-back.
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

    function _chunkOf(uint256 burnLeft, uint256 rQ) internal pure returns (uint256) {
        uint256 max = (rQ * CHUNK_MAX_BPS) / BPS;
        return burnLeft < max ? burnLeft : max;
    }

    /// @dev Pancake V2 getAmountOut (0 for an empty side).
    function _amountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint256) {
        if (reserveIn == 0 || reserveOut == 0) return 0;
        uint256 inWithFee = amountIn * DEX_FEE_NUM;
        return (inWithFee * reserveOut) / (reserveIn * DEX_FEE_DEN + inWithFee);
    }

    /// @dev Take `amount` of `quote` from the caller: native BNB for a WBNB quote (exactly `amount`), otherwise a
    ///      transfer that must arrive in full (a quote that charges on transfer is refused).
    function _pull(address quote, uint256 amount) internal {
        if (msg.value != 0) {
            if (quote != wbnb || msg.value != amount) revert BadValue();
            IWBNBDeposit(wbnb).deposit{value: amount}();
            return;
        }
        uint256 before = IERC20(quote).balanceOf(address(this));
        IERC20(quote).safeTransferFrom(msg.sender, address(this), amount);
        if (IERC20(quote).balanceOf(address(this)) - before != amount) revert FeeOnTransferQuote();
    }
}
