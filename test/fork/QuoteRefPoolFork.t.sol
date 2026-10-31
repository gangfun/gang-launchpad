// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {QuoteRegistry} from "../../src/launchpad-v2/QuoteRegistry.sol";
import {DividendVault} from "../../src/launchpad-v2/DividendVault.sol";
import {PlatformFeeBucket} from "../../src/launchpad-v2/PlatformFeeBucket.sol";
import {LaunchpadV2} from "../../src/launchpad-v2/LaunchpadV2.sol";
import {PostGradTaxHandler} from "../../src/launchpad-v2/PostGradTaxHandler.sol";
import {IV3FactoryLite} from "../../src/launchpad-v2/PoolCheck.sol";
import {SharedDividendVault} from "../../src/common/SharedDividendVault.sol";
import {SharedMigrator} from "../../src/common/SharedMigrator.sol";
import {TokenDeployer} from "../../src/common/TokenDeployer.sol";
import {GangLaunchpad as LaunchpadV3} from "../../src/gang/GangLaunchpad.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {GangTaxHandler as TaxHandlerV3} from "../../src/gang/GangTaxHandler.sol";
import {IGangLaunchpad as ILaunchpadV3} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {GangLaunchpad as FairMintPad} from "../../src/gang/GangLaunchpad.sol";
import {GangTaxHandler as HolderRewardHandler} from "../../src/gang/GangTaxHandler.sol";

interface IV3PoolSlot0 {
    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint32, bool);
}

contract RefForkAgent {
    mapping(address => uint256) public balanceOf;

    function set(address a, uint256 b) external {
        balanceOf[a] = b;
    }
}

