// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SwapBackAudit5bTest, IPairA} from "../audit5b/SwapBackAudit5b.t.sol";
import {PostGradHandlerBase} from "../../../src/common/PostGradHandlerBase.sol";
import {TaxLaunchTokenV3} from "../../../src/launchpad-v3/TaxLaunchTokenV3.sol";

interface IRouterR {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);
    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);
}

interface IPairSwapR {
    function getReserves() external view returns (uint112, uint112, uint32);
    function token0() external view returns (address);
    function swap(uint256, uint256, address, bytes calldata) external;
}

/// @dev Review PoC: 1 wei of quote into the pair, then a 100-wei "sell" (plain transfer into the pair) — it used to
///      skip and spend the whole block's budget.
contract BlockSpenderR {
    function go(address token, address quote, address pair) external {
        IERC20(quote).transfer(pair, 1);
        IERC20(token).transfer(pair, 100);
    }
}

/// @dev Review PoC: spend the block with the trick above, then sell for real in the same tx.
contract DodgeSellerR {
    function sell(address router, address token, address quote, address pair, uint256 amount)
        external
        returns (uint256)
    {
        IERC20(quote).transfer(pair, 1);
        IERC20(token).transfer(pair, 100);
        IERC20(token).approve(router, amount);
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = quote;
        uint256 b = IERC20(quote).balanceOf(address(this));
        IRouterR(router)
            .swapExactTokensForTokensSupportingFeeOnTransferTokens(amount, 0, path, address(this), block.timestamp);
        return IERC20(quote).balanceOf(address(this)) - b;
    }
}

/// @dev Review PoC: sell as a flash swap — take the quote first, pay the tokens in from the callback (the pair's quote
///      below its reserve there). It used to skip the chunk for free.
contract FlashSellerR {
    address token;
    address pair;
    uint256 amount;

    function sell(address token_, address quote, address pair_, uint256 amount_, uint256 sellTaxBps)
        external
        returns (uint256 out)
    {
        (token, pair, amount) = (token_, pair_, amount_);
        (uint112 r0, uint112 r1,) = IPairSwapR(pair_).getReserves();
        bool t0 = IPairSwapR(pair_).token0() == token_;
        (uint256 rT, uint256 rQ) = t0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 net = amount_ - (amount_ * sellTaxBps) / 10_000;
        out = (net * 9975 * rQ) / (rT * 10_000 + net * 9975);
        uint256 b = IERC20(quote).balanceOf(address(this));
        if (t0) IPairSwapR(pair_).swap(0, out, address(this), hex"01");
        else IPairSwapR(pair_).swap(out, 0, address(this), hex"01");
        out = IERC20(quote).balanceOf(address(this)) - b;
    }

    function pancakeCall(address, uint256, uint256, bytes calldata) external {
        require(msg.sender == pair);
        IERC20(token).transfer(pair, amount);
    }
}

