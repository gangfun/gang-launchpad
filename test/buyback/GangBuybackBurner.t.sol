// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {GangBuybackBurner} from "../../src/buyback/GangBuybackBurner.sol";
import {IPlatformFeeBucket} from "./IPlatformFeeBucket.sol";
import {MockPancakeRouter} from "../mocks/MockPancakeRouter.sol";

/// @dev Local mint-anyone token (not src/launchpad-v2/mocks: that path is compiled with via-IR, see IPlatformFeeBucket).
contract MockToken is ERC20 {
    constructor() ERC20("Mock", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Stand-in for the Pancake Smart Router: pulls `spend` of tokenIn from the caller, pays `out` of tokenOut to `to`.
contract MockSmartRouter {
    function swap(address tokenIn, uint256 spend, address tokenOut, uint256 out, address to) external {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), spend);
        IERC20(tokenOut).transfer(to, out);
    }

    function fail() external pure {
        revert("smart");
    }
}

contract GangBuybackBurnerTest is Test {
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address owner = makeAddr("owner");
    address keeper = makeAddr("keeper");
    address feeVault = makeAddr("feeVault");
    address caller = makeAddr("caller");

    MockToken gang;
    MockToken wbnb;
    MockToken usdt;
    MockPancakeRouter router;
    MockSmartRouter smart;
    GangBuybackBurner burner;

    function setUp() public {
        gang = new MockToken();
        wbnb = new MockToken();
        usdt = new MockToken();
        router = new MockPancakeRouter(address(wbnb));
        router.setRate(2);
        smart = new MockSmartRouter();
        burner = new GangBuybackBurner(owner, address(router), address(smart), address(wbnb), address(gang));
        gang.mint(address(router), 1_000_000 ether);
        gang.mint(address(smart), 1_000_000 ether);
    }

    function _fund(MockToken token, uint256 amount) internal {
        token.mint(caller, amount);
        vm.prank(caller);
        token.approve(address(burner), amount);
    }

    // ---------------------------------------------------------------- quote == GANG (the fix)

    function test_gangQuote_burnsWithoutSwap() public {
        router.setRevertSwap(true); // proves the router is not touched
        _fund(gang, 100 ether);
        vm.expectEmit(address(burner));
        emit GangBuybackBurner.BuybackBurned(address(gang), 100 ether, 100 ether);
        vm.prank(caller);
        burner.buybackAndBurn(address(gang), 100 ether, 100 ether);
        assertEq(gang.balanceOf(DEAD), 100 ether);
        assertEq(gang.balanceOf(address(burner)), 0);
        assertEq(burner.quoteReceived(address(gang)), 100 ether);
    }

    function test_gangQuote_smart_ignoresEmptySwapData() public {
        _fund(gang, 50 ether);
        vm.prank(caller);
        burner.buybackAndBurnSmart(address(gang), 50 ether, 1, "");
        assertEq(gang.balanceOf(DEAD), 50 ether);
    }

    function test_gangQuote_minAboveAmount_reverts() public {
        _fund(gang, 10 ether);
        vm.prank(caller);
        vm.expectRevert(GangBuybackBurner.InsufficientGangOut.selector);
        burner.buybackAndBurn(address(gang), 10 ether, 10 ether + 1);
    }

    function test_gangQuote_strayGangStaysPut() public {
        gang.mint(address(burner), 7 ether); // donated, not part of any buyback
        _fund(gang, 10 ether);
        vm.prank(caller);
        burner.buybackAndBurn(address(gang), 10 ether, 1);
        assertEq(gang.balanceOf(DEAD), 10 ether);
        assertEq(gang.balanceOf(address(burner)), 7 ether);
    }

    // ---------------------------------------------------------------- V2 path (unchanged behaviour)

    function test_v2_otherQuote_swapsAndBurns() public {
        _fund(usdt, 10 ether);
        vm.prank(caller);
        burner.buybackAndBurn(address(usdt), 10 ether, 20 ether);
        assertEq(gang.balanceOf(DEAD), 20 ether);
        assertEq(usdt.balanceOf(address(router)), 10 ether);
    }

    function test_v2_slippage_bubblesRouterRevert() public {
        _fund(usdt, 10 ether);
        vm.prank(caller);
        vm.expectRevert(bytes("slippage"));
        burner.buybackAndBurn(address(usdt), 10 ether, 20 ether + 1);
    }

    function test_zeroMinGangOut_reverts() public {
        vm.expectRevert(GangBuybackBurner.ZeroAmount.selector);
        burner.buybackAndBurn(address(usdt), 1, 0);
    }

    function test_zeroAmountIn_isNoop() public {
        burner.buybackAndBurn(address(usdt), 0, 0); // as in the live burner: nothing pulled, no revert
        assertEq(burner.quoteReceived(address(usdt)), 0);
    }

    // ---------------------------------------------------------------- Smart path

    function _smartData(uint256 spend, uint256 out, address to) internal view returns (bytes memory) {
        return abi.encodeCall(MockSmartRouter.swap, (address(usdt), spend, address(gang), out, to));
    }

    function test_smart_burnsDelta_andClearsApproval() public {
        _fund(usdt, 10 ether);
        vm.prank(caller);
        burner.buybackAndBurnSmart(address(usdt), 10 ether, 30 ether, _smartData(10 ether, 30 ether, address(burner)));
        assertEq(gang.balanceOf(DEAD), 30 ether);
        assertEq(usdt.allowance(address(burner), address(smart)), 0);
    }

    function test_smart_partialSpend_reverts() public {
        _fund(usdt, 10 ether);
        vm.prank(caller);
        vm.expectRevert(GangBuybackBurner.IncompleteQuoteSpend.selector);
        burner.buybackAndBurnSmart(address(usdt), 10 ether, 1, _smartData(9 ether, 30 ether, address(burner)));
    }

    function test_smart_outputElsewhere_reverts() public {
        _fund(usdt, 10 ether);
        vm.prank(caller);
        vm.expectRevert(GangBuybackBurner.InsufficientGangOut.selector);
        burner.buybackAndBurnSmart(address(usdt), 10 ether, 1, _smartData(10 ether, 30 ether, caller));
    }

    function test_smart_callFails_reverts() public {
        _fund(usdt, 10 ether);
        vm.prank(caller);
        vm.expectRevert(GangBuybackBurner.SwapFailed.selector);
        burner.buybackAndBurnSmart(address(usdt), 10 ether, 1, abi.encodeCall(MockSmartRouter.fail, ()));
    }

    // ---------------------------------------------------------------- config

    function test_constructor_and_onlyOwner() public {
        assertEq(burner.owner(), owner);
        assertEq(address(burner.router()), address(router));
        assertEq(burner.smartRouter(), address(smart));
        assertEq(burner.wbnb(), address(wbnb));
        assertEq(burner.gang(), address(gang));

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        vm.prank(caller);
        burner.setGang(caller);

        vm.expectRevert(GangBuybackBurner.ZeroAddress.selector);
        new GangBuybackBurner(owner, address(router), address(smart), address(wbnb), address(0));
    }

    // ---------------------------------------------------------------- behind the live PlatformFeeBucket

    function test_bucket_gangAccrual_collects80BurnAnd20Vault() public {
        IPlatformFeeBucket bucket = IPlatformFeeBucket(
            deployCode("src/launchpad-v2/PlatformFeeBucket.sol:PlatformFeeBucket", abi.encode(owner, feeVault))
        );
        vm.startPrank(owner);
        bucket.setLaunchpad(caller);
        bucket.setKeeper(keeper);
        bucket.setBurner(address(burner));
        vm.stopPrank();

        gang.mint(caller, 1000 ether);
        vm.startPrank(caller);
        gang.approve(address(bucket), 1000 ether);
        bucket.notifyAccrual(address(gang), 1000 ether);
        vm.stopPrank();

        vm.prank(keeper);
        bucket.collectPlatform(address(gang), 800 ether);
        assertEq(gang.balanceOf(DEAD), 800 ether);
        assertEq(gang.balanceOf(feeVault), 200 ether);
        assertEq(bucket.accruedQuote(address(gang)), 0);
        assertEq(gang.balanceOf(address(bucket)), 0);
    }
}
