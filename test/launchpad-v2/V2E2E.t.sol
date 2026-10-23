// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LaunchpadV2} from "../../src/launchpad-v2/LaunchpadV2.sol";
import {MigratorV2} from "../../src/launchpad-v2/MigratorV2.sol";
import {QuoteRegistry} from "../../src/launchpad-v2/QuoteRegistry.sol";
import {DividendVault} from "../../src/launchpad-v2/DividendVault.sol";
import {PlatformFeeBucket} from "../../src/launchpad-v2/PlatformFeeBucket.sol";
import {PostGradTaxHandler} from "../../src/launchpad-v2/PostGradTaxHandler.sol";
import {BuybackBurner} from "../../src/launchpad-v2/BuybackBurner.sol";
import {TaxLaunchToken} from "../../src/launchpad-v2/TaxLaunchToken.sol";
import {PoolCheck, IV3FactoryLite, IV3PoolLite} from "../../src/launchpad-v2/PoolCheck.sol";
import {TickMath} from "../../src/launchpad-v2/libraries/TickMath.sol";
import {IPancakeRouter02} from "../../src/launchpad-v2/interfaces/IPancake.sol";

contract MockAgent { mapping(address => uint256) public balanceOf; function set(address a, uint256 b) external { balanceOf[a] = b; } }
contract FakeV2Pair { address public token0; address public token1; constructor(address a, address b) { (token0, token1) = a < b ? (a, b) : (b, a); } function getReserves() external pure returns (uint112, uint112, uint32) { return (1e24, 1e24, 0); } }

interface ISmartRouter {
    struct ExactInputParams { bytes path; address recipient; uint256 amountIn; uint256 amountOutMinimum; }
    function exactInput(ExactInputParams calldata) external payable returns (uint256);
    function swapExactTokensForTokens(uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to) external payable returns (uint256);
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory);
}

