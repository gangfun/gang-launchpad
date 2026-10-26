// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SharedDividendVault} from "./SharedDividendVault.sol";
import {PlatformFeeBucket} from "../launchpad-v2/PlatformFeeBucket.sol";
import {IUniswapV2PairLite} from "../launchpad-v2/interfaces/IUniswapV2PairLite.sol";
import {IPancakeRouter02} from "../launchpad-v2/interfaces/IPancake.sol";

interface IPairSwap {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IHasPair {
    function pair() external view returns (address);
}

/// @title PostGradHandlerBase (pool tax after graduation / launch)
/// @notice What every post-grad tax handler does the same way. The token's transfer hook accrues the tax in tokens;
///         the holders' part of it is credited to holders right then (SharedDividendVault, tax-time units). The tax is
///         sold in small chunks — at most CHUNK_MAX_BPS (0.5%) of the token side of its pair each — so it never piles
///         up into one large sell:
///         - `_swapBack`: a taxed sell into the pair asks for one chunk first (straight into the pair, priced from its
///           reserves in the same call) — at most once per token per block, and never more than SWAP_BACK_SELL_BPS
///           (25%) of that sell, so it can't be looped by tiny transfers or skims, and it adds at most about half the
///           seller's own price impact. Skipped when the pair holds unsynced balances (someone mid-way adding
///           liquidity). `previewSell` quotes a sell with its chunk included.
///         - `_process`: the keeper sells a chunk when no sells come (mandatory off-chain minQuoteOut, V2 H1),
///           through the Pancake router or straight into the pair; any number per block.
///         Each chunk's quote is split at once: the holders' units sold go to the vault (`convertDividend`), the rest to
///         the subclass (`_onProceeds`). Neither sink can make a chunk fail: a conversion the vault refuses waits here
///         (`pendingHolderUnits` / `pendingHolderQuote`, retried by the next chunk or `flushHolders`), and platform
///         quote the bucket refuses is owed (`owedPlatformOf`, `flushPlatform`). Subclasses decide which tokens they
///         accept, how shares are written, and where the rest goes.
/// @dev The pair the tax is sold into must hold exactly the token and its quote on both swap paths (the router path
///      picks its pool from the path, so it is checked here too).
abstract contract PostGradHandlerBase is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @dev Pancake V2 fee numerator (9975/10000 = 0.25%).
    uint256 public constant DEX_FEE_NUM = 9975;
    uint256 public constant DEX_FEE_DEN = 10000;
    /// @notice Largest chunk sold at once, in bps of the token's reserve in its pair (0.5% → about 1% price move).
    uint256 public constant CHUNK_MAX_BPS = 50;
    /// @notice Swap-back floor below the in-call reserve quote (it can only differ for a quote that charges on transfer).
    uint256 public constant SWAP_BACK_SLIPPAGE_BPS = 100;
    /// @notice A swap-back chunk is at most this share of the sell that triggers it (bps).
    uint256 public constant SWAP_BACK_SELL_BPS = 2500;

    SharedDividendVault public immutable dividendVault;

    IPancakeRouter02 public dexRouter;
    address public keeper;
    /// @notice Tax tokens of each token held here and not sold yet (the holders' part included).
    mapping(address => uint256) public accruedTax;
    /// @notice Block of the last swap-back per token (one per block).
    mapping(address token => uint256) public lastSwapBackBlock;
    /// @notice Holders' units sold whose quote the vault refused: held here, converted by the next chunk / flushHolders.
    mapping(address token => uint256) public pendingHolderUnits;
    mapping(address token => uint256) public pendingHolderQuote;
    /// @notice Platform quote the fee bucket refused, held here until `flushPlatform`.
    mapping(address quote => uint256) public owedPlatformOf;

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
    /// @notice A chunk of accrued tax sold (`swapBack` = during a sell, else by the keeper).
    event TaxChunkSold(address indexed token, uint256 taxTokens, uint256 quoteOut, uint256 holderUnits, bool swapBack);
    event HolderConversionDeferred(address indexed token, uint256 units, uint256 quote);
    event PlatformOwed(address indexed quote, uint256 amount);
    event PlatformFlushed(address indexed quote, uint256 amount);
    /// @notice The vault refused a share write (it is retried by the holder's next sync).
    event ShareWriteFailed(address indexed token, address indexed user, uint256 share);

