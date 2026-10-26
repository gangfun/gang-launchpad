// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPancakeRouter02} from "../interfaces/IPancake.sol";

/// @title GangBuybackBurner — platform buyback that also handles GANG-quoted fees
/// @notice Replaces the live launchpad-v2 BuybackBurner (0x2aC1…f8dF) and stocks BuybackBurner (0x508F…4A4b)
///         behind PlatformFeeBucket.setBurner. Same entry points, so the buckets need no redeploy.
/// @dev Fix over the live burners: quote == GANG used to route [GANG, WBNB, GANG] through one pair, which always
///      reverts, so GANG-quoted platform fees could never be collected. GANG is now burned as received, no swap.
///      Other quotes keep the live behaviour: V2 path [WBNB, GANG] or [quote, WBNB, GANG]; Smart path runs keeper
///      calldata with only `quote` approved, full spend of amountIn, GANG delta ≥ minGangOut → DEAD.
///      Router reverts now bubble up instead of being replaced by SwapFailed.
contract GangBuybackBurner is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;

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
    error SwapFailed();
    error InsufficientGangOut();
    error IncompleteQuoteSpend();

    constructor(address owner_, address router_, address smartRouter_, address wbnb_, address gang_) Ownable(owner_) {
        _setRouter(router_);
        _setSmartRouter(smartRouter_);
        _setWbnb(wbnb_);
        _setGang(gang_);
    }

    function setRouter(address router_) external onlyOwner {
        _setRouter(router_);
    }

    function setSmartRouter(address smartRouter_) external onlyOwner {
        _setSmartRouter(smartRouter_);
    }

    function setWbnb(address wbnb_) external onlyOwner {
        _setWbnb(wbnb_);
    }

    /// @notice Real mainnet GANG only (0x0c63…B405), never a mock.
    function setGang(address gang_) external onlyOwner {
        _setGang(gang_);
    }

    /// @notice Pull `amountIn` quote, swap to GANG on Pancake V2 (or burn as is when quote is GANG), burn to DEAD.
    /// @param minGangOut Caller slippage floor from an off-chain quote (never derived in the same tx).
    function buybackAndBurn(address quote, uint256 amountIn, uint256 minGangOut) external nonReentrant {
        if (amountIn == 0) return;
        if (minGangOut == 0) revert ZeroAmount();
        if (quote == address(0)) revert ZeroAddress();
        if (quote == gang) {
            _burnGang(amountIn, minGangOut);
            return;
        }

        _pull(quote, amountIn);
        address[] memory path = _path(quote);
        IERC20(quote).forceApprove(address(router), amountIn);
        uint256 before = IERC20(gang).balanceOf(address(this));
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountIn, minGangOut, path, address(this), block.timestamp
        );
        _burnDelta(quote, amountIn, before, minGangOut);
    }

    /// @notice Pull `amountIn` quote, execute keeper Smart Router calldata, burn GANG to DEAD.
    ///         Quote GANG is burned as is and `swapData` is ignored (may be empty).
    /// @dev Only `quote` is approved to `smartRouter`, so the funded input is quote. After the call the quote
    ///      balance must be exactly quoteBefore - amountIn (exact input; leftover quote would otherwise stick).
    /// @param swapData Calldata for the Smart Router (e.g. quote → USDT (V3) → WBNB → GANG). Not decoded here.
    function buybackAndBurnSmart(address quote, uint256 amountIn, uint256 minGangOut, bytes calldata swapData)
        external
        nonReentrant
    {
        if (amountIn == 0) return;
        if (minGangOut == 0) revert ZeroAmount();
        if (quote == address(0)) revert ZeroAddress();
        if (quote == gang) {
            _burnGang(amountIn, minGangOut);
            return;
        }
        if (swapData.length == 0) revert ZeroAmount();

        _pull(quote, amountIn);
        uint256 gangBefore = IERC20(gang).balanceOf(address(this));
        uint256 quoteBefore = IERC20(quote).balanceOf(address(this));

        IERC20(quote).forceApprove(smartRouter, amountIn);
        (bool ok,) = smartRouter.call(swapData);
        IERC20(quote).forceApprove(smartRouter, 0);
        if (!ok) revert SwapFailed();

        if (IERC20(quote).balanceOf(address(this)) != quoteBefore - amountIn) revert IncompleteQuoteSpend();
        _burnDelta(quote, amountIn, gangBefore, minGangOut);
    }

    /// @dev Quote is GANG: burn what actually arrived. minGangOut still binds (a fee-taking GANG would fail it).
    function _burnGang(uint256 amountIn, uint256 minGangOut) internal {
        uint256 before = IERC20(gang).balanceOf(address(this));
        _pull(gang, amountIn);
        _burnDelta(gang, amountIn, before, minGangOut);
    }

    function _burnDelta(address quote, uint256 amountIn, uint256 gangBefore, uint256 minGangOut) internal {
        uint256 got = IERC20(gang).balanceOf(address(this)) - gangBefore;
        if (got < minGangOut) revert InsufficientGangOut();
        IERC20(gang).safeTransfer(DEAD, got);
        emit BuybackBurned(quote, amountIn, got);
    }

    function _pull(address quote, uint256 amountIn) internal {
        IERC20(quote).safeTransferFrom(msg.sender, address(this), amountIn);
        quoteReceived[quote] += amountIn;
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

    function _setRouter(address router_) internal {
        if (router_ == address(0)) revert ZeroAddress();
        router = IPancakeRouter02(router_);
        emit RouterSet(router_);
    }

    function _setSmartRouter(address smartRouter_) internal {
        if (smartRouter_ == address(0)) revert ZeroAddress();
        smartRouter = smartRouter_;
        emit SmartRouterSet(smartRouter_);
    }

    function _setWbnb(address wbnb_) internal {
        if (wbnb_ == address(0)) revert ZeroAddress();
        wbnb = wbnb_;
        emit WbnbSet(wbnb_);
    }

    function _setGang(address gang_) internal {
        if (gang_ == address(0)) revert ZeroAddress();
        gang = gang_;
        emit GangSet(gang_);
    }
}
