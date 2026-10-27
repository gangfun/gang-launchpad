// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {QuoteRegistry} from "../../src/launchpad-v2/QuoteRegistry.sol";
import {PlatformFeeBucket} from "../../src/launchpad-v2/PlatformFeeBucket.sol";
import {IPancakeRouter02} from "../../src/launchpad-v2/interfaces/IPancake.sol";
import {SharedDividendVault} from "../../src/common/SharedDividendVault.sol";
import {SharedMigrator} from "../../src/common/SharedMigrator.sol";
import {TokenDeployer} from "../../src/common/TokenDeployer.sol";
import {GangLaunchpad as LaunchpadV3} from "../../src/gang/GangLaunchpad.sol";
import {GangTaxHandler as TaxHandlerV3} from "../../src/gang/GangTaxHandler.sol";
import {GangToken as TaxLaunchTokenV3} from "../../src/gang/GangToken.sol";
import {IGangLaunchpad as ILaunchpadV3} from "../../src/gang/interfaces/IGangLaunchpad.sol";

contract V3ForkAgent {
    mapping(address => uint256) public balanceOf;

    function set(address a, uint256 b) external {
        balanceOf[a] = b;
    }
}

interface IPairLite {
    function getReserves() external view returns (uint112, uint112, uint32);
    function token0() external view returns (address);
}

