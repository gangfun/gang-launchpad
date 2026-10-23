// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {BuybackBurner} from "./BuybackBurner.sol";

/// @title PlatformFeeBucket (Stocks track)
/// @notice Holds the platform half of the 1% trade tax (50 bps). collectPlatform → 80% BuybackBurner / 20% feeVault.
/// @dev NEVER writes main-track Launchpad.accruedFees or calls main collectFees.
///      Finding M2: collectPlatform takes caller-supplied minGangOut (no same-tx quote).
///      OPT5B: flushStuck is two-step (requestFlush + 7d); successful collect clears request;
///      collectPlatformSmart passes keeper Smart Router calldata to burner.
contract PlatformFeeBucket is Ownable2Step {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant BUYBACK_BPS = 8_000; // 80%
    /// @dev OPT5B: delay between requestFlush and flushStuckQuoteToTreasury.
    uint256 public constant FLUSH_DELAY = 7 days;

    address public launchpad;
    mapping(address => bool) public operators;
    address public feeVault;
    BuybackBurner public burner;
    address public keeper;

    mapping(address => uint256) public accruedQuote;
    /// @dev quote => timestamp of requestFlush (0 = none).
    mapping(address => uint256) public flushRequestedAt;

    event LaunchpadSet(address indexed launchpad);
    event FeeVaultUpdated(address indexed vault);
    event BurnerSet(address indexed burner);
    event KeeperSet(address indexed keeper);
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

    function setKeeper(address keeper_) external onlyOwner {
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    /// @notice LaunchpadS transfers quote then notifies, OR pulls via transferFrom.
    function notifyAccrual(address quote, uint256 amount) external {
        if (msg.sender != launchpad && !operators[msg.sender]) revert OnlyLaunchpad();
        if (amount == 0) return;
        IERC20(quote).safeTransferFrom(msg.sender, address(this), amount);
        accruedQuote[quote] += amount;
        emit PlatformAccrued(quote, amount);
    }

    /// @param minGangOut Off-chain floor for the 80% buyback leg (Finding M2). Ignored when toBuyback==0.
    /// @dev V2 path via burner.buybackAndBurn. Successful collect clears pending flush request.
    function collectPlatform(address quote, uint256 minGangOut) external {
        if (msg.sender != keeper && msg.sender != owner()) revert OnlyKeeperOrOwner();
        (uint256 toBuyback, uint256 toVault) = _splitAndClear(quote);

        if (toBuyback > 0) {
            IERC20(quote).forceApprove(address(burner), toBuyback);
            burner.buybackAndBurn(quote, toBuyback, minGangOut);
        }
        if (toVault > 0) {
            IERC20(quote).safeTransfer(feeVault, toVault);
        }
        _clearFlushRequest(quote);
        emit PlatformCollected(quote, toBuyback, toVault);
    }

    /// @notice Same 80/20 split as collectPlatform, but 80% leg uses keeper Smart Router calldata.
    /// @param swapData Pancake Smart Router calldata (quote→USDT V3 → WBNB → GANG). Burner only
    ///        approves `quote`, so the funded start token is the collected quote; GANG delta ≥ minGangOut.
    function collectPlatformSmart(address quote, uint256 minGangOut, bytes calldata swapData) external {
        if (msg.sender != keeper && msg.sender != owner()) revert OnlyKeeperOrOwner();
        (uint256 toBuyback, uint256 toVault) = _splitAndClear(quote);

        if (toBuyback > 0) {
            IERC20(quote).forceApprove(address(burner), toBuyback);
            burner.buybackAndBurnSmart(quote, toBuyback, minGangOut, swapData);
        }
        if (toVault > 0) {
            IERC20(quote).safeTransfer(feeVault, toVault);
        }
        _clearFlushRequest(quote);
        emit PlatformCollected(quote, toBuyback, toVault);
    }

    /// @notice Step 1 of stuck-quote escape: owner announces intent; wait FLUSH_DELAY before flush.
    function requestFlush(address quote) external onlyOwner {
        if (quote == address(0)) revert ZeroAddress();
        flushRequestedAt[quote] = block.timestamp;
        emit FlushRequested(quote, block.timestamp);
    }

    /// @notice Step 2: after FLUSH_DELAY since requestFlush, move full actual quote balance to feeVault.
    ///         Reverts if no request or too early. Successful collectPlatform clears the request.
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

    function _splitAndClear(address quote) internal returns (uint256 toBuyback, uint256 toVault) {
        uint256 total = accruedQuote[quote];
        if (total == 0) revert NothingAccrued();
        accruedQuote[quote] = 0;
        toBuyback = (total * BUYBACK_BPS) / BPS;
        toVault = total - toBuyback;
    }

    function _clearFlushRequest(address quote) internal {
        if (flushRequestedAt[quote] != 0) {
            delete flushRequestedAt[quote];
            emit FlushRequestCleared(quote);
        }
    }
}
