// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SwapBackAudit5bTest, IPairA} from "../audit5b/SwapBackAudit5b.t.sol";
import {PostGradHandlerBase} from "../../../src/common/PostGradHandlerBase.sol";
import {GangToken as TaxLaunchTokenV3} from "../../../src/gang/GangToken.sol";

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

interface IPairSyncR {
    function sync() external;
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

/// @dev Review bypass R5-O1: donate quote, sell straight into the pair, take the donation back in the same swap (the
///      pair counts it as input). It used to skip the chunk for the price of 0.25% of the donation.
contract RecoverSellerR {
    function sell(address token, address quote, address pair, uint256 amount, uint256 d, uint256 taxBps)
        external
        returns (uint256 net)
    {
        IERC20(quote).transfer(pair, d);
        IERC20(token).transfer(pair, amount);
        (uint112 r0, uint112 r1,) = IPairSwapR(pair).getReserves();
        bool t0 = IPairSwapR(pair).token0() == token;
        (uint256 rT, uint256 rQ) = t0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        // what came in since the reserves (the chunk, if it ran, already moved them): the tokens (minus tax) and d
        uint256 netT = IERC20(token).balanceOf(pair) - rT;
        uint256 inQ = IERC20(quote).balanceOf(pair) - rQ;
        uint256 den = (rT + netT) * 10_000 - netT * 25;
        uint256 rhs = (rT * rQ * 1e4 + den - 1) / den;
        uint256 out = rQ + inQ - (inQ * 25 + 9_999) / 10_000 - rhs - 1;
        uint256 b = IERC20(quote).balanceOf(address(this));
        if (t0) IPairSwapR(pair).swap(0, out, address(this), "");
        else IPairSwapR(pair).swap(out, 0, address(this), "");
        net = IERC20(quote).balanceOf(address(this)) - b;
        taxBps;
    }
}

/// @notice Review of the audit 5 fixes (AUDIT-BRIEF §18), B-F2 on a BSC fork with the real Pancake V2 router and pair
///         (BSC_RPC_URL): the review's PoCs (and the recovered-donation bypass found after it) as regressions,
///         unsynced balances set aside around the chunk, and the router paths a fix must not break — an ordinary
///         sell, multi-hop sells and buys, addLiquidity in both token orders and addLiquidityETH at any size.
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

    // ------------------------------------------------------------------ unsynced balances: set aside, never skipped
    function _excess() internal view returns (uint256 exT, uint256 exQ) {
        (uint256 rT, uint256 rQ) = _reserves();
        exT = IERC20(t).balanceOf(pair) - rT;
        exQ = IERC20(WBNB).balanceOf(pair) - rQ;
    }

    /// Unsynced quote of any size (here 0.01% … 5% of the quote reserve) no longer skips the chunk: the chunk runs at
    /// the reserves and the quote is back in the pair, unsynced, afterwards.
    function test_review_unsyncedQuoteSetAsideAndReturned() public forkOnly {
        uint16[4] memory bps = [uint16(1), 10, 100, 500];
        (address seller, uint256 amount) = _tokensFor(25, 2);
        for (uint256 i; i < bps.length; i++) {
            uint256 snap = vm.snapshotState();
            (, uint256 rQ) = _reserves();
            uint256 d = (rQ * bps[i]) / 10_000;
            deal(WBNB, address(this), d);
            IERC20(WBNB).transfer(pair, d);
            (, uint256 chunk) = handler.previewSell(t, amount);
            assertGt(chunk, 0, "preview: the chunk runs");
            uint256 acc0 = handler.accruedTax(t);
            vm.prank(seller);
            IERC20(t).transfer(pair, amount); // a plain transfer: nothing swaps after the hook
            assertEq(handler.accruedTax(t), acc0 - chunk + _taxOn(amount), "the chunk ran");
            (uint256 exT, uint256 exQ) = _excess();
            assertEq(exQ, d, "the unsynced quote went back untouched");
            assertEq(exT, amount - _taxOn(amount), "only the seller's tokens on the token side");
            assertEq(IERC20(WBNB).balanceOf(address(handler)), 0, "no quote stayed in the handler");
            assertEq(IERC20(t).balanceOf(address(handler)), handler.accruedTax(t), "no tokens stayed in the handler");
            vm.revertToState(snap);
        }
    }

    /// Unsynced tokens (sent in, not swapped yet) go back too, and the handler never counts them as its own.
    function test_review_unsyncedTokensSetAsideAndReturned() public forkOnly {
        address a = _holder(26);
        uint256 first = 1000 ether; // small: its own chunk leaves most of the block's budget
        vm.prank(a);
        IERC20(t).transfer(pair, first);
        (uint256 exT0,) = _excess();
        assertEq(exT0, first - _taxOn(first));
        (address b, uint256 amount) = _tokensFor(29, 2);
        (, uint256 chunk) = handler.previewSell(t, amount);
        assertGt(chunk, 0);
        uint256 acc0 = handler.accruedTax(t);
        vm.prank(b);
        IERC20(t).transfer(pair, amount);
        assertEq(handler.accruedTax(t), acc0 - chunk + _taxOn(amount), "the chunk ran");
        (uint256 exT, uint256 exQ) = _excess();
        assertEq(exT, exT0 + amount - _taxOn(amount), "a's unsynced tokens went back");
        assertEq(exQ, 0);
        assertEq(IERC20(t).balanceOf(address(handler)), handler.accruedTax(t), "no tokens stayed in the handler");
    }

