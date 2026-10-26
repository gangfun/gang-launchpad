// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SharedDividendVault} from "./SharedDividendVault.sol";
import {SharedPlatformFeeBucket as PlatformFeeBucket} from "./SharedPlatformFeeBucket.sol";
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
///         - `_swapBack`: a taxed sell into the pair asks for a chunk first (straight into the pair), never more than
///           SWAP_BACK_SELL_BPS (25%) of that sell, so it adds at most about half the seller's own price impact.
///         - `_process`: the keeper sells a chunk when no sells come (mandatory off-chain minQuoteOut, V2 H1),
///           through the Pancake router or straight into the pair.
///         Both draw on one budget per token per block (internal audit 5, B-F1 / B-F4 / C-F6): at most CHUNK_MAX_BPS
///         of the token's reserve as it stood at the block's first chunk attempt, counted by tokens sold — so neither
///         a dust sell nor a keeper looping `process` with a 1-wei floor can sell more than one chunk's worth a block.
///         Every chunk also refuses to sell more than MAX_PRICE_DROP_BPS below that same block-start reference: a
///         sell (or a keeper) can't first dump the price and then convert the holders' tax at it. Unsynced pair
///         balances only skip the chunk when they look like a half-made LP add (not a 1-wei donation), and a skip
///         spends the block's budget. `previewSell` / `previewSellNextBlock` quote a sell with its chunk included.
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
    /// @notice Delay between proposing and accepting a new DEX router (flow review F4b: a router swap plus a keeper
    ///         `process` with a 1-wei floor would otherwise hand the whole chunk to the owner's router at once).
    uint256 public constant DEX_ROUTER_DELAY = 48 hours;
    /// @notice Same delay for a new keeper (internal audit 5, C-F6); the first keeper is set at deploy.
    uint256 public constant KEEPER_DELAY = 48 hours;
    /// @notice A chunk never sells at a price more than this below the block's reference price (bps).
    uint256 public constant MAX_PRICE_DROP_BPS = 200;

    SharedDividendVault public immutable dividendVault;

    /// @notice Router `process` sells through; 0 = sell straight into the token's pair.
    IPancakeRouter02 public dexRouter;
    /// @notice A proposed router (0 = direct pair) and when it can be accepted; `dexRouterEta == 0` = no proposal.
    address public pendingDexRouter;
    uint256 public dexRouterEta;
    address public keeper;
    address public pendingKeeper;
    uint256 public keeperEta;
    /// @notice Tax tokens of each token held here and not sold yet (the holders' part included).
    mapping(address => uint256) public accruedTax;

    /// @dev A token's chunk budget for one block: tax tokens sold in `blockNumber` so far, against the reserves the
    ///      pair had at the block's first chunk attempt (`refT` / `refQ`: the reference price and the budget base).
    struct Window {
        uint64 blockNumber;
        uint96 used;
    }

    struct Ref {
        uint112 refT;
        uint112 refQ;
    }

    mapping(address token => Window) public windowOf;
    mapping(address token => Ref) public refOf;
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
    error NoProposal();
    error TooEarly();
    error KeeperAlreadySet();
    error PriceBelowReference();

    event DexRouterSet(address indexed router);
    event DexRouterProposed(address indexed router, uint256 eta);
    event DexRouterCancelled(address indexed router);
    event KeeperSet(address indexed keeper);
    event KeeperProposed(address indexed keeper, uint256 eta);
    event KeeperCancelled(address indexed keeper);
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

    /// @param dexRouter_ Router set at deploy (0 = sell straight into the pair); later changes go through the delay.
    constructor(address owner_, address dividendVault_, address dexRouter_) Ownable(owner_) {
        if (dividendVault_ == address(0)) revert ZeroAddress();
        dividendVault = SharedDividendVault(dividendVault_);
        dexRouter = IPancakeRouter02(dexRouter_);
        emit DexRouterSet(dexRouter_);
    }

    /// @notice Step 1 of a router change: `router_` (0 = sell straight into the pair) takes effect after DEX_ROUTER_DELAY.
    function proposeDexRouter(address router_) external onlyOwner {
        pendingDexRouter = router_;
        dexRouterEta = block.timestamp + DEX_ROUTER_DELAY;
        emit DexRouterProposed(router_, dexRouterEta);
    }

    /// @notice Step 2: apply the proposed router once its delay has passed.
    function acceptDexRouter() external onlyOwner {
        uint256 eta = dexRouterEta;
        if (eta == 0) revert NoProposal();
        if (block.timestamp < eta) revert TooEarly();
        address router_ = pendingDexRouter;
        dexRouter = IPancakeRouter02(router_);
        delete pendingDexRouter;
        delete dexRouterEta;
        emit DexRouterSet(router_);
    }

    function cancelDexRouter() external onlyOwner {
        if (dexRouterEta == 0) revert NoProposal();
        emit DexRouterCancelled(pendingDexRouter);
        delete pendingDexRouter;
        delete dexRouterEta;
    }

    /// @notice The first keeper (deploy). Later changes go through `proposeKeeper` → KEEPER_DELAY → `acceptKeeper`
    ///         (C-F6): an instant swap to a new key plus `process` would skip the router delay's warning period.
    function setKeeper(address keeper_) external onlyOwner {
        if (keeper != address(0)) revert KeeperAlreadySet();
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    function proposeKeeper(address keeper_) external onlyOwner {
        pendingKeeper = keeper_;
        keeperEta = block.timestamp + KEEPER_DELAY;
        emit KeeperProposed(keeper_, keeperEta);
    }

    function acceptKeeper() external onlyOwner {
        uint256 eta = keeperEta;
        if (eta == 0) revert NoProposal();
        if (block.timestamp < eta) revert TooEarly();
        keeper = pendingKeeper;
        delete pendingKeeper;
        delete keeperEta;
        emit KeeperSet(keeper);
    }

    function cancelKeeper() external onlyOwner {
        if (keeperEta == 0) revert NoProposal();
        emit KeeperCancelled(pendingKeeper);
        delete pendingKeeper;
        delete keeperEta;
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

    /// @notice Largest chunk of `token`'s tax that can be sold now: ≤ accrued, ≤ held, ≤ what is left of this block's
    ///         budget (CHUNK_MAX_BPS of the token's reserve at the block's first chunk attempt; the current reserve if
    ///         none ran yet). 0 before the pair exists.
    function maxChunk(address token) public view returns (uint256 amount) {
        amount = accruedTax[token];
        if (amount == 0) return 0;
        uint256 bal = _sellable(token);
        if (amount > bal) amount = bal;
        address pair = IHasPair(token).pair();
        if (pair == address(0)) return 0;
        (uint256 rT,) = _reserves(pair, token);
        uint256 left = _budgetLeft(token, rT, false);
        if (amount > left) amount = left;
    }

    /// @dev Keeper/owner only: sells `amount`, cut to `maxChunk` (only ever less than asked, so a minQuoteOut quoted for
    ///      `amount` can only make it revert), with a mandatory off-chain minQuoteOut, inside this block's budget and
    ///      never below the block's reference price by more than MAX_PRICE_DROP_BPS. Subclasses expose it as `process`
    ///      (nonReentrant).
    function _process(address token, uint256 amount, uint256 minQuoteOut) internal returns (uint256 quoteOut) {
        if (msg.sender != keeper && msg.sender != owner()) revert OnlyKeeperOrOwner();
        if (minQuoteOut == 0) revert ZeroAmount();
        // the pair must be the token's own against its quote before anything is sized from its reserves
        address pair = IHasPair(token).pair();
        if (pair == address(0)) revert NoPair();
        _tokenIs0(pair, token, _quoteOf(token));
        (uint256 rT, uint256 rQ) = _reserves(pair, token);
        Ref memory ref = _openWindow(token, rT, rQ);
        if (_belowRef(rT, rQ, ref)) revert PriceBelowReference();
        uint256 max = maxChunk(token);
        if (amount > max) amount = max;
        if (amount == 0) revert ZeroAmount();
        windowOf[token].used += uint96(amount);
        return _sellChunk(token, amount, minQuoteOut, false);
    }

    /// @dev The token is selling `sellAmount` into its pair (the seller's tokens not moved yet, pair unlocked): sell
    ///      a chunk straight into the pair. Callers wrap this so it can never fail the trade.
    function _swapBack(address token, uint256 sellAmount) internal returns (uint256 quoteOut) {
        if (msg.sender != token) revert OnlyToken();
        address pair = IHasPair(token).pair();
        (uint256 rT, uint256 rQ) = _reserves(pair, token);
        _openWindow(token, rT, rQ);
        (uint256 amount, uint256 out, bool spend) = _swapBackChunk(token, sellAmount, false);
        // a skip for unsynced balances spends the block's budget: nothing can be dumped first and converted after
        if (spend) windowOf[token].used = type(uint96).max;
        if (amount == 0 || out == 0) return 0;
        windowOf[token].used += uint96(amount);
        return _sellChunk(token, amount, (out * (10_000 - SWAP_BACK_SLIPPAGE_BPS)) / 10_000, true);
    }

    /// @dev The chunk a sell of `sellAmount` would trigger and what it fetches (`fresh`: as the first chunk attempt of
    ///      a new block). None when the sell pays no tax, the budget is spent, the price is below the block's
    ///      reference, or the pair holds unsynced balances that look like a half-made LP add (`spend` then: the
    ///      caller spends the block's budget). A 1-wei donation is not that: it is simply absorbed.
    function _swapBackChunk(address token, uint256 sellAmount, bool fresh)
        internal
        view
        returns (uint256 amount, uint256 out, bool spend)
    {
        if ((sellAmount * _sellTaxBps(token)) / 10_000 == 0) return (0, 0, false);
        address pair = IHasPair(token).pair();
        (uint256 rT, uint256 rQ) = _reserves(pair, token);
        Ref memory ref = fresh || windowOf[token].blockNumber != block.number
            ? Ref(uint112(rT), uint112(rQ))
            : refOf[token];
        if (_belowRef(rT, rQ, ref)) return (0, 0, false);
        // someone mid-way adding liquidity (one side sent, not minted yet): a swap now would absorb it. Only an
        // excess worth at least half the sell counts (B-F2: a 1-wei donation must not skip the chunk for free).
        uint256 bT = IERC20(token).balanceOf(pair);
        uint256 bQ = IERC20(_quoteOf(token)).balanceOf(pair);
        // a balance below its reserve: mid-swap (a flash-swap callback) — never sell into that
        if (bT < rT || bQ < rQ) return (0, 0, true);
        (uint256 exT, uint256 exQ) = (bT - rT, bQ - rQ);
        if ((exT > 0 || exQ > 0) && (exT * 2 >= sellAmount || exQ * rT * 2 >= sellAmount * rQ)) return (0, 0, true);
        amount = accruedTax[token];
        uint256 bal = _sellable(token);
        if (amount > bal) amount = bal;
        uint256 left = _budgetLeft(token, rT, fresh);
        if (amount > left) amount = left;
        uint256 bySell = (sellAmount * SWAP_BACK_SELL_BPS) / 10_000;
        if (amount > bySell) amount = bySell;
        if (amount == 0) return (0, 0, false);
        out = _amountOut(amount, rT, rQ);
    }

    /// @notice What selling `amountIn` into the pool pays out in this block, the swap-back chunk it triggers included
    ///         (`chunk` = tax tokens sold right before it). A wallet's transaction usually lands in a later block,
    ///         where the chunk may run although this block's was spent: frontends should use `previewSellNextBlock`.
    function previewSell(address token, uint256 amountIn) external view returns (uint256 quoteOut, uint256 chunk) {
        return _previewSell(token, amountIn, false);
    }

    /// @notice `previewSell` as the first sell of a new block (a fresh chunk budget at today's reserves): what a
    ///         sell sent now most likely gets. Use this for a seller's amountOutMin (internal audit 5, B-F3).
    function previewSellNextBlock(address token, uint256 amountIn)
        external
        view
        returns (uint256 quoteOut, uint256 chunk)
    {
        return _previewSell(token, amountIn, true);
    }

    function _previewSell(address token, uint256 amountIn, bool fresh)
        internal
        view
        returns (uint256 quoteOut, uint256 chunk)
    {
        address pair = IHasPair(token).pair();
        if (pair == address(0)) return (0, 0);
        (uint256 rT, uint256 rQ) = _reserves(pair, token);
        uint256 chunkOut;
        (chunk, chunkOut,) = _swapBackChunk(token, amountIn, fresh);
        uint256 net = amountIn - (amountIn * _sellTaxBps(token)) / 10_000;
        quoteOut = _amountOut(net, rT + chunk, rQ - chunkOut);
    }

    /// @dev `pair`'s reserves as (token side, quote side).
    function _reserves(address pair, address token) internal view returns (uint256 rT, uint256 rQ) {
        (uint112 r0, uint112 r1,) = IUniswapV2PairLite(pair).getReserves();
        (rT, rQ) = IUniswapV2PairLite(pair).token0() == token ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }

    /// @dev The block's first chunk attempt records the reserves as the reference and opens a fresh budget.
    function _openWindow(address token, uint256 rT, uint256 rQ) internal returns (Ref memory ref) {
        if (windowOf[token].blockNumber == block.number) return refOf[token];
        windowOf[token] = Window({blockNumber: uint64(block.number), used: 0});
        ref = Ref({refT: uint112(rT), refQ: uint112(rQ)});
        refOf[token] = ref;
    }

    /// @dev Tokens left in the block's budget (`fresh` / no attempt yet this block: the whole budget at `rT`).
    function _budgetLeft(address token, uint256 rT, bool fresh) internal view returns (uint256) {
        Window memory w = windowOf[token];
        if (fresh || w.blockNumber != block.number) return (rT * CHUNK_MAX_BPS) / 10_000;
        uint256 cap = (uint256(refOf[token].refT) * CHUNK_MAX_BPS) / 10_000;
        return w.used >= cap ? 0 : cap - w.used;
    }

    /// @dev Whether the price now (quote per token) is more than MAX_PRICE_DROP_BPS below the reference.
    function _belowRef(uint256 rT, uint256 rQ, Ref memory ref) internal pure returns (bool) {
        if (ref.refT == 0 || rT == 0) return false;
        return rQ * uint256(ref.refT) * 10_000 < uint256(ref.refQ) * rT * (10_000 - MAX_PRICE_DROP_BPS);
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
