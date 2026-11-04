// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title DividendVault (LaunchpadV2 · post-grad outer tax dividends)
/// @notice Accrues quote rewards per TaxLaunchToken and lets holders claim.
/// @dev V2 Lazy: holder must hold **strictly more than** `minimumShareBalance` tokens
///      (default ensure = 10_000 ether). Comparison uses `<=` so balance == floor has 0 share.
contract DividendVault is Ownable2Step {
    using SafeERC20 for IERC20;

    address public launchpad;
    uint256 public minimumShareBalance;
    mapping(address => bool) public operators;

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
    event OperatorUpdated(address indexed account, bool enabled);

    error OnlyLaunchpad();
    error ZeroAddress();
    error UnknownToken();
    error NothingToClaim();
    /// @dev Depositing with zero total shares would strand the reward forever: accRewardPerShare
    ///      cannot accrue without a denominator, and a share appearing later never catches up.
    error NoShares();

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

    function setOperator(address account, bool enabled) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        operators[account] = enabled;
        if (enabled) excluded[account] = true;
        emit OperatorUpdated(account, enabled);
    }

    function _onlyLaunchpadOrOperator() internal view {
        if (msg.sender != launchpad && !operators[msg.sender]) revert OnlyLaunchpad();
    }

    function setExcluded(address account, bool isExc) external onlyOwner {
        excluded[account] = isExc;
        emit Excluded(account, isExc);
    }

    function setMinimumShareBalance(uint256 amount) external onlyOwner {
        minimumShareBalance = amount;
        emit MinimumShareBalanceUpdated(amount);
    }

    /// @notice LaunchpadV2 (or owner) may raise the floor for taxed tokens (never lower).
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

    function depositReward(address token, uint256 amount) external {
        _onlyLaunchpadOrOperator();
        if (quoteOf[token] == address(0)) revert UnknownToken();
        if (amount == 0) return;
        uint256 ts = totalShares[token];
        // Revert instead of silently stranding: the reward would sit here unclaimable forever
        // (no denominator to accrue against; shares registered later never catch up). The caller
        // (PostGradTaxHandler.process) keeps the tokens accrued and can retry once a holder qualifies.
        if (ts == 0) revert NoShares();
        IERC20(quoteOf[token]).safeTransferFrom(msg.sender, address(this), amount);
        accRewardPerShare[token] += (amount * 1e18) / ts;
        emit RewardDeposited(token, amount);
    }

    /// @dev Strict `>` floor: `newShare <= minimumShareBalance` → 0 shares.
    ///      With ensure=10_000 ether, holders need balance > 10_000 tokens.
    function setShare(address token, address user, uint256 newShare) external {
        _onlyLaunchpadOrOperator();
        if (excluded[user]) {
            newShare = 0;
        } else if (newShare <= minimumShareBalance) {
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
