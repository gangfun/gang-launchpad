// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IGangPadBondView, IBondPair} from "./GangBond.sol";
import {IGangPad} from "./interfaces/IGangPad.sol";
import {IGangPadHandler} from "./interfaces/IGangPadDeps.sol";
import {IGangRecipientModule} from "./interfaces/IGangRecipientModule.sol";

interface IQuoteRegistryView {
    function isQuoted(address quote) external view returns (bool);
}

/// @title GangSplitModule (多人分账)
/// @notice A tax recipient whose income is split among 1–MAX_PAYEES payees at shares fixed when it is cloned (summing
///         to BPS): nobody — not the dev, not the platform — can change the list or the shares afterwards. Each payee
///         may only move its own slot to another address (`setPayee`). A clone, set up as the buy-back splitter is:
///         1. the dev calls GangSplitModuleFactory.create(payees, shares, salt) (the CLI's `--split`): the factory
///            clones this implementation, `initialize`s it and has GangHandlerAdmin list it on the tax handler;
///         2. the dev creates the token with it as `recipient`;
///         3. anyone `bind`s the token (once; the token's creator must be the dev and its recipient this contract):
///            the bound token's quote is what the keeper splits (`previewWork` / `work`), when it serves that
///            quote (`keeperServes`: WBNB, GANG, a QuoteRegistry quote).
///         EVERY asset that reaches it is split at the same shares (`distribute(asset)`, anyone): the bound quote, the
///         tax of any other token naming it as recipient in another quote, a stray transfer. So whatever token a dev
///         points at it, the payees get their shares (audit 2026-10-30 M-1: an all-to-the-first-payee sweep let a dev
///         bind a decoy and route the real token's tax, in another quote, to itself).
///         Each payee's part is pushed with at most PUSH_GAS; the first payee also takes what rounding leaves. A push
///         that fails (a quote that blacklists the payee, or pauses) is owed to that slot (`owedOf`); after the slot's
///         next successful push what it is owed is pushed too, on its own, or anyone can `release` it, in parts if
///         need be (a quote with a per-transfer cap never locks a slot, re-review 2026-10-30 NEW-1). A balance under
///         what is owed (a seized or rebased balance) shrinks every owed part in proportion at the next split; a loss
///         that leaves the balance above what is owed can't be told from smaller arrivals and is borne by what
///         arrives next.
/// @dev Not upgradeable (an EIP-1167 clone of a fixed implementation), no owner. Reads the pad's and the handler's
///      public views; needs no role from the pad, token, vault or handler. Each asset's accounting is its own, so a
///      hostile asset can only disturb itself.
contract GangSplitModule is IGangRecipientModule, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_PAYEES = 10;
    /// @notice Gas given to each push: a refusal that burns its gas costs at most this per payee (audit L-1); a push
    ///         that needs more just becomes owed (`release` sends it without the cap). Room for a token that syncs
    ///         dividend shares on transfer (a GangToken ≈ 106–121k, re-review NEW-2). Each slot pushes at most twice
    ///         (its new part, then what it is owed), so a split costs at most 2 × MAX_PAYEES × PUSH_GAS ≈ 6M.
    uint256 public constant PUSH_GAS = 300_000;
    /// @notice A push starts only with at least PUSH_GAS × 64/63 + this left, so the token always gets its whole
    ///         PUSH_GAS (63/64 rule) and the bookkeeping after it still runs; less reverts PushStarved.
    uint256 public constant PUSH_RESERVE = 60_000;
    /// @notice `previewWork` is due once the unsplit quote reaches this share of the pair's quote reserve…
    uint256 public constant WORK_MIN_BPS = 5;
    /// @notice …or WORK_MAX_IDLE after the last split, once it reaches 1/WORK_IDLE_DIV of that (a small token still
    ///         pays out daily; a dust transfer can't make the keeper split it every day — audit L-2).
    uint64 public constant WORK_MAX_IDLE = 1 days;
    uint256 public constant WORK_IDLE_DIV = 100;
    bytes32 public constant MODULE_TYPE = "split-v1";

    uint8 internal constant KIND_CURVE = 1;

    address public immutable pad;
    address public immutable taxHandler;
    /// @notice The factory that deployed the implementation: the only caller of a clone's `initialize`.
    address public immutable factory;
    address internal immutable _self;
    /// @notice The quotes the keeper serves (`previewWork`), besides the pad's WBNB and the QuoteRegistry's: the
    ///         platform's GANG (0 where there is none). Any other quote is split by hand (`distribute`): a quote the
    ///         dev picked could lie about its balance and burn PUSH_GAS on every push, and so drain the shared
    ///         keeper with a split due every round (pre-testnet review M-1).
    address public immutable gangQuote;
    address internal immutable _wbnb;
    address internal immutable _quoteRegistry;

    /// @notice The dev it was made for (the token's creator once bound).
    address public dev;
    /// @notice The bound token and its quote (0 until `bind`).
    address public token;
    address public quote;
    address[] internal _payees;
    uint16[] internal _shares;
    /// @dev Per asset, what each slot is owed after a failed push.
    mapping(address asset => mapping(uint256 index => uint256)) internal _owed;
    /// @notice Per asset, Σ owed: held here, never split again.
    mapping(address asset => uint256) public owedTotal;
    /// @notice When the bound quote was last split (0: never).
    uint64 public lastDistributedAt;

    event Bound(address indexed token, address indexed quote);
    event Distributed(address indexed asset, uint256 incoming);
    event PayeeOwed(address indexed asset, uint256 indexed index, uint256 amount);
    event PayeeReleased(address indexed asset, uint256 indexed index, uint256 amount);
    event PayeeChanged(uint256 indexed index, address indexed oldPayee, address indexed newPayee);
    /// @notice The asset's balance fell below what was owed; the owed parts shrank by `amount` in proportion.
    event Shortfall(address indexed asset, uint256 amount);

    error ZeroAddress();
    error NotClone();
    error NotFactory();
    error AlreadyInitialized();
    error BadPayees();
    error BadShares();
    error BadPayee();
    error DuplicatePayee();
    error BadIndex();
    error NotPayee();
    error AlreadyBound();
    error NotCurve();
    error NotCreator();
    error NotRecipient();
    error NothingOwed();
    error PushStarved();

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

    /// @notice A clone's setup, by the factory in the tx that clones it: 1–MAX_PAYEES distinct payees (none 0, none
    ///         this contract), each share at least 1 bps, summing to BPS.
    function initialize(address dev_, address[] calldata payees_, uint16[] calldata shares_) external {
        if (address(this) == _self) revert NotClone();
        if (msg.sender != factory) revert NotFactory();
        if (dev != address(0)) revert AlreadyInitialized();
        if (dev_ == address(0)) revert ZeroAddress();
        uint256 n = payees_.length;
        if (n == 0 || n > MAX_PAYEES || shares_.length != n) revert BadPayees();
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
        _payees = payees_;
        _shares = shares_;
    }

    function moduleType() external pure returns (bytes32) {
        return MODULE_TYPE;
    }

    // ---------------------------------------------------------------- a payee
    /// @notice Move slot `index` to `newPayee` (only that slot's payee, at once): the bound quote that arrived before
    ///         is split first and goes to the old address; what the slot is owed (any asset) goes to the new one. The
    ///         share stays.
    function setPayee(uint256 index, address newPayee) external nonReentrant {
        if (index >= _payees.length) revert BadIndex();
        if (msg.sender != _payees[index]) revert NotPayee();
        if (newPayee == address(0)) revert ZeroAddress();
        // paying itself would loop that part back into the next split
        if (newPayee == address(this)) revert BadPayee();
        for (uint256 j; j < _payees.length; j++) {
            if (_payees[j] == newPayee) revert DuplicatePayee();
        }
        if (quote != address(0)) _distribute(quote);
        emit PayeeChanged(index, msg.sender, newPayee);
        _payees[index] = newPayee;
    }

    // ---------------------------------------------------------------- anyone
    /// @notice Bind the dev's token (once): a V3 token the dev created with this contract as its tax recipient. Only
    ///         says which quote the keeper splits; every asset is split at the same shares either way.
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

    /// @notice Split what of `asset` arrived since its last split among the payees.
    function distribute(address asset) external nonReentrant returns (uint256 incoming) {
        return _distribute(asset);
    }

    /// @notice IGangRecipientModule's step: split the bound quote (`minOut` unused: a split trades nothing).
    function work(uint256) external nonReentrant {
        if (quote != address(0)) _distribute(quote);
    }

    /// @notice Split `asset` first (a shortfall is shared before anything leaves), then push up to `maxAmount` of what
    ///         slot `index` is owed in it to its payee (type(uint256).max: all of it; reverts while it still can't
    ///         receive, so nothing owed is lost).
    function release(address asset, uint256 index, uint256 maxAmount) external nonReentrant returns (uint256 amount) {
        if (index >= _payees.length) revert BadIndex();
        _distribute(asset);
        uint256 owed = _owed[asset][index];
        amount = owed < maxAmount ? owed : maxAmount;
        if (amount == 0) revert NothingOwed();
        _owed[asset][index] = owed - amount;
        owedTotal[asset] -= amount;
        IERC20(asset).safeTransfer(_payees[index], amount);
        emit PayeeReleased(asset, index, amount);
    }

    // ---------------------------------------------------------------- views
    function payeesOf() external view returns (address[] memory payees, uint16[] memory shares) {
        return (_payees, _shares);
    }

    function payeeCount() external view returns (uint256) {
        return _payees.length;
    }

    /// @notice What slot `index` is owed in `asset` after failed pushes (before any shortfall not split yet).
    function owedOf(address asset, uint256 index) external view returns (uint256) {
        return _owed[asset][index];
    }

    /// @notice What of `asset` arrived and is not split yet.
    function undistributed(address asset) public view returns (uint256) {
        uint256 bal = IERC20(asset).balanceOf(address(this));
        uint256 held = owedTotal[asset];
        return bal > held ? bal - held : 0;
    }

    /// @notice Whether the keeper serves `q`: the pad's WBNB, `gangQuote`, or a QuoteRegistry quote.
    function keeperServes(address q) public view returns (bool) {
        if (q == address(0)) return false;
        if (q == _wbnb || q == gangQuote) return true;
        return _quoteRegistry != address(0) && IQuoteRegistryView(_quoteRegistry).isQuoted(q);
    }

    /// @notice Due after graduation when the unsplit bound quote reaches WORK_MIN_BPS of the pair's quote reserve, or
    ///         WORK_MAX_IDLE after the last split once it reaches 1/WORK_IDLE_DIV of that; never for a quote the keeper
    ///         doesn't serve (`keeperServes`). `minOut` is always 0.
    function previewWork() external view returns (bool due, uint256 minOut) {
        address q = quote;
        if (!keeperServes(q)) return (false, 0);
        uint256 pending = undistributed(q);
        if (pending == 0) return (false, 0);
        (,,,,,, bool live,,,, address p,) = IGangPadBondView(pad).curves(token);
        if (!live) return (false, 0);
        (uint112 r0, uint112 r1,) = IBondPair(p).getReserves();
        uint256 floor = (IBondPair(p).token0() == token ? uint256(r1) : uint256(r0)) * WORK_MIN_BPS;
        if (pending * BPS >= floor) return (true, 0);
        bool idle = block.timestamp >= lastDistributedAt + WORK_MAX_IDLE;
        return (idle && pending * BPS * WORK_IDLE_DIV >= floor, 0);
    }

    // ---------------------------------------------------------------- internal
    function _distribute(address asset) internal returns (uint256 incoming) {
        uint256 bal = IERC20(asset).balanceOf(address(this));
        uint256 held = owedTotal[asset];
        uint256 n = _payees.length;
        if (bal < held) {
            // every owed part loses in proportion (rounded down)
            uint256 total;
            for (uint256 i; i < n; i++) {
                uint256 o = _owed[asset][i];
                if (o == 0) continue;
                o = (o * bal) / held;
                _owed[asset][i] = o;
                total += o;
            }
            owedTotal[asset] = total;
            emit Shortfall(asset, held - bal);
            return 0;
        }
        incoming = bal - held;
        if (incoming == 0) return 0;
        if (asset == quote) lastDistributedAt = uint64(block.timestamp);
        // the others first, rounded down; the first payee takes the rest
        uint256 left = incoming;
        for (uint256 i = n; i > 1;) {
            unchecked {
                --i;
            }
            uint256 part = (incoming * _shares[i]) / BPS;
            left -= part;
            _pay(asset, i, part);
        }
        _pay(asset, 0, left);
        emit Distributed(asset, incoming);
    }

    /// @dev Push `amount`; when it goes through and the slot is owed, push that too, on its own (a slot that can
    ///      receive again gets it back, audit L-3; one too big to move at once stays owed without holding up the new
    ///      parts, re-review NEW-1). A slot that still can't receive costs one failed push.
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

    /// @dev As the tax handler's, with at most PUSH_GAS and at most 32 bytes of return data copied (a hostile asset
    ///      can't make its own split costly with a huge return, re-review I-1): a transfer that reports failure
    ///      instead of reverting.
    ///      Every push gets its whole PUSH_GAS or the call reverts PushStarved before it (pre-testnet review L-1: a
    ///      check after the call misread a token behind a proxy, whose outer frame hands back the inner 1/64), so a
    ///      caller can't starve a push into an owed part, and gas estimation finds a limit where every push gets its
    ///      PUSH_GAS. A token whose return is malformed (false, 2, 31 bytes) after moving the coins is booked as owed;
    ///      the next split's shortfall corrects it.
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
