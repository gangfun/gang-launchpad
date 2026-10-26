// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title SharedDividendVault (LaunchpadV3 + 打新 · one dividend vault for both cores)
/// @notice launchpad-v2/DividendVault's accounting, shared by several cores. Each token belongs to the core that
///         registered it, and only that core — or an operator bound to that core — can write its shares or deposit
///         its rewards: a handler of one core can't touch another core's tokens (syncShares is permissionless).
///         The share floor is kept per core, so one core raising its floor never changes another core's holders.
/// @dev Removing a core (`setLaunchpad(core, false)`) only stops new registrations: writes for its existing tokens keep
///      working, so retiring a core can't freeze dividends already promised. Claims never depend on any core.
contract SharedDividendVault is Ownable2Step {
    using SafeERC20 for IERC20;

    mapping(address => bool) public launchpads;
    /// @notice The one core an operator may act for (0 = not an operator).
    mapping(address account => address launchpad) public operatorOf;
    mapping(address launchpad => uint256) public minimumShareBalanceOf;

    mapping(address token => address launchpad) public launchpadOf;
    mapping(address token => address quote) public quoteOf;
    mapping(address token => uint256) public totalShares;
    mapping(address token => uint256) public accRewardPerShare; // 1e18 scaled
    mapping(address token => mapping(address user => uint256)) public shares;
    mapping(address token => mapping(address user => uint256)) public rewardDebt;
    mapping(address token => mapping(address user => uint256)) public pendingCredit;
    mapping(address => bool) public excluded;

    event LaunchpadSet(address indexed launchpad, bool enabled);
    event OperatorSet(address indexed account, address indexed launchpad);
    event TokenRegistered(address indexed token, address indexed quote, address indexed launchpad);
    event RewardDeposited(address indexed token, uint256 amount);
    event ShareUpdated(address indexed token, address indexed user, uint256 share);
    event DividendClaimed(address indexed token, address indexed user, uint256 amount);
    event Excluded(address indexed account, bool excluded);
    event MinimumShareBalanceUpdated(address indexed launchpad, uint256 amount);

    error OnlyLaunchpad();
    error ZeroAddress();
    error UnknownToken();
    error NothingToClaim();
    error AlreadyRegistered();

    constructor(address owner_) Ownable(owner_) {
        excluded[address(0)] = true;
        excluded[address(0xdead)] = true;
    }

    // ---------------------------------------------------------------- owner
    function setLaunchpad(address launchpad, bool enabled) external onlyOwner {
        if (launchpad == address(0)) revert ZeroAddress();
        launchpads[launchpad] = enabled;
        if (enabled) excluded[launchpad] = true;
        emit LaunchpadSet(launchpad, enabled);
    }

    /// @notice Bind `account` to one core (launchpad = 0 removes it). The core must be listed when binding.
    function setOperator(address account, address launchpad) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        if (launchpad != address(0)) {
            if (!launchpads[launchpad]) revert OnlyLaunchpad();
            excluded[account] = true;
        }
        operatorOf[account] = launchpad;
        emit OperatorSet(account, launchpad);
    }

    function setExcluded(address account, bool isExc) external onlyOwner {
        excluded[account] = isExc;
        emit Excluded(account, isExc);
    }

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
        emit TokenRegistered(token, quote, msg.sender);
    }

    function depositReward(address token, uint256 amount) external {
        _onlyFor(token);
        if (amount == 0) return;
        IERC20(quoteOf[token]).safeTransferFrom(msg.sender, address(this), amount);
        uint256 ts = totalShares[token];
        if (ts > 0) {
            accRewardPerShare[token] += (amount * 1e18) / ts;
        }
        emit RewardDeposited(token, amount);
    }

    /// @dev Strict `>` floor (the token's core's floor): `newShare <= floor` → 0 shares.
    function setShare(address token, address user, uint256 newShare) external {
        address lp = _onlyFor(token);
        if (excluded[user] || newShare <= minimumShareBalanceOf[lp]) newShare = 0;
        _harvest(token, user);
        uint256 old = shares[token][user];
        totalShares[token] = totalShares[token] - old + newShare;
        shares[token][user] = newShare;
        rewardDebt[token][user] = (newShare * accRewardPerShare[token]) / 1e18;
        emit ShareUpdated(token, user, newShare);
    }

    // ---------------------------------------------------------------- holders
    function claim(address token) external returns (uint256 amount) {
        return claimFor(token, msg.sender);
    }

    function claimFor(address token, address user) public returns (uint256 amount) {
        if (quoteOf[token] == address(0)) revert UnknownToken();
        _harvest(token, user);
        amount = pendingCredit[token][user];
        if (amount == 0) revert NothingToClaim();
        pendingCredit[token][user] = 0;
        IERC20(quoteOf[token]).safeTransfer(user, amount);
        emit DividendClaimed(token, user, amount);
    }

    // ---------------------------------------------------------------- views
    function pending(address token, address user) external view returns (uint256) {
        uint256 accumulated = (shares[token][user] * accRewardPerShare[token]) / 1e18;
        uint256 debt = rewardDebt[token][user];
        uint256 accrued = accumulated > debt ? accumulated - debt : 0;
        return pendingCredit[token][user] + accrued;
    }

    /// @notice Floor of the core that owns `token` (0 for an unknown token).
    function minimumShareBalanceFor(address token) external view returns (uint256) {
        return minimumShareBalanceOf[launchpadOf[token]];
    }

    // ---------------------------------------------------------------- internal
    /// @dev The token's core, or an operator bound to it; returns the core.
    function _onlyFor(address token) internal view returns (address lp) {
        lp = launchpadOf[token];
        if (lp == address(0)) revert UnknownToken();
        if (msg.sender != lp && operatorOf[msg.sender] != lp) revert OnlyLaunchpad();
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
