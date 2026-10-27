// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {QuoteRegistry} from "../../../src/launchpad-v2/QuoteRegistry.sol";
import {SharedPlatformFeeBucket as PlatformFeeBucket} from "../../../src/common/SharedPlatformFeeBucket.sol";
import {SharedDividendVault} from "../../../src/common/SharedDividendVault.sol";
import {SharedMigrator} from "../../../src/common/SharedMigrator.sol";
import {TokenDeployer} from "../../../src/common/TokenDeployer.sol";
import {LaunchpadV3} from "../../../src/launchpad-v3/LaunchpadV3.sol";
import {TaxHandlerV3} from "../../../src/launchpad-v3/TaxHandlerV3.sol";
import {PostGradHandlerBase} from "../../../src/common/PostGradHandlerBase.sol";
import {GangToken} from "../../../src/gang/GangToken.sol";
import {ILaunchpadV3} from "../../../src/launchpad-v3/interfaces/ILaunchpadV3.sol";

interface IRouterA {
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory);
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);
}

interface IPairA {
    function getReserves() external view returns (uint112, uint112, uint32);
    function token0() external view returns (address);
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
}

contract Agent5b {
    mapping(address => uint256) public balanceOf;

    function set(address a, uint256 b) external {
        balanceOf[a] = b;
    }
}

/// @dev A seller's contract: donates 1 wei of quote to the pair, then sells through the router in the same tx.
contract SkipSeller {
    function sell(address router, address token, address quote, address pair, uint256 amount)
        external
        returns (uint256)
    {
        IERC20(quote).transfer(pair, 1);
        IERC20(token).approve(router, amount);
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = quote;
        uint256 b = IERC20(quote).balanceOf(address(this));
        IRouterA(router)
            .swapExactTokensForTokensSupportingFeeOnTransferTokens(amount, 0, path, address(this), block.timestamp);
        return IERC20(quote).balanceOf(address(this)) - b;
    }
}

