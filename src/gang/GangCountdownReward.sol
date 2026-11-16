// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IGangPadBondView} from "./GangBond.sol";
import {IGangPad} from "./interfaces/IGangPad.sol";
import {IGangPadHandler} from "./interfaces/IGangPadDeps.sol";
import {IGangRecipientModule} from "./interfaces/IGangRecipientModule.sol";
import {IQuoteRegistryView} from "./GangSplitModule.sol";
import {IWBNB} from "../interfaces/IPancake.sol";

interface ICountdownToken {
    function pair() external view returns (address);
}

interface ICountdownPair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

/// @title GangCountdownReward (倒计时奖励：dev 那份税变成买家的奖励)
/// @notice The tax recipient of one V3 (curve) token that turns the recipient's part of the pool tax into a reward for
///         the token's buyers. It is also the buy entry: a pool buy made through `buy` / `buyWithQuote` (on the
///         token's own Pancake V2 pair, read from the token) is "counted". Each counted buy sets the round's deadline to
///         `now + window`; once the deadline passes, the round's last `entries` counted buys share a payout fixed when
///         the round is frozen: `min(available × payoutBps, maxPayout)`. The last buy gets `lastBps` of it on top of
///         an equal share of the rest. Whatever is not paid stays for the next round. Buyers `claim` what they were
///         credited (pull, never pushed).
///         Money in: the tax the handler pushes (a plain transfer), of which `devBps` is booked to the dev, and
///         `fund` (a seed, from anyone, the graduation reward's carry included), all of which goes to the reward pool.
///         Nothing is ever taken out except buyers' claims and the dev's booked part. Nobody, not the dev, not the
///         platform, can change a setting or move the pool.
///         No randomness, no holding check: the guard is economic (a counted buy is a real buy of at least `minBuy`
///         paying the buy tax; a round pays at most `maxPayout`). docs/SPEC-COUNTDOWN-REWARD-2026-11-17.md.
/// @dev Not upgradeable (an EIP-1167 clone of a fixed implementation), no owner. Needs no role from the pad, token or
///      handler. Lazy rounds: two buffers alternate; the first counted buy after a deadline freezes that round (its
///      payout reserved) and starts the next; a buffer about to be reused is settled first, so a frozen round is never
///      overwritten. Every entry point books the quote that arrived (`_book`) before it reads or moves the pool.
///      A balance under the books (only a quote whose issuer can take funds from an address, as USDT's
///      `destroyBlackFunds`; WBNB and GANG can't) is only reported (`Shortfall`): the last claims would fail. Not
///      scaled down as GangFloorModule does.
contract GangCountdownReward is IGangRecipientModule, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant MAX_ENTRIES = 20;
    uint64 public constant MIN_WINDOW = 30 minutes;
    uint64 public constant MAX_WINDOW = 24 hours;
    uint16 public constant MIN_PAYOUT_BPS = 1_000;
    uint16 public constant MAX_PAYOUT_BPS = 5_000;
    uint16 public constant MAX_LAST_BPS = 2_000;
    uint16 public constant MAX_DEV_BPS = 5_000;
    uint64 public constant MIN_IDLE = 7 days;
    uint64 public constant MAX_IDLE = 90 days;
    /// @notice Pancake V2's swap fee (0.25%): the output `buy` asks the pair for.
    uint256 internal constant FEE_NUM = 9_975;
    uint256 internal constant FEE_DEN = 10_000;
    bytes32 public constant MODULE_TYPE = "countdown-v1";
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint8 internal constant KIND_CURVE = 1;

    address public immutable pad;
    address public immutable taxHandler;
    address public immutable factory;
    address internal immutable _self;
    address public immutable gangQuote;
    address internal immutable _wbnb;
    address internal immutable _quoteRegistry;

    struct Config {
        uint64 window;
        uint64 idle;
        uint16 payoutBps;
        uint16 lastBps;
        uint16 devBps;
        uint8 entries;
        uint256 minBuy;
        uint256 minPot;
        uint256 maxPayout;
    }

    struct Entry {
        address buyer;
        uint96 tokens;
    }

    /// @dev One of the two alternating round buffers.
    struct Round {
        uint64 id;
        uint32 count; // counted buys in the round (the ring keeps the last `entries`)
        bool frozen;
        bool settled;
        uint256 reserved; // the payout fixed at freeze, until settled
    }

    address public dev;
    /// @notice The only token this module can ever serve, fixed at clone (its CREATE2 address).
    address public rewardToken;
    /// @notice The quote the pool is counted in, fixed at clone.
    address public rewardQuote;
    /// @notice The bound token (0 before `bind`, IGangRecipientModule).
    address public token;
    address public quote;
    Config internal _cfg;

    /// @notice The reward pool not reserved for any round: what the next freeze takes its payout from.
    uint256 public pot;
    /// @notice Σ payouts frozen but not settled.
    uint256 public reservedTotal;
    /// @notice Σ credited to buyers, not claimed.
    uint256 public claimTotal;
    /// @notice The dev's booked part of the tax, not claimed.
    uint256 public devOwed;
    mapping(address => uint256) public claimableOf;

    Round[2] internal _rounds;
    Entry[MAX_ENTRIES][2] internal _ring;
    /// @notice The buffer of the round now running (or of the last one, while none runs).
    uint8 public cur;
    /// @notice The running round's deadline (0: no round running).
    uint64 public deadline;
    uint64 public lastRoundId;
    uint64 public lastCountedAt;
    uint64 public lastFinalizedAt;

    event Bound(address indexed token, address indexed quote);
    event Funded(address indexed from, uint256 amount);
    event TaxBooked(uint256 incoming, uint256 toPot, uint256 toDev);
    event Shortfall(uint256 amount);
    event RoundStarted(uint64 indexed round);
    event Counted(uint64 indexed round, address indexed buyer, uint256 quoteIn, uint256 tokensOut, uint64 deadline);
    event RoundFrozen(uint64 indexed round, uint256 payout, uint256 entries);
    event Settled(uint64 indexed round, uint256 payout, uint256 credited, uint256 dust);
    event Finalized(uint64 indexed round, uint256 payout);
    event Credited(address indexed buyer, uint64 indexed round, uint256 amount);
    event Claimed(address indexed buyer, address indexed to, uint256 amount);
    event DevClaimed(address indexed dev, uint256 amount);
    event Distributed(address indexed asset, uint256 amount);

    error ZeroAddress();
    error NotClone();
    error NotFactory();
    error AlreadyInitialized();
    error BadQuote();
    error BadConfig();
    error AlreadyBound();
    error NotBound();
    error WrongToken();
    error NotCurve();
    error NotCreator();
    error WrongQuote();
    error NothingForRecipient();
    error NotRecipient();
    error NotTradable();
    error NotWbnb();
    error Expired();
    error ZeroAmount();
    error Slippage();
    error NothingToClaim();
    error NotDue();
    error NotCounted();

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

    /// @notice A clone's setup, by the factory in the tx that clones it. Bounds: window MIN_WINDOW–MAX_WINDOW, idle
    ///         MIN_IDLE–MAX_IDLE, payoutBps MIN_PAYOUT_BPS–MAX_PAYOUT_BPS, lastBps ≤ MAX_LAST_BPS, devBps ≤ MAX_DEV_BPS,
    ///         entries 1–MAX_ENTRIES, minBuy and maxPayout above 0.
    function initialize(address dev_, address token_, address quote_, Config calldata c) external {
        if (address(this) == _self) revert NotClone();
        if (msg.sender != factory) revert NotFactory();
        if (dev != address(0)) revert AlreadyInitialized();
        if (dev_ == address(0) || token_ == address(0) || quote_ == address(0)) revert ZeroAddress();
        if (!keeperServes(quote_)) revert BadQuote();
        if (
            c.window < MIN_WINDOW || c.window > MAX_WINDOW || c.idle < MIN_IDLE || c.idle > MAX_IDLE
                || c.payoutBps < MIN_PAYOUT_BPS || c.payoutBps > MAX_PAYOUT_BPS || c.lastBps > MAX_LAST_BPS
                || c.devBps > MAX_DEV_BPS || c.entries == 0 || c.entries > MAX_ENTRIES || c.minBuy == 0
                || c.maxPayout == 0
        ) revert BadConfig();
        dev = dev_;
        rewardToken = token_;
        rewardQuote = quote_;
        _cfg = c;
    }

    function moduleType() external pure returns (bytes32) {
        return MODULE_TYPE;
    }

    // ---------------------------------------------------------------- buyers
    /// @notice Buy the token with BNB (a WBNB-quoted token only) on its own pair; the tokens go to the caller. Counted
    ///         when at least `minBuy` and a round runs (or the pool is at least `minPot`). With `mustCount` a buy that
    ///         would not be counted reverts NotCounted (what `wouldCount` said before may have changed by the block).
    function buy(uint256 minTokensOut, uint256 deadline_, bool mustCount)
        external
        payable
        nonReentrant
        returns (uint256 tokensOut)
    {
        if (rewardQuote != _wbnb) revert NotWbnb();
        if (msg.value == 0) revert ZeroAmount();
        address p = _pairChecked(deadline_);
        _book();
        // the buyer's BNB never sits here as WBNB: wrapped and sent on in one go, no balance read in between
        IWBNB(_wbnb).deposit{value: msg.value}();
        IERC20(_wbnb).safeTransfer(p, msg.value);
        tokensOut = _swapOut(p, minTokensOut, mustCount);
    }

    /// @notice Buy the token with `quoteIn` of its quote (approved to this contract) on its own pair; the quote goes
    ///         straight from the caller to the pair. Counted as `buy`.
    function buyWithQuote(uint256 quoteIn, uint256 minTokensOut, uint256 deadline_, bool mustCount)
        external
        nonReentrant
        returns (uint256 tokensOut)
    {
        if (quoteIn == 0) revert ZeroAmount();
        address p = _pairChecked(deadline_);
        _book();
        IERC20(rewardQuote).safeTransferFrom(msg.sender, p, quoteIn);
        tokensOut = _swapOut(p, minTokensOut, mustCount);
    }

    /// @notice Send what the caller was credited to `to`.
    function claim(address to) external nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        amount = claimableOf[msg.sender];
        if (amount == 0) revert NothingToClaim();
        claimableOf[msg.sender] = 0;
        claimTotal -= amount;
        IERC20(rewardQuote).safeTransfer(to, amount);
        emit Claimed(msg.sender, to, amount);
    }

    // ---------------------------------------------------------------- anyone
    /// @notice Add `amount` of the quote (approved to this contract) to the reward pool: a seed, or the graduation
    ///         reward's carry. All of it is the pool's (no dev part). What actually arrived is counted. Only once bound
    ///         (NotBound before).
    function fund(uint256 amount) external nonReentrant {
        _fund(amount);
    }

    /// @notice The graduation reward's carry (冲毕业奖励): the same as `fund` (approved, all of it to the pool, no dev
    ///         part). Its own name so the pad's call reads as what it is.
    function receiveCarry(uint256 amount) external nonReentrant {
        _fund(amount);
    }

    function _fund(uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();
        // only into a module bound to its token: a seed or carry sent to one that never binds would be stuck (L-4)
        if (token == address(0)) revert NotBound();
        _book();
        IERC20 q = IERC20(rewardQuote);
        uint256 before = q.balanceOf(address(this));
        q.safeTransferFrom(msg.sender, address(this), amount);
        uint256 got = q.balanceOf(address(this)) - before;
        pot += got;
        emit Funded(msg.sender, got);
    }

    /// @notice Bind the token (once): `token_` must be `rewardToken`, by now a V3 token the dev created with this
    ///         contract as its tax recipient, quoted in `rewardQuote`, with less than all of the tax to dividends.
    function bind(address token_) external {
        if (token != address(0)) revert AlreadyBound();
        if (token_ != rewardToken) revert WrongToken();
        if (IGangPadBondView(pad).kindOf(token_) != KIND_CURVE) revert NotCurve();
        (address creator, address quote_,,,,,,,, uint16 dividendBps,,) = IGangPadBondView(pad).curves(token_);
        if (creator != dev) revert NotCreator();
        if (quote_ != rewardQuote) revert WrongQuote();
        if (dividendBps >= BPS) revert NothingForRecipient();
        (, address recipient) = IGangPadHandler(taxHandler).routeOf(token_);
        if (recipient != address(this)) revert NotRecipient();
        token = token_;
        quote = quote_;
        emit Bound(token_, quote_);
    }

    /// @notice Book what arrived, freeze the running round once its deadline passed, and settle every frozen round.
    function settle() external nonReentrant {
        _settleAll();
    }

    /// @notice After `idle` with no counted buy: pay the last round's entries again (at most `maxPayout`), once per
    ///         `idle`. A later counted buy starts the game again as usual.
    function finalize() external nonReentrant {
        _finalize();
    }

    function _settleAll() internal {
        _book();
        _freezeIfDue();
        _settleBuf(0);
        _settleBuf(1);
    }

    function _finalize() internal {
        _settleAll();
        uint64 last = lastCountedAt;
        uint64 idle = _cfg.idle;
        if (last == 0 || deadline != 0) revert NotDue();
        uint64 since = lastFinalizedAt > last ? lastFinalizedAt : last;
        if (block.timestamp < uint256(since) + idle) revert NotDue();
        lastFinalizedAt = uint64(block.timestamp);
        // under `minPot` no new round can start either: the pool waits for the tax to bring it back, it is not paid
        // again and again to the last round's entries (audit 2026-11-17 L-3)
        if (pot < _cfg.minPot) revert NotDue();
        uint8 b = cur;
        uint256 payout = _payoutOf(pot);
        if (payout == 0) revert NotDue();
        pot -= payout;
        uint256 credited = _credit(b, payout);
        uint256 dust = payout - credited;
        pot += dust;
        emit Finalized(_rounds[b].id, credited);
    }

    /// @notice Any asset other than the quote that ended up here (another token's tax naming this module, a stray
    ///         transfer) can't count in the pool: all of it goes to 0xdead, as GangFloorModule's `distribute`.
    function distribute(address asset) external nonReentrant returns (uint256 amount) {
        if (asset == rewardQuote) revert WrongQuote();
        amount = IERC20(asset).balanceOf(address(this));
        if (amount == 0) revert ZeroAmount();
        IERC20(asset).safeTransfer(DEAD, amount);
        emit Distributed(asset, amount);
    }

    /// @notice Send the dev's booked part of the tax to the dev.
    function claimDev() external nonReentrant returns (uint256 amount) {
        _book();
        amount = devOwed;
        if (amount == 0) revert NothingToClaim();
        devOwed = 0;
        IERC20(rewardQuote).safeTransfer(dev, amount);
        emit DevClaimed(dev, amount);
    }

    /// @notice IGangRecipientModule's step: `settle` (or `finalize` when that is what is due).
    function work(uint256) external nonReentrant {
        (bool settleDue, bool finalizeDue) = _due();
        if (settleDue) _settleAll();
        else if (finalizeDue) _finalize();
        else revert NotDue();
    }

    // ---------------------------------------------------------------- views
    function config() external view returns (Config memory) {
        return _cfg;
    }

    function keeperServes(address q) public view returns (bool) {
        if (q == address(0)) return false;
        if (q == _wbnb || q == gangQuote) return true;
        return _quoteRegistry != address(0) && IQuoteRegistryView(_quoteRegistry).isQuoted(q);
    }

    /// @notice The running round's id (0: none running).
    function currentRound() external view returns (uint64) {
        return deadline == 0 ? 0 : _rounds[cur].id;
    }

    /// @notice What a freeze now would take its payout from: the pool with what arrived since the last booking.
    function potAvailable() public view returns (uint256 p) {
        (uint256 incoming, bool short) = _incoming();
        p = pot;
        if (!short) p += incoming - (incoming * _cfg.devBps) / BPS;
    }

    /// @notice A buffer's round: id, counted buys, frozen, settled, reserved payout, and its entries (oldest first).
    function round(uint8 b)
        external
        view
        returns (uint64 id, uint32 count, bool frozen, bool settled, uint256 reserved, Entry[] memory list)
    {
        Round storage r = _rounds[b];
        (id, count, frozen, settled, reserved) = (r.id, r.count, r.frozen, r.settled, r.reserved);
        list = _entriesOf(b);
    }

    /// @notice Whether a pool buy of `quoteIn` would be counted now.
    function wouldCount(uint256 quoteIn) external view returns (bool) {
        if (token == address(0) || quoteIn < _cfg.minBuy) return false;
        if (deadline != 0 && block.timestamp <= deadline) return true;
        // a buy after the deadline freezes that round and starts the next one, as does the first buy with none running
        uint256 p = potAvailable();
        if (deadline != 0) p -= _payoutOf(p);
        return p >= _cfg.minPot;
    }

    /// @notice IGangRecipientModule: due when a round can be frozen or settled, or a `finalize` can pay.
    function previewWork() external view returns (bool due, uint256 minOut) {
        (bool s, bool f) = _due();
        return (s || f, 0);
    }

    // ---------------------------------------------------------------- internal: buying
    function _pairChecked(uint256 deadline_) internal view returns (address p) {
        if (block.timestamp > deadline_) revert Expired();
        address t = token;
        if (t == address(0)) revert NotBound();
        // the token's own pair, set once at graduation (0 before: nothing to buy on)
        p = ICountdownToken(t).pair();
        if (p == address(0)) revert NotTradable();
    }

    /// @dev The quote is in the pair: ask it for Pancake V2's output (0.25% fee) for what came in, to the caller,
    ///      then count the buy.
    function _swapOut(address p, uint256 minTokensOut, bool mustCount) internal returns (uint256 tokensOut) {
        address t = token;
        (uint112 r0, uint112 r1,) = ICountdownPair(p).getReserves();
        bool t0 = ICountdownPair(p).token0() == t;
        if ((t0 ? ICountdownPair(p).token1() : ICountdownPair(p).token0()) != rewardQuote) revert WrongQuote();
        (uint256 rIn, uint256 rOut) = t0 ? (uint256(r1), uint256(r0)) : (uint256(r0), uint256(r1));
        uint256 quoteIn = IERC20(rewardQuote).balanceOf(p) - rIn;
        uint256 inFee = quoteIn * FEE_NUM;
        uint256 out = (inFee * rOut) / (rIn * FEE_DEN + inFee);
        if (out == 0) revert ZeroAmount();
        uint256 before = IERC20(t).balanceOf(msg.sender);
        if (t0) ICountdownPair(p).swap(out, 0, msg.sender, "");
        else ICountdownPair(p).swap(0, out, msg.sender, "");
        tokensOut = IERC20(t).balanceOf(msg.sender) - before;
        if (tokensOut < minTokensOut) revert Slippage();
        if (!_count(msg.sender, quoteIn, tokensOut) && mustCount) revert NotCounted();
    }

    function _count(address buyer, uint256 quoteIn, uint256 tokensOut) internal returns (bool) {
        if (quoteIn < _cfg.minBuy) return false;
        _freezeIfDue();
        if (deadline == 0) {
            if (pot < _cfg.minPot) return false;
            _startRound();
        }
        uint8 b = cur;
        Round storage r = _rounds[b];
        uint256 n = _cfg.entries;
        _ring[b][r.count % n] = Entry(buyer, tokensOut > type(uint96).max ? type(uint96).max : uint96(tokensOut));
        r.count += 1;
        uint64 d = uint64(block.timestamp) + _cfg.window;
        deadline = d;
        lastCountedAt = uint64(block.timestamp);
        emit Counted(r.id, buyer, quoteIn, tokensOut, d);
        return true;
    }

    /// @dev A new round in the other buffer; a round still frozen there is settled first, so it is never overwritten.
    function _startRound() internal {
        uint8 b = lastRoundId == 0 ? 0 : 1 - cur;
        _settleBuf(b);
        uint64 id = ++lastRoundId;
        _rounds[b] = Round(id, 0, false, false, 0);
        cur = b;
        emit RoundStarted(id);
    }

    // ---------------------------------------------------------------- internal: rounds
    function _freezeIfDue() internal {
        uint64 d = deadline;
        if (d == 0 || block.timestamp <= d) return;
        Round storage r = _rounds[cur];
        uint256 payout = _payoutOf(pot);
        pot -= payout;
        reservedTotal += payout;
        r.reserved = payout;
        r.frozen = true;
        deadline = 0;
        emit RoundFrozen(r.id, payout, _min(r.count, _cfg.entries));
    }

    function _settleBuf(uint8 b) internal {
        Round storage r = _rounds[b];
        if (!r.frozen || r.settled) return;
        uint256 payout = r.reserved;
        r.reserved = 0;
        r.settled = true;
        reservedTotal -= payout;
        uint256 credited = _credit(b, payout);
        uint256 dust = payout - credited;
        pot += dust;
        emit Settled(r.id, payout, credited, dust);
    }

    /// @dev `payout` over buffer `b`'s entries: an equal share of (payout − last's extra) each, the last entry the
    ///      extra `lastBps` on top; one entry takes all. Returns what was credited (the rest is rounding dust).
    function _credit(uint8 b, uint256 payout) internal returns (uint256 credited) {
        Round storage r = _rounds[b];
        uint256 n = _cfg.entries;
        uint256 k = _min(r.count, n);
        if (k == 0 || payout == 0) return 0;
        uint64 id = r.id;
        uint256 lastIdx = (uint256(r.count) - 1) % n;
        uint256 extra = k == 1 ? 0 : (payout * _cfg.lastBps) / BPS;
        uint256 each = (payout - extra) / k;
        for (uint256 j; j < k; j++) {
            uint256 idx = (uint256(r.count) - 1 - j) % n;
            uint256 amt = idx == lastIdx ? each + extra : each;
            if (amt == 0) continue;
            address w = _ring[b][idx].buyer;
            claimableOf[w] += amt;
            credited += amt;
            emit Credited(w, id, amt);
        }
        claimTotal += credited;
    }

    function _payoutOf(uint256 p) internal view returns (uint256 payout) {
        payout = (p * _cfg.payoutBps) / BPS;
        if (payout > _cfg.maxPayout) payout = _cfg.maxPayout;
    }

    // ---------------------------------------------------------------- internal: money in
    /// @dev The quote above everything accounted for is tax the handler pushed: `devBps` of it to the dev, the rest
    ///      to the pool. `fund` books its own arrivals, so they never pass through here.
    function _book() internal {
        (uint256 incoming, bool short) = _incoming();
        if (short) {
            emit Shortfall(incoming);
            return;
        }
        if (incoming == 0) return;
        uint256 toDev = (incoming * _cfg.devBps) / BPS;
        devOwed += toDev;
        pot += incoming - toDev;
        emit TaxBooked(incoming, incoming - toDev, toDev);
    }

    /// @dev (balance − accounted, false), or (accounted − balance, true) when the balance is short.
    function _incoming() internal view returns (uint256 amount, bool short) {
        uint256 bal = IERC20(rewardQuote).balanceOf(address(this));
        uint256 held = pot + reservedTotal + claimTotal + devOwed;
        return bal >= held ? (bal - held, false) : (held - bal, true);
    }

    function _due() internal view returns (bool settleDue, bool finalizeDue) {
        if (deadline != 0 && block.timestamp > deadline) return (true, false);
        if ((_rounds[0].frozen && !_rounds[0].settled) || (_rounds[1].frozen && !_rounds[1].settled)) {
            return (true, false);
        }
        uint64 last = lastCountedAt;
        if (last == 0 || deadline != 0) return (false, false);
        uint64 since = lastFinalizedAt > last ? lastFinalizedAt : last;
        uint256 p = potAvailable();
        finalizeDue = block.timestamp >= uint256(since) + _cfg.idle && p >= _cfg.minPot && _payoutOf(p) != 0;
    }

    function _entriesOf(uint8 b) internal view returns (Entry[] memory list) {
        Round storage r = _rounds[b];
        uint256 n = _cfg.entries;
        uint256 k = _min(r.count, n);
        list = new Entry[](k);
        for (uint256 j; j < k; j++) {
            list[j] = _ring[b][(uint256(r.count) - k + j) % n];
        }
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}