    /// The bypass found in the review (R5-O1): donate quote, sell straight into the pair, take the donation back in
    /// the same swap. With the skim the chunk runs anyway, so the seller gets no more than an honest router sell.
    function test_review_recoveredDonationNoLongerSkips() public forkOnly {
        address seller = _holder(40);
        uint256 amount = IERC20(t).balanceOf(seller) / 2;
        (, uint256 chunk) = handler.previewSell(t, amount);
        assertGt(chunk, 0);
        uint256 snap = vm.snapshotState();
        uint256 honest = _swap(seller, t, WBNB, amount);
        vm.revertToState(snap);
        (, uint256 rQ) = _reserves();
        uint256 d = (rQ * 10 + 9_999) / 10_000; // 0.1% of the quote reserve (the old skip threshold)
        RecoverSellerR r = new RecoverSellerR();
        vm.prank(seller);
        IERC20(t).transfer(address(r), amount);
        deal(WBNB, address(r), d);
        uint256 acc0 = handler.accruedTax(t);
        uint256 got = r.sell(t, WBNB, pair, amount, d, SELL_TAX);
        assertEq(handler.accruedTax(t), acc0 - chunk + _taxOn(amount), "the chunk ran");
        assertGe(got, d, "the donation came back");
        assertLe(got - d, honest, "no gain over an honest sell");
        console.log("recovered donation: honest / net", honest, got - d);
    }

    /// The chunk with balances set aside still runs inside the token's gas cap at every gas limit that succeeds.
    function test_review_gasSweep_unsyncedQuote() public forkOnly {
        (, uint256 rQ) = _reserves();
        deal(WBNB, address(this), rQ / 1000);
        IERC20(WBNB).transfer(pair, rQ / 1000);
        _sweep(false);
        _sweep(true);
    }

    /// Gas of a router sell with its chunk, storage cooled first (one test is one transaction: without `vm.cool`
    /// whatever the setup touched would look warm): pair synced, unsynced quote, unsynced quote and tokens.
    function _cooledSell(address a, uint256 amt) internal returns (uint256 g) {
        address[6] memory c = [pair, address(handler), t, WBNB, address(vault), address(bucket)];
        for (uint256 i; i < c.length; i++) {
            vm.cool(c[i]);
        }
        g = gasleft();
        _swap(a, t, WBNB, amt);
        g -= gasleft();
    }

