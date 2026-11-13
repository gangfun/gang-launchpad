// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {RoutedBuybackBurner} from "../../src/buyback/RoutedBuybackBurner.sol";
import {IPancakeRouter02} from "../../src/interfaces/IPancake.sol";
import {IPlatformFeeBucket} from "../buyback/IPlatformFeeBucket.sol";
import {MainnetAddresses as M} from "../../config/MainnetAddresses.sol";

interface IV3Quoter {
    function quoteExactInput(bytes memory path, uint256 amountIn)
        external
        returns (uint256 amountOut, uint160[] memory, uint32[] memory, uint256);
}

interface ISharedBucketOperators {
    function setOperator(address account, bool enabled) external;
}

/// @dev BSC mainnet fork: put the SharedPlatformFeeBucket (LaunchpadV3 / 打新 / Flywheel) on RoutedBuybackBurner and
///      collect the stock-quote fees that were stuck because they have no Pancake V2 depth. Runs only when BSC_RPC_URL
///      is set: forge test --match-path 'test/fork/*'
contract RoutedBuybackBurnerForkTest is Test {
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address constant SHARED_BUCKET = 0xB8C4B68a62513240A5e44EFd78fFc35ac25bA21b;
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant V3_QUOTER = 0xB048Bbc1Ee6b733FFfCFb9e9CeF7375518e25997;
    address constant O_ANTHROPIC = 0x24B518b332543a4E1C3649d063daB199d103760a;
    address constant EWYB = 0xBE82F76637DBA2C114C41Df856c2C51e522E2Cb8;
    address constant W_TCENTX = 0x41333Df9E7639188BBfca5522dC4844398Af9f9E;
    address constant BABAB = 0x4eF9d3062c7F6ebA4AAE4990c5036598C6eff4ec;
    uint256 constant SLIPPAGE_BPS = 150;

    RoutedBuybackBurner burner;
    IPlatformFeeBucket bucket = IPlatformFeeBucket(SHARED_BUCKET);

    function setUp() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        burner = new RoutedBuybackBurner(M.OWNER, M.PANCAKE_V2_ROUTER, M.PANCAKE_SMART_ROUTER, M.WBNB, M.GANG);
        vm.startPrank(M.OWNER);
        burner.setV3Route(O_ANTHROPIC, _viaUsdt(O_ANTHROPIC));
        burner.setV3Route(EWYB, _viaUsdt(EWYB));
        burner.setV3Route(W_TCENTX, _viaUsdt(W_TCENTX));
        burner.setV3Route(BABAB, _viaUsdt(BABAB));
        vm.stopPrank();
        vm.prank(bucket.owner());
        bucket.setBurner(address(burner));
    }

    function _viaUsdt(address q) internal pure returns (bytes memory) {
        return abi.encodePacked(q, uint24(2500), USDT, uint24(100), M.WBNB);
    }

    /// @dev The keeper's floor: V3 quote to WBNB, V2 getAmountsOut to GANG, minus SLIPPAGE_BPS.
    function _minGangOut(address q, uint256 toBuyback) internal returns (uint256) {
        (uint256 wbnbOut,,,) = IV3Quoter(V3_QUOTER).quoteExactInput(_viaUsdt(q), toBuyback);
        address[] memory p = new address[](2);
        p[0] = M.WBNB;
        p[1] = M.GANG;
        uint256 gangOut = IPancakeRouter02(M.PANCAKE_V2_ROUTER).getAmountsOut(wbnbOut, p)[1];
        return (gangOut * (10_000 - SLIPPAGE_BPS)) / 10_000;
    }

    /// @dev Tops the bucket up the way a core does, so the test still bites once the live balance is collected. The
    ///      shared bucket has no launchpad (launchpad() = 0): its cores are operators, so a test operator stands in.
    function _accrue(address quote, uint256 amount) internal {
        address pad = makeAddr("core");
        vm.prank(bucket.owner());
        ISharedBucketOperators(SHARED_BUCKET).setOperator(pad, true);
        deal(quote, pad, amount);
        vm.startPrank(pad);
        IERC20(quote).approve(SHARED_BUCKET, amount);
        bucket.notifyAccrual(quote, amount);
        vm.stopPrank();
    }

    function _collect(address q, uint256 seed) internal {
        if (bucket.accruedQuote(q) == 0) _accrue(q, seed);
        uint256 acc = bucket.accruedQuote(q);
        uint256 toBuyback = (acc * bucket.BUYBACK_BPS()) / bucket.BPS();
        uint256 minOut = _minGangOut(q, toBuyback);
        uint256 dead0 = IERC20(M.GANG).balanceOf(DEAD);
        uint256 vault0 = IERC20(q).balanceOf(bucket.feeVault());

        vm.prank(bucket.keeper());
        bucket.collectPlatform(q, minOut);

        uint256 burned = IERC20(M.GANG).balanceOf(DEAD) - dead0;
        console.log("quote", q);
        console.log("  accrued (e15)", acc / 1e15, "GANG burned (e18)", burned / 1e18);
        assertGe(burned, minOut);
        assertEq(IERC20(q).balanceOf(bucket.feeVault()) - vault0, acc - toBuyback);
        assertEq(bucket.accruedQuote(q), 0);
        assertEq(IERC20(q).balanceOf(address(burner)), 0);
        assertEq(IERC20(M.WBNB).balanceOf(address(burner)), 0);
        assertEq(IERC20(M.GANG).balanceOf(address(burner)), 0);
    }

    function test_collect_oAnthropic() public {
        if (address(burner) == address(0)) return;
        _collect(O_ANTHROPIC, 1 ether);
    }

    function test_collect_ewyb() public {
        if (address(burner) == address(0)) return;
        _collect(EWYB, 0.1 ether);
    }

    function test_collect_wTcentx() public {
        if (address(burner) == address(0)) return;
        _collect(W_TCENTX, 0.01 ether);
    }

    /// @dev BABAB has a Pancake V2 pair, but ~5.6% impact there; V3 via USDT is deep.
    function test_collect_babab() public {
        if (address(burner) == address(0)) return;
        _collect(BABAB, 1 ether);
    }

    /// @dev A quote without a route still goes through Pancake V2, and WBNB / GANG keep working.
    function test_noRoute_stillV2() public {
        if (address(burner) == address(0)) return;
        _accrue(M.WBNB, 0.1 ether);
        _accrue(M.GANG, 1_000 ether);
        uint256 dead0 = IERC20(M.GANG).balanceOf(DEAD);
        vm.startPrank(bucket.keeper());
        bucket.collectPlatform(M.WBNB, 1);
        bucket.collectPlatform(M.GANG, (bucket.accruedQuote(M.GANG) * bucket.BUYBACK_BPS()) / bucket.BPS());
        vm.stopPrank();
        assertGt(IERC20(M.GANG).balanceOf(DEAD), dead0);
    }
}