/// @notice V3 tax token on real PancakeSwap V2: the pool tax is sold in chunks before taxed sells (≤ 0.5% of the
///         token side, ≤ 25% of the sell, once per block), previewSell is exact, dust triggers nothing, and the chunk
///         runs at the gas a wallet's estimate would pick.
contract V3SwapBackForkTest is Test {
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
    V3ForkAgent agent;

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
        PlatformFeeBucket bucket = new PlatformFeeBucket(owner, owner);
        handler = new TaxHandlerV3(owner, address(vault), address(bucket), V2_ROUTER);
        pad = new LaunchpadV3(
            owner, address(reg), address(vault), address(bucket), address(handler), address(deployer), WBNB, V2_FACTORY
        );
        agent = new V3ForkAgent();
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
    }

    function _graduated(address t) internal view returns (bool g) {
        (,,,,,, g,,,,,) = pad.curves(t);
    }

    /// @dev WBNB, buy / sell tax 3%, half of the rest to holders; graduated by distinct agent wallets on the curve.
    function _launched() internal returns (address t, address pair) {
        vm.prank(dev);
        t = pad.create(
            "Fork V3",
            "FV3",
            "",
            "",
            WBNB,
            address(0),
            ILaunchpadV3.TaxConfig({buyTaxBps: 300, sellTaxBps: SELL_TAX, dividendBps: 5000, recipient: treasury})
        );
        for (uint256 i = 0; i < 400 && !_graduated(t); i++) {
            address w = address(uint160(0xA11CE000 + i));
            agent.set(w, 1);
            deal(WBNB, w, 1 ether);
            vm.startPrank(w);
            IERC20(WBNB).approve(address(pad), 1 ether);
            pad.buy(t, 1 ether, 0);
            vm.stopPrank();
        }
        assertTrue(_graduated(t), "graduated");
        pair = TaxLaunchTokenV3(t).pair();
    }

    function _swap(address who, address tokenIn, address tokenOut, uint256 amountIn) internal returns (uint256 got) {
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
        vm.startPrank(who);
        IERC20(tokenIn).approve(V2_ROUTER, amountIn);
        uint256 before = IERC20(tokenOut).balanceOf(who);
        IPancakeRouter02(V2_ROUTER)
            .swapExactTokensForTokensSupportingFeeOnTransferTokens(amountIn, 0, path, who, block.timestamp);
        got = IERC20(tokenOut).balanceOf(who) - before;
        vm.stopPrank();
    }

    function _reserves(address t, address pair) internal view returns (uint256 rT, uint256 rQ) {
        (uint112 r0, uint112 r1,) = IPairLite(pair).getReserves();
        (rT, rQ) = IPairLite(pair).token0() == t ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }

    /// @dev Pool buys only: no sell, so no swap-back; the buy tax piles up past one chunk.
    function _backlog(address t, uint256 n) internal {
        for (uint256 i = 0; i < n; i++) {
            address b = address(uint160(0xB0B0000 + i));
            deal(WBNB, b, 3 ether);
            _swap(b, WBNB, t, 3 ether);
        }
    }

    function test_fork_v3_swapBack_realPancake() public forkOnly {
        (address t, address pair) = _launched();
        _backlog(t, 10);
        uint256 accrued = handler.accruedTax(t);
        (uint256 rT0, uint256 rQ0) = _reserves(t, pair);
        uint256 cap = (rT0 * 50) / 10_000;
        assertGt(accrued, cap, "backlog past one chunk");

        // a holder sells with previewSell's amount as the floor: exact fill, one chunk sold first
        address seller = address(uint160(0xA11CE000));
        uint256 amount = IERC20(t).balanceOf(seller) / 2;
        address[] memory path = new address[](2);
        path[0] = t;
        path[1] = WBNB;
        uint256 naive = IPancakeRouter02(V2_ROUTER).getAmountsOut(amount, path)[1];
        (uint256 quoted, uint256 chunk) = handler.previewSell(t, amount);
        assertEq(chunk, amount / 4 < cap ? amount / 4 : cap, "<= 25% of the sell, <= 0.5% of the token side");
        vm.startPrank(seller);
        IERC20(t).approve(V2_ROUTER, amount);
        uint256 got0 = IERC20(WBNB).balanceOf(seller);
        uint256 g = gasleft();
        IPancakeRouter02(V2_ROUTER)
            .swapExactTokensForTokensSupportingFeeOnTransferTokens(amount, quoted, path, seller, block.timestamp);
        uint256 gasWithChunk = g - gasleft();
        vm.stopPrank();
        assertEq(IERC20(WBNB).balanceOf(seller) - got0, quoted, "previewSell is exact");
        assertEq(
            handler.accruedTax(t), accrued - chunk + (amount * SELL_TAX) / 10_000, "one chunk sold before the sell"
        );
        console.log("v3 sell: naive quote / previewSell (bps of naive)", naive, (quoted * 10_000) / naive);
        console.log("gas: router sell with a swap-back chunk", gasWithChunk);

        // one budget per block: the first sell's chunk took all of it, so a second sell in the same block sells none
        uint256 accrued1 = handler.accruedTax(t);
        uint256 amount2 = IERC20(t).balanceOf(seller) / 4;
        _swap(seller, t, WBNB, amount2);
        assertEq(handler.accruedTax(t), accrued1 + (amount2 * SELL_TAX) / 10_000, "no second chunk this block");

        // a 1-wei transfer to the pair (no tax on it) triggers nothing, next block included
        vm.roll(vm.getBlockNumber() + 1);
        uint256 accrued2 = handler.accruedTax(t);
        vm.prank(seller);
        IERC20(t).transfer(pair, 1);
        assertEq(handler.accruedTax(t), accrued2, "dust is untaxed: no chunk");

        // price impact of one chunk on its own stays about 1%
        (uint256 rTa, uint256 rQa) = _reserves(t, pair);
        vm.prank(t);
        handler.swapBack(t, type(uint128).max);
        (uint256 rTb, uint256 rQb) = _reserves(t, pair);
        // the 1 wei sent above sat unsynced in the pair: dust is absorbed by the chunk now (audit 5 B-F2)
        assertLe(rTb - rTa - 1, (rTa * 50) / 10_000, "<= 0.5% of the token side");
        assertGe(rQb * rTa * 1000, rQa * rTb * 989, "price moves <= ~1.1%");
        assertGt(rQ0, 0);
    }

    /// @dev A: at the least gas a taxed sell transfer succeeds with (what eth_estimateGas finds), the chunk ran.
    function test_fork_v3_swapBack_runsAtTheEstimatedGas() public forkOnly {
        (address t, address pair) = _launched();
        _backlog(t, 10);
        vm.roll(vm.getBlockNumber() + 1);
        address seller = address(uint160(0xA11CE001));
        uint256 amount = IERC20(t).balanceOf(seller) / 2;
        (, uint256 chunk) = handler.previewSell(t, amount);
        assertGt(chunk, 0);
        uint256 accrued = handler.accruedTax(t);
        bytes memory data = abi.encodeCall(IERC20.transfer, (pair, amount));
        uint256 lo = 30_000;
        uint256 hi = 5_000_000;
        while (lo < hi) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            vm.prank(seller);
            (bool ok,) = t.call{gas: mid}(data);
            vm.revertToState(snap);
            if (ok) hi = mid;
            else lo = mid + 1;
        }
        vm.prank(seller);
        (bool done,) = t.call{gas: lo}(data);
        assertTrue(done);
        assertEq(
            handler.accruedTax(t), accrued - chunk + (amount * SELL_TAX) / 10_000, "the chunk ran at the estimated gas"
        );
        console.log("estimated gas for a taxed sell transfer with a chunk", lo);
    }

    /// @dev The first chunk after graduation, everything cold: the handler's first approve of the router (allowance
    ///      0 → max), the recipient's and the vault's first WBNB (balance 0 → non-zero). The chunk must fit the token's
    ///      SWAP_BACK_GAS cap (600k): measured on a direct swapBack call with exactly the cap, then on a real router sell.
    function test_fork_v3_firstChunkAfterGraduation_coldFitsTheCap() public forkOnly {
        (address t, address pair) = _launched();
        _backlog(t, 10);
        assertEq(IERC20(t).allowance(address(handler), V2_ROUTER), 0, "no approve yet");
        assertEq(IERC20(WBNB).balanceOf(treasury), 0, "recipient never paid yet");
        uint256 cap = TaxLaunchTokenV3(t).SWAP_BACK_GAS();
        assertEq(cap, 600_000);
        vm.roll(vm.getBlockNumber() + 1);
        address seller = address(uint160(0xA11CE002));
        uint256 amount = IERC20(t).balanceOf(seller) / 2;
        (, uint256 chunk) = handler.previewSell(t, amount);
        assertGt(chunk, 0);
        uint256 accrued = handler.accruedTax(t);

        // 1) the swap-back alone, with exactly the cap and cold storage
        uint256 snap = vm.snapshotState();
        _coolAll(t, pair);
        vm.prank(t);
        uint256 g = gasleft();
        uint256 out = handler.swapBack{gas: cap}(t, amount);
        g -= gasleft();
        assertGt(out, 0, "the chunk sold within the cap");
        assertEq(handler.accruedTax(t), accrued - chunk, "exactly one chunk");
        assertGt(IERC20(WBNB).balanceOf(treasury), 0, "recipient's first payment in the chunk");
        console.log("gas: first swapBack after graduation, cold (cap 600000)", g);
        vm.revertToState(snap);

        // 2) a real router sell (the token's own gas-capped try): the chunk runs, it is not swallowed
        _coolAll(t, pair);
        address[] memory path = new address[](2);
        path[0] = t;
        path[1] = WBNB;
        vm.startPrank(seller);
        IERC20(t).approve(V2_ROUTER, amount);
        vm.recordLogs();
        g = gasleft();
        IPancakeRouter02(V2_ROUTER)
            .swapExactTokensForTokensSupportingFeeOnTransferTokens(amount, 0, path, seller, block.timestamp);
        g -= gasleft();
        vm.stopPrank();
        bytes32 failed = keccak256("SwapBackFailed()");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            assertTrue(logs[i].topics.length == 0 || logs[i].topics[0] != failed, "chunk not swallowed");
        }
        assertEq(
            handler.accruedTax(t), accrued - chunk + (amount * SELL_TAX) / 10_000, "first chunk ran in the router sell"
        );
        assertGt(IERC20(WBNB).balanceOf(treasury), 0, "recipient paid");
        console.log("gas: first router sell after graduation with its chunk, cold", g);
    }

    function _coolAll(address t, address pair) internal {
        address[9] memory c = [
            t,
            pair,
            address(handler),
            WBNB,
            address(vault),
            address(handler.platformBucket()),
            treasury,
            V2_ROUTER,
            address(pad)
        ];
        for (uint256 i; i < c.length; i++) {
            vm.cool(c[i]);
        }
    }
}
