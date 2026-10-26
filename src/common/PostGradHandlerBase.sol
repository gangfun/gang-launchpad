// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {DividendVault} from "../launchpad-v2/DividendVault.sol";
import {IUniswapV2PairLite} from "../launchpad-v2/interfaces/IUniswapV2PairLite.sol";
import {IPancakeRouter02} from "../launchpad-v2/interfaces/IPancake.sol";

interface IPairSwap {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IHasPair {
    function pair() external view returns (address);
}

/// @title PostGradHandlerBase (pool tax after graduation / launch)
/// @notice What every post-grad tax handler does the same way: the token's transfer hook only accrues the tax (in
///         tokens, V2 Finding 2); the keeper later sells it for the quote (`_process`: mandatory off-chain minQuoteOut,
///         V2 H1) through the Pancake router or straight into the token's own pair, and the subclass splits the quote.
///         Subclasses decide which tokens they accept (`_quoteOf`), how a share is written, and where the quote goes.
/// @dev The pair the tax is sold into must hold exactly the token and its quote on both swap paths (the router path
///      picks its pool from the path, so it is checked here too).
abstract contract PostGradHandlerBase is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev Pancake V2 fee numerator (9975/10000 = 0.25%).
    uint256 public constant DEX_FEE_NUM = 9975;
    uint256 public constant DEX_FEE_DEN = 10000;

    DividendVault public immutable dividendVault;

    IPancakeRouter02 public dexRouter;
    address public keeper;
    /// @notice Tax tokens accrued per token, sold by the next `process`.
    mapping(address => uint256) public accruedTax;

    error OnlyToken();
    error ZeroAddress();
    error ZeroAmount();
    error NoPair();
    error SwapFailed();
    error Slippage();
    error OnlyKeeperOrOwner();
    error PairQuoteMismatch();
    error OutOfGas();

    event DexRouterSet(address indexed router);
    event KeeperSet(address indexed keeper);
    event TaxAccrued(
        address indexed token, address indexed from, address indexed to, uint256 taxAmount, uint256 accrued
    );

    constructor(address owner_, address dividendVault_) Ownable(owner_) {
        if (dividendVault_ == address(0)) revert ZeroAddress();
        dividendVault = DividendVault(dividendVault_);
    }

    /// @notice 0 = sell straight into the token's pair.
    function setDexRouter(address router_) external onlyOwner {
        if (router_ == address(0)) revert ZeroAddress();
        dexRouter = IPancakeRouter02(router_);
        emit DexRouterSet(router_);
    }

    function setKeeper(address keeper_) external onlyOwner {
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    // ---------------------------------------------------------------- for subclasses
    /// @dev Transfer-hook guard: only the token itself, never for nothing.
    function _checkHook(address token, uint256 taxAmount) internal view {
        if (msg.sender != token) revert OnlyToken();
        if (taxAmount == 0) revert ZeroAmount();
    }

    function _accrue(address token, address from, address to, uint256 taxAmount) internal {
        accruedTax[token] += taxAmount;
        emit TaxAccrued(token, from, to, taxAmount, accruedTax[token]);
    }

    /// @dev The quote `token`'s tax is sold for; reverts for a token this handler does not serve.
    function _quoteOf(address token) internal view virtual returns (address quote);

    /// @dev Called once the amount to sell is fixed (`amount` ≤ `accrued`, less when the balance fell short), before
    ///      the swap; returns whatever the split needs to remember (e.g. the platform's part, in tokens).
    function _takeAccrued(address token, uint256 amount, uint256 accrued) internal virtual returns (uint256 ctx);

    /// @dev Pays out `quoteOut` (already held here) for `amount` tax tokens sold.
    function _onProceeds(address token, address quote, uint256 amount, uint256 quoteOut, uint256 ctx) internal virtual;

    /// @dev Tax tokens of `token` this contract may sell (its whole balance unless the subclass holds some for others).
    function _sellable(address token) internal view virtual returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    /// @dev Keeper/owner only, mandatory minQuoteOut. Subclasses expose it as `process` (nonReentrant).
    function _process(address token, uint256 minQuoteOut) internal returns (uint256 quoteOut) {
        if (msg.sender != keeper && msg.sender != owner()) revert OnlyKeeperOrOwner();
        if (minQuoteOut == 0) revert ZeroAmount();
        uint256 accrued = accruedTax[token];
        if (accrued == 0) revert ZeroAmount();

        address pair = IHasPair(token).pair();
        if (pair == address(0)) revert NoPair();
        address quote = _quoteOf(token);
        bool tokenIs0 = _tokenIs0(pair, token, quote);

        uint256 amount = accrued;
        uint256 bal = _sellable(token);
        if (amount > bal) amount = bal;
        if (amount == 0) revert ZeroAmount();
        accruedTax[token] = 0;
        uint256 ctx = _takeAccrued(token, amount, accrued);

        if (address(dexRouter) != address(0)) {
            quoteOut = _swapViaRouter(token, quote, amount, minQuoteOut);
        } else {
            quoteOut = _swapViaPair(token, pair, quote, tokenIs0, amount, minQuoteOut);
        }
        _onProceeds(token, quote, amount, quoteOut, ctx);
    }

    /// @dev Writes a vault share without letting a vault-side failure (e.g. operator revoked) freeze the transfer
    ///      this runs in; a caller that starved the call (63/64 rule) to leave a stale share behind is refused instead.
    function _setShareGuarded(address token, address user, uint256 share) internal {
        uint256 gasBefore = gasleft();
        try dividendVault.setShare(token, user, share) {}
        catch {
            if (gasleft() <= gasBefore / 63) revert OutOfGas();
        }
    }

    // ---------------------------------------------------------------- swap
    /// @dev `pair` holds exactly `token` and `quote`; whether `token` is token0.
    function _tokenIs0(address pair, address token, address quote) internal view returns (bool tokenIs0) {
        address t0 = IUniswapV2PairLite(pair).token0();
        address t1 = IUniswapV2PairLite(pair).token1();
        tokenIs0 = t0 == token;
        if (tokenIs0 ? t1 != quote : (t1 != token || t0 != quote)) revert PairQuoteMismatch();
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

    /// @dev Direct pair swap with the Pancake V2 0.25% fee; prices what the pair actually received (handlers are
    ///      tax-excluded, so that equals `amountIn`).
    function _swapViaPair(
        address token,
        address pair,
        address quote,
        bool tokenIs0,
        uint256 amountIn,
        uint256 minQuoteOut
    ) internal returns (uint256 quoteOut) {
        (uint112 r0, uint112 r1,) = IUniswapV2PairLite(pair).getReserves();
        uint256 reserveIn = tokenIs0 ? uint256(r0) : uint256(r1);
        uint256 reserveOut = tokenIs0 ? uint256(r1) : uint256(r0);
        if (reserveIn == 0 || reserveOut == 0) revert SwapFailed();
        uint256 inWithFee = amountIn * DEX_FEE_NUM;
        uint256 out = (inWithFee * reserveOut) / (reserveIn * DEX_FEE_DEN + inWithFee);
        if (out == 0 || out >= reserveOut) revert SwapFailed();
        if (out < minQuoteOut) revert Slippage();

        IERC20(token).safeTransfer(pair, amountIn);
        uint256 before = IERC20(quote).balanceOf(address(this));
        if (tokenIs0) IPairSwap(pair).swap(0, out, address(this), "");
        else IPairSwap(pair).swap(out, 0, address(this), "");
        quoteOut = IERC20(quote).balanceOf(address(this)) - before;
    }
}
