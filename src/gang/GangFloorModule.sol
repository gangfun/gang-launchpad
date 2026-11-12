// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IGangPadBondView, IBondPair} from "./GangBond.sol";
import {IGangPad} from "./interfaces/IGangPad.sol";
import {IGangPadHandler} from "./interfaces/IGangPadDeps.sol";
import {IGangRecipientModule} from "./interfaces/IGangRecipientModule.sol";
import {IQuoteRegistryView} from "./GangSplitModule.sol";

/// @title GangFloorModule (底价赎回：税收进金库，持有人随时按比例赎回)
/// @notice The tax recipient of one V3 (curve) token that keeps the tax as a treasury instead of spending it: of every
///         quote it receives, `payBps` goes to 0–MAX_PAYEES payees at fixed shares until they have been credited
///         `capAmount` in all (GangCappedSplitter's cap: counted when split, owed or pushed alike); the rest — and,
///         once the cap is reached or when there are no payees, all of it — stays here. Any holder may `redeem`: its
///         tokens go to 0xdead and it takes `amount × treasury ÷ floorSupply` of the quote, less `redeemFeeBps` that
///         stays in the treasury. `floorSupply` = the token's total supply less what 0xdead holds: it reads no pair
///         reserve, so a flash loan or flash swap can't move it. A redemption never lowers the treasury per token of
///         those who stay (with a fee it raises it).
///         The token is fixed when the module is cloned (`floorToken`, the token's CREATE2 address, known before it is
///         created): `bind` only checks it, so no other token can ever be bound and redeem this treasury. The tax of
///         any other token that names this module as its recipient is a gift to this token's holders.
///         Everything is fixed when it is cloned — nobody, not the dev, not the platform, can change the token, the
///         cap, the ratios, the fee, the payees or their shares — except that each payee may move its own slot.
///         There is no buy-back, no liquidity add and no swap of any kind here: the only way out of the treasury is
///         `redeem`, and a redemption calls no payee: only the pad (a view), the token and the quote.
///         Assets other than the bound quote can't count in the treasury: all of each goes to 0xdead (one that can't
///         be sent there stays here).
/// @dev Not upgradeable (an EIP-1167 clone of a fixed implementation), no owner. Needs no role from the pad, token,
///      vault or handler. The payees, cap, push and owed code is GangCappedSplitter's (capped-v1, audited and live),
///      the keeper's split rule GangSplitModule's: change them together. `_splitQuote` and `_afterSplit` are its
///      own (the treasury and `payeesPending` instead of the two set-aside parts). docs/SPEC-FLOOR-MODULE-2026-11-11.md.
contract GangFloorModule is IGangRecipientModule, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_PAYEES = 10;
    /// @notice The most `redeemFeeBps` can be (D-1).
    uint256 public constant MAX_REDEEM_FEE_BPS = 500;
    /// @notice Gas given to each push (GangSplitModule's: a refusal that burns its gas costs at most this per payee).
    uint256 public constant PUSH_GAS = 300_000;
    /// @notice A push starts only with at least PUSH_GAS × 64/63 + this left (else PushStarved).
    uint256 public constant PUSH_RESERVE = 60_000;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    /// @notice The keeper splits once the payees' pending part reaches this share of the pair's quote reserve…
    uint256 public constant WORK_MIN_BPS = 5;
    /// @notice …or, WORK_MAX_IDLE after the last payout, once it reaches 1/WORK_IDLE_DIV of that.
    uint64 public constant WORK_MAX_IDLE = 1 days;
    uint256 public constant WORK_IDLE_DIV = 100;
    /// @notice `floorPrice`'s scale.
    uint256 public constant PRICE_SCALE = 1e18;
    bytes32 public constant MODULE_TYPE = "floor-v1";

    uint8 internal constant KIND_CURVE = 1;

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
    /// @notice The only token this module can ever serve, fixed at clone (K-13). It need not exist yet.
    address public floorToken;
    /// @notice The bound token: `floorToken` once `bind` checked it, 0 before (IGangRecipientModule).
    address public token;
    /// @notice The bound quote: `floorQuote` once bound, 0 before.
    address public quote;
    /// @notice The quote the treasury and the cap are counted in, fixed at clone: the token must be quoted in it.
    address public floorQuote;
    /// @notice The most the payees are ever credited, in all, in `floorQuote`'s smallest unit (fixed; 0: no payees).
    uint256 public capAmount;
    /// @notice What the payees are credited so far (pushed, owed or set aside in `payeesPending`). Only grows; never
    ///         above `capAmount`.
    uint256 public paidTotal;
    /// @notice Share of the incoming quote that goes to the payees while the cap is not reached (fixed; 0: no payees).
    uint16 public payBps;
    /// @notice Share of a redemption that stays in the treasury (fixed, at most MAX_REDEEM_FEE_BPS).
    uint16 public redeemFeeBps;
    address[] internal _payees;
    uint16[] internal _shares;
    /// @notice The treasury as of the last split (`treasury()` adds what arrived since).
    uint256 public treasuryHeld;
    /// @notice The payees' part that a redemption's split counted (against the cap too) and left for the next push: a
    ///         redemption never calls a payee (audit 2026-11-11 L-3).
    uint256 public payeesPending;
    /// @dev Per asset, what each payee slot is owed after a failed push.
    mapping(address asset => mapping(uint256 index => uint256)) internal _owed;
    /// @notice Per asset, Σ owed.
    mapping(address asset => uint256) public owedTotal;
    /// @notice When the payees' part of the bound quote was last paid out (0: never).
    uint64 public lastPaidAt;

    event Bound(address indexed token, address indexed quote);
    /// @notice The bound quote that arrived: `toTreasury` kept, `toPayees` counted against the cap — pushed (or owed)
    ///         in the same call by a pushing split, only set aside (`payeesPending`, no transfer in this tx) by a
    ///         redemption's: read the payouts from the transfers, not from this event.
    event Split(uint256 incoming, uint256 toTreasury, uint256 toPayees);
    /// @notice The payees were credited the whole cap: from now on all of the quote stays in the treasury.
    event CapReached(uint256 capAmount);
    /// @notice `holder` sent `tokensIn` to 0xdead and `to` got `quoteOut`; `fee` stayed in the treasury.
    event Redeemed(
        address indexed holder,
        address indexed to,
        uint256 tokensIn,
        uint256 quoteOut,
        uint256 fee,
        uint256 treasuryAfter,
        uint256 supplyAfter
    );
    /// @notice Another asset: `toDead` (all of it, or 0 when it can't be sent there and it stays here) sent to 0xdead.
    event Distributed(address indexed asset, uint256 incoming, uint256 toDead);
    event PayeeOwed(address indexed asset, uint256 indexed index, uint256 amount);
    event PayeeReleased(address indexed asset, uint256 indexed index, uint256 amount);
    event PayeeChanged(uint256 indexed index, address indexed oldPayee, address indexed newPayee);
    /// @notice A balance under what was held; the treasury, what payees are owed and `payeesPending` shrank in
    ///         proportion.
    event Shortfall(address indexed asset, uint256 amount);

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
    error WrongToken();
    error NotCurve();
    error NotCreator();
    error NotRecipient();
    error NothingOwed();
    error NotTradable();
    error Slippage();
    error PushStarved();
    error BadCap();
    error WrongQuote();
    error BadQuote();
    error ZeroAmount();
    error BadTo();
    error NothingToRedeem();
    error NothingForRecipient();

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

    /// @notice A clone's setup, by the factory in the tx that clones it. `token_` the address the dev's token will
    ///         have (not checked here: it need not exist yet); `floorQuote_` a quote the keeper serves (the pad's WBNB,
    ///         `gangQuote` or a QuoteRegistry quote: else BadQuote); `redeemFeeBps_` at most MAX_REDEEM_FEE_BPS.
    ///         With payees: `payBps_` 1–BPS, `capAmount_` above 0, 1–MAX_PAYEES distinct payees (none 0, none this
    ///         contract), each share at least 1 bps, summing to BPS. Without: `payBps_`, `capAmount_` and both lists
    ///         empty — all of the quote stays in the treasury from the first wei.
    function initialize(
        address dev_,
        address token_,
        address floorQuote_,
        uint256 capAmount_,
        uint16 payBps_,
        uint16 redeemFeeBps_,
        address[] calldata payees_,
        uint16[] calldata shares_
    ) external {
        if (address(this) == _self) revert NotClone();
        if (msg.sender != factory) revert NotFactory();
        if (dev != address(0)) revert AlreadyInitialized();
        if (dev_ == address(0) || token_ == address(0) || floorQuote_ == address(0)) revert ZeroAddress();
        if (!keeperServes(floorQuote_)) revert BadQuote();
        if (payBps_ > BPS || redeemFeeBps_ > MAX_REDEEM_FEE_BPS) revert BadBps();
        uint256 n = payees_.length;
        if (shares_.length != n || n > MAX_PAYEES) revert BadPayees();
        if (payBps_ == 0) {
            if (capAmount_ != 0) revert BadCap();
            if (n != 0) revert BadPayees();
        } else {
            if (capAmount_ == 0) revert BadCap();
            if (n == 0) revert BadPayees();
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
        }
        dev = dev_;
        floorToken = token_;
        floorQuote = floorQuote_;
        capAmount = capAmount_;
        payBps = payBps_;
        redeemFeeBps = redeemFeeBps_;
        _payees = payees_;
        _shares = shares_;
    }

    function moduleType() external pure returns (bytes32) {
        return MODULE_TYPE;
    }

    // ---------------------------------------------------------------- a holder
    /// @notice Give up `amount` tokens (approved to this contract; they go to 0xdead) for
    ///         `amount × treasury ÷ floorSupply` of the bound quote, less `redeemFeeBps` of it that stays in the
    ///         treasury; `to` gets at least `minQuoteOut` (else Slippage). The quote that arrived before is split
    ///         first, so the payees' part of it is never redeemed; it is set aside (`payeesPending`) and pushed by
    ///         the next `split` / `work`, not here. Only after graduation (NotTradable before).
    /// @return quoteOut What `to` received.
    function redeem(uint256 amount, uint256 minQuoteOut, address to) external nonReentrant returns (uint256 quoteOut) {
        if (amount == 0) revert ZeroAmount();
        if (to == address(0)) revert ZeroAddress();
        if (to == address(this)) revert BadTo();
        address t = token;
        if (t == address(0)) revert NotBound();
        if (!_live(t)) revert NotTradable();
        // counted, not pushed: what a payee does can't cost a holder gas or stop a redemption
        _splitQuote(false);
        uint256 held = treasuryHeld;
        uint256 supply = _supplyOf(t);
        uint256 fee;
        (quoteOut, fee) = _quoteFor(amount, held, supply);
        if (quoteOut == 0) revert NothingToRedeem();
        if (quoteOut < minQuoteOut) revert Slippage();
        held -= quoteOut;
        treasuryHeld = held;
        // neither side is the pair, so the token takes no tax on it; a holder without the balance reverts here
        IERC20(t).safeTransferFrom(msg.sender, DEAD, amount);
        IERC20(quote).safeTransfer(to, quoteOut);
        emit Redeemed(msg.sender, to, amount, quoteOut, fee, held, supply - amount);
    }

    // ---------------------------------------------------------------- a payee
    /// @notice Move slot `index` to `newPayee` (only that slot's payee, at once): the bound quote that arrived before
    ///         is split first and paid to the old address (with `payeesPending`); what the slot is owed goes to the
    ///         new one. The cap and the slot's share stay as they are. While the balance is short of what is held
    ///         (a quote that was frozen or taken), the split only records the shortfall: what is set aside then goes
    ///         to the new address at the next push.
    function setPayee(uint256 index, address newPayee) external nonReentrant {
        if (index >= _payees.length) revert BadIndex();
        if (msg.sender != _payees[index]) revert NotPayee();
        if (newPayee == address(0)) revert ZeroAddress();
        if (newPayee == address(this)) revert BadPayee();
        for (uint256 j; j < _payees.length; j++) {
            if (_payees[j] == newPayee) revert DuplicatePayee();
        }
        _splitQuote(true);
        emit PayeeChanged(index, msg.sender, newPayee);
        _payees[index] = newPayee;
    }

    // ---------------------------------------------------------------- anyone
    /// @notice Bind the token (once): `token_` must be `floorToken` (else WrongToken), by now a V3 token the dev created
    ///         with this contract as its tax recipient, quoted in `floorQuote`, with less than all of the tax going to
    ///         the holders' dividend.
    function bind(address token_) external {
        if (token != address(0)) revert AlreadyBound();
        if (token_ != floorToken) revert WrongToken();
        if (IGangPadBondView(pad).kindOf(token_) != KIND_CURVE) revert NotCurve();
        (address creator, address quote_,,,,,,,, uint16 dividendBps,,) = IGangPadBondView(pad).curves(token_);
        if (creator != dev) revert NotCreator();
        if (quote_ != floorQuote) revert WrongQuote();
        // all of the tax to the holders' dividend: this module would never receive any (audit 2026-11-11 L-1)
        if (dividendBps >= BPS) revert NothingForRecipient();
        (, address recipient) = IGangPadHandler(taxHandler).routeOf(token_);
        if (recipient != address(this)) revert NotRecipient();
        token = token_;
        quote = quote_;
        emit Bound(token_, quote_);
    }

    /// @notice Split the bound quote that arrived: the payees paid (until the cap), the rest added to the treasury.
    function split() external nonReentrant {
        _splitQuote(true);
    }

    /// @notice Split `asset` that arrived (the bound quote: as `split`; any other: all of it to 0xdead — it can't count
    ///         in the treasury).
    function distribute(address asset) external nonReentrant returns (uint256 incoming) {
        // before `bind` the quote is unknown: the tax already here must not be sent away as another asset
        if (quote == address(0)) revert NotBound();
        if (asset == quote) {
            _splitQuote(true);
            return 0;
        }
        return _distribute(asset);
    }

    /// @notice Split the bound quote first (a shortfall is shared before anything leaves), then push up to
    ///         `maxAmount` of what slot `index` is owed to its payee (type(uint256).max: all of it; reverts while it
    ///         still can't receive). Payees are only ever owed the bound quote: any other `asset` reverts NothingOwed.
    ///         If that split's push already paid the slot what it was owed, this reverts NothingOwed and the push
    ///         with it: call `split` first.
    function release(address asset, uint256 index, uint256 maxAmount) external nonReentrant returns (uint256 amount) {
        if (quote == address(0)) revert NotBound();
        if (index >= _payees.length) revert BadIndex();
        if (asset != quote) revert NothingOwed();
        _splitQuote(true);
        uint256 owed = _owed[asset][index];
        amount = owed < maxAmount ? owed : maxAmount;
        if (amount == 0) revert NothingOwed();
        _owed[asset][index] = owed - amount;
        owedTotal[asset] -= amount;
        IERC20(asset).safeTransfer(_payees[index], amount);
        emit PayeeReleased(asset, index, amount);
    }

    /// @notice IGangRecipientModule's step: the split (it pays the payees; the treasury needs no step).
    function work(uint256) external nonReentrant {
        _splitQuote(true);
    }

    // ---------------------------------------------------------------- views
    function payeesOf() external view returns (address[] memory payees, uint16[] memory shares) {
        return (_payees, _shares);
    }

    function owedOf(address asset, uint256 index) external view returns (uint256) {
        return _owed[asset][index];
    }

    /// @notice What is left of the cap (0 once reached, and when there are no payees).
    function capLeft() external view returns (uint256) {
        return capAmount - paidTotal;
    }

    /// @notice Whether the payees have been credited the whole cap (always, when there are none).
    function capReached() external view returns (bool) {
        return paidTotal == capAmount;
    }

    /// @notice The bound quote that arrived and is not split yet.
    function unsplit() public view returns (uint256) {
        address q = quote;
        if (q == address(0)) return 0;
        uint256 bal = IERC20(q).balanceOf(address(this));
        uint256 held = treasuryHeld + owedTotal[q] + payeesPending;
        return bal > held ? bal - held : 0;
    }

    /// @notice What `distribute(asset)` would act on: the bound quote's `unsplit`; any other asset's whole balance.
    ///         Before `bind` the bound quote is not known yet, so `floorQuote` reads as another asset here while
    ///         `distribute` reverts NotBound.
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

    /// @notice The treasury as a split now would leave it: what `redeem` shares out. 0 before `bind`.
    function treasury() public view returns (uint256 held) {
        (held,) = _afterSplit();
    }

    /// @notice The supply a redemption is measured against: the token's total supply less what 0xdead holds. The pair's
    ///         tokens and the handler's unsold tax count. 0 before `bind`.
    function floorSupply() public view returns (uint256) {
        address t = token;
        return t == address(0) ? 0 : _supplyOf(t);
    }

    /// @notice The treasury per whole token (1e18 of its smallest unit), before the redemption fee, scaled by
    ///         PRICE_SCALE ÷ 1e18 — i.e. quote wei per token wei × PRICE_SCALE. 0 before `bind`.
    function floorPrice() external view returns (uint256) {
        uint256 supply = floorSupply();
        return supply == 0 ? 0 : (treasury() * PRICE_SCALE) / supply;
    }

    /// @notice What `redeem(amount, …)` would pay now and the fee it would leave in the treasury. Zeros before `bind`,
    ///         before graduation, and for an `amount` above `floorSupply`.
    function previewRedeem(uint256 amount) external view returns (uint256 quoteOut, uint256 fee) {
        address t = token;
        if (t == address(0) || !_live(t)) return (0, 0);
        uint256 supply = _supplyOf(t);
        if (amount > supply) return (0, 0);
        (uint256 held,) = _afterSplit();
        return _quoteFor(amount, held, supply);
    }

    /// @notice Due when `work` would pay the payees an amount worth a call: their part not pushed yet (of what arrived,
    ///         and `payeesPending`) at least WORK_MIN_BPS of
    ///         the pair's quote reserve, or 1/WORK_IDLE_DIV of that WORK_MAX_IDLE after the last payout. Never for a
    ///         quote the keeper doesn't serve, or before graduation. With no payees it is never due, and once the cap
    ///         is reached only until what a redemption set aside is pushed: the treasury itself needs no keeper. (A
    ///         set-aside part under the threshold after the cap is never due: a payee calls `split` for it. During a
    ///         shortfall the first `work` only records it; the next one pushes.)
    function previewWork() external view returns (bool due, uint256 minOut) {
        address q = quote;
        if (!keeperServes(q)) return (false, 0);
        (, uint256 pay) = _afterSplit();
        if (pay == 0) return (false, 0);
        (,,,,,, bool live,,,, address p,) = IGangPadBondView(pad).curves(token);
        if (!live) return (false, 0);
        (uint112 r0, uint112 r1,) = IBondPair(p).getReserves();
        uint256 floor = (IBondPair(p).token0() == token ? uint256(r1) : uint256(r0)) * WORK_MIN_BPS;
        if (pay * BPS >= floor) return (true, 0);
        bool idle = block.timestamp >= lastPaidAt + WORK_MAX_IDLE;
        return (idle && pay * BPS * WORK_IDLE_DIV >= floor, 0);
    }

    // ---------------------------------------------------------------- internal: the redemption
    /// @dev `amount` of a `supply` whose treasury is `held`: its share rounded down, the fee rounded down out of it.
    ///      `redeem` and `previewRedeem` both use it, so a preview always matches the redemption that follows.
    function _quoteFor(uint256 amount, uint256 held, uint256 supply)
        internal
        view
        returns (uint256 quoteOut, uint256 fee)
    {
        if (supply == 0) return (0, 0);
        uint256 gross = (amount * held) / supply;
        fee = (gross * redeemFeeBps) / BPS;
        quoteOut = gross - fee;
    }

    function _supplyOf(address t) internal view returns (uint256) {
        return IERC20(t).totalSupply() - IERC20(t).balanceOf(DEAD);
    }

    /// @dev Graduated: the pair exists and the token moves freely.
    function _live(address t) internal view returns (bool live) {
        (,,,,,, live,,,,,) = IGangPadBondView(pad).curves(t);
    }

    // ---------------------------------------------------------------- internal: the split
    /// @dev The bound quote: held = the treasury, what payees are owed and what is set aside for them; a balance
    ///      under it shrinks all three in proportion (`paidTotal` stays: the cap is only ever used up sooner); what
    ///      arrived above it is split. With `push` the payees' part (and what earlier splits set aside) is pushed;
    ///      without, it is set aside for the next split that pushes.
    function _splitQuote(bool push) internal {
        address q = quote;
        if (q == address(0)) return;
        uint256 bal = IERC20(q).balanceOf(address(this));
        uint256 pend = payeesPending;
        uint256 held = treasuryHeld + owedTotal[q] + pend;
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
            pend = (pend * bal) / held;
            payeesPending = pend;
            treasuryHeld = bal - total - pend;
            emit Shortfall(q, held - bal);
            return;
        }
        uint256 incoming = bal - held;
        if (incoming != 0) {
            uint256 paid = paidTotal;
            (uint256 toPayees, uint256 toTreasury) = _partsOf(incoming, paid);
            treasuryHeld += toTreasury;
            if (toPayees != 0) {
                // counted before any push: a payee that refuses is owed, and what it is owed is part of the cap
                paid += toPayees;
                paidTotal = paid;
                pend += toPayees;
            }
            emit Split(incoming, toTreasury, toPayees);
            if (toPayees != 0 && paid == capAmount) emit CapReached(paid);
        }
        if (!push) {
            payeesPending = pend;
            return;
        }
        if (pend == 0) return;
        payeesPending = 0;
        lastPaidAt = uint64(block.timestamp);
        _payAll(q, pend);
    }

    /// @dev How `incoming` of the bound quote splits with `paid` already credited: the payees' `payBps`, at most what
    ///      is left of the cap; the rest to the treasury. `_splitQuote` and `_afterSplit` both use it.
    function _partsOf(uint256 incoming, uint256 paid) internal view returns (uint256 toPayees, uint256 toTreasury) {
        toPayees = (incoming * payBps) / BPS;
        uint256 left = capAmount - paid;
        if (toPayees > left) toPayees = left;
        toTreasury = incoming - toPayees;
    }

    /// @dev `(treasury, payees' part not pushed yet)` as `_splitQuote` would leave them now.
    function _afterSplit() internal view returns (uint256 held, uint256 pay) {
        held = treasuryHeld;
        address q = quote;
        if (q == address(0)) return (held, 0);
        uint256 bal = IERC20(q).balanceOf(address(this));
        pay = payeesPending;
        uint256 all = held + owedTotal[q] + pay;
        if (bal < all) {
            uint256 n = _payees.length;
            uint256 total;
            for (uint256 i; i < n; i++) {
                total += (_owed[q][i] * bal) / all;
            }
            pay = (pay * bal) / all;
            return (bal - total - pay, pay);
        }
        (uint256 toPayees, uint256 toTreasury) = _partsOf(bal - all, paidTotal);
        return (held + toTreasury, pay + toPayees);
    }

    /// @dev Another asset: all of it to 0xdead (left here when it can't be sent there). Nothing of it is ever owed to
    ///      a payee or part of the treasury, so the whole balance is what arrived.
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
}