/// @notice Review of the audit 5 fixes (AUDIT-BRIEF §18), B-F2 on a BSC fork with the real Pancake V2 router and pair
///         (BSC_RPC_URL): the review's three PoCs as regressions, and the router paths a fix must not break —
///         an ordinary sell, multi-hop sells and buys, addLiquidity in both token orders, addLiquidityETH.
contract ReviewForkTest is SwapBackAudit5bTest {
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;

    function _tokensFor(uint256 i, uint256 div) internal view returns (address who, uint256 amount) {
        who = _holder(i);
        amount = IERC20(t).balanceOf(who) / div;
    }

    function _taxOn(uint256 amount) internal pure returns (uint256) {
        return (amount * SELL_TAX) / 10_000;
    }

    // ------------------------------------------------------------------ (a) flash-swap sell: refused
    function test_review_flashSwapSellRefused() public forkOnly {
        (address seller, uint256 amount) = _tokensFor(23, 2);
        (, uint256 chunk) = handler.previewSell(t, amount);
        assertGt(chunk, 0);
        FlashSellerR f = new FlashSellerR();
        vm.prank(seller);
        IERC20(t).transfer(address(f), amount);
        vm.expectRevert(TaxLaunchTokenV3.SellDuringFlashSwap.selector);
        f.sell(t, WBNB, pair, amount, SELL_TAX);
        // the same tokens sold the ordinary way: the chunk runs
        uint256 acc0 = handler.accruedTax(t);
        uint256 out = _swap(address(f), t, WBNB, amount);
        assertGt(out, 0);
        assertEq(handler.accruedTax(t), acc0 - chunk + _taxOn(amount), "ordinary sell: chunk ran");
    }

    /// A flash-swap sell is refused even when no chunk would run (nothing accrued): it can't be timed around.
    function test_review_flashSwapSellRefusedWithoutBacklog() public forkOnly {
        (address seller, uint256 amount) = _tokensFor(24, 4);
        vm.roll(vm.getBlockNumber() + 1);
        while (handler.maxChunk(t) > 0) {
            vm.prank(keeper);
            handler.process(t, type(uint256).max, 1);
            vm.roll(vm.getBlockNumber() + 1);
        }
        assertEq(handler.accruedTax(t), 0);
        FlashSellerR f = new FlashSellerR();
        vm.prank(seller);
        IERC20(t).transfer(address(f), amount);
        vm.expectRevert(TaxLaunchTokenV3.SellDuringFlashSwap.selector);
        f.sell(t, WBNB, pair, amount, SELL_TAX);
    }

    // ------------------------------------------------------------------ (b) the spend trick no longer works
    function test_review_spendTrickNoLongerSkipsTheChunk() public forkOnly {
        (address seller, uint256 amount) = _tokensFor(22, 2);
        (, uint256 chunk) = handler.previewSell(t, amount);
        assertGt(chunk, 0);
        uint256 snap = vm.snapshotState();
        uint256 honest = _swap(seller, t, WBNB, amount);
        vm.revertToState(snap);

        DodgeSellerR d = new DodgeSellerR();
        vm.prank(seller);
        IERC20(t).transfer(address(d), amount + 100);
        deal(WBNB, address(d), 1);
        uint256 acc0 = handler.accruedTax(t);
        uint256 out = d.sell(V2_ROUTER, t, WBNB, pair, amount);
        assertLt(handler.accruedTax(t), acc0 + 3 + _taxOn(amount), "the chunk ran");
        assertLe(out, honest + 1, "no gain from the trick");
        console.log("dodge: honest / out", honest, out);
    }

    // ------------------------------------------------------------------ (b)+(c) dust + 1 wei spends nothing
    function test_review_dustPlusOneWeiNoLongerSpendsTheBlock() public forkOnly {
        BlockSpenderR g = new BlockSpenderR();
        vm.prank(_holder(20));
        IERC20(t).transfer(address(g), 1000);
        deal(WBNB, address(g), 10);
        uint256 max0 = handler.maxChunk(t);
        assertGt(max0, 0);
        g.go(t, WBNB, pair);
        (uint256 used,) = _windowUsed();
        assertLe(used, 25, "at most the dust sell's own dust chunk");
        assertGt(handler.maxChunk(t), 0, "the block's budget is still there");

        // an honest big sell later in the same block gets its chunk
        (address seller, uint256 amount) = _tokensFor(21, 2);
        (, uint256 chunk) = handler.previewSell(t, amount);
        assertGt(chunk, 0);
        uint256 acc1 = handler.accruedTax(t);
        _swap(seller, t, WBNB, amount);
        assertEq(handler.accruedTax(t), acc1 - chunk + _taxOn(amount), "the honest sell's chunk ran");
    }

    /// The keeper can still sell after a dust + 1 wei in the same block.
    function test_review_keeperUnaffectedByDust() public forkOnly {
        BlockSpenderR g = new BlockSpenderR();
        vm.prank(_holder(20));
        IERC20(t).transfer(address(g), 1000);
        deal(WBNB, address(g), 10);
        g.go(t, WBNB, pair);
        uint256 acc0 = handler.accruedTax(t);
        vm.prank(keeper);
        handler.process(t, type(uint256).max, 1);
        assertLt(handler.accruedTax(t), acc0);
    }

    // ------------------------------------------------------------------ (c) the LP-add threshold is the pool's
    function test_review_quoteAtThresholdSkipsWithoutSpending() public forkOnly {
        (, uint256 rQ) = _reserves();
        uint256 need = (rQ * handler.LP_ADD_MIN_BPS() + 9_999) / 10_000;
        address donor = makeAddr("donor");
        deal(WBNB, donor, need);
        vm.prank(donor);
        IERC20(WBNB).transfer(pair, need);
        (address seller, uint256 amount) = _tokensFor(25, 2);
        uint256 acc0 = handler.accruedTax(t);
        _swap(seller, t, WBNB, amount);
        assertEq(handler.accruedTax(t), acc0 + _taxOn(amount), "skipped (looks like a half-made LP add)");
        (uint256 used, bool thisBlock) = _windowUsed();
        assertTrue(thisBlock);
        assertEq(used, 0, "and the block's budget is untouched");
    }

    function test_review_quoteJustBelowThresholdIsAbsorbed() public forkOnly {
        (, uint256 rQ) = _reserves();
        uint256 below = (rQ * handler.LP_ADD_MIN_BPS()) / 10_000 - 1;
        address donor = makeAddr("donor");
        deal(WBNB, donor, below);
        vm.prank(donor);
        IERC20(WBNB).transfer(pair, below);
        (address seller, uint256 amount) = _tokensFor(26, 2);
        (, uint256 chunk) = handler.previewSell(t, amount);
        assertGt(chunk, 0, "preview: the chunk runs");
        uint256 acc0 = handler.accruedTax(t);
        _swap(seller, t, WBNB, amount);
        assertEq(handler.accruedTax(t), acc0 - chunk + _taxOn(amount), "the chunk ran (the excess absorbed)");
    }

    // ------------------------------------------------------------------ router paths a fix must not break
    function test_review_routerSellUnchanged() public forkOnly {
        (address seller, uint256 amount) = _tokensFor(27, 2);
        (uint256 quoted, uint256 chunk) = handler.previewSell(t, amount);
        assertGt(chunk, 0);
        uint256 acc0 = handler.accruedTax(t);
        uint256 got = _swap(seller, t, WBNB, amount);
        assertEq(got, quoted, "exactly the preview");
        assertEq(handler.accruedTax(t), acc0 - chunk + _taxOn(amount));
    }

    function test_review_multiHopSellAndBuy() public forkOnly {
        (address seller, uint256 amount) = _tokensFor(28, 2);
        (, uint256 chunk) = handler.previewSell(t, amount);
        assertGt(chunk, 0);
        address[] memory path = new address[](3);
        (path[0], path[1], path[2]) = (t, WBNB, USDT);
        uint256 acc0 = handler.accruedTax(t);
        vm.startPrank(seller);
        IERC20(t).approve(V2_ROUTER, amount);
        IRouterR(V2_ROUTER)
            .swapExactTokensForTokensSupportingFeeOnTransferTokens(amount, 1, path, seller, block.timestamp);
        vm.stopPrank();
        uint256 usdt = IERC20(USDT).balanceOf(seller);
        assertGt(usdt, 0, "token > WBNB > USDT");
        assertEq(handler.accruedTax(t), acc0 - chunk + _taxOn(amount), "the chunk ran on the first hop");

        // and back: USDT → WBNB → token (a buy: no chunk, buy tax only)
        (path[0], path[1], path[2]) = (USDT, WBNB, t);
        uint256 tok0 = IERC20(t).balanceOf(seller);
        vm.startPrank(seller);
        IERC20(USDT).approve(V2_ROUTER, usdt);
        IRouterR(V2_ROUTER)
            .swapExactTokensForTokensSupportingFeeOnTransferTokens(usdt, 1, path, seller, block.timestamp);
        vm.stopPrank();
        assertGt(IERC20(t).balanceOf(seller), tok0, "USDT > WBNB > token");
    }

    /// Pancake addLiquidity sends tokenA, then tokenB, then mints.
    function _addLiquidity(address lp, bool tokenFirst, uint256 amt) internal returns (uint256 liq) {
        (, liq) = _addLiquidityUsed(lp, tokenFirst, amt);
    }

    /// @return used the tokens the router actually sent (it may round the optimal amount down)
    function _addLiquidityUsed(address lp, bool tokenFirst, uint256 amt) internal returns (uint256 used, uint256 liq) {
        (uint256 rT, uint256 rQ) = _reserves();
        uint256 q = (amt * rQ) / rT;
        deal(WBNB, lp, q);
        vm.startPrank(lp);
        IERC20(t).approve(V2_ROUTER, amt);
        IERC20(WBNB).approve(V2_ROUTER, q);
        if (tokenFirst) (used,, liq) = IRouterR(V2_ROUTER).addLiquidity(t, WBNB, amt, q, 0, 0, lp, block.timestamp);
        else (, used, liq) = IRouterR(V2_ROUTER).addLiquidity(WBNB, t, q, amt, 0, 0, lp, block.timestamp);
        vm.stopPrank();
    }

    /// Token first: no unsynced quote when the token's hook runs, so the chunk runs before the LP's tokens arrive;
    /// the mint still works (the LP gets the liquidity of the scarcer side at the post-chunk price).
    function test_review_addLiquidityTokenFirst() public forkOnly {
        (address lp, uint256 amt) = _tokensFor(30, 2);
        uint256 acc0 = handler.accruedTax(t);
        uint256 liq = _addLiquidity(lp, true, amt);
        assertGt(liq, 0);
        assertEq(IPairA(pair).balanceOf(lp), liq);
        assertLt(handler.accruedTax(t), acc0 + _taxOn(amt), "the chunk ran");
    }

    /// Quote first, an add of at least LP_ADD_MIN_BPS of the pool: the token's hook sees the unsynced quote, skips
    /// the chunk (budget untouched), and the mint gets both sides.
    function test_review_addLiquidityQuoteFirst() public forkOnly {
        (address lp, uint256 amt) = _tokensFor(31, 2);
        (uint256 rT,) = _reserves();
        assertGe(amt * 10_000, rT * handler.LP_ADD_MIN_BPS(), "the add is at least the threshold");
        uint256 acc0 = handler.accruedTax(t);
        (uint256 sent, uint256 liq) = _addLiquidityUsed(lp, false, amt);
        assertGt(liq, 0);
        assertEq(handler.accruedTax(t), acc0 + _taxOn(sent), "skipped: no chunk absorbed the LP's quote");
        (uint256 used,) = _windowUsed();
        assertEq(used, 0, "budget untouched");
        assertEq(IPairA(pair).balanceOf(lp), liq);
    }

    /// Known limit of the pool-relative threshold: a quote-first add below LP_ADD_MIN_BPS of the pool, while a chunk
    /// is due, has its quote absorbed by the chunk and the mint reverts (no loss; token-first or a later block works).
    function test_review_smallQuoteFirstAddReverts_tokenFirstWorks() public forkOnly {
        (uint256 rT,) = _reserves();
        uint256 amt = (rT * handler.LP_ADD_MIN_BPS()) / 10_000 / 2; // half the threshold
        address lp = _holder(32);
        assertGe(IERC20(t).balanceOf(lp), amt);
        assertGt(handler.maxChunk(t), 0, "a chunk is due");
        uint256 snap = vm.snapshotState();
        (uint256 rT_, uint256 rQ) = _reserves();
        uint256 q = (amt * rQ) / rT_;
        deal(WBNB, lp, q);
        vm.startPrank(lp);
        IERC20(t).approve(V2_ROUTER, amt);
        IERC20(WBNB).approve(V2_ROUTER, q);
        vm.expectRevert(bytes("Pancake: INSUFFICIENT_LIQUIDITY_MINTED"));
        IRouterR(V2_ROUTER).addLiquidity(WBNB, t, q, amt, 0, 0, lp, block.timestamp);
        vm.stopPrank();
        vm.revertToState(snap);
        assertGt(_addLiquidity(lp, true, amt), 0, "the same add, token first, works");
    }

    function test_review_addLiquidityETH() public forkOnly {
        (address lp, uint256 amt) = _tokensFor(33, 2);
        (uint256 rT, uint256 rQ) = _reserves();
        uint256 eth = (amt * rQ) / rT;
        vm.deal(lp, eth);
        uint256 acc0 = handler.accruedTax(t);
        vm.startPrank(lp);
        IERC20(t).approve(V2_ROUTER, amt);
        (,, uint256 liq) = IRouterR(V2_ROUTER).addLiquidityETH{value: eth}(t, amt, 0, 0, lp, block.timestamp);
        vm.stopPrank();
        assertGt(liq, 0);
        assertEq(IPairA(pair).balanceOf(lp), liq);
        assertLt(handler.accruedTax(t), acc0 + _taxOn(amt), "token goes first: the chunk ran");
    }
}