/// BSC mainnet fork: LaunchpadV2 with dev-supplied reference pools (V3 NVDAB/USDT, V2 NVDAB/WBNB, V3 USDT/WBNB).
/// Skipped unless BSC_RPC_URL is set (same idea as test/fork/Migration.t.sol). Does not broadcast.
contract V2E2EForkTest is Test {
    address constant NVDAB = 0x02Fca66C1D1aFB4E2A7884261eB00F63598a7436;
    address constant NVDAB_USDT_V3 = 0x8FB4243b553aC29BA088aCf00B9B7dA24bD6690C; // 0.25%, deepest; also NVDAB whale
    address constant NVDAB_WBNB_V2 = 0x217e9ed14C797dF4597512D2245c00cA93e5a567;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant GANG = 0x0c6302401aa5325C2E36F170f52C00B1d220B405;
    address constant V2_FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address constant V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address constant V2_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant SMART_ROUTER = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 constant Q96 = 2 ** 96;

    address owner = makeAddr("owner"); address feeVault = makeAddr("feeVault"); address dev = makeAddr("dev"); address keeper = makeAddr("keeper");
    QuoteRegistry reg; DividendVault div; PlatformFeeBucket bucket; PostGradTaxHandler handler; BuybackBurner burner; LaunchpadV2 pad; MigratorV2 mig; MockAgent agent;
    address token; address pair; address trader = makeAddr("trader"); address bridge;

    /// @dev No-op when setUp did not fork, so `forge test` does not touch mainnet.
    modifier forkOnly() {
        if (address(pad) == address(0)) return;
        _;
    }

    function setUp() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);

        vm.startPrank(owner);
        reg = new QuoteRegistry(owner); div = new DividendVault(owner); bucket = new PlatformFeeBucket(owner, feeVault);
        handler = new PostGradTaxHandler(owner, address(div), address(bucket)); burner = new BuybackBurner(owner); agent = new MockAgent();
        pad = new LaunchpadV2(owner, address(reg), address(div), address(bucket), address(handler), WBNB, V2_FACTORY);
        mig = new MigratorV2(V2_FACTORY, address(pad));
        pad.setMigrator(address(mig)); pad.setAgentGate(true, address(agent)); agent.set(dev, 1);
        pad.setV3Factory(V3_FACTORY);
        bridge = IV3FactoryLite(V3_FACTORY).getPool(WBNB, USDT, 500); require(bridge != address(0), "no USDT/WBNB 0.05% pool");
        pad.setBridgePool(USDT, bridge);
        div.setLaunchpad(address(pad)); bucket.setLaunchpad(address(pad)); div.setOperator(address(handler), true); bucket.setOperator(address(handler), true);
        handler.setRouter(V2_ROUTER); handler.setKeeper(keeper);
        burner.setRouter(V2_ROUTER); burner.setWbnb(WBNB); burner.setGang(GANG); bucket.setBurner(address(burner)); bucket.setKeeper(keeper);
        vm.stopPrank();
    }

    function _give(address to, uint256 amt) internal { vm.prank(NVDAB_USDT_V3); IERC20(NVDAB).transfer(to, amt); }

    /// USDT per 1 unit of `tok` in Q96, read from a V3 pool whose other side is USDT (spot).
    function _usdtPerQ96(address pool, address tok) internal view returns (uint256) {
        (uint160 sqrtP,,,,,,) = IV3PoolLite(pool).slot0();
        uint256 p1per0 = Math.mulDiv(sqrtP, sqrtP, Q96);
        return IV3PoolLite(pool).token0() == tok ? p1per0 : Math.mulDiv(Q96, Q96, p1per0);
    }

    // ---------------------------------------------------------------- pricing sanity
    function test_tickMath_matchesLivePools() public view forkOnly {
        address[2] memory pools = [NVDAB_USDT_V3, bridge];
        for (uint256 i; i < 2; i++) {
            (uint160 sqrtP, int24 tick,,,,,) = IV3PoolLite(pools[i]).slot0();
            assertLe(TickMath.getSqrtRatioAtTick(tick), sqrtP, "lower bound");
            assertGt(TickMath.getSqrtRatioAtTick(tick + 1), sqrtP, "upper bound");
        }
    }

    function test_gradAmt_v3RefPool_matches15Bnb() public view forkOnly {
        uint256 g = pad.graduationAmountOf(NVDAB, NVDAB_USDT_V3);
        uint256 expected = Math.mulDiv(15e18, _usdtPerQ96(bridge, WBNB), _usdtPerQ96(NVDAB_USDT_V3, NVDAB));
        console.log("gradAmt NVDAB via V3 (e15)", g / 1e15, "expected from spot (e15)", expected / 1e15);
        assertApproxEqRel(g, expected, 0.1e18, "within 10% of spot (TWAP drift)"); // TWAP vs spot
    }

    function test_gradAmt_v2RefPool() public view forkOnly {
        uint256 g = pad.graduationAmountOf(NVDAB, NVDAB_WBNB_V2);
        console.log("gradAmt NVDAB via V2 NVDAB/WBNB (e15)", g / 1e15);
        assertGt(g, 0);
    }

    function test_gradAmt_usdtQuote_viaBridgeAsRef() public view forkOnly {
        uint256 g = pad.graduationAmountOf(USDT, bridge); // counter == WBNB, no bridge needed
        console.log("gradAmt USDT (e18)", g / 1e18);
        assertApproxEqRel(g, Math.mulDiv(15e18, _usdtPerQ96(bridge, WBNB), Q96), 0.1e18);
    }

    function test_fakePool_reverts() public forkOnly {
        FakeV2Pair fake = new FakeV2Pair(NVDAB, WBNB);
        vm.expectRevert(PoolCheck.PoolNotFactory.selector);
        pad.graduationAmountOf(NVDAB, address(fake));
    }

    function test_quoteNotInPool_reverts() public forkOnly {
        vm.expectRevert(PoolCheck.QuoteNotInPool.selector);
        pad.graduationAmountOf(GANG, NVDAB_USDT_V3);
    }

    function test_noRefPool_reverts() public forkOnly {
        vm.expectRevert(LaunchpadV2.RefPoolRequired.selector);
        pad.graduationAmountOf(NVDAB, address(0));
    }

    // ---------------------------------------------------------------- full flow with V3 reference pool
    function test_e2e_nvdab_taxed_v3ref() public forkOnly {
        vm.prank(dev);
        token = pad.create("Alpha", "ALPHA", "", true, NVDAB, NVDAB_USDT_V3);
        uint256 g = pad.gradAmtOf(token);
        assertEq(pad.virtualQuoteOf(token), g / 3, "vq = grad/3");
        assertEq(div.minimumShareBalance(), 10_000 ether, "min share >10k");
        console.log("locked gradAmt NVDAB (e15)", g / 1e15);

        uint256 n;
        for (uint256 i = 0; i < 300; i++) {
            if (pad.graduationRemaining(token) == 0) break;
            address b = address(uint160(0xB0000 + i)); agent.set(b, 1); _give(b, 1e18);
            vm.startPrank(b); IERC20(NVDAB).approve(address(pad), type(uint256).max); pad.buy(token, 1e18, 0); vm.stopPrank(); n++;
        }
        (, , , uint128 sold, , , bool graduated, , address pair_, ) = pad.curves(token); pair = pair_;
        console.log("buyers", n, "sold(M)", uint256(sold) / 1e24);
        assertTrue(graduated, "graduated");
        assertEq(IERC20(NVDAB).balanceOf(address(div)), 0, "V2: no bonding dividend");
        assertGt(bucket.accruedQuote(NVDAB), 0, "V2: bonding fee to bucket");
        assertApproxEqAbs(uint256(sold), 800_000_000 ether, 1e18, "sold ~800M");
        assertTrue(pair != address(0) && IERC20(pair).balanceOf(DEAD) > 0, "LP burned");
        assertEq(TaxLaunchToken(token).pair(), pair); assertEq(TaxLaunchToken(token).taxHandler(), address(handler));
        assertEq(div.shares(token, pair), 0, "pair no shares"); assertEq(div.shares(token, address(mig)), 0, "migrator no shares");
        console.log("pair NVDAB (e15)", IERC20(NVDAB).balanceOf(pair) / 1e15, "pair token (M)", IERC20(token).balanceOf(pair) / 1e24);
        _stageDex(); _stageProcess(); _stageBuyback(); _stageSmart();
    }

    function _stageDex() internal {
        _give(trader, 2e18);
        vm.startPrank(trader);
        IERC20(NVDAB).approve(V2_ROUTER, type(uint256).max); IERC20(token).approve(V2_ROUTER, type(uint256).max);
        address[] memory p = new address[](2); p[0] = NVDAB; p[1] = token;
        IPancakeRouter02(V2_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(1e18, 0, p, trader, block.timestamp);
        uint256 got = IERC20(token).balanceOf(trader); assertGt(got, 0, "dex buy");
        uint256 acc1 = handler.accruedTax(token); assertGt(acc1, 0, "tax accrued on buy");
        assertEq(div.shares(token, trader), got > 10_000 ether ? got : 0, "trader share synced");
        p[0] = token; p[1] = NVDAB;
        IPancakeRouter02(V2_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(got / 2, 0, p, trader, block.timestamp);
        vm.stopPrank();
        assertGt(handler.accruedTax(token), acc1, "tax accrued on sell");
    }

    function _stageProcess() internal {
        vm.expectRevert(); vm.prank(trader); handler.process(token, 1);
        uint256 vaultBefore = IERC20(NVDAB).balanceOf(address(div)); uint256 bucketBefore = bucket.accruedQuote(NVDAB);
        vm.prank(keeper); uint256 qOut = handler.process(token, 1);
        assertGt(qOut, 0); assertEq(IERC20(NVDAB).balanceOf(address(div)) - vaultBefore, qOut / 2, "50% to vault");
        assertEq(bucket.accruedQuote(NVDAB) - bucketBefore, qOut - qOut / 2, "50% to bucket");
        address holder = address(uint160(0xB0000)); uint256 pend = div.pending(token, holder);
        if (pend > 0) { vm.prank(holder); div.claim(token); }
    }

    function _stageBuyback() internal {
        uint256 deadBefore = IERC20(GANG).balanceOf(DEAD); uint256 vaultFeeBefore = IERC20(NVDAB).balanceOf(feeVault);
        uint256 total = bucket.accruedQuote(NVDAB);
        vm.prank(keeper); bucket.collectPlatform(NVDAB, 1);
        console.log("V2 buyback GANG burned (e18)", (IERC20(GANG).balanceOf(DEAD) - deadBefore) / 1e18);
        assertEq(IERC20(NVDAB).balanceOf(feeVault) - vaultFeeBefore, total - (total * 8000) / 10000, "20% to feeVault");
    }

    function _stageSmart() internal {
        address[] memory p = new address[](2);
        vm.startPrank(trader); p[0] = NVDAB; p[1] = token;
        IPancakeRouter02(V2_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(5e17, 0, p, trader, block.timestamp); vm.stopPrank();
        vm.prank(keeper); handler.process(token, 1);
        uint256 amt = (bucket.accruedQuote(NVDAB) * 8000) / 10000;
        bytes memory path = abi.encodePacked(NVDAB, uint24(2500), USDT, uint24(500), WBNB);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeWithSelector(ISmartRouter.exactInput.selector, ISmartRouter.ExactInputParams(path, address(2), amt, 0));
        address[] memory v2p = new address[](2); v2p[0] = WBNB; v2p[1] = GANG;
        calls[1] = abi.encodeWithSelector(ISmartRouter.swapExactTokensForTokens.selector, 0, 1, v2p, address(1));
        bytes memory swapData = abi.encodeWithSelector(ISmartRouter.multicall.selector, calls);
        uint256 deadBefore = IERC20(GANG).balanceOf(DEAD);
        vm.prank(keeper); bucket.collectPlatformSmart(NVDAB, 1, swapData);
        console.log("Smart buyback GANG burned (e18)", (IERC20(GANG).balanceOf(DEAD) - deadBefore) / 1e18);
    }
}
