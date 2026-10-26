// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {BuybackBurner} from "../launchpad-v2/BuybackBurner.sol";

/// @title SharedPlatformFeeBucket (LaunchpadV3 + 打新 · platform fees)
/// @notice launchpad-v2/PlatformFeeBucket for the shared cores, with two differences (internal audit 5, C-F2 / C-F6):
///         - Only the fixed-path `collectPlatform` (80% BuybackBurner / 20% feeVault). There is no
///           `collectPlatformSmart`: it handed keeper-supplied router calldata to the burner, so the hot keeper key
///           could route the 80% leg to itself and pass `minGangOut` with dust.
///         - The keeper is set once at deploy; changing it later takes KEEPER_DELAY (propose → accept).
///         `notifyAccrual` credits what actually arrived (a quote that charges on transfer can't over-credit).
/// @dev flushStuck stays two-step (requestFlush + 7 days); a successful collect clears the request.
contract SharedPlatformFeeBucket is Ownable2Step {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant BUYBACK_BPS = 8_000; // 80%
    uint256 public constant FLUSH_DELAY = 7 days;
    uint256 public constant KEEPER_DELAY = 48 hours;

    address public launchpad;
    mapping(address => bool) public operators;
    address public feeVault;
    BuybackBurner public burner;
    address public keeper;
    address public pendingKeeper;
    uint256 public keeperEta;

    mapping(address => uint256) public accruedQuote;
    mapping(address => uint256) public flushRequestedAt;

    event LaunchpadSet(address indexed launchpad);
    event FeeVaultUpdated(address indexed vault);
    event BurnerSet(address indexed burner);
    event KeeperSet(address indexed keeper);
    event KeeperProposed(address indexed keeper, uint256 eta);
    event KeeperCancelled(address indexed keeper);
    event OperatorUpdated(address indexed account, bool enabled);
    event PlatformAccrued(address indexed quote, uint256 amount);
    event PlatformCollected(address indexed quote, uint256 toBuyback, uint256 toVault);
    event FlushRequested(address indexed quote, uint256 requestedAt);
    event FlushExecuted(address indexed quote, uint256 amount, address indexed to);
    event FlushRequestCleared(address indexed quote);

    error OnlyLaunchpad();
    error OnlyKeeperOrOwner();
    error ZeroAddress();
    error NothingAccrued();
    error NothingToFlush();
    error FlushNotRequested();
    error FlushTooEarly();
    error KeeperAlreadySet();
    error NoProposal();
    error TooEarly();

    constructor(address owner_, address feeVault_) Ownable(owner_) {
        if (feeVault_ == address(0)) revert ZeroAddress();
        feeVault = feeVault_;
        emit FeeVaultUpdated(feeVault_);
    }

    function setLaunchpad(address launchpad_) external onlyOwner {
        if (launchpad_ == address(0)) revert ZeroAddress();
        launchpad = launchpad_;
        emit LaunchpadSet(launchpad_);
    }

    function setOperator(address account, bool enabled) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        operators[account] = enabled;
        emit OperatorUpdated(account, enabled);
    }

    function setFeeVault(address vault_) external onlyOwner {
        if (vault_ == address(0)) revert ZeroAddress();
        feeVault = vault_;
        emit FeeVaultUpdated(vault_);
    }

    function setBurner(address burner_) external onlyOwner {
        if (burner_ == address(0)) revert ZeroAddress();
        burner = BuybackBurner(burner_);
        emit BurnerSet(burner_);
    }

    /// @notice The first keeper (deploy); later changes go through `proposeKeeper` → KEEPER_DELAY → `acceptKeeper`.
    function setKeeper(address keeper_) external onlyOwner {
        if (keeper != address(0)) revert KeeperAlreadySet();
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    function proposeKeeper(address keeper_) external onlyOwner {
        pendingKeeper = keeper_;
        keeperEta = block.timestamp + KEEPER_DELAY;
        emit KeeperProposed(keeper_, keeperEta);
    }

    function acceptKeeper() external onlyOwner {
        uint256 eta = keeperEta;
        if (eta == 0) revert NoProposal();
        if (block.timestamp < eta) revert TooEarly();
        keeper = pendingKeeper;
        delete pendingKeeper;
        delete keeperEta;
        emit KeeperSet(keeper);
    }

    function cancelKeeper() external onlyOwner {
        if (keeperEta == 0) revert NoProposal();
        emit KeeperCancelled(pendingKeeper);
        delete pendingKeeper;
        delete keeperEta;
    }

    /// @notice Pulls `amount` of `quote` from a core / its handler and credits what arrived.
    function notifyAccrual(address quote, uint256 amount) external {
        if (msg.sender != launchpad && !operators[msg.sender]) revert OnlyLaunchpad();
        if (amount == 0) return;
        uint256 before = IERC20(quote).balanceOf(address(this));
        IERC20(quote).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(quote).balanceOf(address(this)) - before;
        accruedQuote[quote] += received;
        emit PlatformAccrued(quote, received);
    }

    /// @param minGangOut Off-chain floor for the 80% buyback leg. Ignored when toBuyback == 0.
    function collectPlatform(address quote, uint256 minGangOut) external {
        if (msg.sender != keeper && msg.sender != owner()) revert OnlyKeeperOrOwner();
        uint256 total = accruedQuote[quote];
        if (total == 0) revert NothingAccrued();
        accruedQuote[quote] = 0;
        uint256 toBuyback = (total * BUYBACK_BPS) / BPS;
        uint256 toVault = total - toBuyback;

        if (toBuyback > 0) {
            IERC20(quote).forceApprove(address(burner), toBuyback);
            burner.buybackAndBurn(quote, toBuyback, minGangOut);
        }
        if (toVault > 0) IERC20(quote).safeTransfer(feeVault, toVault);
        _clearFlushRequest(quote);
        emit PlatformCollected(quote, toBuyback, toVault);
    }

    /// @notice Step 1 of the stuck-quote escape: announce it; `flushStuckQuoteToTreasury` works FLUSH_DELAY later.
    function requestFlush(address quote) external onlyOwner {
        if (quote == address(0)) revert ZeroAddress();
        flushRequestedAt[quote] = block.timestamp;
        emit FlushRequested(quote, block.timestamp);
    }

    /// @notice Step 2: move the whole `quote` balance to feeVault (a successful collect in between cancels it).
    function flushStuckQuoteToTreasury(address quote) external onlyOwner {
        uint256 requestedAt = flushRequestedAt[quote];
        if (requestedAt == 0) revert FlushNotRequested();
        if (block.timestamp < requestedAt + FLUSH_DELAY) revert FlushTooEarly();
        uint256 bal = IERC20(quote).balanceOf(address(this));
        if (bal == 0) revert NothingToFlush();
        accruedQuote[quote] = 0;
        delete flushRequestedAt[quote];
        IERC20(quote).safeTransfer(feeVault, bal);
        emit FlushExecuted(quote, bal, feeVault);
    }

    function _clearFlushRequest(address quote) internal {
        if (flushRequestedAt[quote] != 0) {
            delete flushRequestedAt[quote];
            emit FlushRequestCleared(quote);
        }
    }
}
