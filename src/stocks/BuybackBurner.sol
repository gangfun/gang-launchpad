// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title BuybackBurner (Stocks track · stub)
/// @notice Receives quote from PlatformFeeBucket; stub-burns any held GANG to dead.
/// @dev Does NOT read or write main-track accruedFees.
contract BuybackBurner is Ownable {
    using SafeERC20 for IERC20;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address public gang;
    mapping(address => uint256) public quoteReceived;

    event GangSet(address indexed gang);
    event BuybackBurned(address indexed quote, uint256 quoteIn, uint256 gangBurned);

    error ZeroAddress();

    constructor(address owner_) Ownable(owner_) {}

    function setGang(address gang_) external onlyOwner {
        if (gang_ == address(0)) revert ZeroAddress();
        gang = gang_;
        emit GangSet(gang_);
    }

    /// @notice Pull quote from caller. If this contract holds GANG, send it to dead (stub burn).
    function buybackAndBurn(address quote, uint256 amountIn, uint256 /* minGangOut */ ) external {
        if (amountIn == 0) return;
        IERC20(quote).safeTransferFrom(msg.sender, address(this), amountIn);
        quoteReceived[quote] += amountIn;

        uint256 burned;
        if (gang != address(0)) {
            uint256 bal = IERC20(gang).balanceOf(address(this));
            if (bal > 0) {
                burned = bal;
                IERC20(gang).safeTransfer(DEAD, burned);
            }
        }
        emit BuybackBurned(quote, amountIn, burned);
    }
}
