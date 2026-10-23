// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPancakeRouter02} from "./interfaces/IPancake.sol";

/// @title BuybackBurner (Gang Pair platform buyback)
/// @notice Pulls quote from PlatformFeeBucket, swaps quote→GANG, burns GANG to dead.
/// @dev Gate R5: `gang` MUST be real mainnet GANG (0x0c6302…B405), never MockGANG.
///      V2 path: quote==WBNB → [WBNB,GANG]; else [quote,WBNB,GANG].
///      OPT5B/C Smart path: keeper calldata to Pancake Smart Router; only `quote` is approved
///      (start-token gate); exact-input full spend of amountIn; GANG Δ ≥ minGangOut → DEAD.
///      Does NOT read or write main-track accruedFees.
contract BuybackBurner is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    /// @dev PancakeSwap Smart Router (BSC mainnet). Owner may override via setSmartRouter.
    address public constant DEFAULT_SMART_ROUTER = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;
    uint256 public constant BPS = 10_000;

    IPancakeRouter02 public router;
    address public wbnb;
    address public gang;
    address public smartRouter;

    mapping(address => uint256) public quoteReceived;

    event RouterSet(address indexed router);
    event SmartRouterSet(address indexed smartRouter);
    event WbnbSet(address indexed wbnb);
    event GangSet(address indexed gang);
    event BuybackBurned(address indexed quote, uint256 quoteIn, uint256 gangBurned);

    error ZeroAddress();
    error ZeroAmount();
    error RouterNotSet();
    error SmartRouterNotSet();
    error GangNotSet();
    error WbnbNotSet();
    error SwapFailed();
    error InsufficientGangOut();
    error IncompleteQuoteSpend();

    constructor(address owner_) Ownable(owner_) {
        smartRouter = DEFAULT_SMART_ROUTER;
        emit SmartRouterSet(DEFAULT_SMART_ROUTER);
    }

    function setRouter(address router_) external onlyOwner {
        if (router_ == address(0)) revert ZeroAddress();
        router = IPancakeRouter02(router_);
        emit RouterSet(router_);
    }

    function setSmartRouter(address smartRouter_) external onlyOwner {
        if (smartRouter_ == address(0)) revert ZeroAddress();
        smartRouter = smartRouter_;
        emit SmartRouterSet(smartRouter_);
    }

    function setWbnb(address wbnb_) external onlyOwner {
        if (wbnb_ == address(0)) revert ZeroAddress();
        wbnb = wbnb_;
        emit WbnbSet(wbnb_);
    }

    /// @notice Gate R5 — set to real mainnet GANG only.
    function setGang(address gang_) external onlyOwner {
        if (gang_ == address(0)) revert ZeroAddress();
        gang = gang_;
        emit GangSet(gang_);
    }

    /// @notice Pull `amountIn` quote, swap to GANG on Pancake V2, burn to DEAD.
    /// @param minGangOut Caller slippage floor from off-chain quote (Finding M2: never derive minOut in same tx).
    function buybackAndBurn(address quote, uint256 amountIn, uint256 minGangOut) external nonReentrant {
        if (amountIn == 0) return;
        if (minGangOut == 0) revert ZeroAmount();
        if (address(router) == address(0)) revert RouterNotSet();
        if (gang == address(0)) revert GangNotSet();
        if (wbnb == address(0)) revert WbnbNotSet();
        if (quote == address(0)) revert ZeroAddress();

        IERC20(quote).safeTransferFrom(msg.sender, address(this), amountIn);
        quoteReceived[quote] += amountIn;

        address[] memory path = _path(quote);

        IERC20(quote).forceApprove(address(router), amountIn);
        uint256 before = IERC20(gang).balanceOf(address(this));
        try router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountIn, minGangOut, path, address(this), block.timestamp
        ) {
            uint256 got = IERC20(gang).balanceOf(address(this)) - before;
            if (got < minGangOut) revert InsufficientGangOut();
            if (got > 0) {
                IERC20(gang).safeTransfer(DEAD, got);
            }
            emit BuybackBurned(quote, amountIn, got);
        } catch {
            revert SwapFailed();
        }
    }

    /// @notice Pull `amountIn` quote, execute keeper Smart Router calldata, burn GANG to DEAD.
    /// @dev Start-token gate: only `quote` is approved to `smartRouter`, so the funded input is quote.
    ///      OPT5C: after call, quote balance must equal quoteBefore - amountIn (exact-input; no leftover).
    ///      Route intent (ops): quote → USDT (V3) → WBNB → GANG. Contract does not decode path.
    /// @param minGangOut Required GANG balance delta floor (>0).
    /// @param swapData Calldata for Pancake Smart Router (or settable smartRouter).
    function buybackAndBurnSmart(address quote, uint256 amountIn, uint256 minGangOut, bytes calldata swapData)
        external
        nonReentrant
    {
        if (amountIn == 0) return;
        if (minGangOut == 0) revert ZeroAmount();
        if (smartRouter == address(0)) revert SmartRouterNotSet();
        if (gang == address(0)) revert GangNotSet();
        if (quote == address(0)) revert ZeroAddress();
        if (swapData.length == 0) revert ZeroAmount();

        IERC20(quote).safeTransferFrom(msg.sender, address(this), amountIn);
        quoteReceived[quote] += amountIn;

        uint256 gangBefore = IERC20(gang).balanceOf(address(this));
        uint256 quoteBefore = IERC20(quote).balanceOf(address(this));

        IERC20(quote).forceApprove(smartRouter, amountIn);
        (bool ok,) = smartRouter.call(swapData);
        IERC20(quote).forceApprove(smartRouter, 0);
        if (!ok) revert SwapFailed();

        // OPT5C: exact-input — full amountIn must be spent; leftover quote would otherwise stick forever.
        if (IERC20(quote).balanceOf(address(this)) != quoteBefore - amountIn) revert IncompleteQuoteSpend();

        uint256 got = IERC20(gang).balanceOf(address(this)) - gangBefore;
        if (got < minGangOut) revert InsufficientGangOut();
        IERC20(gang).safeTransfer(DEAD, got);
        emit BuybackBurned(quote, amountIn, got);
    }

    function _path(address quote) internal view returns (address[] memory path) {
        if (quote == wbnb) {
            path = new address[](2);
            path[0] = wbnb;
            path[1] = gang;
        } else {
            path = new address[](3);
            path[0] = quote;
            path[1] = wbnb;
            path[2] = gang;
        }
    }

}
