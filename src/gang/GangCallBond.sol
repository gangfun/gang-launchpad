// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IGangCallBond} from "./interfaces/IGangCallBond.sol";

/// @dev What GangCallBond reads from the 3.0 pad (public getters; `curves` keeps the 12-field layout).
interface IGangPad3CallView {
    function kindOf(address token) external view returns (uint8);
    function tokenVersionOf(address token) external view returns (uint8);
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
}

interface ICallBondPair {
    function token0() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
}

interface ICallBondWBNB {
    function deposit() external payable;
}

/// @title GangCallBond (喊单保证金)
/// @notice An address bonds its own call on a 3.0 curve token: `amount` of the token's quote, promising its balance of
///         the token stays at least `hold` from the post until `settle` (docs/SPEC-AGENT-CALLS-2026-11-09.md §5).
///         - Kept: from the deadline anyone `requestSettle`s, and SETTLE_DELAY later `settle`s while the balance still
///           meets the promise (both times; after graduation the pair must not be mid flash swap). The whole bond goes
///           back to the caller.
///         - Broken: whenever the balance is below `hold` before `settle` (after the deadline too), anyone `report`s.
///           1% to the reporter (burnt when the caller reports itself), half burnt at once, the rest becomes this
///           bond's followers' pool. The settler posts one Merkle root of (account, amount) payouts; the owner (Safe)
///           can `veto` it for DISPUTE; after that anyone `claim`s for an account. Nothing in the pool can ever reach
///           the caller: what isn't paid out goes to 0xdead.
/// @dev Not upgradeable. Reads only the pad's public views, balances and the pair's reserves; needs no role anywhere.
///      Which follower gets what is computed off-chain from chain data (spec §5.3); the contract only bounds it: one
///      live root per bond, its total at most the pool, claims at most the total, one claim per account.
contract GangCallBond is IGangCallBond, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    uint256 public constant BPS = 10_000;
    uint256 public constant REPORTER_BPS = 100;
    uint256 public constant BURN_BPS = 5_000;
    uint64 public constant MIN_DURATION = 48 hours;
    uint64 public constant MAX_DURATION = 7 days;
    uint64 public constant SETTLE_DELAY = 1 hours;
    /// @notice A root can't come before the price window (1 h from the violation, which is at or before the report)
    ///         has closed and its blocks are final.
    uint64 public constant ROOT_DELAY = 1 hours + 10 minutes;
    /// @notice Roots can be posted this long after the report ...
    uint64 public constant POST_WINDOW = 28 days;
    /// @notice ... or this long after a veto ...
    uint64 public constant REPOST_WINDOW = 3 days;
    /// @notice ... but never later than this after the report.
    uint64 public constant POST_CAP = 60 days;
    /// @notice The owner can veto a root this long after it was posted; claims start after it.
    uint64 public constant DISPUTE = 2 days;
    /// @notice Claims run this long after a root became claimable.
    uint64 public constant CLAIM_WINDOW = 90 days;
    uint8 public constant KIND_CURVE = 1;
    uint8 public constant TOKEN_VERSION = 1;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address public immutable pad;
    address public immutable wbnb;
    address public immutable quote1;
    address public immutable quote2;
    address public immutable quote3;

    address public settler;
    uint256 public bondCount;

    mapping(uint256 id => Bond) internal _bonds;
    mapping(address caller => mapping(address token => uint256 id)) public activeBondOf;
    mapping(uint256 id => mapping(address account => bool)) public claimed;

    /// @param quotes_ up to three more allowed quotes besides WBNB (USDT, USDC, USD1 on mainnet); 0 = unused.
    constructor(address pad_, address wbnb_, address[3] memory quotes_, address owner_, address settler_)
        Ownable(owner_)
    {
        if (pad_ == address(0) || wbnb_ == address(0) || settler_ == address(0)) revert ZeroAddress();
        if (settler_ == owner_) revert SettlerIsOwner();
        pad = pad_;
        wbnb = wbnb_;
        quote1 = quotes_[0];
        quote2 = quotes_[1];
        quote3 = quotes_[2];
        settler = settler_;
        emit SettlerSet(settler_);
    }

    // ---------------------------------------------------------------- owner
    function setSettler(address settler_) external onlyOwner {
        if (settler_ == address(0)) revert ZeroAddress();
        if (settler_ == owner() || settler_ == pendingOwner()) revert SettlerIsOwner();
        settler = settler_;
        emit SettlerSet(settler_);
    }

    /// @dev Without an owner nobody could veto a root or replace a stolen settler key.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    /// @dev The settler and the vetoer must stay different accounts.
    function transferOwnership(address newOwner) public override onlyOwner {
        if (newOwner == settler) revert SettlerIsOwner();
        super.transferOwnership(newOwner);
    }

    /// @notice Void a root during its dispute window. The settler may post again (REPOST_WINDOW).
    function veto(uint256 id) external onlyOwner {
        Bond storage b = _bonds[id];
        if (b.state != State.Reported || b.root == bytes32(0)) revert NoPendingRoot();
        if (block.timestamp >= uint256(b.rootAt) + DISPUTE) revert DisputeOver();
        bytes32 root = b.root;
        b.root = bytes32(0);
        b.total = 0;
        b.rootAt = 0;
        b.vetoAt = uint64(block.timestamp);
        emit RootVetoed(id, root);
    }

    // ---------------------------------------------------------------- caller
    /// @notice Bond a call: `amount` of the token's quote (a WBNB quote takes native BNB as msg.value too), promising
    ///         the sender's balance of `token` stays at least `hold` until `settle`, `duration` (48 h – 7 days) on.
    ///         `noteTx` names the call (not checked here; spec §5.4 says when the site shows it as bonded).
    function post(address token, bytes32 noteTx, uint256 amount, uint256 hold, uint64 duration)
        external
        payable
        nonReentrant
        returns (uint256 id)
    {
        address quote = _checkToken(token);
        if (noteTx == bytes32(0)) revert BadNote();
        if (amount == 0) revert ZeroAmount();
        if (duration < MIN_DURATION || duration > MAX_DURATION) revert BadDuration();
        if (hold == 0 || hold > IERC20(token).balanceOf(msg.sender)) revert BadHold();
        if (activeBondOf[msg.sender][token] != 0) revert BondLive();

        id = ++bondCount;
        uint64 deadline = uint64(block.timestamp) + duration;
        Bond storage b = _bonds[id];
        b.caller = msg.sender;
        b.postedAt = uint64(block.timestamp);
        b.state = State.Active;
        b.token = token;
        b.deadline = deadline;
        b.quote = quote;
        b.amount = amount.toUint128();
        b.hold = hold.toUint128();
        b.noteTx = noteTx;
        activeBondOf[msg.sender][token] = id;

        _pull(quote, amount);
        emit CallBondPosted(id, msg.sender, token, noteTx, quote, amount, hold, deadline);
    }

    // ---------------------------------------------------------------- anyone
    /// @notice The caller holds less than it promised: 1% to the sender (burnt when the sender is the caller), half
    ///         to 0xdead, the rest is this bond's followers' pool. Works after the deadline too, until `settle`.
    function report(uint256 id) external nonReentrant {
        Bond storage b = _activeOf(id);
        uint256 bal = IERC20(b.token).balanceOf(b.caller);
        if (bal >= b.hold) revert NotViolated();

        uint256 amount = b.amount;
        uint256 reward = (amount * REPORTER_BPS) / BPS;
        uint256 burned = (amount * BURN_BPS) / BPS;
        if (msg.sender == b.caller) {
            burned += reward;
            reward = 0;
        }
        uint256 pool = amount - reward - burned;

        b.state = State.Reported;
        b.reportedAt = uint64(block.timestamp);
        b.reportedBlock = uint64(block.number);
        b.pool = pool.toUint128();
        delete activeBondOf[b.caller][b.token];

        IERC20 q = IERC20(b.quote);
        if (reward != 0) q.safeTransfer(msg.sender, reward);
        if (burned != 0) q.safeTransfer(DEAD, burned);
        emit CallBondReported(id, msg.sender, block.number, bal, reward, burned, pool);
    }

    /// @notice From the deadline, while the caller holds what it promised: `settle` may run SETTLE_DELAY from now.
    function requestSettle(uint256 id) external nonReentrant {
        Bond storage b = _activeOf(id);
        if (block.timestamp < b.deadline) revert NotDue();
        if (b.settleAt != 0) revert AlreadyRequested();
        _requireHeld(b);
        uint64 at = uint64(block.timestamp) + SETTLE_DELAY;
        b.settleAt = at;
        emit SettleRequested(id, at);
    }

    /// @notice A requested settle, SETTLE_DELAY on, the promise still kept: the whole bond goes back to the caller.
    function settle(uint256 id) external nonReentrant {
        Bond storage b = _activeOf(id);
        if (b.settleAt == 0) revert NoSettleRequest();
        if (block.timestamp < b.settleAt) revert NotDue();
        _requireHeld(b);
        b.state = State.Settled;
        delete activeBondOf[b.caller][b.token];
        IERC20(b.quote).safeTransfer(b.caller, b.amount);
        emit CallBondSettled(id, b.caller, b.amount);
    }

    // ---------------------------------------------------------------- the followers' pool
    /// @notice The settler posts a reported bond's payouts: leaves `leaf(id, account, amount)`, summing to `total`
    ///         (0 when no follower qualifies). A leaf for the caller can never be claimed.
    function postRoot(uint256 id, bytes32 root, uint256 total) external nonReentrant {
        if (msg.sender != settler) revert NotSettler();
        Bond storage b = _bonds[id];
        if (b.state != State.Reported) revert NotReported();
        if (b.root != bytes32(0)) revert RootExists();
        if (block.timestamp < uint256(b.reportedAt) + ROOT_DELAY) revert TooEarly();
        if (!_canPost(b)) revert PostWindowClosed();
        // total 0: no follower qualifies, and the whole pool burns once the dispute window is over (burnRemainder)
        if (root == bytes32(0) || total > b.pool) revert BadTotal();
        b.root = root;
        b.total = total.toUint128();
        b.rootAt = uint64(block.timestamp);
        emit RootPosted(id, root, total, uint64(block.timestamp) + DISPUTE);
    }

    /// @notice Pay `account` its leaf (anyone may send it; the money only goes to `account`).
    function claim(uint256 id, address account, uint256 amount, bytes32[] calldata proof) external nonReentrant {
        Bond storage b = _bonds[id];
        if (!_claimable(b)) revert NotClaimable();
        if (account == b.caller) revert NotFollower(); // nothing in the pool reaches the caller, whatever the root says
        if (claimed[id][account]) revert AlreadyClaimed();
        if (!MerkleProof.verifyCalldata(proof, b.root, _leaf(id, account, amount))) revert BadProof();
        uint256 spent = uint256(b.spent) + amount;
        uint256 paidToFollowers = spent - (b.remainderBurned ? uint256(b.pool) - b.total : 0);
        if (paidToFollowers > b.total) revert OverTotal();
        claimed[id][account] = true;
        b.spent = spent.toUint128();
        IERC20(b.quote).safeTransfer(account, amount);
        emit Claimed(id, account, amount);
    }

    /// @notice Once a root is claimable, the part of the pool it doesn't pay out goes to 0xdead.
    function burnRemainder(uint256 id) external nonReentrant {
        Bond storage b = _bonds[id];
        if (b.state != State.Reported || !_ready(b)) revert NotClaimable();
        if (b.remainderBurned) revert AlreadyBurned();
        uint256 amount = uint256(b.pool) - b.total;
        b.remainderBurned = true;
        b.spent += amount.toUint128();
        if (amount != 0) IERC20(b.quote).safeTransfer(DEAD, amount);
        emit RemainderBurned(id, amount);
    }

    /// @notice Close a reported bond and send what its pool has left to 0xdead: no root pending or live and none can
    ///         be posted any more, or the claim window of the live root is over.
    function burnUnpaid(uint256 id) external nonReentrant {
        Bond storage b = _bonds[id];
        if (b.state != State.Reported) revert NotReported();
        bool over = b.root == bytes32(0)
            ? !_canPost(b)
            : _ready(b) && block.timestamp >= uint256(b.rootAt) + DISPUTE + CLAIM_WINDOW;
        if (!over) revert StillPayable();
        uint256 left = uint256(b.pool) - b.spent;
        b.state = State.Closed;
        b.spent = b.pool;
        if (left != 0) IERC20(b.quote).safeTransfer(DEAD, left);
        emit UnpaidBurned(id, left);
    }

    // ---------------------------------------------------------------- views
    function bondOf(uint256 id) external view returns (Bond memory) {
        return _bonds[id];
    }

    function canPostRoot(uint256 id) external view returns (bool) {
        Bond storage b = _bonds[id];
        return b.state == State.Reported && b.root == bytes32(0)
            && block.timestamp >= uint256(b.reportedAt) + ROOT_DELAY && _canPost(b);
    }

    /// @notice The Merkle leaf of a payout (OpenZeppelin StandardMerkleTree's double hash over
    ///         (this contract, chain id, id, account, amount)).
    function leaf(uint256 id, address account, uint256 amount) external view returns (bytes32) {
        return _leaf(id, account, amount);
    }

    // ---------------------------------------------------------------- internal
    /// @dev A 3.0 curve token on the curve, created under the first rule set, quoted in an allowed quote.
    function _checkToken(address token) internal view returns (address quote) {
        IGangPad3CallView p = IGangPad3CallView(pad);
        if (p.kindOf(token) != KIND_CURVE) revert NotCurveToken();
        if (p.tokenVersionOf(token) != TOKEN_VERSION) revert BadTokenVersion();
        bool graduated;
        (, quote,,,,, graduated,,,,,) = p.curves(token);
        if (graduated) revert AlreadyGraduated();
        if (!_allowedQuote(quote)) revert QuoteNotAllowed();
    }

    function _allowedQuote(address q) internal view returns (bool) {
        return q != address(0) && (q == wbnb || q == quote1 || q == quote2 || q == quote3);
    }

    function _activeOf(uint256 id) internal view returns (Bond storage b) {
        b = _bonds[id];
        if (b.state != State.Active) revert NotActive();
    }

    /// @dev The promise holds now; after graduation the pair's token balance must cover its reserve (no flash swap
    ///      lending the caller its tokens for this call).
    function _requireHeld(Bond storage b) internal view {
        address token = b.token;
        if (IERC20(token).balanceOf(b.caller) < b.hold) revert Violated();
        (,,,,,, bool graduated,,,, address pair,) = IGangPad3CallView(pad).curves(token);
        if (!graduated || pair == address(0)) return;
        (uint112 r0, uint112 r1,) = ICallBondPair(pair).getReserves();
        uint256 reserve = ICallBondPair(pair).token0() == token ? r0 : r1;
        if (IERC20(token).balanceOf(pair) < reserve) revert FlashSwapActive();
    }

    function _canPost(Bond storage b) internal view returns (bool) {
        uint256 t = block.timestamp;
        uint256 r = b.reportedAt;
        if (t >= r + POST_CAP) return false;
        if (t < r + POST_WINDOW) return true;
        return b.vetoAt != 0 && t < uint256(b.vetoAt) + REPOST_WINDOW;
    }

    function _ready(Bond storage b) internal view returns (bool) {
        return b.root != bytes32(0) && block.timestamp >= uint256(b.rootAt) + DISPUTE;
    }

    function _claimable(Bond storage b) internal view returns (bool) {
        return b.state == State.Reported && _ready(b) && block.timestamp < uint256(b.rootAt) + DISPUTE + CLAIM_WINDOW;
    }

    function _leaf(uint256 id, address account, uint256 amount) internal view returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(address(this), block.chainid, id, account, amount))));
    }

    function _pull(address quote, uint256 amount) internal {
        if (msg.value != 0) {
            if (quote != wbnb || msg.value != amount) revert BadValue();
            ICallBondWBNB(wbnb).deposit{value: amount}();
            return;
        }
        uint256 before = IERC20(quote).balanceOf(address(this));
        IERC20(quote).safeTransferFrom(msg.sender, address(this), amount);
        if (IERC20(quote).balanceOf(address(this)) - before != amount) revert FeeOnTransferQuote();
    }
}