    constructor(address owner_, address dividendVault_) Ownable(owner_) {
        if (dividendVault_ == address(0)) revert ZeroAddress();
        dividendVault = SharedDividendVault(dividendVault_);
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

    /// @dev Called once the chunk is fixed (`amount` of `accrued`, `holderUnits` of it the holders'), before the swap;
    ///      returns whatever the split needs to remember (e.g. the platform's part, in tokens).
    function _takeAccrued(address token, uint256 amount, uint256 accrued, uint256 holderUnits)
        internal
        virtual
        returns (uint256 ctx);

    /// @dev Pays out the chunk's quote held here: `quoteOut` in all, of which `toHolders` already went to the vault.
    function _onProceeds(address token, address quote, uint256 amount, uint256 quoteOut, uint256 toHolders, uint256 ctx)
        internal
        virtual;

    /// @dev The token's sell tax (bps), for `previewSell`.
    function _sellTaxBps(address token) internal view virtual returns (uint256);

    /// @dev The fee bucket the platform's quote goes to.
    function _bucket() internal view virtual returns (PlatformFeeBucket);

    /// @dev Tax tokens of `token` this contract may sell (its whole balance unless the subclass holds some for others).
    function _sellable(address token) internal view virtual returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    /// @notice Largest chunk of `token`'s tax that can be sold now: ≤ accrued, ≤ held, ≤ CHUNK_MAX_BPS of the token's
    ///         reserve in its pair (0 before the pair exists).
    function maxChunk(address token) public view returns (uint256 amount) {
        amount = accruedTax[token];
        if (amount == 0) return 0;
        uint256 bal = _sellable(token);
        if (amount > bal) amount = bal;
        address pair = IHasPair(token).pair();
        if (pair == address(0)) return 0;
        (uint112 r0, uint112 r1,) = IUniswapV2PairLite(pair).getReserves();
        uint256 reserve = IUniswapV2PairLite(pair).token0() == token ? uint256(r0) : uint256(r1);
        uint256 cap = (reserve * CHUNK_MAX_BPS) / 10_000;
        if (amount > cap) amount = cap;
    }

    /// @dev Keeper/owner only: sells `amount`, cut to `maxChunk` (only ever less than asked, so a minQuoteOut quoted for
    ///      `amount` can only make it revert), with a mandatory off-chain minQuoteOut. Subclasses expose it as `process`
    ///      (nonReentrant).
    function _process(address token, uint256 amount, uint256 minQuoteOut) internal returns (uint256 quoteOut) {
        if (msg.sender != keeper && msg.sender != owner()) revert OnlyKeeperOrOwner();
        if (minQuoteOut == 0) revert ZeroAmount();
        // the pair must be the token's own against its quote before anything is sized from its reserves
        address pair = IHasPair(token).pair();
        if (pair == address(0)) revert NoPair();
        _tokenIs0(pair, token, _quoteOf(token));
        uint256 max = maxChunk(token);
        if (amount > max) amount = max;
        if (amount == 0) revert ZeroAmount();
        return _sellChunk(token, amount, minQuoteOut, false);
    }

    /// @dev The token is selling `sellAmount` into its pair (the seller's tokens not moved yet, pair unlocked): sell
    ///      one chunk straight into the pair at its current reserves. Callers wrap this so it can never fail the trade.
    function _swapBack(address token, uint256 sellAmount) internal returns (uint256 quoteOut) {
        if (msg.sender != token) revert OnlyToken();
        (uint256 amount, uint256 out) = _swapBackChunk(token, sellAmount);
        if (amount == 0 || out == 0) return 0;
        lastSwapBackBlock[token] = block.number;
        return _sellChunk(token, amount, (out * (10_000 - SWAP_BACK_SLIPPAGE_BPS)) / 10_000, true);
    }

    /// @dev The chunk a sell of `sellAmount` would trigger now, and what it fetches: none if one ran this block, if the
    ///      pair holds unsynced balances, or if the sell pays no tax.
    function _swapBackChunk(address token, uint256 sellAmount) internal view returns (uint256 amount, uint256 out) {
        if (lastSwapBackBlock[token] == block.number) return (0, 0);
        if ((sellAmount * _sellTaxBps(token)) / 10_000 == 0) return (0, 0);
        amount = maxChunk(token);
        uint256 bySell = (sellAmount * SWAP_BACK_SELL_BPS) / 10_000;
        if (amount > bySell) amount = bySell;
        if (amount == 0) return (0, 0);
        address pair = IHasPair(token).pair();
        (uint112 r0, uint112 r1,) = IUniswapV2PairLite(pair).getReserves();
        bool tokenIs0 = IUniswapV2PairLite(pair).token0() == token;
        (uint256 rT, uint256 rQ) = tokenIs0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        // someone mid-way adding liquidity (one side sent, not minted yet): a swap now would absorb it
        if (IERC20(token).balanceOf(pair) != rT || IERC20(_quoteOf(token)).balanceOf(pair) != rQ) return (0, 0);
        out = _amountOut(amount, rT, rQ);
    }

    /// @notice What selling `amountIn` into the pool pays out now, the swap-back chunk it triggers included (for a
    ///         seller the token taxes; `chunk` = tax tokens sold right before it).
    function previewSell(address token, uint256 amountIn) external view returns (uint256 quoteOut, uint256 chunk) {
        address pair = IHasPair(token).pair();
        if (pair == address(0)) return (0, 0);
        (uint112 r0, uint112 r1,) = IUniswapV2PairLite(pair).getReserves();
        bool tokenIs0 = IUniswapV2PairLite(pair).token0() == token;
        (uint256 rT, uint256 rQ) = tokenIs0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 chunkOut;
        (chunk, chunkOut) = _swapBackChunk(token, amountIn);
        uint256 net = amountIn - (amountIn * _sellTaxBps(token)) / 10_000;
        quoteOut = _amountOut(net, rT + chunk, rQ - chunkOut);
    }

    /// @notice Retry a holders' conversion the vault refused. Anyone; reverts while it still refuses.
    function flushHolders(address token) external nonReentrant {
        uint256 units = pendingHolderUnits[token];
        if (units == 0) revert ZeroAmount();
        uint256 q = pendingHolderQuote[token];
        pendingHolderUnits[token] = 0;
        pendingHolderQuote[token] = 0;
        address quote = _quoteOf(token);
        _allow(quote, address(dividendVault), q);
        dividendVault.convertDividend(token, units, q);
    }

    /// @notice Pay the bucket platform quote it refused earlier. Anyone; reverts while it still refuses.
    function flushPlatform(address quote) external nonReentrant {
        uint256 amount = owedPlatformOf[quote];
        if (amount == 0) revert ZeroAmount();
        owedPlatformOf[quote] = 0;
        PlatformFeeBucket bucket = _bucket();
        _allow(quote, address(bucket), amount);
        bucket.notifyAccrual(quote, amount);
        emit PlatformFlushed(quote, amount);
    }

    /// @dev Sells `amount` of the accrued tax; the holders' part of it (oldest first in the vault) is the same share of
    ///      the chunk as of what is accrued, rounded up so it always drains.
    function _sellChunk(address token, uint256 amount, uint256 minQuoteOut, bool swapBack)
        internal
        returns (uint256 quoteOut)
    {
        address pair = IHasPair(token).pair();
        if (pair == address(0)) revert NoPair();
        address quote = _quoteOf(token);
        bool tokenIs0 = _tokenIs0(pair, token, quote);

        uint256 accrued = accruedTax[token];
        // holder units already sold but waiting on the vault are not in the tokens left to sell
        uint256 unsold = dividendVault.unsoldUnits(token) - pendingHolderUnits[token];
        uint256 holderUnits = amount == accrued ? unsold : Math.mulDiv(unsold, amount, accrued, Math.Rounding.Ceil);
        accruedTax[token] = accrued - amount;
        uint256 ctx = _takeAccrued(token, amount, accrued, holderUnits);

        if (swapBack || address(dexRouter) == address(0)) {
            quoteOut = _swapViaPair(token, pair, quote, tokenIs0, amount, minQuoteOut);
        } else {
            quoteOut = _swapViaRouter(token, quote, amount, minQuoteOut);
        }

        uint256 toHolders = holderUnits == 0 ? 0 : (quoteOut * holderUnits) / amount;
        _convertHolders(token, quote, holderUnits, toHolders);
        _onProceeds(token, quote, amount, quoteOut, toHolders, ctx);
        emit TaxChunkSold(token, amount, quoteOut, holderUnits, swapBack);
    }

    /// @dev Holders' units sold (with any still waiting) → quote in the vault; a refusal keeps them waiting here.
    function _convertHolders(address token, address quote, uint256 units, uint256 q) internal {
        units += pendingHolderUnits[token];
        if (units == 0) return;
        q += pendingHolderQuote[token];
        _allow(quote, address(dividendVault), q);
        try dividendVault.convertDividend(token, units, q) {
            if (pendingHolderUnits[token] != 0) (pendingHolderUnits[token], pendingHolderQuote[token]) = (0, 0);
        } catch {
            (pendingHolderUnits[token], pendingHolderQuote[token]) = (units, q);
            emit HolderConversionDeferred(token, units, q);
        }
    }

    /// @dev Platform quote → the bucket; a refusal (e.g. the handler's operator role revoked) is owed, not fatal.
    function _payPlatform(address quote, uint256 amount) internal {
        if (amount == 0) return;
        PlatformFeeBucket bucket = _bucket();
        _allow(quote, address(bucket), amount);
        try bucket.notifyAccrual(quote, amount) {}
        catch {
            owedPlatformOf[quote] += amount;
            emit PlatformOwed(quote, amount);
        }
    }

    /// @dev The vault and the fee bucket are fixed (immutable) sinks that pull what they are paid: approve them once
    ///      for good instead of before every payment (one allowance write less per chunk).
    function _allow(address quote, address spender, uint256 amount) internal {
        if (IERC20(quote).allowance(address(this), spender) < amount) {
            IERC20(quote).forceApprove(spender, type(uint256).max);
        }
    }

    /// @dev Credits the holders' part of a tax just taken; false (nothing credited, the caller pays that part
    ///      elsewhere) when the token has no shares or the vault refuses — this runs inside token transfers, and a
    ///      vault-side failure (e.g. operator revoked) must not freeze trading. A starved call is refused instead.
    function _creditHolders(address token, uint256 units) internal returns (bool) {
        if (units == 0 || dividendVault.totalShares(token) == 0) return false;
        uint256 gasBefore = gasleft();
        try dividendVault.accrueDividendUnits(token, units) {
            return true;
        } catch {
            if (gasleft() <= gasBefore / 63) revert OutOfGas();
            return false;
        }
    }

    /// @dev Writes a vault share without letting a vault-side failure (e.g. operator revoked) freeze the transfer
    ///      this runs in; a caller that starved the call (63/64 rule) to leave a stale share behind is refused instead.
    function _setShareGuarded(address token, address user, uint256 share) internal {
        uint256 gasBefore = gasleft();
        try dividendVault.setShare(token, user, share) {}
        catch {
            if (gasleft() <= gasBefore / 63) revert OutOfGas();
            emit ShareWriteFailed(token, user, share);
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
        uint256 reserveOut = tokenIs0 ? uint256(r1) : uint256(r0);
        uint256 out = _amountOut(amountIn, tokenIs0 ? r0 : r1, reserveOut);
        if (out == 0 || out >= reserveOut) revert SwapFailed();
        if (out < minQuoteOut) revert Slippage();

        IERC20(token).safeTransfer(pair, amountIn);
        uint256 before = IERC20(quote).balanceOf(address(this));
        if (tokenIs0) IPairSwap(pair).swap(0, out, address(this), "");
        else IPairSwap(pair).swap(out, 0, address(this), "");
        quoteOut = IERC20(quote).balanceOf(address(this)) - before;
        // audit 4 B-Info: re-check what arrived (a fee-on-transfer quote pays less than `out`)
        if (quoteOut < minQuoteOut) revert Slippage();
    }

    /// @dev Pancake V2 getAmountOut (0 for an empty side).
    function _amountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint256) {
        if (reserveIn == 0 || reserveOut == 0) return 0;
        uint256 inWithFee = amountIn * DEX_FEE_NUM;
        return (inWithFee * reserveOut) / (reserveIn * DEX_FEE_DEN + inWithFee);
    }
}