/// @notice Internal audit 5 B (swap-back, MEV, gas, keeper) — the PoCs turned into regressions on a BSC fork with the
///         real Pancake V2 router (BSC_RPC_URL, e.g. https://rpc-bsc.48.club).
contract SwapBackAudit5bTest is Test {
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant V2_FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address constant V2_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    uint16 constant SELL_TAX = 300;

    address owner = makeAddr("owner");
    address keeper = makeAddr("keeper");
    address treasury = makeAddr("treasury");
    address dev = makeAddr("dev");

    SharedDividendVault vault;
    TaxHandlerV3 handler;
    LaunchpadV3 pad;
    Agent5b agent;
    PlatformFeeBucket bucket;
    address t;
    address pair;

    modifier forkOnly() {
        if (address(pad) == address(0)) return;
        _;
    }

    function setUp() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        vm.startPrank(owner);
        QuoteRegistry reg = new QuoteRegistry(owner);
        vault = new SharedDividendVault(owner);
        SharedMigrator mig = new SharedMigrator(owner, V2_FACTORY);
        TokenDeployer deployer = new TokenDeployer(owner);
        bucket = new PlatformFeeBucket(owner, owner);
        handler = new TaxHandlerV3(owner, address(vault), address(bucket), V2_ROUTER);
        pad = new LaunchpadV3(
            owner, address(reg), address(vault), address(bucket), address(handler), address(deployer), WBNB, V2_FACTORY
        );
        agent = new Agent5b();
        vault.setLaunchpad(address(pad), true);
        vault.setMinimumShareBalance(address(pad), 10_000 ether);
        vault.setOperator(address(handler), address(pad));
        mig.addLaunchpad(address(pad));
        deployer.setLaunchpad(address(pad), true);
        bucket.setOperator(address(pad), true);
        bucket.setOperator(address(handler), true);
        handler.setLaunchpad(address(pad));
        handler.setKeeper(keeper);
        handler.list(treasury, "treasury");
        pad.setMigrator(address(mig));
        pad.setAgentGate(true, address(agent));
        vm.stopPrank();
        agent.set(dev, 1);

        vm.prank(dev);
        t = pad.create(
            "A5",
            "A5",
            "",
            "",
            WBNB,
            address(0),
            ILaunchpadV3.TaxConfig({buyTaxBps: 300, sellTaxBps: SELL_TAX, dividendBps: 5000, recipient: treasury})
        );
        for (uint256 i = 0; i < 400 && GangToken(t).pair() == address(0); i++) {
            address w = address(uint160(0xA11CE000 + i));
            agent.set(w, 1);
            deal(WBNB, w, 1 ether);
            vm.startPrank(w);
            IERC20(WBNB).approve(address(pad), 1 ether);
            pad.buy(t, 1 ether, 0);
            vm.stopPrank();
        }
        pair = GangToken(t).pair();
        require(pair != address(0), "not graduated");
        // backlog: buys only (no chunk on buys)
        for (uint256 i = 0; i < 10; i++) {
            address b = address(uint160(0xB0B0000 + i));
            deal(WBNB, b, 3 ether);
            _swap(b, WBNB, t, 3 ether);
        }
        vm.roll(vm.getBlockNumber() + 1);
    }

    function _swap(address who, address tokenIn, address tokenOut, uint256 amountIn) internal returns (uint256 got) {
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
        vm.startPrank(who);
        IERC20(tokenIn).approve(V2_ROUTER, amountIn);
        uint256 before = IERC20(tokenOut).balanceOf(who);
        IRouterA(V2_ROUTER)
            .swapExactTokensForTokensSupportingFeeOnTransferTokens(amountIn, 0, path, who, block.timestamp);
        got = IERC20(tokenOut).balanceOf(who) - before;
        vm.stopPrank();
    }

    function _reserves() internal view returns (uint256 rT, uint256 rQ) {
        (uint112 r0, uint112 r1,) = IPairA(pair).getReserves();
        (rT, rQ) = IPairA(pair).token0() == t ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }

    function _windowUsed() internal view returns (uint256 used, bool thisBlock) {
        (uint64 b, uint96 u) = handler.windowOf(t);
        return (u, b == vm.getBlockNumber());
    }

    function _holder(uint256 i) internal pure returns (address) {
        return address(uint160(0xA11CE000 + i));
    }

    // ------------------------------------------------------------------ F1 (regression): a dust sell no longer burns the block
    function test_F1_dustSellNoLongerBurnsTheBlock() public forkOnly {
        address griefer = _holder(5);
        address victim = _holder(6);
        uint256 amount = IERC20(t).balanceOf(victim) / 2;
        (, uint256 chunkExpected) = handler.previewSell(t, amount);
        assertGt(chunkExpected, 0, "victim's sell would sell a chunk");

        uint256 accBefore = handler.accruedTax(t);
        _swap(griefer, t, WBNB, 1e12); // first in the block
        uint256 dust = accBefore + (uint256(1e12) * SELL_TAX) / 10_000 - handler.accruedTax(t);
        (uint256 used,) = _windowUsed();
        assertEq(used, dust, "the dust sell only drew its own dust chunk");

        uint256 acc1 = handler.accruedTax(t);
        (, uint256 chunkNow) = handler.previewSell(t, amount);
        assertGt(chunkNow, 0, "the victim's sell still gets a chunk");
        _swap(victim, t, WBNB, amount);
        assertEq(handler.accruedTax(t), acc1 - chunkNow + (amount * SELL_TAX) / 10_000, "and it ran");
    }

    // ------------------------------------------------------------------ F2 (regression): 1 wei of quote no longer skips the chunk
    function test_F2_oneWeiQuoteDonationNoLongerSkipsChunk() public forkOnly {
        address seller = _holder(7);
        uint256 amount = IERC20(t).balanceOf(seller) / 2;
        (uint256 quoted, uint256 chunk) = handler.previewSell(t, amount);
        assertGt(chunk, 0);

        uint256 snap = vm.snapshotState();
        uint256 honest = _swap(seller, t, WBNB, amount);
        assertEq(honest, quoted);
        vm.revertToState(snap);

        SkipSeller sk = new SkipSeller();
        vm.prank(seller);
        IERC20(t).transfer(address(sk), amount); // wallet → contract, untaxed
        deal(WBNB, address(sk), 1);
        uint256 acc0 = handler.accruedTax(t);
        uint256 tokensIn = IERC20(t).balanceOf(address(sk));
        uint256 out = sk.sell(V2_ROUTER, t, WBNB, pair, tokensIn);
        assertLt(handler.accruedTax(t), acc0 + (tokensIn * SELL_TAX) / 10_000, "the chunk ran anyway");
        assertLe(out, honest + 1, "no gain from the donation");
    }

    // ------------------------------------------------------------------ F3 (regression): previewSellNextBlock for wallets
    function test_F3_previewSellNextBlockMatchesTheNextBlock() public forkOnly {
        _swap(_holder(8), t, WBNB, IERC20(t).balanceOf(_holder(8)) / 2); // this block's budget used by a chunk
        address seller = _holder(9);
        uint256 amount = IERC20(t).balanceOf(seller) / 2;
        (uint256 quoted, uint256 chunk) = handler.previewSellNextBlock(t, amount);
        assertGt(chunk, 0, "the next block's chunk is priced in");

        vm.roll(vm.getBlockNumber() + 1); // the tx lands in the next block
        address[] memory path = new address[](2);
        path[0] = t;
        path[1] = WBNB;
        vm.startPrank(seller);
        IERC20(t).approve(V2_ROUTER, amount);
        uint256 b = IERC20(WBNB).balanceOf(seller);
        IRouterA(V2_ROUTER)
            .swapExactTokensForTokensSupportingFeeOnTransferTokens(amount, quoted, path, seller, block.timestamp);
        vm.stopPrank();
        assertEq(IERC20(WBNB).balanceOf(seller) - b, quoted, "exactly the next-block preview");
    }

    // ------------------------------------------------------------------ gas sweep: no gas limit where the chunk is silently skipped / deferred
    function _sweep(bool viaRouter) internal returns (uint256 minOk) {
        address seller = _holder(10);
        uint256 amount = IERC20(t).balanceOf(seller) / 2;
        (, uint256 chunk) = handler.previewSell(t, amount);
        assertGt(chunk, 0);
        uint256 acc = handler.accruedTax(t);
        address[] memory path = new address[](2);
        path[0] = t;
        path[1] = WBNB;
        vm.prank(seller);
        IERC20(t).approve(V2_ROUTER, type(uint256).max);
        (address target, bytes memory data) = viaRouter
            ? (
                V2_ROUTER,
                abi.encodeCall(
                    IRouterA.swapExactTokensForTokensSupportingFeeOnTransferTokens,
                    (amount, 0, path, seller, block.timestamp)
                )
            )
            : (t, abi.encodeCall(IERC20.transfer, (pair, amount)));
        uint256 okNoChunk;
        uint256 okDeferred;
        for (uint256 gl = 100_000; gl <= 1_300_000; gl += 1_000) {
            uint256 snap = vm.snapshotState();
            vm.prank(seller);
            (bool ok,) = target.call{gas: gl}(data);
            if (ok) {
                if (minOk == 0) minOk = gl;
                bool ran = handler.accruedTax(t) == acc - chunk + (amount * SELL_TAX) / 10_000;
                if (!ran) okNoChunk++;
                if (handler.pendingHolderUnits(t) != 0 || handler.owedPlatformOf(WBNB) != 0 || handler.owedOf(t) != 0) {
                    okDeferred++;
                }
            }
            vm.revertToState(snap);
        }
        console.log(viaRouter ? "sweep router: min ok gas" : "sweep transfer: min ok gas", minOk);
        console.log("  ok without chunk / ok with deferral", okNoChunk, okDeferred);
        assertEq(okNoChunk, 0, "chunk silently skipped at some gas limit");
        assertEq(okDeferred, 0, "a sink starved at some gas limit");
    }

    function test_gasSweep_router() public forkOnly {
        _sweep(true);
    }

    function test_gasSweep_transfer() public forkOnly {
        _sweep(false);
    }

    // ------------------------------------------------------------------ typical gas
    function test_gas_typical() public forkOnly {
        address a = _holder(11);
        uint256 bn = block.number;
        // warm-up: one sell this block (cold slots warmed in a prior tx don't matter on-chain, but keep it fair)
        vm.roll(++bn);
        uint256 amt = IERC20(t).balanceOf(a) / 4;
        uint256 g0 = gasleft();
        _swap(a, t, WBNB, amt);
        console.log("gas: router sell WITH chunk", g0 - gasleft());
        g0 = gasleft();
        _swap(a, t, WBNB, amt);
        console.log("gas: router sell, chunk slot used (no chunk)", g0 - gasleft());
        vm.roll(++bn);
        uint256 accT = handler.accruedTax(t);
        g0 = gasleft();
        vm.prank(a);
        IERC20(t).transfer(pair, amt);
        console.log("gas: direct transfer to pair WITH chunk (warm)", g0 - gasleft());
        console.log("  tax tokens sold by the chunk", accT + (amt * SELL_TAX) / 10_000 - handler.accruedTax(t));
        deal(WBNB, a, 1 ether);
        g0 = gasleft();
        _swap(a, WBNB, t, 1 ether);
        console.log("gas: router buy", g0 - gasleft());
        vm.roll(++bn);
        g0 = gasleft();
        vm.prank(keeper);
        handler.process(t, type(uint256).max, 1);
        console.log("gas: keeper process (router)", g0 - gasleft());
    }

    // ------------------------------------------------------------------ I1 (regression): one block budget for the keeper too
    function test_I1_keeperCanSellOneBudgetPerBlock() public forkOnly {
        (uint256 rT,) = _reserves();
        uint256 acc0 = handler.accruedTax(t);
        vm.prank(keeper);
        handler.process(t, type(uint256).max, 1);
        uint256 sold = acc0 - handler.accruedTax(t);
        assertLe(sold, (rT * 50) / 10_000, "at most one chunk's worth");
        assertEq(handler.maxChunk(t), 0, "spent for this block");
        vm.prank(keeper);
        vm.expectRevert(PostGradHandlerBase.ZeroAmount.selector);
        handler.process(t, type(uint256).max, 1);
        vm.roll(vm.getBlockNumber() + 1);
        assertGt(handler.maxChunk(t), 0, "a fresh budget next block");
    }

    // ------------------------------------------------------------------ LP add (token first) triggers the chunk
    function test_I2_addLiquidityETHTriggersChunk() public forkOnly {
        address lp = _holder(12);
        uint256 amt = IERC20(t).balanceOf(lp) / 2;
        (uint256 rT, uint256 rQ) = _reserves();
        uint256 eth = (amt * rQ) / rT;
        vm.deal(lp, eth * 2);
        uint256 snap = vm.snapshotState();
        uint256 liqA = _addLp(lp, amt, eth);
        (uint256 usedA, bool thisBlock) = _windowUsed();
        bool chunked = thisBlock && usedA > 0;
        vm.revertToState(snap);
        // spend the block's budget (a skipped half-LP-add does) so the add runs without a chunk
        vm.prank(keeper);
        handler.process(t, type(uint256).max, 1);
        uint256 liqB = _addLp(lp, amt, eth);
        console.log("I2 chunk during add?", chunked);
        console.log("I2 LP minted with chunk / without (bps)", liqA, (liqA * 10_000) / liqB);
    }

    function _addLp(address lp, uint256 amt, uint256 eth) internal returns (uint256 liq) {
        vm.startPrank(lp);
        IERC20(t).approve(V2_ROUTER, amt);
        (,, liq) = IRouterA(V2_ROUTER).addLiquidityETH{value: eth}(t, amt, 0, 0, lp, block.timestamp);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ sandwich: force the chunk at a depressed price
    function test_I3_forcedChunkAtDepressedPriceUnprofitable() public forkOnly {
        address att = _holder(14);
        // attacker holds tokens from the curve; give it a lot more (pool-bought at fair cost would be worse for it)
        uint256 bal0 = IERC20(t).balanceOf(att);
        deal(WBNB, att, 1);
        // 1) skip-trick big sell (no chunk), 2) sell 4x chunk to trigger the full chunk at the low price, 3) buy back
        SkipSeller s = new SkipSeller();
        vm.prank(att);
        IERC20(t).transfer(address(s), bal0 / 2);
        deal(WBNB, address(s), 1);
        uint256 q = s.sell(V2_ROUTER, t, WBNB, pair, IERC20(t).balanceOf(address(s)));
        // the big sell's own chunk ran first at the honest price; the budget left for a "forced" chunk at the
        // depressed price is whatever remains of the block's (and it can't sell 2% below the reference anyway)
        uint256 c = handler.maxChunk(t);
        if (c > 0) q += _swap(att, t, WBNB, c * 4);
        deal(WBNB, att, q);
        uint256 back = _swap(att, WBNB, t, q);
        uint256 bal1 = IERC20(t).balanceOf(att);
        console.log("I3 attacker tokens before / after", bal0, bal1);
        assertLt(bal1, bal0, "round trip loses (taxes > forced-chunk gain)");
        back;
    }

    // ------------------------------------------------------------------ F4 (regression): no keeper dump to sandwich
    function test_F4_keeperDumpSandwichNoLongerPays() public forkOnly {
        for (uint256 i = 0; i < 20; i++) {
            address b = address(uint160(0xC0C0000 + i));
            deal(WBNB, b, 3 ether);
            _swap(b, WBNB, t, 3 ether);
        }
        vm.roll(vm.getBlockNumber() + 1);
        address mev = _holder(15);
        uint256 tok0 = IERC20(t).balanceOf(mev);
        uint256 q = _swap(mev, t, WBNB, tok0); // front-run: its own chunk runs at the fair price, the price drops
        // the keeper (or owner) tries to dump everything with a 1-wei floor in the same block
        uint256 acc = handler.accruedTax(t);
        uint256 n;
        for (; n < 200; n++) {
            vm.prank(keeper);
            (bool ok,) = address(handler).call(abi.encodeCall(TaxHandlerV3.process, (t, type(uint256).max, 1)));
            if (!ok) break;
        }
        assertEq(n, 0, "below the block's reference price / budget spent: the keeper sells nothing more");
        assertEq(handler.accruedTax(t), acc);
        uint256 tok1 = _swap(mev, WBNB, t, q); // back-run
        assertLt(tok1, tok0, "the round trip loses (taxes), nothing to sandwich");
    }
}