    /// The same sell three ways, after the same small sell in the block before (so the vault's batches are in the
    /// same state): pair synced (`sync()`), unsynced quote (0.1% of the reserve), unsynced quote and tokens.
    function test_review_gas_unsynced() public forkOnly {
        address a = _holder(11);
        uint256 amt = IERC20(t).balanceOf(a) / 4;
        (, uint256 rQ) = _reserves();
        vm.prank(_holder(12));
        IERC20(t).transfer(pair, 1000 ether); // its own small chunk runs; its tokens stay unsynced
        uint256 snap = vm.snapshotState();
        for (uint256 k; k < 3; k++) {
            if (k < 2) IPairSyncR(pair).sync();
            if (k > 0) {
                deal(WBNB, address(this), rQ / 1000);
                IERC20(WBNB).transfer(pair, rQ / 1000);
            }
            vm.roll(vm.getBlockNumber() + 1);
            uint256 g = _cooledSell(a, amt);
            if (k == 0) console.log("gas: router sell WITH chunk, pair synced", g);
            if (k == 1) console.log("gas: router sell WITH chunk, unsynced quote set aside", g);
            if (k == 2) console.log("gas: router sell WITH chunk, unsynced quote + tokens set aside", g);
            vm.revertToState(snap);
        }
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

    // ------------------------------------------------------------------ LP adds: both orders, any size, and ETH
    struct LpCase {
        uint256 rT;
        uint256 rQ;
        uint256 ts;
        uint256 acc;
    }

    function _lpBefore() internal view returns (LpCase memory c) {
        (c.rT, c.rQ) = _reserves();
        c.ts = IPairA(pair).totalSupply();
        c.acc = handler.accruedTax(t);
    }

    /// What Pancake's mint gives for what arrived (`netT` tokens after the sell tax, `q` quote), worked back from the
    /// state after it: the reserves before the mint (after the chunk) and the supply after `_mintFee`.
    function _checkMint(uint256 liq, uint256 netT, uint256 q) internal view {
        (uint256 rT, uint256 rQ) = _reserves();
        uint256 ts = IPairA(pair).totalSupply() - liq;
        uint256 a = (netT * ts) / (rT - netT);
        uint256 b = (q * ts) / (rQ - q);
        assertEq(liq, a < b ? a : b, "Pancake's mint on both sides as sent: nothing absorbed");
    }

    /// Against the same add with no tax and no chunk (amt × supply / reserve): only the sell tax on the tokens sent in
    /// (3%) and the chunk sold first (≤ 0.5% of the token reserve, so ≤ 0.5% fewer LP units per token) separate them.
    function _checkVsUntaxed(LpCase memory c, uint256 liq, uint256 amt, string memory label) internal pure {
        uint256 untaxed = (amt * c.ts) / c.rT;
        uint256 floor = (untaxed * (10_000 - SELL_TAX) * (10_000 - 50)) / 1e8;
        assertGe(liq + 1, floor, "only the tax and the chunk");
        assertLe(liq, untaxed, "never more than untaxed");
        label;
    }

    function _lpAmounts() internal view returns (uint256[5] memory a) {
        (uint256 rT,) = _reserves();
        uint16[5] memory bps = [uint16(1), 5, 20, 100, 500]; // 0.01% … 5% of the token reserve
        for (uint256 i; i < 5; i++) {
            a[i] = (rT * bps[i]) / 10_000;
        }
    }

    /// Pancake addLiquidity sends tokenA, then tokenB, then mints. Quote first: the token's hook sees the quote unsynced,
    /// sets it aside around the chunk and gives it back, so the mint gets both sides (any size — the old small-add
    /// revert is gone). Token first: no unsynced quote yet, the chunk runs before the LP's tokens arrive.
    function _addLiquidityCase(bool tokenFirst, uint256 amt) internal {
        address lp = makeAddr("lp");
        deal(t, lp, amt);
        LpCase memory c = _lpBefore();
        uint256 q = (amt * c.rQ) / c.rT;
        deal(WBNB, lp, q);
        vm.startPrank(lp);
        IERC20(t).approve(V2_ROUTER, amt);
        IERC20(WBNB).approve(V2_ROUTER, q);
        uint256 sentT;
        uint256 sentQ;
        uint256 liq;
        if (tokenFirst) {
            (sentT, sentQ, liq) = IRouterR(V2_ROUTER).addLiquidity(t, WBNB, amt, q, 0, 0, lp, block.timestamp);
        } else {
            (sentQ, sentT, liq) = IRouterR(V2_ROUTER).addLiquidity(WBNB, t, q, amt, 0, 0, lp, block.timestamp);
        }
        vm.stopPrank();
        assertGt(liq, 0);
        assertEq(IPairA(pair).balanceOf(lp), liq);
        assertLt(handler.accruedTax(t), c.acc + _taxOn(sentT), "the chunk ran");
        _checkMint(liq, sentT - _taxOn(sentT), sentQ);
        _checkVsUntaxed(c, liq, sentT, "");
        console.log(
            tokenFirst
                ? "addLiquidity token first: amt / LP bps of untaxed"
                : "addLiquidity quote first: amt / LP bps of untaxed",
            amt,
            (liq * 10_000) / ((sentT * c.ts) / c.rT)
        );
    }

    function test_review_addLiquidityTokenFirst_anySize() public forkOnly {
        uint256[5] memory a = _lpAmounts();
        for (uint256 i; i < 5; i++) {
            uint256 snap = vm.snapshotState();
            _addLiquidityCase(true, a[i]);
            vm.revertToState(snap);
        }
    }

    function test_review_addLiquidityQuoteFirst_anySize() public forkOnly {
        uint256[5] memory a = _lpAmounts();
        for (uint256 i; i < 5; i++) {
            uint256 snap = vm.snapshotState();
            _addLiquidityCase(false, a[i]);
            vm.revertToState(snap);
        }
    }

    function test_review_addLiquidityETH_anySize() public forkOnly {
        uint256[5] memory a = _lpAmounts();
        address lp = makeAddr("lpEth");
        for (uint256 i; i < 5; i++) {
            uint256 snap = vm.snapshotState();
            deal(t, lp, a[i]);
            LpCase memory c = _lpBefore();
            uint256 eth = (a[i] * c.rQ) / c.rT;
            vm.deal(lp, eth);
            vm.startPrank(lp);
            IERC20(t).approve(V2_ROUTER, a[i]);
            (uint256 sentT, uint256 sentQ, uint256 liq) =
                IRouterR(V2_ROUTER).addLiquidityETH{value: eth}(t, a[i], 0, 0, lp, block.timestamp);
            vm.stopPrank();
            assertGt(liq, 0);
            assertLt(handler.accruedTax(t), c.acc + _taxOn(sentT), "token goes first: the chunk ran");
            _checkMint(liq, sentT - _taxOn(sentT), sentQ);
            _checkVsUntaxed(c, liq, sentT, "");
            console.log("addLiquidityETH: amt / LP bps of untaxed", a[i], (liq * 10_000) / ((sentT * c.ts) / c.rT));
            vm.revertToState(snap);
        }
    }
}
