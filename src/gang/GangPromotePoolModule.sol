// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IGangPadBondView, IBondPair} from "./GangBond.sol";
import {IGangPad} from "./interfaces/IGangPad.sol";
import {IGangPromote} from "./interfaces/IGangPromote.sol";
import {IGangRecipientModule} from "./interfaces/IGangRecipientModule.sol";

interface IPromotePoolRoute {
    function routeOf(address token)
        external
        view
        returns (address quote, address recipient, uint16 dividendBps, uint8 kind);
}

interface IPromotePoolQuotes {
    function isQuoted(address quote) external view returns (bool);
}

interface IPromotePoolFactory {
    function settler() external view returns (address);
    function owner() external view returns (address);
}

/// @title GangPromotePoolModule (推广分成延续到外盘)
/// @notice The tax recipient of one 3.0 token made with `createWithPromote`: it carries the promoter share past
///         graduation (docs/SPEC-PROMOTER-POOL-SHARE-2026-11-05.md). Wallets still bind on the curve only; the pad's
///         `bindingOf` and `promoteOf` stay the only source of who was referred, by whom and for how long.
///         The handler pays the recipient's part in plain transfers that say nothing about the trade, so the split by
///         promoter is computed off-chain and bounded here:
///         1. of every arrival, the promoter share `shareBps` is escrowed and the rest pushed to the dev at once;
///         2. the settler posts a Merkle root of cumulative amounts per account, the dev's part included. It takes
///            effect after DISPUTE_WINDOW, during which the factory's owner can veto it;
///         3. each account claims its own amount. Nothing a root says can move more than the escrow.
///         A wrong root can only misallocate the escrow. It can't touch what was already pushed to the dev, or what
///         was claimed. Once no window can still run (`escrowOpen`), every arrival goes to the dev. A settler silent
///         for SETTLER_SILENCE lets the dev take back what no root allocated and close the module for good (`reclaim`):
///         the settler posts every period while escrow runs, even with nothing new, so silence means it stopped.
///         A balance seized from this contract isn't shared out: the next arrival fills the hole unsplit, and until
///         then the last claim reverts.
/// @dev Not upgradeable (an EIP-1167 clone of a fixed implementation), no owner of its own. Reads the pad's and the
///      handler's public views and needs no role from them.
contract GangPromotePoolModule is IGangRecipientModule, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    /// @notice Gas for the dev's push; a push that needs more becomes `devOwed` (`releaseDev` sends it without the cap).
    uint256 public constant PUSH_GAS = 300_000;
    /// @notice A push starts only with PUSH_GAS × 64/63 + this left, so it always gets its whole PUSH_GAS.
    uint256 public constant PUSH_RESERVE = 60_000;
    /// @notice As GangSplitModule: due at this share of the pair's quote reserve…
    uint256 public constant WORK_MIN_BPS = 5;
    /// @notice …or WORK_MAX_IDLE after the last split, at 1/WORK_IDLE_DIV of that.
    uint64 public constant WORK_MAX_IDLE = 1 days;
    uint256 public constant WORK_IDLE_DIV = 100;
    /// @notice How long a posted root waits before it takes effect.
    uint64 public constant DISPUTE_WINDOW = 2 days;
    /// @notice Tax taken inside a window is sold later, in chunks: escrow keeps running this long after the last window.
    uint64 public constant ESCROW_GRACE = 7 days;
    /// @notice No root posted for this long: the dev may take back what no root allocated.
    uint64 public constant SETTLER_SILENCE = 30 days;
    bytes32 public constant MODULE_TYPE = "promote-pool-v1";

    uint8 internal constant KIND_CURVE = 1;

    address public immutable pad;
    address public immutable taxHandler;
    /// @notice The factory that deployed the implementation: names the settler, and its owner can veto a root.
    address public immutable factory;
    address internal immutable _self;
    /// @notice The quotes the keeper serves besides the pad's WBNB and the QuoteRegistry's (as GangSplitModule).
    address public immutable gangQuote;
    address internal immutable _wbnb;
    address internal immutable _quoteRegistry;

    /// @notice The dev it was made for (the token's creator once bound).
    address public dev;
    /// @notice The bound token and its quote (0 until `bind`).
    address public token;
    address public quote;
    /// @notice The token's promoter terms, read from the pad at `bind`.
    uint16 public shareBps;
    uint32 public window;
    /// @notice The first split that saw the token graduated (never earlier than the graduation; 0: not yet).
    uint64 public firstGradSeenAt;
    uint64 public lastSplitAt;
    uint64 public lastPostAt;
    /// @notice The dev reclaimed: no more roots, and every arrival goes to the dev.
    bool public closed;

    /// @notice Cumulative quote escrowed.
    uint256 public escrowIn;
    /// @notice Cumulative quote the dev took back (`reclaim`).
    uint256 public reclaimed;
    /// @notice Cumulative quote claimed against roots.
    uint256 public claimedTotal;
    /// @notice The dev's quote after a failed push.
    uint256 public devOwed;

    /// @notice The root in effect, the most it can pay out in all, and the last block it covers.
    bytes32 public root;
    uint256 public allocatedTotal;
    uint64 public throughBlock;

    /// @notice A posted root waiting for its dispute window (`pendingRoot` 0: none).
    bytes32 public pendingRoot;
    uint256 public pendingAllocated;
    uint64 public pendingThroughBlock;
    uint64 public pendingActiveAt;

    /// @notice What each account has claimed so far.
    mapping(address account => uint256) public claimed;

    event Bound(address indexed token, address indexed quote, uint16 shareBps, uint32 window);
    /// @notice `incoming` arrived: `toEscrow` stays, the rest went to the dev (or `devOwed`).
    event Split(uint256 incoming, uint256 toEscrow, uint256 toDev);
    event DevOwed(uint256 amount);
    event DevReleased(address indexed to, uint256 amount);
    /// @param uri Where the leaves are published (they can also be recomputed from the chain).
    event RootPosted(bytes32 indexed root, uint256 allocatedTotal, uint64 throughBlock, uint64 activeAt, string uri);
    event RootActivated(bytes32 indexed root, uint256 allocatedTotal, uint64 throughBlock);
    event RootVetoed(bytes32 indexed root);
    event Claimed(address indexed account, address indexed to, uint256 amount);
    event Reclaimed(address indexed to, uint256 amount);
    event Swept(address indexed asset, uint256 amount);

    error ZeroAddress();
    error NotClone();
    error NotFactory();
    error AlreadyInitialized();
    error AlreadyBound();
    error NotBound();
    error NotCurve();
    error NotCreator();
    error NotRecipient();
    error NotPromoted();
    error AllDividends();
    error AlreadyGraduated();
    error NotSettler();
    error NotVetoer();
    error NotDev();
    error BadRoot();
    error BadAllocated();
    error BadThroughBlock();
    error PostPending();
    error NothingPending();
    error TooEarly();
    error TooLate();
    error BadProof();
    error NothingToClaim();
    error OverAllocated();
    error BadReceiver();
    error StillActive();
    error Closed();
    error NothingOwed();
    error BoundQuote();
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

    /// @notice A clone's setup, by the factory in the tx that clones it.
    function initialize(address dev_) external {
        if (address(this) == _self) revert NotClone();
        if (msg.sender != factory) revert NotFactory();
        if (dev != address(0)) revert AlreadyInitialized();
        if (dev_ == address(0)) revert ZeroAddress();
        dev = dev_;
    }

    function moduleType() external pure returns (bytes32) {
        return MODULE_TYPE;
    }

    // ---------------------------------------------------------------- anyone
    /// @notice Bind the dev's token (once, before it graduates, so the bound period holds every pool trade): a curve
    ///         token of this pad, made by the dev with promoter terms and with this contract as its tax recipient, and
    ///         whose tax doesn't all go to holders. A token's promoters are owed pool income only when `token` here is
    ///         that token: the site and the CLI must check it (a dev could point a real token at a module bound to a
    ///         decoy). A token that graduated unbound has no pool share; `sweep` sends the dev its income.
    function bind(address token_) external {
        if (token != address(0)) revert AlreadyBound();
        if (IGangPadBondView(pad).kindOf(token_) != KIND_CURVE) revert NotCurve();
        (address creator, address quote_,,,,, bool graduated,,,,,) = IGangPadBondView(pad).curves(token_);
        if (creator != dev) revert NotCreator();
        if (graduated) revert AlreadyGraduated();
        (, address recipient, uint16 dividendBps,) = IPromotePoolRoute(taxHandler).routeOf(token_);
        if (recipient != address(this)) revert NotRecipient();
        if (dividendBps >= BPS) revert AllDividends();
        (uint16 share, uint32 window_) = IGangPromote(pad).promoteOf(token_);
        if (share == 0) revert NotPromoted();
        token = token_;
        quote = quote_;
        shareBps = share;
        window = window_;
        emit Bound(token_, quote_, share, window_);
    }

    /// @notice IGangRecipientModule's step: split what arrived (`minOut` unused: a split trades nothing).
    function work(uint256) external nonReentrant {
        _split();
    }

    /// @notice Put a root in effect once its dispute window is over (`claim` and `post` do it on their own too).
    function activate() external nonReentrant {
        if (pendingRoot == bytes32(0)) revert NothingPending();
        if (block.timestamp < pendingActiveAt) revert TooEarly();
        _activate();
    }

    /// @notice Send the dev any asset that isn't the bound quote (the tax of another token naming this contract, a stray
    ///         transfer), and any asset at all before `bind`: only the bound token's promoters are owed anything here.
    function sweep(address asset) external nonReentrant returns (uint256 amount) {
        if (asset == quote && asset != address(0)) revert BoundQuote();
        amount = IERC20(asset).balanceOf(address(this));
        if (amount == 0) revert NothingOwed();
        IERC20(asset).safeTransfer(dev, amount);
        emit Swept(asset, amount);
    }

    // ---------------------------------------------------------------- the settler and the factory's owner
    /// @notice Post a root covering the token's trades through block `through`. `allocated` is the cumulative total the
    ///         root can pay out: never below the last one, and never above what is escrowed.
    function post(bytes32 root_, uint256 allocated, uint64 through, string calldata uri) external nonReentrant {
        if (msg.sender != IPromotePoolFactory(factory).settler()) revert NotSettler();
        if (quote == address(0)) revert NotBound();
        if (closed) revert Closed();
        _activate();
        if (pendingRoot != bytes32(0)) revert PostPending();
        if (root_ == bytes32(0)) revert BadRoot();
        _split();
        if (allocated < allocatedTotal || allocated > escrowIn - reclaimed) revert BadAllocated();
        if (through <= throughBlock || through >= block.number) revert BadThroughBlock();
        uint64 activeAt = uint64(block.timestamp) + DISPUTE_WINDOW;
        pendingRoot = root_;
        pendingAllocated = allocated;
        pendingThroughBlock = through;
        pendingActiveAt = activeAt;
        lastPostAt = uint64(block.timestamp);
        emit RootPosted(root_, allocated, through, activeAt, uri);
    }

    /// @notice Drop a posted root during its dispute window.
    function veto() external nonReentrant {
        if (msg.sender != IPromotePoolFactory(factory).owner()) revert NotVetoer();
        bytes32 r = pendingRoot;
        if (r == bytes32(0)) revert NothingPending();
        if (block.timestamp >= pendingActiveAt) revert TooLate();
        _clearPending();
        emit RootVetoed(r);
    }

    // ---------------------------------------------------------------- an account named by a root
    /// @notice Claim up to `cumulative`, the caller's total in the root in effect, to `to`.
    function claim(uint256 cumulative, bytes32[] calldata proof, address to)
        external
        nonReentrant
        returns (uint256 amount)
    {
        if (to == address(0) || to == address(this)) revert BadReceiver();
        _activate();
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(msg.sender, cumulative))));
        if (!MerkleProof.verifyCalldata(proof, root, leaf)) revert BadProof();
        uint256 done = claimed[msg.sender];
        if (cumulative <= done) revert NothingToClaim();
        amount = cumulative - done;
        if (claimedTotal + amount > allocatedTotal) revert OverAllocated();
        claimed[msg.sender] = cumulative;
        claimedTotal += amount;
        IERC20(quote).safeTransfer(to, amount);
        emit Claimed(msg.sender, to, amount);
    }

    // ---------------------------------------------------------------- the dev
    /// @notice Take back what no root allocated and close the module, once the token has graduated and the settler has
    ///         been silent for SETTLER_SILENCE after the later of the graduation being seen and the last post. Roots in effect keep what they allocated;
    ///         no root can be posted after this, and every later arrival goes to the dev.
    function reclaim(address to) external nonReentrant returns (uint256 amount) {
        if (msg.sender != dev) revert NotDev();
        if (to == address(0) || to == address(this)) revert BadReceiver();
        if (closed) revert Closed();
        _activate();
        if (pendingRoot != bytes32(0)) revert PostPending();
        _split();
        uint64 seen = firstGradSeenAt;
        uint64 from = seen > lastPostAt ? seen : lastPostAt;
        if (seen == 0 || block.timestamp < uint256(from) + SETTLER_SILENCE) revert StillActive();
        closed = true;
        amount = escrowIn - reclaimed - allocatedTotal;
        reclaimed += amount;
        if (amount != 0) IERC20(quote).safeTransfer(to, amount);
        emit Reclaimed(to, amount);
    }

    /// @notice Send what a failed push left (reverts while `to` still can't receive).
    function releaseDev(address to) external nonReentrant returns (uint256 amount) {
        if (msg.sender != dev) revert NotDev();
        if (to == address(0) || to == address(this)) revert BadReceiver();
        amount = devOwed;
        if (amount == 0) revert NothingOwed();
        devOwed = 0;
        IERC20(quote).safeTransfer(to, amount);
        emit DevReleased(to, amount);
    }

    // ---------------------------------------------------------------- views
    /// @notice Whether an arrival is still escrowed: unless closed, until `window` + ESCROW_GRACE after the graduation was first seen.
    ///         Every binding is made before the graduation, so no window runs past `firstGradSeenAt + window`.
    function escrowOpen() public view returns (bool) {
        if (closed) return false;
        uint64 seen = firstGradSeenAt;
        return seen == 0 || block.timestamp < uint256(seen) + window + ESCROW_GRACE;
    }

    /// @notice What the module holds for others: the dev's failed pushes and the escrow not paid out or taken back.
    function held() public view returns (uint256) {
        return devOwed + escrowIn - reclaimed - claimedTotal;
    }

    /// @notice What of the bound quote arrived and is not split yet.
    function undistributed() public view returns (uint256) {
        address q = quote;
        if (q == address(0)) return 0;
        uint256 bal = IERC20(q).balanceOf(address(this));
        uint256 h = held();
        return bal > h ? bal - h : 0;
    }

    /// @notice Whether the keeper serves `q`: the pad's WBNB, `gangQuote`, or a QuoteRegistry quote.
    function keeperServes(address q) public view returns (bool) {
        if (q == address(0)) return false;
        if (q == _wbnb || q == gangQuote) return true;
        return _quoteRegistry != address(0) && IPromotePoolQuotes(_quoteRegistry).isQuoted(q);
    }

    /// @notice As GangSplitModule: due after graduation at WORK_MIN_BPS of the pair's quote reserve, or WORK_MAX_IDLE
    ///         after the last split at 1/WORK_IDLE_DIV of that. `minOut` is always 0.
    function previewWork() external view returns (bool due, uint256 minOut) {
        address q = quote;
        if (!keeperServes(q)) return (false, 0);
        uint256 pending = undistributed();
        if (pending == 0) return (false, 0);
        (,,,,,, bool live,,,, address p,) = IGangPadBondView(pad).curves(token);
        if (!live) return (false, 0);
        (uint112 r0, uint112 r1,) = IBondPair(p).getReserves();
        uint256 floor = (IBondPair(p).token0() == token ? uint256(r1) : uint256(r0)) * WORK_MIN_BPS;
        if (pending * BPS >= floor) return (true, 0);
        bool idle = block.timestamp >= lastSplitAt + WORK_MAX_IDLE;
        return (idle && pending * BPS * WORK_IDLE_DIV >= floor, 0);
    }

    // ---------------------------------------------------------------- internal
    function _split() internal {
        address q = quote;
        if (q == address(0)) return;
        if (firstGradSeenAt == 0) {
            (,,,,,, bool live,,,,,) = IGangPadBondView(pad).curves(token);
            if (live) firstGradSeenAt = uint64(block.timestamp);
        }
        uint256 bal = IERC20(q).balanceOf(address(this));
        uint256 h = held();
        if (bal <= h) return;
        uint256 incoming = bal - h;
        uint256 toEscrow = escrowOpen() ? (incoming * shareBps) / BPS : 0;
        uint256 toDev = incoming - toEscrow;
        escrowIn += toEscrow;
        lastSplitAt = uint64(block.timestamp);
        if (toDev != 0 && !_tryTransfer(q, dev, toDev)) {
            devOwed += toDev;
            emit DevOwed(toDev);
        }
        emit Split(incoming, toEscrow, toDev);
    }

    /// @dev Put a pending root in effect when its dispute window is over.
    function _activate() internal {
        bytes32 r = pendingRoot;
        if (r == bytes32(0) || block.timestamp < pendingActiveAt) return;
        root = r;
        allocatedTotal = pendingAllocated;
        throughBlock = pendingThroughBlock;
        emit RootActivated(r, pendingAllocated, pendingThroughBlock);
        _clearPending();
    }

    function _clearPending() internal {
        pendingRoot = bytes32(0);
        pendingAllocated = 0;
        pendingThroughBlock = 0;
        pendingActiveAt = 0;
    }

    /// @dev As GangSplitModule's: at most PUSH_GAS and 32 bytes of return data; a transfer that reports failure instead
    ///      of reverting counts as failed.
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
