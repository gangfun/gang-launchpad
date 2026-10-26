// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {DividendVault} from "../launchpad-v2/DividendVault.sol";
import {IPostGradTaxHandler} from "../launchpad-v2/interfaces/IPostGradTaxHandler.sol";
import {IUniswapV2PairLite} from "../launchpad-v2/interfaces/IUniswapV2PairLite.sol";
import {IPancakeRouter02} from "../launchpad-v2/interfaces/IPancake.sol";
import {TaxRouterV3} from "./TaxRouterV3.sol";
import {TaxLaunchTokenV3} from "./TaxLaunchTokenV3.sol";
import {ITaxRouter} from "./interfaces/ITaxRouter.sol";

interface IUniswapV2PairSwap4V3 {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

/// @title PostGradTaxHandlerV3
/// @notice Same as V2 PostGradTaxHandler up to the swap; the resulting quote goes to TaxRouterV3 instead of a
///         fixed 50/50, so the split follows each token's dividend share and tax recipient.
///         Buys and sells may be taxed at different rates, so the platform's 0.5% of volume is counted per trade
///         when the tax accrues (in tokens) and handed to the router as the same fraction of the swap's quote.
/// @dev Must be a TaxRouterV3 source and a DividendVault operator.
///      V2 Finding 2: accrue only in the transfer hook. H1: `process` keeper/owner-only with mandatory minQuoteOut.
///      H2: the DEX pair never holds dividend shares.
contract PostGradTaxHandlerV3 is IPostGradTaxHandler, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev Pancake V2 fee numerator (9975/10000 = 0.25%).
    uint256 public constant DEX_FEE_NUM = 9975;
    uint256 public constant DEX_FEE_DEN = 10000;
    /// @dev Platform's part of every taxed trade, as a share of its volume (same as LaunchpadV3.PLATFORM_TAX_BPS).
    uint256 public constant PLATFORM_TAX_BPS = 50;

    DividendVault public immutable dividendVault;
    TaxRouterV3 public immutable router;

    IPancakeRouter02 public dexRouter;
    address public keeper;
    mapping(address => uint256) public accruedTax;
    /// @notice Part of `accruedTax` that is the platform's (tokens).
    mapping(address => uint256) public accruedPlatformTax;

    error OnlyToken();
    error ZeroAddress();
    error ZeroAmount();
    error NoPair();
    error UnknownToken();
    error SwapFailed();
    error Slippage();
    error OnlyKeeperOrOwner();

    event DexRouterSet(address indexed router);
    event KeeperSet(address indexed keeper);
    event TaxAccrued(
        address indexed token, address indexed from, address indexed to, uint256 taxAmount, uint256 accrued
    );
    event OuterTaxProcessed(
        address indexed token, address indexed quote, uint256 taxTokens, uint256 quoteOut, uint256 platformQuote
    );

    constructor(address owner_, address dividendVault_, address router_) Ownable(owner_) {
        if (dividendVault_ == address(0) || router_ == address(0)) revert ZeroAddress();
        dividendVault = DividendVault(dividendVault_);
        router = TaxRouterV3(router_);
    }

    function setDexRouter(address router_) external onlyOwner {
        if (router_ == address(0)) revert ZeroAddress();
        dexRouter = IPancakeRouter02(router_);
        emit DexRouterSet(router_);
    }

