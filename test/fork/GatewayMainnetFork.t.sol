// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {GangMainnetRefs as M} from "../../config/GangDeployRefs.sol";
import {IGangPad} from "../../src/gang/interfaces/IGangPad.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {GangPadRegistry} from "../../src/gang/GangPadRegistry.sol";
import {GangGateway} from "../../src/router/GangGateway.sol";
import {IGangGateway} from "../../src/router/interfaces/IGangGateway.sol";
import {GangRouterDeployLib as R} from "../../script/GangRouterDeployLib.sol";
import {GangGatewayDeployLib as G} from "../../script/GangGatewayDeployLib.sol";
import {GatewayAdapter} from "../router/GangGateway.t.sol";

/// @notice GangGateway on a BSC mainnet fork, against the live GangLaunchpad and GangPadRegistry: deployed as the
///         deploy script does (48 h timelock run by the Safe), listed by the Safe, then a BNB buy and a BNB sell (real
///         WBNB unwraps through the proxy's 2300-gas `receive`) through an aggregator-style adapter on a live WBNB
///         curve, both matching tryBuy / trySell to the wei; getTokenInfo of a graduated token; the pad's own rules
///         (origin, allowance) still apply, and only whitelisted callers sell for someone else. The trader's Agent ID
///         is mocked (balanceOf = 1).
/// @dev Needs BSC_RPC_URL (without it every test is skipped).
contract GatewayMainnetForkTest is Test {
    address constant PAD = 0x15CFD2dc8278Fb87a1783ef42111618E20874365;
    address constant REGISTRY = 0x4fF77D4d9ac080939a24E1B805206bA094C44e5C;

    GangGateway gw;
    G.Gateway stack;
    GatewayAdapter adapter;
    address user = makeAddr("fork-user");
    address feeTo = makeAddr("fork-feeTo");
    address live;
    address graduated;

    function setUp() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        stack = G.deploy(REGISTRY, M.WBNB, M.OWNER_SAFE, R.MAINNET_MIN_DELAY);
        gw = GangGateway(payable(stack.proxy));
        vm.prank(M.OWNER_SAFE);
        IGangPad(PAD).setRouter(address(gw), true);
        adapter = new GatewayAdapter(IGangGateway(address(gw)), feeTo);
        vm.prank(M.OWNER_SAFE);
        gw.setCaller(address(adapter), true);
        vm.mockCall(
            M.AGENT_ID_REGISTRY, abi.encodeWithSelector(IERC721.balanceOf.selector, user), abi.encode(uint256(1))
        );
        vm.deal(user, 10 ether);

        uint256 n = IGangPad(PAD).tokenCount();
        for (uint256 i = n; i > 0 && (live == address(0) || graduated == address(0)); i--) {
            address t = IGangPad(PAD).allTokens(i - 1);
            (uint8 status, address quote,,, uint256 left) = gw.getTokenInfo(t);
            if (status == 1 && quote == address(0) && left > 0.5 ether && live == address(0)) live = t;
            if (status == 2 && graduated == address(0) && IGangPad(PAD).kindOf(t) == 1) graduated = t;
        }
    }

    modifier forkOnly() {
        if (address(gw) == address(0)) {
            vm.skip(true);
            return;
        }
        _;
    }

    function test_fork_selfCheck() public forkOnly {
        G.check(
            stack,
            G.Expect({
                registry: REGISTRY,
                wbnb: M.WBNB,
                safe: M.OWNER_SAFE,
                deployer: address(this),
                minDelay: R.MAINNET_MIN_DELAY,
                mainnet: true
            })
        );
        assertTrue(IGangPad(PAD).routers(address(gw)));
        assertTrue(IGangPad(PAD).agentGateEnabled());
        assertEq(gw.owner(), M.OWNER_SAFE);
    }

    function test_fork_buyAndSellLiveCurve() public forkOnly {
        if (live == address(0)) {
            console.log("no live WBNB curve with room on mainnet now: skipped");
            vm.skip(true);
            return;
        }
        console.log("live curve", live);
        uint256 funds = 0.005 ether;
        (,, uint256 est, uint256 cost,,,,) = gw.tryBuy(live, user, 0, funds);
        assertGt(est, 0, "quote");
        uint256 wBefore = IERC20(M.WBNB).balanceOf(user);
        vm.prank(user, user);
        uint256 g0 = gasleft();
        (uint256 out, uint256 used) = adapter.buyBnb{value: funds}(live, est);
        console.log("gas adapter.buyBnb", g0 - gasleft());
        assertEq(out, est);
        assertEq(used, cost);
        assertEq(IERC20(live).balanceOf(user), out);
        assertEq(IERC20(M.WBNB).balanceOf(user) - wBefore, funds - cost, "refund");

        vm.prank(user);
        IERC20(live).approve(address(gw), type(uint256).max);
        (,, uint256 fundsQ,) = gw.trySell(live, out);
        uint256 routerFee = (fundsQ * 100) / 10_000;
        uint256 bnbBefore = user.balance;
        vm.prank(user, user);
        g0 = gasleft();
        uint256 toSeller = adapter.sell(live, out, fundsQ - routerFee);
        console.log("gas adapter.sell", g0 - gasleft());
        assertEq(toSeller, fundsQ - routerFee);
        assertEq(user.balance - bnbBefore, toSeller, "BNB to the seller (real WBNB unwrap)");
        assertEq(feeTo.balance, routerFee);
        assertEq(IERC20(live).balanceOf(user), 0);
        assertEq(address(gw).balance, 0);
        assertEq(IERC20(M.WBNB).balanceOf(address(gw)), 0);
    }

    function test_fork_padRulesStillApply() public forkOnly {
        if (live == address(0)) {
            vm.skip(true);
            return;
        }
        vm.prank(user, user);
        (uint256 out,) = gw.buyTokenAMAP{value: 0.002 ether}(live, user, 0.002 ether, 0);
        // only a pad allowance: the gateway cannot sell
        vm.prank(user);
        IERC20(live).approve(PAD, type(uint256).max);
        vm.prank(user, user);
        vm.expectRevert();
        gw.sellToken(0, live, user, out, 0, 0, address(0));
        // with the gateway allowance, but in someone else's tx
        vm.prank(user);
        IERC20(live).approve(address(gw), type(uint256).max);
        address other = makeAddr("fork-other");
        vm.prank(other, other);
        vm.expectRevert(IGangGateway.NotWhitelisted.selector);
        gw.sellToken(0, live, user, out, 0, 500, other);
        // through the whitelisted adapter the seller is `other` itself: the user's tokens stay put
        vm.prank(other, other);
        vm.expectRevert();
        adapter.sell(live, out, 0);
        assertEq(IERC20(live).balanceOf(user), out);
        // a wallet without an Agent ID
        vm.deal(other, 1 ether);
        vm.prank(other, other);
        vm.expectRevert(IGangLaunchpad.NotAgent.selector);
        gw.buyTokenAMAP{value: 0.002 ether}(live, other, 0.002 ether, 0);
    }

    function test_fork_graduatedInfo() public forkOnly {
        if (graduated == address(0)) {
            vm.skip(true);
            return;
        }
        (uint8 status,, address pair,,) = gw.getTokenInfo(graduated);
        assertEq(status, 2);
        (,,,,,,,,,, address p,) = IGangPad(PAD).curves(graduated);
        assertEq(pair, p);
        vm.prank(user, user);
        vm.expectRevert(IGangGateway.NotCurveToken.selector);
        gw.buyTokenAMAP{value: 0.001 ether}(graduated, user, 0.001 ether, 0);
    }
}