/// @notice BSC mainnet fork: V3 core and 打新 core price an unlisted stock token (NVDAB) from the creator's reference
///         pool exactly like LaunchpadV2 — Pancake V2 pair (reserves) and Pancake V3 pool (TWAP, bridged USDT → WBNB).
///         The reference is a LaunchpadV2 deployed here with the same factories / TWAP window / bridge.
///         Skipped unless BSC_RPC_URL is set. Does not broadcast.
contract QuoteRefPoolForkTest is Test {
    address constant NVDAB = 0x02Fca66C1D1aFB4E2A7884261eB00F63598a7436;
    address constant NVDAB_USDT_V3 = 0x8FB4243b553aC29BA088aCf00B9B7dA24bD6690C; // also an NVDAB whale
    address constant NVDAB_WBNB_V2 = 0x217e9ed14C797dF4597512D2245c00cA93e5a567;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    /// @dev Pancake V3 USDT/WBNB 0.01% (deepest): the refPool for a USDT quote now that mainnet sets no fixed rate
    address constant USDT_REF_POOL = 0x172fcD41E0913e95784454622d1c3724f546f849;
    address constant V2_FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address constant V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;

    address owner = makeAddr("owner");
    address dev = makeAddr("dev");
    RefForkAgent agent;
    LaunchpadV2 v2;
    LaunchpadV3 v3;
    FairMintPad fair;
    address bridge;

    modifier forkOnly() {
        if (address(v3) == address(0)) {
            vm.skip(true);
            return;
        }
        _;
    }

    function setUp() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        bridge = IV3FactoryLite(V3_FACTORY).getPool(WBNB, USDT, 500);
        require(bridge != address(0), "no USDT/WBNB 0.05% pool");

        vm.startPrank(owner);
        agent = new RefForkAgent();
        QuoteRegistry reg = new QuoteRegistry(owner);

        // LaunchpadV2: the pricing reference
        DividendVault v2Div = new DividendVault(owner);
        PlatformFeeBucket v2Bucket = new PlatformFeeBucket(owner, owner);
        v2 = new LaunchpadV2(
            owner,
            address(reg),
            address(v2Div),
            address(v2Bucket),
            address(new PostGradTaxHandler(owner, address(v2Div), address(v2Bucket))),
            WBNB,
            V2_FACTORY
        );
        v2.setV3Factory(V3_FACTORY);
        v2.setBridgePool(USDT, bridge);

        // one vault / migrator / deployer / bucket for both cores, as deployed
        SharedDividendVault div = new SharedDividendVault(owner);
        SharedMigrator mig = new SharedMigrator(owner, V2_FACTORY);
        TokenDeployer deployer = new TokenDeployer(owner);
        PlatformFeeBucket bucket = new PlatformFeeBucket(owner, owner);

        // V3 core
        TaxHandlerV3 handler = new TaxHandlerV3(owner, address(div), address(bucket), address(0));
        v3 = new LaunchpadV3(
            owner, address(reg), address(div), address(bucket), address(handler), address(deployer), WBNB, V2_FACTORY
        );
        div.setLaunchpad(address(v3), true);
        div.setMinimumShareBalance(address(v3), 10_000 ether);
        div.setOperator(address(handler), address(v3));
        mig.addLaunchpad(address(v3));
        deployer.setLaunchpad(address(v3), true);
        bucket.setOperator(address(v3), true);
        bucket.setOperator(address(handler), true);
        handler.setLaunchpad(address(v3));
        v3.setMigrator(address(mig));
        v3.setAgentGate(true, address(agent));
        v3.setV3Factory(V3_FACTORY);
        v3.setBridgePool(USDT, bridge);

        // 打新 core
        HolderRewardHandler fh = new HolderRewardHandler(owner, address(div), address(bucket), address(0));
        fair = new FairMintPad(
            owner, address(reg), address(div), address(bucket), address(fh), address(deployer), WBNB, V2_FACTORY
        );
        div.setLaunchpad(address(fair), true);
        div.setMinimumShareBalance(address(fair), 10_000 ether);
        div.setOperator(address(fh), address(fair));
        mig.addLaunchpad(address(fair));
        deployer.setLaunchpad(address(fair), true);
        bucket.setOperator(address(fair), true);
        bucket.setOperator(address(fh), true);
        fh.setLaunchpad(address(fair));
        fair.setMigrator(address(mig));
        fair.setAgentGate(true, address(agent));
        fair.setV3Factory(V3_FACTORY);
        fair.setBridgePool(USDT, bridge);
        vm.stopPrank();

        agent.set(dev, 1);
    }

    function _untaxed() internal pure returns (ILaunchpadV3.TaxConfig memory) {
        return ILaunchpadV3.TaxConfig({buyTaxBps: 0, sellTaxBps: 0, dividendBps: 0, recipient: address(0)});
    }

    function _cfg() internal pure returns (IGangLaunchpad.MintConfig memory) {
        return
            IGangLaunchpad.MintConfig({raiseBnb: 15 ether, capBps: 50, holdBps: 6000, mintFeeBps: 100, exitFeeBps: 100});
    }

    /// @dev NVDAB is not in QuoteRegistry: priced from the pool, the same number LaunchpadV2 locks.
    function _v3Creates(address ref) internal {
        uint256 want = v2.graduationAmountOf(NVDAB, ref);
        assertGt(want, 0);
        assertEq(v3.graduationAmountFor(NVDAB, ref, 15 ether), want, "V3 core prices like V2");
        vm.prank(dev);
        address t = v3.createWithGradTarget("NV Tax", "NVT", "", "", NVDAB, ref, _untaxed(), 15 ether);
        assertEq(v3.gradAmtOf(t), want, "locked at create");
        console.log("V3 gradAmt NVDAB (e15)", want / 1e15);
    }

    function _fairCreates(address ref) internal {
        uint256 want = v2.graduationAmountOf(NVDAB, ref); // raise 15 BNB = V2's graduation target
        (uint256 raiseQuote, uint256 price) = fair.previewCreate(NVDAB, ref, 15 ether);
        assertEq(raiseQuote, want, "fair core prices like V2");
        vm.prank(NVDAB_USDT_V3);
        IERC20(NVDAB).transfer(dev, price * 2);
        vm.startPrank(dev);
        IERC20(NVDAB).approve(address(fair), type(uint256).max);
        address t = fair.create("NV Fair", "NVF", "", "", NVDAB, ref, _cfg(), 1);
        vm.stopPrank();
        (,,,,,,,,,, uint128 sharePrice,,,) = fair.sales(t);
        assertEq(sharePrice, price, "share price locked at create");
        console.log("fair raise NVDAB (e15)", raiseQuote / 1e15);
    }

    function test_fork_v3_nvdab_viaV2Pair() public forkOnly {
        _v3Creates(NVDAB_WBNB_V2);
    }

    function test_fork_v3_nvdab_viaV3PoolAndBridge() public forkOnly {
        _v3Creates(NVDAB_USDT_V3);
    }

    function test_fork_fair_nvdab_viaV2Pair() public forkOnly {
        _fairCreates(NVDAB_WBNB_V2);
    }

    function test_fork_fair_nvdab_viaV3PoolAndBridge() public forkOnly {
        _fairCreates(NVDAB_USDT_V3);
    }

    /// @dev Without a fixed rate a pool is required; with one, the rate wins over any pool (both cores).
    function test_fork_fixedRateWinsAndNoPoolRefused() public forkOnly {
        vm.startPrank(dev);
        vm.expectRevert(IGangLaunchpad.RefPoolRequired.selector);
        v3.createWithGradTarget("X", "X", "", "", NVDAB, address(0), _untaxed(), 15 ether);
        vm.expectRevert(IGangLaunchpad.RefPoolRequired.selector);
        fair.previewCreate(NVDAB, address(0), 15 ether);
        vm.stopPrank();

        QuoteRegistry reg = QuoteRegistry(address(v3.quoteRegistry()));
        vm.prank(owner);
        reg.setQuote(NVDAB, true, 77 ether);
        assertEq(v3.graduationAmountFor(NVDAB, NVDAB_WBNB_V2, 15 ether), 77 ether);
        (uint256 raiseQuote,) = fair.previewCreate(NVDAB, address(0), 15 ether);
        assertEq(raiseQuote, 77 ether);
    }

    /// @dev USDT with no fixed rate: both cores lock ≈ 15 BNB of USDT from USDT_REF_POOL's TWAP, the same number V2
    ///      would; a fixed rate set later still wins.
    function test_fork_usdt_pricedFromRefPool() public forkOnly {
        uint256 want = v2.graduationAmountOf(USDT, USDT_REF_POOL);
        assertEq(v3.graduationAmountFor(USDT, USDT_REF_POOL, 15 ether), want, "V3 core prices USDT like V2");
        // 2.0's default target (9 BNB) is the same pool price for 9 BNB
        assertApproxEqAbs(v3.graduationAmountOf(USDT, USDT_REF_POOL), (want * 9) / 15, 1e6, "default 9 BNB");
        (uint256 raiseQuote,) = fair.previewCreate(USDT, USDT_REF_POOL, 15 ether);
        assertEq(raiseQuote, want, "fair core prices USDT like V2");
        (uint160 sqrtP,,,,,,) = IV3PoolSlot0(USDT_REF_POOL).slot0(); // token0 USDT, token1 WBNB
        uint256 spot = Math.mulDiv(15 ether, 1 << 192, uint256(sqrtP) * uint256(sqrtP));
        assertApproxEqRel(want, spot, 0.05e18, "TWAP within 5% of spot: about 15 BNB of USDT");
        console.log("15 BNB in USDT (e18)", want / 1e18);

        vm.prank(dev);
        address t = v3.createWithGradTarget("U Tax", "UT", "", "", USDT, USDT_REF_POOL, _untaxed(), 15 ether);
        assertEq(v3.gradAmtOf(t), want, "locked at create");

        QuoteRegistry reg = QuoteRegistry(address(v3.quoteRegistry()));
        vm.prank(owner);
        reg.setQuote(USDT, true, 9_000 ether);
        assertEq(v3.graduationAmountFor(USDT, USDT_REF_POOL, 15 ether), 9_000 ether, "fixed rate wins over the pool");
        (raiseQuote,) = fair.previewCreate(USDT, USDT_REF_POOL, 15 ether);
        assertEq(raiseQuote, 9_000 ether);
    }

    /// @dev Matches what the live LaunchpadV2 (0x1B8F…966E) returns for the same V2 pair: reserves, no TWAP.
    function test_fork_matchesLiveV2_onV2Pair() public forkOnly {
        uint256 live = LaunchpadV2(0x1B8F3f69DFa0a7F63d308C7EB0Fd38D8b099966E).graduationAmountOf(NVDAB, NVDAB_WBNB_V2);
        assertEq(v3.graduationAmountFor(NVDAB, NVDAB_WBNB_V2, 15 ether), live);
        (uint256 raiseQuote,) = fair.previewCreate(NVDAB, NVDAB_WBNB_V2, 15 ether);
        assertEq(raiseQuote, live);
    }
}