    function setKeeper(address keeper_) external onlyOwner {
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    /// @inheritdoc IPostGradTaxHandler
    function notifyTax(address token, address from, address to, uint256 taxAmount) external nonReentrant {
        if (msg.sender != token) revert OnlyToken();
        if (taxAmount == 0) revert ZeroAmount();
        accruedTax[token] += taxAmount;
        // the token taxed this trade at its buy or sell rate; the platform's 0.5% of volume is that share of the tax
        TaxLaunchTokenV3 t = TaxLaunchTokenV3(token);
        uint256 rate = from == t.pair() ? t.buyTaxBps() : t.sellTaxBps();
        if (rate > 0) accruedPlatformTax[token] += (taxAmount * PLATFORM_TAX_BPS) / rate;
        emit TaxAccrued(token, from, to, taxAmount, accruedTax[token]);
    }

    /// @inheritdoc IPostGradTaxHandler
    /// @dev Permissionless and never reverts for unknown tokens (runs inside token transfers).
    function syncShares(address token, address from, address to) external {
        if (dividendVault.quoteOf(token) == address(0)) return;
        _syncShares(token, from);
        _syncShares(token, to);
    }

    /// @inheritdoc IPostGradTaxHandler
    function process(address token, uint256 minQuoteOut) external nonReentrant returns (uint256 quoteOut) {
        if (msg.sender != keeper && msg.sender != owner()) revert OnlyKeeperOrOwner();
        if (minQuoteOut == 0) revert ZeroAmount();
        uint256 amount = accruedTax[token];
        if (amount == 0) revert ZeroAmount();

        address pair = TaxLaunchTokenV3(token).pair();
        if (pair == address(0)) revert NoPair();
        (address quote,,) = router.routeOf(token);
        if (quote == address(0)) revert UnknownToken();

        uint256 platformTokens = accruedPlatformTax[token];
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (amount > bal) {
            platformTokens = (platformTokens * bal) / amount;
            amount = bal;
        }
        if (amount == 0) revert ZeroAmount();
        accruedTax[token] = 0;
        accruedPlatformTax[token] = 0;

        if (address(dexRouter) != address(0)) {
            quoteOut = _swapViaRouter(token, quote, amount, minQuoteOut);
        } else {
            quoteOut = _swapViaPair(token, pair, quote, amount, minQuoteOut);
        }

        uint256 platformQuote = (quoteOut * platformTokens) / amount;
        IERC20(quote).forceApprove(address(router), quoteOut);
        router.distribute(token, quoteOut, platformQuote, ITaxRouter.Phase.PostGrad);

        emit OuterTaxProcessed(token, quote, amount, quoteOut, platformQuote);
    }

    function _syncShares(address token, address user) internal {
        if (user == address(0)) return;
        if (user == address(this)) return;
        address pair = TaxLaunchTokenV3(token).pair();
        if (user == pair) {
            if (dividendVault.shares(token, user) != 0) dividendVault.setShare(token, user, 0);
            return;
        }
        // Audit G-01: setExcluded does not clear shares, so an excluded holder is written to 0 here instead of being
        // skipped (skipping left its old share earning forever)
        if (dividendVault.excluded(user)) {
            if (dividendVault.shares(token, user) != 0) dividendVault.setShare(token, user, 0);
            return;
        }
        dividendVault.setShare(token, user, IERC20(token).balanceOf(user));
    }

    function _swapViaRouter(address token, address quote, uint256 amountIn, uint256 minQuoteOut)
        internal
        returns (uint256 quoteOut)
    {
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = quote;

        IERC20(token).forceApprove(address(dexRouter), amountIn);
        uint256 before = IERC20(quote).balanceOf(address(this));
        dexRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountIn, minQuoteOut, path, address(this), block.timestamp
        );
        quoteOut = IERC20(quote).balanceOf(address(this)) - before;
        if (quoteOut == 0) revert SwapFailed();
        if (quoteOut < minQuoteOut) revert Slippage();
    }

    function _swapViaPair(address token, address pair, address quote, uint256 taxAmount, uint256 minQuoteOut)
        internal
        returns (uint256 quoteOut)
    {
        address t0 = IUniswapV2PairLite(pair).token0();
        address t1 = IUniswapV2PairLite(pair).token1();
        (uint112 r0, uint112 r1,) = IUniswapV2PairLite(pair).getReserves();
        bool tokenIs0 = token == t0;
        if (!tokenIs0 && token != t1) revert SwapFailed();
        if (quote != (tokenIs0 ? t1 : t0)) revert SwapFailed();

        uint256 reserveIn = tokenIs0 ? uint256(r0) : uint256(r1);
        uint256 reserveOut = tokenIs0 ? uint256(r1) : uint256(r0);
        if (reserveIn == 0 || reserveOut == 0) revert SwapFailed();
        uint256 amountInWithFee = taxAmount * DEX_FEE_NUM;
        quoteOut = (amountInWithFee * reserveOut) / (reserveIn * DEX_FEE_DEN + amountInWithFee);
        if (quoteOut == 0 || quoteOut >= reserveOut) revert SwapFailed();
        if (quoteOut < minQuoteOut) revert Slippage();

        IERC20(token).safeTransfer(pair, taxAmount);
        uint256 before = IERC20(quote).balanceOf(address(this));
        if (tokenIs0) IUniswapV2PairSwap4V3(pair).swap(0, quoteOut, address(this), "");
        else IUniswapV2PairSwap4V3(pair).swap(quoteOut, 0, address(this), "");
        quoteOut = IERC20(quote).balanceOf(address(this)) - before;
    }
}
