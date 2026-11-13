// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPancakeRouter02} from "../interfaces/IPancake.sol";

/// @dev Pancake Smart Router's V3 exact-input entry (IV3SwapRouter: no deadline field).
interface IV3SwapRouter {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

/// @title RoutedBuybackBurner — buyback for the SharedPlatformFeeBucket (LaunchpadV3 / 打新 / Flywheel), with Pancake V3
///        routes the owner sets per quote
/// @notice Drop-in for GangBuybackBurner behind SharedPlatformFeeBucket.setBurner: same `buybackAndBurn` entry, so the
///         bucket needs no redeploy. Stock-style quotes (oANTHROPIC, EWYB, …) have their depth on Pancake V3 against
///         USDT and none on V2, so the fixed V2 path left their fees stuck in the bucket.
///         - quote == GANG: burned as received, no swap.
///         - quote with a V3 route: quote → … → WBNB on Pancake V3 (the owner's path, recipient this contract), then
///           WBNB → GANG on Pancake V2.
///         - any other quote: Pancake V2 [WBNB, GANG] or [quote, WBNB, GANG], as before.
///         GANG received ≥ minGangOut, all of it to DEAD.
/// @dev Why the route is owner-set and not keeper-supplied (internal audit 5, C-F2, the reason the shared bucket has no
///      collectPlatformSmart): keeper calldata could send the 80% leg anywhere, and a keeper-chosen V3 fee tier could
///      pick a pool the keeper seeded itself. Here the keeper only chooses `minGangOut`, exactly as on the V2 path;
///      the pools are the ones the owner named, and every swap pays this contract.
contract RoutedBuybackBurner is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 private constant ADDR = 20;
    uint256 private constant HOP = 23; // fee (3 bytes) + next token (20 bytes)

    IPancakeRouter02 public immutable router;
    address public immutable smartRouter;
    address public immutable wbnb;
    address public immutable gang;

    /// @notice Pancake V3 path (token, fee, token, …) from the quote to WBNB; empty = V2 path.
    mapping(address => bytes) public v3Route;
    mapping(address => uint256) public quoteReceived;

    event V3RouteSet(address indexed quote, bytes path);
    event BuybackBurned(address indexed quote, uint256 quoteIn, uint256 gangBurned);

    error ZeroAddress();
    error ZeroAmount();
    error InsufficientGangOut();
    error IncompleteQuoteSpend();
    error NoWbnbOut();
    error BadRoute();

    constructor(address owner_, address router_, address smartRouter_, address wbnb_, address gang_) Ownable(owner_) {
        if (router_ == address(0) || smartRouter_ == address(0) || wbnb_ == address(0) || gang_ == address(0)) {
            revert ZeroAddress();
        }
        router = IPancakeRouter02(router_);
        smartRouter = smartRouter_;
        wbnb = wbnb_;
        gang = gang_;
    }

    /// @notice Route `quote`'s buyback through Pancake V3 along `path` (quote, fee, token, …, fee, WBNB); an empty
    ///         `path` returns `quote` to the V2 path. Fees must be Pancake V3 tiers (100 / 500 / 2500 / 10000).
    function setV3Route(address quote, bytes calldata path) external onlyOwner {
        if (quote == address(0)) revert ZeroAddress();
        if (path.length != 0) _checkRoute(quote, path);
        v3Route[quote] = path;
        emit V3RouteSet(quote, path);
    }

    /// @notice Pull `amountIn` quote, swap it to GANG (see the contract notice for the route), burn the GANG to DEAD.
    /// @param minGangOut Caller slippage floor for the whole route, from an off-chain quote (never derived in the tx).
    function buybackAndBurn(address quote, uint256 amountIn, uint256 minGangOut) external nonReentrant {
        if (amountIn == 0) return;
        if (minGangOut == 0) revert ZeroAmount();
        if (quote == address(0)) revert ZeroAddress();

        uint256 gangBefore = IERC20(gang).balanceOf(address(this));
        _pull(quote, amountIn);
        if (quote == gang) {
            _burnDelta(gang, amountIn, gangBefore, minGangOut);
            return;
        }

        bytes memory path = v3Route[quote];
        if (path.length == 0) {
            IERC20(quote).forceApprove(address(router), amountIn);
            router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                amountIn, minGangOut, _v2Path(quote), address(this), block.timestamp
            );
        } else {
            uint256 wbnbOut = _v3ToWbnb(quote, amountIn, path);
            IERC20(wbnb).forceApprove(address(router), wbnbOut);
            router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
                wbnbOut, minGangOut, _v2Path(wbnb), address(this), block.timestamp
            );
        }
        _burnDelta(quote, amountIn, gangBefore, minGangOut);
    }

    /// @dev Exact input on Pancake V3, paid to this contract; returns the WBNB that actually arrived. No per-leg floor:
    ///      minGangOut binds the whole route at the end, after the V2 leg. Nothing arrived (the router paid someone else,
    ///      or the route is dust) reverts here, not on whatever the V2 router says about a zero input.
    function _v3ToWbnb(address quote, uint256 amountIn, bytes memory path) internal returns (uint256) {
        uint256 quoteBefore = IERC20(quote).balanceOf(address(this));
        uint256 wbnbBefore = IERC20(wbnb).balanceOf(address(this));
        IERC20(quote).forceApprove(smartRouter, amountIn);
        IV3SwapRouter(smartRouter)
            .exactInput(
                IV3SwapRouter.ExactInputParams({
                    path: path, recipient: address(this), amountIn: amountIn, amountOutMinimum: 0
                })
            );
        IERC20(quote).forceApprove(smartRouter, 0);
        if (IERC20(quote).balanceOf(address(this)) != quoteBefore - amountIn) revert IncompleteQuoteSpend();
        uint256 got = IERC20(wbnb).balanceOf(address(this)) - wbnbBefore;
        if (got == 0) revert NoWbnbOut();
        return got;
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

    function _v2Path(address quote) internal view returns (address[] memory path) {
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

    /// @dev path = quote (fee token)+ with the last token WBNB; at most 3 hops; no WBNB / GANG before the end (a route
    ///      through GANG would buy and sell the token being burned); every fee a Pancake V3 tier.
    function _checkRoute(address quote, bytes calldata path) internal view {
        if (quote == wbnb || quote == gang) revert BadRoute();
        uint256 n = path.length;
        if (n < ADDR + HOP || (n - ADDR) % HOP != 0 || (n - ADDR) / HOP > 3) revert BadRoute();
        if (_tokenAt(path, 0) != quote) revert BadRoute();
        for (uint256 o = ADDR; o < n; o += HOP) {
            uint24 fee = uint24(bytes3(path[o:o + 3]));
            if (fee != 100 && fee != 500 && fee != 2500 && fee != 10000) revert BadRoute();
            address t = _tokenAt(path, o + 3);
            bool last = o + HOP == n;
            if (last ? t != wbnb : (t == wbnb || t == gang || t == quote || t == address(0))) revert BadRoute();
        }
    }

    function _tokenAt(bytes calldata path, uint256 o) internal pure returns (address) {
        return address(bytes20(path[o:o + ADDR]));
    }
}
