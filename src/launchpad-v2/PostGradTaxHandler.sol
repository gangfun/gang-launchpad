// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {DividendVault} from "./DividendVault.sol";
import {PlatformFeeBucket} from "./PlatformFeeBucket.sol";
import {TaxLaunchToken} from "./TaxLaunchToken.sol";
import {IPostGradTaxHandler} from "./interfaces/IPostGradTaxHandler.sol";
import {IUniswapV2PairLite} from "./interfaces/IUniswapV2PairLite.sol";
import {IPancakeRouter02} from "./interfaces/IPancake.sol";

/// @title PostGradTaxHandler (Tip B)
/// @notice Receives 1% outer TaxLaunchToken tax, later sells to quote, then splits 50/50
///         DividendVault / PlatformFeeBucket (→ 80/20 feeVault on collect).
/// @dev Finding 2 (Critical, 2026-10-23): NEVER swap inside transfer/`notifyTax`. Hook only accrues;
///      `process(token, minQuoteOut)` sells via router (preferred) or fee-aware pair swap (0.25% Pancake K).
///      Finding 3: `syncShares` on every transfer (including wallet↔wallet).
///      Review 2026-10-23 (H1/H2): `process` is keeper/owner-only with a mandatory off-chain minQuoteOut;
///      the DEX pair can never hold dividend shares (forced to zero on every sync).
interface IUniswapV2PairSwap4 {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

contract PostGradTaxHandler is IPostGradTaxHandler, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant DIV_SHARE_BPS = 5_000; // 50% of outer tax → holders
    /// @dev Pancake V2 fee numerator (9975/10000 = 0.25%). OPT5 Lazy #10.
    uint256 public constant DEX_FEE_NUM = 9975;
    uint256 public constant DEX_FEE_DEN = 10000;

    DividendVault public immutable dividendVault;
    PlatformFeeBucket public immutable platformBucket;

    IPancakeRouter02 public router;
    /// @notice Keeper allowed to call `process` (owner always allowed). Off-chain minQuoteOut is mandatory.
    address public keeper;
    /// @notice Accrued tax tokens awaiting `process` (already held by this contract).
    mapping(address => uint256) public accruedTax;

    error OnlyToken();
    error ZeroAddress();
    error ZeroAmount();
    error NoPair();
    error SwapFailed();
    error Slippage();
    error RouterNotSet();
    error OnlyKeeperOrOwner();

    event RouterSet(address indexed router);
    event KeeperSet(address indexed keeper);
    event TaxAccrued(address indexed token, address indexed from, address indexed to, uint256 taxAmount, uint256 accrued);
    event OuterTaxProcessed(
        address indexed token, address indexed quote, uint256 taxTokens, uint256 quoteOut, uint256 toDiv, uint256 toPlat
    );

    constructor(address owner_, address dividendVault_, address platformBucket_) Ownable(owner_) {
        if (dividendVault_ == address(0) || platformBucket_ == address(0)) revert ZeroAddress();
        dividendVault = DividendVault(dividendVault_);
        platformBucket = PlatformFeeBucket(platformBucket_);
    }

    function setRouter(address router_) external onlyOwner {
        if (router_ == address(0)) revert ZeroAddress();
        router = IPancakeRouter02(router_);
        emit RouterSet(router_);
    }

