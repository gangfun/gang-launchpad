// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title SharedDividendVault (LaunchpadV3 + 打新 · one dividend vault for both cores)
/// @notice launchpad-v2/DividendVault's accounting, shared by several cores. Each token belongs to the core that
///         registered it, and only that core — or an operator bound to that core — can write its shares or deposit
///         its rewards: a handler of one core can't touch another core's tokens (syncShares is permissionless).
///         The share floor is kept per core, so one core raising its floor never changes another core's holders.
/// @dev Removing a core (`setLaunchpad(core, false)`) only stops new registrations: writes for its existing tokens keep
///      working, so retiring a core can't freeze dividends already promised. Claims never depend on any core.
///
///      Two ways rewards come in:
///      - `depositReward`: quote paid in now (the bonding-curve tax), split over the shares of this moment.
///      - Pool tax after graduation is taken in the token and sold later. Its holders' part is credited the moment it
///        is taxed (`accrueDividendUnits`, in tax-token units, over the shares of that moment) and turned into quote
///        when sold (`convertDividend`), so who held when the tax was paid is who gets it — not who holds when it is
///        sold. Units sit in batches sold first-in first-out; at most two are unsettled: `open` takes new units,
///        `selling` is being sold. A batch settles once all its units are sold, at the quote they fetched; each
///        holder then gets their units of it × quote / units. Rounding is always down (dust stays here).
contract SharedDividendVault is Ownable2Step {
    using SafeERC20 for IERC20;

    mapping(address => bool) public launchpads;
    /// @notice The one core an operator may act for (0 = not an operator).
    mapping(address account => address launchpad) public operatorOf;
    /// @notice The one operator bound to each core (its tax handler); set once, never changed.
    mapping(address launchpad => address) public operatorFor;
    /// @notice Each core's floor for tokens it registers from now on (snapshotted per token at registerToken).
    mapping(address launchpad => uint256) public minimumShareBalanceOf;
    /// @notice A token's floor, fixed when it was registered: later floor changes never touch existing holders.
    mapping(address token => uint256) public tokenMinimumShareBalance;

    mapping(address token => address launchpad) public launchpadOf;
    mapping(address token => address quote) public quoteOf;
    mapping(address token => uint256) public totalShares;
    mapping(address token => uint256) public accRewardPerShare; // 1e18 scaled
    mapping(address token => mapping(address user => uint256)) public shares;
    mapping(address token => mapping(address user => uint256)) public rewardDebt;
    mapping(address token => mapping(address user => uint256)) public pendingCredit;
    mapping(address => bool) public excluded;

    /// @dev Scale of the tax-time per-share indexes (`acc`, `cumQuote`): large shares against a small batch must keep
    ///      their precision (1e18 left ~8 digits).
    uint256 internal constant UNIT_SCALE = 1e36;

    /// @dev One batch of tax-time dividend units of a token.
    struct Batch {
        uint128 units; // credited to holders (token amounts: ≤ the 1e27 supply)
        uint128 sold; // of `units`, sold so far
        uint256 quote; // quote received for `sold`
        uint256 acc; // units per share (UNIT_SCALE), only grows while the batch is open
        uint256 cumQuote; // Σ acc × quote / units over settled batches up to this one (UNIT_SCALE); set when it settles
    }

    /// @dev Batch ids: `open` takes new units; `selling` (0 = none) is being sold; `settled` = the last settled id.
    ///      Ids grow by one and settle in order, so every id ≤ `settled` is settled and `selling` = `settled` + 1.
    struct Pipe {
        uint64 open;
        uint64 selling;
        uint64 settled;
    }

    /// @dev A holder's tax-time units: `batch` = the open batch when last touched, `debt` = its acc then; unsettled
    ///      units it already holds sit in at most two batches (`idA` / `idB`).
    struct Position {
        uint64 batch;
        uint64 idA;
        uint64 idB;
        uint256 debt;
        uint128 unitsA;
        uint128 unitsB;
    }

    mapping(address token => Pipe) public pipeOf;
    mapping(address token => mapping(uint256 id => Batch)) public batchOf;
    mapping(address token => mapping(address user => Position)) public positionOf;

    event LaunchpadSet(address indexed launchpad, bool enabled);
    event OperatorSet(address indexed account, address indexed launchpad);
    event TokenRegistered(address indexed token, address indexed quote, address indexed launchpad);
    event RewardDeposited(address indexed token, uint256 amount);
    event ShareUpdated(address indexed token, address indexed user, uint256 share);
    event DividendClaimed(address indexed token, address indexed user, uint256 amount);
    event Excluded(address indexed account, bool excluded);
    event MinimumShareBalanceUpdated(address indexed launchpad, uint256 amount);
    event DividendUnitsAccrued(address indexed token, uint256 indexed batch, uint256 units);
    event DividendConverted(address indexed token, uint256 units, uint256 quote);
    event DividendBatchSettled(address indexed token, uint256 indexed batch, uint256 units, uint256 quote);

    error OnlyLaunchpad();
    error ZeroAddress();
    error UnknownToken();
    error NothingToClaim();
    error AlreadyRegistered();
    error NoShares();
    error TooManyUnits();
    error OperatorAlreadyBound();
    error NotAContract();

    constructor(address owner_) Ownable(owner_) {
        excluded[address(0)] = true;
        excluded[address(0xdead)] = true;
        // audit 4 (A-F2 / C-F4): the vault can hold a dividend token (as another token's reward quote); a share here
        // would earn rewards that `claimFor(token, vault)` pays back to the vault, owned by no one
        excluded[address(this)] = true;
    }

    // ---------------------------------------------------------------- owner
    function setLaunchpad(address launchpad, bool enabled) external onlyOwner {
        if (launchpad == address(0)) revert ZeroAddress();
        launchpads[launchpad] = enabled;
        if (enabled) excluded[launchpad] = true;
        emit LaunchpadSet(launchpad, enabled);
    }

    /// @notice Bind `account` (the core's tax handler) as the core's one operator. Once per core and per account,
    ///         with no unbind or rebind: an operator writes every share and deposits every reward of the core's tokens,
    ///         so a rebindable slot would let the owner install a contract that pays itself the holders' part
    ///         (flow review F4a). No emergency unbind is needed: the handlers' code is immutable, and their share writes
    ///         are guarded, so a vault refusal never freezes token transfers.
    function setOperator(address account, address launchpad) external onlyOwner {
        if (account == address(0) || launchpad == address(0)) revert ZeroAddress();
        if (!launchpads[launchpad]) revert OnlyLaunchpad();
        if (operatorFor[launchpad] != address(0) || operatorOf[account] != address(0)) revert OperatorAlreadyBound();
        excluded[account] = true;
        operatorOf[account] = launchpad;
        operatorFor[launchpad] = account;
        emit OperatorSet(account, launchpad);
    }

    /// @notice Exclude a contract (a pool, a locker, an exchange's contract wallet) from shares; un-excluding is
    ///         free. Internal audit 5 C-F5: only an address with code can be excluded, so the owner can't exclude every
    ///         holder but chosen wallets and steer all future dividends to them. A wallet delegated under EIP-7702
    ///         (its code is just the 23-byte designator 0xef0100 ‖ address) is a wallet, not a contract (review).
    function setExcluded(address account, bool isExc) external onlyOwner {
        if (isExc && !_isContract(account)) revert NotAContract();
        excluded[account] = isExc;
        emit Excluded(account, isExc);
    }

    /// @dev Code that is not an EIP-7702 delegation designator. 0xef can't start deployed code (EIP-3541), so 23 bytes
    ///      starting 0xef0100 is always a delegated wallet.
    function _isContract(address account) internal view returns (bool) {
        uint256 len = account.code.length;
        if (len != 23) return len != 0;
        bytes memory code = account.code;
        return code[0] != 0xef || code[1] != 0x01 || code[2] != 0x00;
    }

    /// @notice The floor `launchpad`'s tokens registered from now on get; tokens already registered keep their own.
    function setMinimumShareBalance(address launchpad, uint256 amount) external onlyOwner {
        minimumShareBalanceOf[launchpad] = amount;
        emit MinimumShareBalanceUpdated(launchpad, amount);
    }

    // ---------------------------------------------------------------- cores
    /// @notice A core raises its own floor (never lowers it).
    function ensureMinimumShareBalance(uint256 amount) external {
        if (!launchpads[msg.sender]) revert OnlyLaunchpad();
        if (amount > minimumShareBalanceOf[msg.sender]) {
            minimumShareBalanceOf[msg.sender] = amount;
            emit MinimumShareBalanceUpdated(msg.sender, amount);
        }
    }

    /// @notice Bind a freshly created token to the calling core. Once only: no core can take over another's token.
    function registerToken(address token, address quote) external {
        if (!launchpads[msg.sender]) revert OnlyLaunchpad();
        if (token == address(0) || quote == address(0)) revert ZeroAddress();
        if (launchpadOf[token] != address(0)) revert AlreadyRegistered();
        launchpadOf[token] = msg.sender;
        quoteOf[token] = quote;
        // flow review F4c: the floor is the token's own from here; raising the core's floor later only affects new tokens
        tokenMinimumShareBalance[token] = minimumShareBalanceOf[msg.sender];
        emit TokenRegistered(token, quote, msg.sender);
    }

    function depositReward(address token, uint256 amount) external {
        _onlyFor(token);
        if (amount == 0) return;
        // audit 4 (A-F1 / C-F2): credit what arrived, not what was asked — one balance per quote is shared by every
        // token on it, so an over-credit would be paid out of the other tokens' rewards
        IERC20 quote = IERC20(quoteOf[token]);
        uint256 before = quote.balanceOf(address(this));
        quote.safeTransferFrom(msg.sender, address(this), amount);
        amount = quote.balanceOf(address(this)) - before;
        uint256 ts = totalShares[token];
        if (ts > 0) {
            accRewardPerShare[token] += (amount * 1e18) / ts;
        }
        emit RewardDeposited(token, amount);
    }

    /// @dev Strict `>` floor (the token's floor, snapshotted at registration): `newShare <= floor` → 0 shares.
    function setShare(address token, address user, uint256 newShare) external {
        _onlyFor(token);
        if (excluded[user] || newShare <= tokenMinimumShareBalance[token]) newShare = 0;
        _harvest(token, user);
        uint256 old = shares[token][user];
        if (old != 0 || newShare != 0) _harvestUnits(token, user, old);
        totalShares[token] = totalShares[token] - old + newShare;
        shares[token][user] = newShare;
        rewardDebt[token][user] = (newShare * accRewardPerShare[token]) / 1e18;
        emit ShareUpdated(token, user, newShare);
    }

    /// @notice Holders' part of a pool tax just taken, in tax tokens: credited now over the current shares. The caller
    ///         holds those tokens and sells them later (`convertDividend`). Reverts with no shares (the caller pays
    ///         that part elsewhere).
    function accrueDividendUnits(address token, uint256 units) external {
        _onlyFor(token);
        if (units == 0) return;
        uint256 ts = totalShares[token];
        if (ts == 0) revert NoShares();
        Pipe storage p = pipeOf[token];
        if (p.open == 0) p.open = 1;
        Batch storage b = batchOf[token][p.open];
        b.units += SafeCast.toUint128(units);
        b.acc += (units * UNIT_SCALE) / ts;
        emit DividendUnitsAccrued(token, p.open, units);
    }

    /// @notice `units` of the holders' tax tokens were sold for `amount` quote (pulled from the caller): applied to the
    ///         oldest unsold units first; a batch whose units are all sold settles.
    function convertDividend(address token, uint256 units, uint256 amount) external {
        _onlyFor(token);
        if (units == 0) return;
        if (amount > 0) {
            IERC20 quote = IERC20(quoteOf[token]);
            uint256 before = quote.balanceOf(address(this));
            quote.safeTransferFrom(msg.sender, address(this), amount);
            amount = quote.balanceOf(address(this)) - before;
        }
        emit DividendConverted(token, units, amount);
        Pipe storage p = pipeOf[token];
        while (units > 0) {
            if (p.selling == 0) {
                // the open batch starts selling; new units go to a fresh open batch
                if (p.open == 0 || batchOf[token][p.open].units == 0) revert TooManyUnits();
                p.selling = p.open;
                p.open += 1;
            }
            Batch storage b = batchOf[token][p.selling];
            uint256 left = b.units - b.sold;
            uint256 take = units < left ? units : left;
            uint256 got = take == units ? amount : (amount * take) / units;
            b.sold += uint128(take); // ≤ units - sold
            b.quote += got;
            units -= take;
            amount -= got;
            if (b.sold == b.units) {
                uint256 prev = p.settled == 0 ? 0 : batchOf[token][p.settled].cumQuote;
                b.cumQuote = prev + Math.mulDiv(b.acc, b.quote, b.units);
                p.settled = p.selling;
                p.selling = 0;
                emit DividendBatchSettled(token, p.settled, b.units, b.quote);
            }
        }
    }

    // ---------------------------------------------------------------- holders
    function claim(address token) external returns (uint256 amount) {
        return claimFor(token, msg.sender);
    }

    function claimFor(address token, address user) public returns (uint256 amount) {
        if (quoteOf[token] == address(0)) revert UnknownToken();
        _harvest(token, user);
        _harvestUnits(token, user, shares[token][user]);
        amount = pendingCredit[token][user];
        if (amount == 0) revert NothingToClaim();
        pendingCredit[token][user] = 0;
        IERC20(quoteOf[token]).safeTransfer(user, amount);
        emit DividendClaimed(token, user, amount);
    }

    // ---------------------------------------------------------------- views
    function pending(address token, address user) external view returns (uint256) {
        uint256 s = shares[token][user];
        uint256 accumulated = (s * accRewardPerShare[token]) / 1e18;
        uint256 debt = rewardDebt[token][user];
        uint256 accrued = accumulated > debt ? accumulated - debt : 0;
        (uint256 fromUnits,) = _unitsView(token, user, s);
        return pendingCredit[token][user] + accrued + fromUnits;
    }

    /// @notice Tax-time units `user` holds whose batch has not settled yet (they turn into quote when it does; part of
    ///         them may already be sold, its quote held in the batch).
    function pendingUnits(address token, address user) external view returns (uint256) {
        (, Position memory np) = _unitsView(token, user, shares[token][user]);
        return np.unitsA + np.unitsB;
    }

    /// @notice Holders' tax tokens credited but not sold yet (what `convertDividend` may still be told about).
    function unsoldUnits(address token) external view returns (uint256 units) {
        Pipe memory p = pipeOf[token];
        if (p.selling != 0) {
            Batch storage s = batchOf[token][p.selling];
            units = s.units - s.sold;
        }
        if (p.open != 0) units += batchOf[token][p.open].units;
    }

    /// @notice `token`'s floor, fixed at registration (0 for an unknown token).
    function minimumShareBalanceFor(address token) external view returns (uint256) {
        return tokenMinimumShareBalance[token];
    }

    // ---------------------------------------------------------------- internal
    /// @dev The token's core, or an operator bound to it; returns the core.
    function _onlyFor(address token) internal view returns (address lp) {
        lp = launchpadOf[token];
        if (lp == address(0)) revert UnknownToken();
        if (msg.sender != lp && operatorOf[msg.sender] != lp) revert OnlyLaunchpad();
    }

    /// @dev Moves `user`'s tax-time units forward (share `s` held since the last touch) and credits what settled.
    function _harvestUnits(address token, address user, uint256 s) internal {
        if (pipeOf[token].open == 0) return; // no pool tax credited yet
        (uint256 quote, Position memory np) = _unitsView(token, user, s);
        if (quote > 0) pendingCredit[token][user] += quote;
        Position storage u = positionOf[token][user];
        if (u.batch != np.batch || u.debt != np.debt) {
            u.batch = np.batch;
            u.debt = np.debt;
        }
        if (u.idA != np.idA || u.idB != np.idB) {
            u.idA = np.idA;
            u.idB = np.idB;
        }
        if (u.unitsA != np.unitsA || u.unitsB != np.unitsB) {
            u.unitsA = np.unitsA;
            u.unitsB = np.unitsB;
        }
    }

    /// @dev Quote `user` gained from settled batches, and the position after it (unsettled units only in the selling
    ///      and the open batch). `s` = the share held, unchanged, since the last touch.
    function _unitsView(address token, address user, uint256 s) internal view returns (uint256 quote, Position memory np) {
        Pipe memory p = pipeOf[token];
        if (p.open == 0) return (0, np);
        Position memory u = positionOf[token][user];
        uint256 uS;
        uint256 uO;
        (quote, uS, uO) = _place(token, p, u.idA, u.unitsA, quote, uS, uO);
        (quote, uS, uO) = _place(token, p, u.idB, u.unitsB, quote, uS, uO);
        if (s > 0) {
            uint64 b0 = u.batch;
            // the rest of the batch that was open at the last touch
            if (b0 != 0) {
                (quote, uS, uO) =
                    _place(token, p, b0, Math.mulDiv(s, batchOf[token][b0].acc - u.debt, UNIT_SCALE), quote, uS, uO);
            }
            // whole batches since, already settled: one step through the cumulative index
            if (p.settled > b0) {
                uint256 from = b0 == 0 ? 0 : batchOf[token][b0].cumQuote;
                quote += Math.mulDiv(s, batchOf[token][p.settled].cumQuote - from, UNIT_SCALE);
            }
            // whole batches since, not settled yet (the selling and the open one)
            if (p.selling > b0) uS += Math.mulDiv(s, batchOf[token][p.selling].acc, UNIT_SCALE);
            if (p.open > b0) uO += Math.mulDiv(s, batchOf[token][p.open].acc, UNIT_SCALE);
        }
        np.batch = p.open;
        np.debt = batchOf[token][p.open].acc;
        // a holder's units are a share of a batch's (≤ uint128)
        if (uS > 0) (np.idA, np.unitsA) = (p.selling, uint128(uS));
        if (uO > 0) (np.idB, np.unitsB) = (p.open, uint128(uO));
    }

    /// @dev `units` in batch `id`: quote if it settled, else kept as selling / open units.
    function _place(address token, Pipe memory p, uint64 id, uint256 units, uint256 quote, uint256 uS, uint256 uO)
        internal
        view
        returns (uint256, uint256, uint256)
    {
        if (id == 0 || units == 0) return (quote, uS, uO);
        if (id <= p.settled) {
            Batch storage b = batchOf[token][id];
            quote += Math.mulDiv(units, b.quote, b.units);
        } else if (id == p.selling) {
            uS += units;
        } else {
            uO += units; // id == p.open: ids only move forward (open → selling → settled)
        }
        return (quote, uS, uO);
    }

    function _harvest(address token, address user) internal {
        uint256 accumulated = (shares[token][user] * accRewardPerShare[token]) / 1e18;
        uint256 debt = rewardDebt[token][user];
        if (accumulated > debt) {
            pendingCredit[token][user] += accumulated - debt;
        }
        rewardDebt[token][user] = accumulated;
    }
}
