// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IGangPadBondView, IBondPair, IBondToken} from "./GangBond.sol";
import {IGangPad} from "./interfaces/IGangPad.sol";
import {IGangPadHandler} from "./interfaces/IGangPadDeps.sol";
import {IGangRecipientModule} from "./interfaces/IGangRecipientModule.sol";
import {IQuoteRegistryView} from "./GangSplitModule.sol";
import {ILpPair} from "./GangLiquiditySplitter.sol";

/// @title GangCappedSplitter (税收封顶：dev 拿满上限后，税全部回到币上)
/// @notice The tax recipient of one V3 (curve) token whose payees' take has a cap fixed for good: of every quote it
///         receives, `payBps` goes to 1–MAX_PAYEES payees at fixed shares until they have been credited `capAmount`
///         in all (counted when split, owed or pushed alike); the rest — and, once the cap is reached, all of it — is
///         set aside for buy-back-and-burn (`buybackOfRestBps` of it) and liquidity locked at 0xdead (the remainder).
///         The split that crosses the cap pays the payees exactly what is left of it. Everything is fixed when it is
///         cloned — nobody, not the dev, not the platform, can change the cap, its quote, the ratios, the payees or
///         their shares — except that each payee may move its own slot (`setPayee`), which leaves the cap as it is.
///         A clone, set up as the others are: the factory clones and lists it, the dev creates the token with it as
///         `recipient`, anyone `bind`s it (only a token whose quote is `capQuote`).
///         The cap covers only this recipient's part of the pool tax: not the creator's share of the curve fee, not
///         the dev's own tokens, not the holders' dividend.
///         The chunks are GangComboSplitter's: one chunk (a buy-back or a liquidity add) per CHUNK_GAP, each at most
///         CHUNK_MAX_BPS of the pair's quote reserve, none while the spot price is more than MAX_PRICE_RISE_BPS above
///         the pair's own TWAP, always of the larger set-aside part; the keeper's `work` does the one action
///         `previewWork` planned and encoded in `minOut`'s top byte.
///         Assets other than the bound quote can't count against the cap: all of each such asset goes to 0xdead (one
///         that can't be sent there stays here), so a token the dev binds as a decoy can't route the real token's
///         tax around the cap to the payees.
/// @dev Not upgradeable (an EIP-1167 clone of a fixed implementation), no owner. Needs no role from the pad, token,
///      vault or handler. Copied from GangComboSplitter (combo-v1, audited and live); only the split, `bind`'s quote
///      check and the handling of other assets differ. The chunk code is GangBuybackSplitter v4's and
///      GangLiquiditySplitter's, the push code GangSplitModule's, the price math GangBond's: change them together.
contract GangCappedSplitter is IGangRecipientModule, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_PAYEES = 10;
    /// @notice Gas given to each push (GangSplitModule's: a refusal that burns its gas costs at most this per payee).
    uint256 public constant PUSH_GAS = 300_000;
    /// @notice A push starts only with at least PUSH_GAS × 64/63 + this left (else PushStarved).
    uint256 public constant PUSH_RESERVE = 60_000;
    /// @notice One chunk spends at most this share of the pair's quote reserve.
    uint256 public constant CHUNK_MAX_BPS = 50;
    /// @notice A chunk compares the spot price with the pair's average over at least this long.
    uint32 public constant TWAP_WINDOW = 10 minutes;
    /// @notice At most one chunk (of either kind) per this long (GangBond audit 2026-10-29 H-1).
    uint64 public constant CHUNK_GAP = 4 minutes;
    /// @notice No chunk while the spot price is more than this above that average.
    uint256 public constant MAX_PRICE_RISE_BPS = 200;
    /// @dev Pancake V2 fee (9975/10000 = 0.25%).
    uint256 public constant DEX_FEE_NUM = 9975;
    uint256 public constant DEX_FEE_DEN = 10_000;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    /// @notice `previewWork`'s `minOut`: the previewed buy less this, for a trade earlier in the same block.
    uint256 public constant WORK_SLIPPAGE_BPS = 100;
    /// @notice The keeper acts on a part (a chunk, or the payees' pending split) once it reaches this share of the
    ///         pair's quote reserve…
    uint256 public constant WORK_MIN_BPS = 5;
    /// @notice …or, for the payees' part, WORK_MAX_IDLE after the last payout once it reaches 1/WORK_IDLE_DIV of that.
    uint64 public constant WORK_MAX_IDLE = 1 days;
    uint256 public constant WORK_IDLE_DIV = 100;
    bytes32 public constant MODULE_TYPE = "capped-v1";

    uint8 internal constant KIND_CURVE = 1;
    /// @dev What `work` does (`_plan`).
    uint8 internal constant DO_NOTHING = 0;
    uint8 internal constant DO_BURN = 1;
    uint8 internal constant DO_ADD = 2;
    uint8 internal constant DO_OBSERVE = 3;
    uint8 internal constant DO_SPLIT = 4;

    address public immutable pad;
    address public immutable taxHandler;
    /// @notice The factory that deployed the implementation: the only caller of a clone's `initialize`.
    address public immutable factory;
    address internal immutable _self;
    /// @notice The quotes the keeper serves besides the pad's WBNB and the QuoteRegistry's (as GangSplitModule).
    address public immutable gangQuote;
    address internal immutable _wbnb;
    address internal immutable _quoteRegistry;

    /// @notice The dev it was made for (the token's creator once bound).
    address public dev;
    /// @notice The bound token, its quote and its pair (the pair cached at the first chunk after graduation).
    address public token;
    bool internal _tokenIs0;
    address public quote;
    address public pair;
    /// @notice The quote the cap is counted in, fixed at clone: `bind` takes only a token with this quote.
    address public capQuote;
    /// @notice The most the payees are ever credited, in all, in `capQuote`'s smallest unit (fixed).
    uint256 public capAmount;
    /// @notice What the payees are credited so far (pushed or owed). Only grows; never above `capAmount`.
    uint256 public paidTotal;
    /// @notice Share of the incoming quote that goes to the payees while the cap is not reached (fixed).
    uint16 public payBps;
    /// @notice Of the rest, the share set aside for the buy-back; the liquidity gets the remainder (fixed).
    uint16 public buybackOfRestBps;
    address[] internal _payees;
    uint16[] internal _shares;
    /// @notice Quote set aside and not spent yet.
    uint256 public buybackLeft;
    uint256 public lpLeft;
    /// @dev Per asset, what each payee slot is owed after a failed push.
    mapping(address asset => mapping(uint256 index => uint256)) internal _owed;
    /// @notice Per asset, Σ owed.
    mapping(address asset => uint256) public owedTotal;
    /// @notice When the last chunk of either kind ran (0: none yet).
    uint64 public lastChunkAt;
    /// @notice When the payees' part of the bound quote was last paid out (0: never).
    uint64 public lastPaidAt;

    struct Obs {
        uint256 cumulative;
        uint32 at;
    }

    struct Twap {
        Obs old;
        Obs recent;
    }

    Twap internal _twap;

    event Bound(address indexed token, address indexed quote);
    /// @notice The bound quote that arrived: `toBuyback` and `toLp` set aside, `toPayees` pushed (or owed) and counted
    ///         against the cap. Same fields in the same order as GangComboSplitter's Split: the two share one topic
    ///         (the topic hashes the types only), so one decoder reads both without mixing the fields up.
    event Split(uint256 incoming, uint256 toBuyback, uint256 toLp, uint256 toPayees);
    /// @notice The payees were credited the whole cap: from now on all of the quote goes to the buy-back and liquidity.
    event CapReached(uint256 capAmount);
    /// @notice Another asset: `toDead` (all of it, or 0 when it can't be sent there and it stays here) sent to 0xdead.
    ///         The combo's event has the same topic, but there a `toDead` below `incoming` means the rest went to the
    ///         payees: here it never does — read it by `moduleType`.
    event Distributed(address indexed asset, uint256 incoming, uint256 toDead);
    event PayeeOwed(address indexed asset, uint256 indexed index, uint256 amount);
    event PayeeReleased(address indexed asset, uint256 indexed index, uint256 amount);
    event PayeeChanged(uint256 indexed index, address indexed oldPayee, address indexed newPayee);
    /// @notice A balance under what was held; every held part shrank in proportion.
    event Shortfall(address indexed asset, uint256 amount);
    event BoughtBack(uint256 quoteIn, uint256 burned, uint256 left);
    event LiquidityAdded(uint256 quoteIn, uint256 tokensIn, uint256 liquidity, uint256 left);

    error ZeroAddress();
    error NotClone();
    error NotFactory();
    error AlreadyInitialized();
    error BadBps();
    error BadPayees();
    error BadShares();
    error BadPayee();
    error DuplicatePayee();
    error BadIndex();
    error NotPayee();
    error AlreadyBound();
    error NotBound();
    error NotCurve();
    error NotCreator();
    error NotRecipient();
    error NothingOwed();
    error NothingToChunk();
    error ChunkTooSoon();
    error NotTradable();
    error Slippage();
    error PushStarved();
    error BadCap();
    error WrongQuote();
    error BadQuote();

    /// @dev The implementation, deployed by the factory; it is never initialized itself.
    constructor(address pad_, address gangQuote_) {
        if (pad_ == address(0)) revert ZeroAddress();
        pad = pad_;
        taxHandler = IGangPad(pad_).taxHandler();
        factory = msg.sender;
        _self = address(this);
        gangQuote = gangQuote_;
        _wbnb = IGangPad(pad_).wbnb();
        _quoteRegistry = IGangPad(pad_).quoteRegistry();
    }

    /// @notice A clone's setup, by the factory in the tx that clones it. `capQuote_` a quote the keeper serves (the
    ///         pad's WBNB, `gangQuote` or a QuoteRegistry quote: else BadQuote — a dev's own quote token could move the
    ///         set-aside parts out, and a typo could never be bound; audit 2026-11-08 L-1), `capAmount_` above 0,
    ///         `payBps_` 1–BPS, `buybackOfRestBps_` at most BPS; 1–MAX_PAYEES distinct payees (none 0, none this
    ///         contract), each share at least 1 bps, summing to BPS.
    function initialize(
        address dev_,
        address capQuote_,
        uint256 capAmount_,
        uint16 payBps_,
        uint16 buybackOfRestBps_,
        address[] calldata payees_,
        uint16[] calldata shares_
    ) external {
        if (address(this) == _self) revert NotClone();
        if (msg.sender != factory) revert NotFactory();
        if (dev != address(0)) revert AlreadyInitialized();
        if (dev_ == address(0) || capQuote_ == address(0)) revert ZeroAddress();
        if (!keeperServes(capQuote_)) revert BadQuote();
        if (capAmount_ == 0) revert BadCap();
        if (payBps_ == 0 || payBps_ > BPS || buybackOfRestBps_ > BPS) revert BadBps();
        uint256 n = payees_.length;
        if (n == 0 || shares_.length != n || n > MAX_PAYEES) revert BadPayees();
        uint256 sum;
        for (uint256 i; i < n; i++) {
            address p = payees_[i];
            if (p == address(0)) revert ZeroAddress();
            if (p == address(this)) revert BadPayee();
            for (uint256 j; j < i; j++) {
                if (payees_[j] == p) revert DuplicatePayee();
            }
            if (shares_[i] == 0) revert BadShares();
            sum += shares_[i];
        }
        if (sum != BPS) revert BadShares();
        dev = dev_;
        capQuote = capQuote_;
        capAmount = capAmount_;
        payBps = payBps_;
        buybackOfRestBps = buybackOfRestBps_;
        _payees = payees_;
        _shares = shares_;
    }

    function moduleType() external pure returns (bytes32) {
        return MODULE_TYPE;
    }

    // ---------------------------------------------------------------- a payee
    /// @notice Move slot `index` to `newPayee` (only that slot's payee, at once): the bound quote that arrived before
    ///         is split first and paid to the old address; what the slot is owed (only ever the bound quote) goes to
    ///         the new one. The cap and the slot's share stay as they are.
    function setPayee(uint256 index, address newPayee) external nonReentrant {
        if (index >= _payees.length) revert BadIndex();
        if (msg.sender != _payees[index]) revert NotPayee();
        if (newPayee == address(0)) revert ZeroAddress();
        if (newPayee == address(this)) revert BadPayee();
        for (uint256 j; j < _payees.length; j++) {
            if (_payees[j] == newPayee) revert DuplicatePayee();
        }
        _splitQuote();
        emit PayeeChanged(index, msg.sender, newPayee);
        _payees[index] = newPayee;
    }

    // ---------------------------------------------------------------- anyone
    /// @notice Bind the dev's token (once): a V3 token the dev created with this contract as its tax recipient, quoted
    ///         in `capQuote` (else WrongQuote: the cap would be counted in another unit).
    function bind(address token_) external {
        if (token != address(0)) revert AlreadyBound();
        if (IGangPadBondView(pad).kindOf(token_) != KIND_CURVE) revert NotCurve();
        (address creator, address quote_,,,,,,,,,,) = IGangPadBondView(pad).curves(token_);
        if (creator != dev) revert NotCreator();
        if (quote_ != capQuote) revert WrongQuote();
        (, address recipient) = IGangPadHandler(taxHandler).routeOf(token_);
        if (recipient != address(this)) revert NotRecipient();
        token = token_;
        quote = quote_;
        emit Bound(token_, quote_);
    }

    /// @notice Split the bound quote that arrived: the buy-back and liquidity parts set aside, the payees paid.
    function split() external nonReentrant {
        _splitQuote();
    }

    /// @notice Split `asset` that arrived (the bound quote: as `split`; any other: all of it to 0xdead, none to the
    ///         payees — it can't count against the cap).
    function distribute(address asset) external nonReentrant returns (uint256 incoming) {
        // before `bind` the quote is unknown: the tax already here must not be split as another asset (re-review)
        if (quote == address(0)) revert NotBound();
        if (asset == quote) {
            _splitQuote();
            return 0;
        }
        return _distribute(asset);
    }

    /// @notice Split the bound quote first (a shortfall is shared before anything leaves), then push up to
    ///         `maxAmount` of what slot `index` is owed to its payee (type(uint256).max: all of it; reverts while it
    ///         still can't receive). Payees are only ever owed the bound quote: any other `asset` reverts NothingOwed.
    function release(address asset, uint256 index, uint256 maxAmount) external nonReentrant returns (uint256 amount) {
        if (quote == address(0)) revert NotBound();
        if (index >= _payees.length) revert BadIndex();
        if (asset != quote) revert NothingOwed();
        _splitQuote();
        uint256 owed = _owed[asset][index];
        amount = owed < maxAmount ? owed : maxAmount;
        if (amount == 0) revert NothingOwed();
        _owed[asset][index] = owed - amount;
        owedTotal[asset] -= amount;
        IERC20(asset).safeTransfer(_payees[index], amount);
        emit PayeeReleased(asset, index, amount);
    }

    /// @notice Split, then one chunk of the larger set-aside part: a buy-back (GangBuybackSplitter v4's `burnChunk`:
    ///         buy from the pair, send to 0xdead) or a liquidity add (GangLiquiditySplitter's `addChunk`: half buys,
    ///         all of it goes back, the matching quote follows, LP to 0xdead). One per CHUNK_GAP for both kinds
    ///         (sooner reverts ChunkTooSoon). Returns zeros while the price check is not ready. Reverts NotTradable
    ///         before graduation. Gas: a liquidity chunk takes ~0.55–0.75M on a real pair: use the node's estimate.
    /// @param minTokensOut Least tokens the chunk's buy brings in (after the buy tax; for a liquidity chunk, its half),
    ///        scaled down to what the pair received.
    /// @return burn Whether it was a buy-back (else a liquidity add).
    /// @return quoteIn Quote spent.
    /// @return tokensOut Tokens burned, or tokens the pair received back.
    /// @return liquidity LP minted to 0xdead (a liquidity add).
    function chunk(uint256 minTokensOut)
        external
        nonReentrant
        returns (bool burn, uint256 quoteIn, uint256 tokensOut, uint256 liquidity)
    {
        _splitQuote();
        uint8 kind = _kindOf(buybackLeft, lpLeft);
        if (kind == DO_NOTHING) revert NothingToChunk();
        if (kind == DO_BURN) {
            (quoteIn, tokensOut) = _burnChunk(minTokensOut);
            return (true, quoteIn, tokensOut, 0);
        }
        (quoteIn, tokensOut, liquidity) = _addChunk(minTokensOut);
    }

    /// @notice IGangRecipientModule's step: split, then the action `previewWork` planned (in `minOut`'s top byte, its
    ///         value below) if this state still leads to it — a chunk, a TWAP observation, or nothing more; else only
    ///         the split (the keeper previews again next run).
    function work(uint256 minOut) external nonReentrant {
        _splitQuote();
        (uint8 action,,) = _plan(buybackLeft, lpLeft, 0);
        if (action != uint8(minOut >> 248)) return;
        minOut &= (uint256(1) << 248) - 1;
        if (action == DO_BURN) {
            _burnChunk(minOut);
        } else if (action == DO_ADD) {
            _addChunk(minOut);
        } else if (action == DO_OBSERVE) {
            (address p, bool tokenIs0) = _pairOf();
            (uint256 rT, uint256 rQ, uint256 cum) = _pairState(p, tokenIs0);
            (Twap memory next,) = _twapCheck(_twap, cum, rT, rQ);
            _twap = next;
        }
    }

    // ---------------------------------------------------------------- views
    function payeesOf() external view returns (address[] memory payees, uint16[] memory shares) {
        return (_payees, _shares);
    }

    function owedOf(address asset, uint256 index) external view returns (uint256) {
        return _owed[asset][index];
    }

    /// @notice What is left of the cap (0 once reached).
    function capLeft() external view returns (uint256) {
        return capAmount - paidTotal;
    }

    /// @notice Whether the payees have been credited the whole cap.
    function capReached() external view returns (bool) {
        return paidTotal == capAmount;
    }

    /// @notice The bound quote that arrived and is not split yet.
    function unsplit() public view returns (uint256) {
        if (quote == address(0)) return 0;
        uint256 bal = IERC20(quote).balanceOf(address(this));
        uint256 held = buybackLeft + lpLeft + owedTotal[quote];
        return bal > held ? bal - held : 0;
    }

    /// @notice What `distribute(asset)` would act on: the bound quote's `unsplit`; any other asset's whole balance
    ///         (nothing of it is ever owed or set aside; `distribute` sends it to 0xdead). Before `bind` the bound quote
    ///         is not known yet, so `capQuote` reads as another asset here while `distribute` reverts NotBound.
    function undistributed(address asset) external view returns (uint256) {
        if (asset == quote) return unsplit();
        return IERC20(asset).balanceOf(address(this));
    }

    /// @notice Whether the keeper serves `q`: the pad's WBNB, `gangQuote`, or a QuoteRegistry quote.
    function keeperServes(address q) public view returns (bool) {
        if (q == address(0)) return false;
        if (q == _wbnb || q == gangQuote) return true;
        return _quoteRegistry != address(0) && IQuoteRegistryView(_quoteRegistry).isQuoted(q);
    }

    /// @notice What `chunk` would do now (after the split it starts with): whether it trades, whether it is a
    ///         buy-back (else a liquidity add), the chunk's quote (a liquidity chunk: both halves at most) and the
    ///         tokens its buy brings in after the buy tax.
    function previewChunk() external view returns (bool ready, bool burn, uint256 amount, uint256 tokensOut) {
        (uint256 bb, uint256 lp,) = _afterSplit();
        uint8 kind = _kindOf(bb, lp);
        if (kind == DO_NOTHING) return (false, false, 0, 0);
        burn = kind == DO_BURN;
        (ready, amount, tokensOut) = _previewChunk(burn ? bb : lp, !burn);
    }

    /// @notice Due when `work` would act: a chunk (of the larger part, when it is at least WORK_MIN_BPS of the pair's
    ///         quote reserve; value = its tokens out less WORK_SLIPPAGE_BPS); else the TWAP observation it needs; else
    ///         the payees' pending part at least WORK_MIN_BPS of that reserve, or 1/WORK_IDLE_DIV of it WORK_MAX_IDLE
    ///         after the last payout. `minOut` = the action in its top byte, the value below: pass it to `work` as is.
    ///         Never for a quote the keeper doesn't serve, or before graduation; once the cap is reached the payees' part
    ///         is always 0, so it is never a split.
    function previewWork() external view returns (bool due, uint256 minOut) {
        if (!keeperServes(quote)) return (false, 0);
        (uint256 bb, uint256 lp, uint256 pay) = _afterSplit();
        (uint8 action, uint256 value,) = _plan(bb, lp, pay);
        if (action == DO_NOTHING) return (false, 0);
        return (true, (uint256(action) << 248) | value);
    }

    // ---------------------------------------------------------------- internal: the split
    /// @dev The bound quote: held = the two set-aside parts and what payees are owed; a balance under it shrinks every
    ///      held part in proportion; what arrived above it is split.
    function _splitQuote() internal {
        address q = quote;
        if (q == address(0)) return;
        uint256 bal = IERC20(q).balanceOf(address(this));
        uint256 owed = owedTotal[q];
        uint256 held = buybackLeft + lpLeft + owed;
        if (bal < held) {
            uint256 n = _payees.length;
            uint256 total;
            for (uint256 i; i < n; i++) {
                uint256 o = _owed[q][i];
                if (o == 0) continue;
                o = (o * bal) / held;
                _owed[q][i] = o;
                total += o;
            }
            owedTotal[q] = total;
            uint256 lp = (lpLeft * bal) / held;
            lpLeft = lp;
            buybackLeft = bal - total - lp;
            emit Shortfall(q, held - bal);
            return;
        }
        uint256 incoming = bal - held;
        if (incoming == 0) return;
        uint256 paid = paidTotal;
        (uint256 toPayees, uint256 toBuyback, uint256 toLp) = _partsOf(incoming, paid);
        buybackLeft += toBuyback;
        lpLeft += toLp;
        if (toPayees != 0) {
            // counted before the push: a payee that refuses is owed, and what it is owed is part of the cap (K-6)
            paid += toPayees;
            paidTotal = paid;
            _payAll(q, toPayees);
            lastPaidAt = uint64(block.timestamp);
        }
        emit Split(incoming, toBuyback, toLp, toPayees);
        if (toPayees != 0 && paid == capAmount) emit CapReached(paid);
    }

    /// @dev How `incoming` of the bound quote splits with `paid` already credited: the payees' `payBps`, at most what
    ///      is left of the cap; of the rest, `buybackOfRestBps` to the buy-back and the remainder to the liquidity.
    ///      `_splitQuote` and `_afterSplit` both use it, so a preview always matches the split that follows.
    function _partsOf(uint256 incoming, uint256 paid)
        internal
        view
        returns (uint256 toPayees, uint256 toBuyback, uint256 toLp)
    {
        toPayees = (incoming * payBps) / BPS;
        uint256 left = capAmount - paid;
        if (toPayees > left) toPayees = left;
        uint256 rest = incoming - toPayees;
        toBuyback = (rest * buybackOfRestBps) / BPS;
        toLp = rest - toBuyback;
    }

    /// @dev `(buybackLeft, lpLeft, payees' part)` as `_splitQuote` would leave them now.
    function _afterSplit() internal view returns (uint256 bb, uint256 lp, uint256 pay) {
        bb = buybackLeft;
        lp = lpLeft;
        address q = quote;
        if (q == address(0)) return (bb, lp, 0);
        uint256 bal = IERC20(q).balanceOf(address(this));
        uint256 owed = owedTotal[q];
        uint256 held = bb + lp + owed;
        if (bal < held) {
            uint256 n = _payees.length;
            uint256 total;
            for (uint256 i; i < n; i++) {
                total += (_owed[q][i] * bal) / held;
            }
            lp = (lp * bal) / held;
            return (bal - total - lp, lp, 0);
        }
        (uint256 toPayees, uint256 toBuyback, uint256 toLp) = _partsOf(bal - held, paidTotal);
        return (bb + toBuyback, lp + toLp, toPayees);
    }

    /// @dev Another asset: all of it to 0xdead (left here when it can't be sent there). Nothing of it is ever owed to
    ///      a payee, so the whole balance is what arrived.
    function _distribute(address asset) internal returns (uint256 incoming) {
        incoming = IERC20(asset).balanceOf(address(this));
        if (incoming == 0) return 0;
        uint256 toDead = _tryTransfer(asset, DEAD, incoming) ? incoming : 0;
        emit Distributed(asset, incoming, toDead);
    }

    /// @dev `amount` of `asset` to the payees at their shares: the others rounded down, the first takes the rest.
    function _payAll(address asset, uint256 amount) internal {
        uint256 left = amount;
        for (uint256 i = _payees.length; i > 1;) {
            unchecked {
                --i;
            }
            uint256 part = (amount * _shares[i]) / BPS;
            left -= part;
            _pay(asset, i, part);
        }
        _pay(asset, 0, left);
    }

    /// @dev GangSplitModule's `_pay`: push; on success push what the slot is owed too, on its own.
    function _pay(address asset, uint256 i, uint256 amount) internal {
        if (amount == 0) return;
        address to = _payees[i];
        if (!_tryTransfer(asset, to, amount)) {
            _owed[asset][i] += amount;
            owedTotal[asset] += amount;
            emit PayeeOwed(asset, i, amount);
            return;
        }
        uint256 owed = _owed[asset][i];
        if (owed != 0 && _tryTransfer(asset, to, owed)) {
            _owed[asset][i] = 0;
            owedTotal[asset] -= owed;
            emit PayeeReleased(asset, i, owed);
        }
    }

    /// @dev GangSplitModule's `_tryTransfer`: at most PUSH_GAS, at most 32 bytes of return copied, PushStarved before a
    ///      push that could not get its whole PUSH_GAS.
    function _tryTransfer(address asset, address to, uint256 amount) internal returns (bool ok) {
        bytes memory data = abi.encodeCall(IERC20.transfer, (to, amount));
        uint256 size;
        uint256 word;
        if (gasleft() < (PUSH_GAS * 64) / 63 + PUSH_RESERVE) revert PushStarved();
        assembly ("memory-safe") {
            ok := call(PUSH_GAS, asset, 0, add(data, 32), mload(data), 0, 32)
            size := returndatasize()
            word := mload(0)
        }
        if (!ok) return false;
        if (size == 0) return asset.code.length > 0;
        return size >= 32 && word == 1;
    }

    // ---------------------------------------------------------------- internal: the keeper's plan
    /// @dev What `work` does with these parts (after the split): a chunk of the larger part worth a call
    ///      (WORK_MIN_BPS of the reserve) when the price check is ready, else an observation it needs, else a split
    ///      that pays `pay` to the payees when it is worth a call. Returns the action, its `minOut` and the reserve.
    function _plan(uint256 bb, uint256 lp, uint256 pay)
        internal
        view
        returns (uint8 action, uint256 minOut, uint256 rQ)
    {
        if (token == address(0)) return (DO_NOTHING, 0, 0);
        (address p, bool tokenIs0, bool live) = _pairView();
        if (!live) return (DO_NOTHING, 0, 0);
        uint256 rT;
        uint256 cum;
        (rT, rQ, cum) = _pairState(p, tokenIs0);
        uint256 floor = rQ * WORK_MIN_BPS;
        uint8 kind = _kindOf(bb, lp);
        bool burn = kind == DO_BURN;
        if (kind != DO_NOTHING && (burn ? bb : lp) * BPS >= floor && !_tooSoon()) {
            Twap memory w = _twap;
            uint32 seen = w.recent.at;
            (Twap memory next, bool ready) = _twapCheck(w, cum, rT, rQ);
            if (ready) {
                uint256 out = burn ? _amountOut(_chunkOf(bb, rQ), rQ, rT) : _amountOut(_chunkOf(lp, rQ) / 2, rQ, rT);
                out -= (out * IBondToken(token).buyTaxBps()) / BPS;
                return (kind, (out * (BPS - WORK_SLIPPAGE_BPS)) / BPS, rQ);
            }
            if (next.recent.at != seen) return (DO_OBSERVE, 0, rQ);
        }
        if (pay != 0) {
            bool idle = block.timestamp >= lastPaidAt + WORK_MAX_IDLE;
            if (pay * BPS >= floor || (idle && pay * BPS * WORK_IDLE_DIV >= floor)) return (DO_SPLIT, 0, rQ);
        }
        return (DO_NOTHING, 0, rQ);
    }

    /// @dev The kind of the next chunk: the larger set-aside part's (a buy-back on a tie), a part that can't make a
    ///      chunk (a liquidity part under 2 wei has no half) left out.
    function _kindOf(uint256 bb, uint256 lp) internal pure returns (uint8) {
        bool canBurn = bb != 0;
        bool canAdd = lp / 2 != 0;
        if (!canBurn && !canAdd) return DO_NOTHING;
        if (!canAdd) return DO_BURN;
        if (!canBurn) return DO_ADD;
        return bb >= lp ? DO_BURN : DO_ADD;
    }

    /// @dev What a chunk of `left` would do now (`lp`: a liquidity chunk, whose buy is half of it).
    function _previewChunk(uint256 left, bool lp) internal view returns (bool ready, uint256 amount, uint256 out) {
        if (left == 0 || _tooSoon() || token == address(0)) return (false, 0, 0);
        (address p, bool tokenIs0, bool live) = _pairView();
        if (!live) return (false, 0, 0);
        (uint256 rT, uint256 rQ, uint256 cum) = _pairState(p, tokenIs0);
        (, ready) = _twapCheck(_twap, cum, rT, rQ);
        if (!ready) return (false, 0, 0);
        amount = _chunkOf(left, rQ);
        uint256 buy = lp ? amount / 2 : amount;
        if (buy == 0) return (false, 0, 0);
        out = _amountOut(buy, rQ, rT);
        out -= (out * IBondToken(token).buyTaxBps()) / BPS;
    }

    // ---------------------------------------------------------------- internal: the chunks
    /// @dev GangBuybackSplitter v4's chunk (with the LP audit L-1 scaling), on the shared pace.
    function _burnChunk(uint256 minTokensOut) internal returns (uint256 quoteIn, uint256 burned) {
        uint256 left = buybackLeft;
        if (left == 0) revert NothingToChunk();
        if (_tooSoon()) revert ChunkTooSoon();
        (address p, bool tokenIs0) = _pairOf();
        (uint256 rT, uint256 rQ, bool ok) = _rollTwap(p, tokenIs0);
        if (!ok) return (0, 0);
        quoteIn = _chunkOf(left, rQ);
        if (quoteIn == 0) return (0, 0);
        lastChunkAt = uint64(block.timestamp);
        left -= quoteIn;
        buybackLeft = left;
        IERC20(quote).safeTransfer(p, quoteIn);
        uint256 got;
        {
            uint256 bal = IERC20(quote).balanceOf(p);
            got = bal > rQ ? bal - rQ : 0;
        }
        uint256 out = _amountOut(got, rQ, rT);
        if (out != 0) {
            burned = IERC20(token).balanceOf(address(this));
            if (tokenIs0) IBondPair(p).swap(out, 0, address(this), "");
            else IBondPair(p).swap(0, out, address(this), "");
            burned = IERC20(token).balanceOf(address(this)) - burned;
            // scaled down when the pair got less (a quote taxing the transfer), never up (LP audit 2026-10-30 L-1)
            if (burned * quoteIn < minTokensOut * (got < quoteIn ? got : quoteIn)) revert Slippage();
            IERC20(token).safeTransfer(DEAD, burned);
        }
        emit BoughtBack(quoteIn, burned, left);
    }

    /// @dev GangLiquiditySplitter's chunk (with its audit fixes), on the shared pace.
    function _addChunk(uint256 minTokensOut) internal returns (uint256 quoteIn, uint256 tokensIn, uint256 liquidity) {
        uint256 left = lpLeft;
        if (left == 0) revert NothingToChunk();
        if (_tooSoon()) revert ChunkTooSoon();
        (address p, bool tokenIs0) = _pairOf();
        (uint256 rT, uint256 rQ, bool ok) = _rollTwap(p, tokenIs0);
        if (!ok) return (0, 0, 0);
        uint256 amount = _chunkOf(left, rQ);
        uint256 half = amount / 2;
        if (half == 0) return (0, 0, 0);
        lastChunkAt = uint64(block.timestamp);
        left -= half;
        lpLeft = left;

        // 1. buy with half, priced on what the pair received
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
            if (bought * half < minTokensOut * (got < half ? got : half)) revert Slippage();

            // 2. all of it back into the pair (sell tax; the handler may swap back first and pay this recipient)
            IERC20(token).safeTransfer(p, bought);
            (uint112 r0, uint112 r1,) = IBondPair(p).getReserves();
            (rT, rQ) = tokenIs0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
            uint256 tBal = IERC20(token).balanceOf(p);
            tokensIn = tBal > rT ? tBal - rT : 0;

            // 3. the matching quote at those reserves (rounded up), at most the other half
            uint256 match_ = rT == 0 ? 0 : (tokensIn * rQ + rT - 1) / rT;
            uint256 room = amount - half;
            if (match_ > room) match_ = room;
            uint256 supply = ILpPair(p).totalSupply();
            // a mint of 0 LP reverts in the pair: then the tokens are left in it unsynced (dust only)
            if (match_ != 0 && (tokensIn * supply) / rT != 0 && (match_ * supply) / rQ != 0) {
                IERC20(quote).safeTransfer(p, match_);
                quoteIn += match_;
                left -= match_;
                lpLeft = left;
                liquidity = ILpPair(p).mint(DEAD);
            }
        }
        emit LiquidityAdded(quoteIn, tokensIn, liquidity, left);
    }

    /// @dev Roll the TWAP (writing it when it moved) and say whether a chunk may trade now.
    function _rollTwap(address p, bool tokenIs0) internal returns (uint256 rT, uint256 rQ, bool ok) {
        uint256 cum;
        (rT, rQ, cum) = _pairState(p, tokenIs0);
        Twap memory w = _twap;
        uint32 seen = w.recent.at;
        Twap memory next;
        (next, ok) = _twapCheck(w, cum, rT, rQ);
        if (next.recent.at != seen) _twap = next;
    }

    /// @dev The pair, cached on first use after graduation (NotTradable before).
    function _pairOf() internal returns (address p, bool tokenIs0) {
        p = pair;
        tokenIs0 = _tokenIs0;
        if (p != address(0)) return (p, tokenIs0);
        if (token == address(0)) revert NotBound();
        bool live;
        (,,,,,, live,,,, p,) = IGangPadBondView(pad).curves(token);
        if (!live) revert NotTradable();
        tokenIs0 = IBondPair(p).token0() == token;
        pair = p;
        _tokenIs0 = tokenIs0;
    }

    function _pairView() internal view returns (address p, bool tokenIs0, bool live) {
        p = pair;
        if (p != address(0)) return (p, _tokenIs0, true);
        (,,,,,, live,,,, p,) = IGangPadBondView(pad).curves(token);
        if (!live) return (address(0), false, false);
        tokenIs0 = IBondPair(p).token0() == token;
    }

    function _tooSoon() internal view returns (bool) {
        uint64 last = lastChunkAt;
        return last != 0 && block.timestamp < last + CHUNK_GAP;
    }

    // GangBond's price math, as in the buy-back and liquidity splitters: keep identical.

    function _pairState(address p, bool tokenIs0) internal view returns (uint256 rT, uint256 rQ, uint256 cum) {
        (uint112 r0, uint112 r1, uint32 last) = IBondPair(p).getReserves();
        (rT, rQ) = tokenIs0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        cum = tokenIs0 ? IBondPair(p).price0CumulativeLast() : IBondPair(p).price1CumulativeLast();
        uint32 now32 = uint32(block.timestamp);
        unchecked {
            if (last != now32 && rT != 0) cum += ((rQ << 112) / rT) * uint32(now32 - last);
        }
    }

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

    function _amountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint256) {
        if (reserveIn == 0 || reserveOut == 0) return 0;
        uint256 inWithFee = amountIn * DEX_FEE_NUM;
        return (inWithFee * reserveOut) / (reserveIn * DEX_FEE_DEN + inWithFee);
    }
}
