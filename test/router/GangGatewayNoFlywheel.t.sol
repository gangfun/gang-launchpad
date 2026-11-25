// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {GangPadRegistry} from "../../src/gang/GangPadRegistry.sol";
import {GangGateway} from "../../src/router/GangGateway.sol";
import {IGangGateway} from "../../src/router/interfaces/IGangGateway.sol";
import {GangRouterDeployLib as R} from "../../script/GangRouterDeployLib.sol";
import {GangPadRegistryDeployLib as RG} from "../../script/GangPadRegistryDeployLib.sol";
import {GangGatewayDeployLib as G} from "../../script/GangGatewayDeployLib.sol";
import {FlywheelFixture} from "../flywheel/FlywheelFixture.sol";

/// @notice GangGateway does not trade 铸币飞轮 tokens (kind 3), even on a pad that lists it.
contract GangGatewayNoFlywheelTest is FlywheelFixture {
    function test_flywheelTokenRefused() public {
        _deploy();
        address[] memory pads = new address[](1);
        pads[0] = address(pad);
        GangPadRegistry reg = GangPadRegistry(RG.deploy(owner, pads).proxy);
        GangGateway gw = GangGateway(payable(G.deploy(address(reg), address(wbnb), owner, R.MAINNET_MIN_DELAY).proxy));
        vm.prank(owner);
        pad.setRouter(address(gw), true);
        address t = _create(_wide(), 1);
        (, uint8 kind) = reg.lookup(t);
        assertEq(kind, 3);

        (uint8 s,,,,) = gw.getTokenInfo(t);
        assertEq(s, 0);
        address w = _newAgent();
        (,, uint256 est,,,,,) = gw.tryBuy(t, w, 0, 1 ether);
        assertEq(est, 0);
        (,, uint256 funds,) = gw.trySell(t, 100_000 ether);
        assertEq(funds, 0);
        vm.deal(w, 2 ether);
        vm.startPrank(w, w);
        vm.expectRevert(IGangGateway.NotCurveToken.selector);
        gw.buyTokenAMAP{value: 1 ether}(t, w, 1 ether, 0);
        vm.expectRevert(IGangGateway.NotCurveToken.selector);
        gw.sellToken(0, t, w, 100_000 ether, 0, 0, address(0));
        vm.stopPrank();
    }
}
