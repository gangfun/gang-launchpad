// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title DividendVault (Stocks track · D2 tax dividend)
/// @notice Accrues quote rewards per TaxLaunchToken and lets holders claim. Not corporate dividends.
/// @dev Share updates come from LaunchpadS (and later TaxLaunchToken hooks). Manual claim only.
contract DividendVault is Ownable {
    using SafeERC20 for IERC20;

    address public launchpad;
    uint256 public minimumShareBalance;

    mapping(address token => address quote) public quoteOf;
    mapping(address token => uint256) public totalShares;
    mapping(address token => uint256) public accRewardPerShare; // 1e18 scaled
    mapping(address token => mapping(address user => uint256)) public shares;
    mapping(address token => mapping(address user => uint256)) public rewardDebt;
    mapping(address token => mapping(address user => uint256)) public pendingCredit;
    mapping(address => bool) public excluded;

    event LaunchpadSet(address indexed launchpad);
    event TokenRegistered(address indexed token, address indexed quote);
    event RewardDeposited(address indexed token, uint256 amount);
    event ShareUpdated(address indexed token, address indexed user, uint256 share);
    event DividendClaimed(address indexed token, address indexed user, uint256 amount);
    event Excluded(address indexed account, bool excluded);
    event MinimumShareBalanceUpdated(uint256 amount);

    error OnlyLaunchpad();
    error ZeroAddress();
    error UnknownToken();
    error NothingToClaim();

    constructor(address owner_) Ownable(owner_) {
        excluded[address(0)] = true;
        excluded[address(0xdead)] = true;
    }

    function setLaunchpad(address launchpad_) external onlyOwner {
        if (launchpad_ == address(0)) revert ZeroAddress();
        launchpad = launchpad_;
        excluded[launchpad_] = true;
        emit LaunchpadSet(launchpad_);
    }

    function setExcluded(address account, bool isExc) external onlyOwner {
        excluded[account] = isExc;
        emit Excluded(account, isExc);
    }

    function setMinimumShareBalance(uint256 amount) external onlyOwner {
        minimumShareBalance = amount;
        emit MinimumShareBalanceUpdated(amount);
    }

    /// @notice LaunchpadU (or owner) may raise the floor for taxed tokens (never lower).
    function ensureMinimumShareBalance(uint256 amount) external {
        if (msg.sender != launchpad && msg.sender != owner()) revert OnlyLaunchpad();
        if (amount > minimumShareBalance) {
            minimumShareBalance = amount;
            emit MinimumShareBalanceUpdated(amount);
        }
    }

    function registerToken(address token, address quote) external {
        if (msg.sender != launchpad) revert OnlyLaunchpad();
        if (token == address(0) || quote == address(0)) revert ZeroAddress();
        quoteOf[token] = quote;
        emit TokenRegistered(token, quote);
    }

    /// @notice LaunchpadS transfers quote then calls this. Orphan rewards (no shares) stay in vault.
    function depositReward(address token, uint256 amount) external {
        if (msg.sender != launchpad) revert OnlyLaunchpad();
        if (quoteOf[token] == address(0)) revert UnknownToken();
        if (amount == 0) return;
        IERC20(quoteOf[token]).safeTransferFrom(msg.sender, address(this), amount);
        uint256 ts = totalShares[token];
        if (ts > 0) {
            accRewardPerShare[token] += (amount * 1e18) / ts;
        }
        emit RewardDeposited(token, amount);
    }

    function setShare(address token, address user, uint256 newShare) external {
        if (msg.sender != launchpad) revert OnlyLaunchpad();
        if (excluded[user]) {
            newShare = 0;
        } else if (newShare < minimumShareBalance) {
            newShare = 0;
        }
        _harvest(token, user);
        uint256 old = shares[token][user];
        totalShares[token] = totalShares[token] - old + newShare;
        shares[token][user] = newShare;
        rewardDebt[token][user] = (newShare * accRewardPerShare[token]) / 1e18;
        emit ShareUpdated(token, user, newShare);
    }

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

    function pending(address token, address user) external view returns (uint256) {
        uint256 accumulated = (shares[token][user] * accRewardPerShare[token]) / 1e18;
        uint256 debt = rewardDebt[token][user];
        uint256 accrued = accumulated > debt ? accumulated - debt : 0;
        return pendingCredit[token][user] + accrued;
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