    /// @notice Owner sets (or clears) the keeper allowed to call `process`.
    function setKeeper(address keeper_) external onlyOwner {
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    /// @inheritdoc IPostGradTaxHandler
    /// @dev Accrue only. NO DEX call (avoids pair LOCKED / bad K / 3-arg selector). Share sync is NOT done here:
    ///      TaxLaunchToken._update always calls `syncShares` right after, so doing it twice only wastes gas.
    function notifyTax(address token, address from, address to, uint256 taxAmount) external nonReentrant {
        if (msg.sender != token) revert OnlyToken();
        if (taxAmount == 0) revert ZeroAmount();

        accruedTax[token] += taxAmount;
        emit TaxAccrued(token, from, to, taxAmount, accruedTax[token]);
    }

    /// @inheritdoc IPostGradTaxHandler
    /// @dev Permissionless: only mirrors true balances into the vault, so anyone calling it is harmless.
    ///      Silently ignores tokens the vault does not know (never revert here: this runs inside token transfers).
    function syncShares(address token, address from, address to) external {
        if (dividendVault.quoteOf(token) == address(0)) return;
        _syncShares(token, from);
        _syncShares(token, to);
    }

    /// @inheritdoc IPostGradTaxHandler
    /// @dev Keeper/owner only (H1). `minQuoteOut` is mandatory and must come from an off-chain quote; a
    ///      permissionless caller with a self-chosen floor could sandwich the whole accrued balance.
    function process(address token, uint256 minQuoteOut) external nonReentrant returns (uint256 quoteOut) {
        if (msg.sender != keeper && msg.sender != owner()) revert OnlyKeeperOrOwner();
        if (minQuoteOut == 0) revert ZeroAmount();
        uint256 amount = accruedTax[token];
        if (amount == 0) revert ZeroAmount();

        address pair = TaxLaunchToken(token).pair();
        if (pair == address(0)) revert NoPair();

        address quote = dividendVault.quoteOf(token);
        if (quote == address(0)) revert ZeroAddress();

        // Cap by actual balance (defensive).
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (amount > bal) amount = bal;
        if (amount == 0) revert ZeroAmount();
        accruedTax[token] = 0;

        if (address(router) != address(0)) {
            quoteOut = _swapViaRouter(token, quote, amount, minQuoteOut);
        } else {
            quoteOut = _swapViaPair(token, pair, quote, amount, minQuoteOut);
        }

        uint256 toDiv = (quoteOut * DIV_SHARE_BPS) / BPS;
        uint256 toPlat = quoteOut - toDiv;

        if (toDiv > 0) {
            IERC20(quote).forceApprove(address(dividendVault), toDiv);
            dividendVault.depositReward(token, toDiv);
        }
        if (toPlat > 0) {
            IERC20(quote).forceApprove(address(platformBucket), toPlat);
            platformBucket.notifyAccrual(quote, toPlat);
        }

        emit OuterTaxProcessed(token, quote, amount, quoteOut, toDiv, toPlat);
    }

    function _syncShares(address token, address user) internal {
        if (user == address(0)) return;
        if (user == address(this)) return;
        address pair = TaxLaunchToken(token).pair();
        if (user == pair) {
            // H2: the DEX pair must never earn dividends (anyone could `claimFor(pair)` + `skim`). Force 0.
            if (dividendVault.shares(token, user) != 0) dividendVault.setShare(token, user, 0);
            return;
        }
        if (dividendVault.excluded(user)) return;
        uint256 bal = IERC20(token).balanceOf(user);
        dividendVault.setShare(token, user, bal);
    }

    function _swapViaRouter(address token, address quote, uint256 amountIn, uint256 minQuoteOut)
        internal
        returns (uint256 quoteOut)
    {
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = quote;

        IERC20(token).forceApprove(address(router), amountIn);
        uint256 before = IERC20(quote).balanceOf(address(this));
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountIn, minQuoteOut, path, address(this), block.timestamp
        );
        quoteOut = IERC20(quote).balanceOf(address(this)) - before;
        if (quoteOut == 0) revert SwapFailed();
        if (quoteOut < minQuoteOut) revert Slippage();
    }

    /// @dev Direct pair swap with Pancake V2 0.25% fee (OPT5). Uses 4-arg swap.
    function _swapViaPair(address token, address pair, address quote, uint256 taxAmount, uint256 minQuoteOut)
        internal
        returns (uint256 quoteOut)
    {
        (bool tokenIs0, uint256 outAmt) = _quotePairOut(token, pair, quote, taxAmount);
        if (outAmt < minQuoteOut) revert Slippage();
        IERC20(token).safeTransfer(pair, taxAmount);
        if (tokenIs0) {
            IUniswapV2PairSwap4(pair).swap(0, outAmt, address(this), "");
        } else {
            IUniswapV2PairSwap4(pair).swap(outAmt, 0, address(this), "");
        }
        quoteOut = outAmt;
    }

    function _quotePairOut(address token, address pair, address quote, uint256 taxAmount)
        internal
        view
        returns (bool tokenIs0, uint256 quoteOut)
    {
        address t0 = IUniswapV2PairLite(pair).token0();
        address t1 = IUniswapV2PairLite(pair).token1();
        (uint112 r0, uint112 r1,) = IUniswapV2PairLite(pair).getReserves();

        tokenIs0 = token == t0;
        if (!tokenIs0 && token != t1) revert SwapFailed();
        if (quote != (tokenIs0 ? t1 : t0)) revert SwapFailed();

        uint256 reserveIn = tokenIs0 ? uint256(r0) : uint256(r1);
        uint256 reserveOut = tokenIs0 ? uint256(r1) : uint256(r0);
        if (reserveIn == 0 || reserveOut == 0) revert SwapFailed();

        uint256 amountInWithFee = taxAmount * DEX_FEE_NUM;
        quoteOut = (amountInWithFee * reserveOut) / (reserveIn * DEX_FEE_DEN + amountInWithFee);
        if (quoteOut == 0 || quoteOut >= reserveOut) revert SwapFailed();
    }
}
