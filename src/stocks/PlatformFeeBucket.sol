// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BuybackBurner} from "./BuybackBurner.sol";

/// @title PlatformFeeBucket (Stocks track)
/// @notice Holds the platform half of the 1% trade tax (50 bps). collectPlatform → 80% BuybackBurner / 20% feeVault.
/// @dev NEVER writes main-track Launchpad.accruedFees or calls main collectFees.
contract PlatformFeeBucket is Ownable {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant BUYBACK_BPS = 8_000; // 80%

    address public launchpad;
    address public feeVault;
    BuybackBurner public burner;
    address public keeper;

    mapping(address => uint256) public accruedQuote;

    event LaunchpadSet(address indexed launchpad);
    event FeeVaultUpdated(address indexed vault);
    event BurnerSet(address indexed burner);
    event KeeperSet(address indexed keeper);
    event PlatformAccrued(address indexed quote, uint256 amount);
    event PlatformCollected(address indexed quote, uint256 toBuyback, uint256 toVault);

    error OnlyLaunchpad();
    error OnlyKeeperOrOwner();
    error ZeroAddress();
    error NothingAccrued();

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
        if (msg.sender != launchpad) revert OnlyLaunchpad();
        if (amount == 0) return;
        IERC20(quote).safeTransferFrom(msg.sender, address(this), amount);
        accruedQuote[quote] += amount;
        emit PlatformAccrued(quote, amount);
    }

    function collectPlatform(address quote) external {
        if (msg.sender != keeper && msg.sender != owner()) revert OnlyKeeperOrOwner();
        uint256 total = accruedQuote[quote];
        if (total == 0) revert NothingAccrued();
        accruedQuote[quote] = 0;

        uint256 toBuyback = (total * BUYBACK_BPS) / BPS;
        uint256 toVault = total - toBuyback;

        if (toBuyback > 0) {
            IERC20(quote).forceApprove(address(burner), toBuyback);
            burner.buybackAndBurn(quote, toBuyback, 0);
        }
        if (toVault > 0) {
            IERC20(quote).safeTransfer(feeVault, toVault);
        }
        emit PlatformCollected(quote, toBuyback, toVault);
    }
}
