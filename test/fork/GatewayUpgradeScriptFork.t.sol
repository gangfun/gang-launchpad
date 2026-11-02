// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {GangMainnetRefs as M} from "../../config/GangDeployRefs.sol";
import {GangGateway} from "../../src/router/GangGateway.sol";
import {GangRouterDeployLib as R} from "../../script/GangRouterDeployLib.sol";
import {GangGatewayDeployLib as G} from "../../script/GangGatewayDeployLib.sol";
import {UpgradeGangGateway} from "../../script/UpgradeGangGateway.s.sol";

/// @notice script/UpgradeGangGateway.s.sol (AUDIT-BRIEF §26, audit L-3 / I-8) run end to end on a BSC mainnet fork, the Safe's
///         schedule / execute done by pranks: simulation-only implementation, step 1 (printed), pending, step 2
///         (printed), step 3 (self-check + pad listings printed), and the "operation done but the proxy runs another
///         build" refusal. Run with -vv to see the printed calls. Needs BSC_RPC_URL.
contract GatewayUpgradeScriptForkTest is Test {
    uint256 constant PK = 0xA11CE;
    G.Gateway stack;
    TimelockController tl;

    function setUp() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(PK));
        vm.setEnv("GATEWAY_IMPL", vm.toString(address(0)));
        stack = G.load(M.GANG_GATEWAY);
        tl = TimelockController(payable(stack.timelock));
    }

    function _op(address impl) internal view returns (bytes memory call, bytes32 id) {
        call = abi.encodeCall(ProxyAdmin.upgradeAndCall, (ITransparentUpgradeableProxy(stack.proxy), impl, bytes("")));
        id = tl.hashOperation(stack.proxyAdmin, 0, call, bytes32(0), bytes32(0));
    }

    function test_fork_scriptSteps() public {
        if (stack.proxy == address(0)) return vm.skip(true, "no BSC_RPC_URL");
        address oldImpl = stack.impl;
        assertFalse(tl.hasRole(tl.PROPOSER_ROLE(), vm.addr(PK)));

        // simulation-only implementation: nothing scheduled, proxy unchanged
        new UpgradeGangGateway().run();
        assertEq(G.load(M.GANG_GATEWAY).impl, oldImpl);

        // step 1 with a deployed implementation: printed for the Safe
        address impl = address(new GangGateway());
        vm.setEnv("GATEWAY_IMPL", vm.toString(impl));
        (bytes memory call, bytes32 id) = _op(impl);
        new UpgradeGangGateway().run();
        assertFalse(tl.isOperation(id), "the script sends nothing for a non-proposer");

        // the Safe schedules what was printed; re-run: pending
        vm.prank(M.OWNER_SAFE);
        tl.schedule(stack.proxyAdmin, 0, call, bytes32(0), bytes32(0), R.MAINNET_MIN_DELAY);
        new UpgradeGangGateway().run();

        // step 2: printed
        vm.warp(vm.getBlockTimestamp() + R.MAINNET_MIN_DELAY + 1);
        new UpgradeGangGateway().run();
        assertTrue(tl.isOperationReady(id), "still not executed by the script");
        vm.prank(M.OWNER_SAFE);
        tl.execute(stack.proxyAdmin, 0, call, bytes32(0), bytes32(0));

        // step 3: self-check, listings printed for the Safe (the flywheel pads)
        new UpgradeGangGateway().run();

        // another upgrade after it (back to V1): the done operation is refused, not re-proposed
        (bytes memory back, bytes32 idBack) = _op(oldImpl);
        vm.startPrank(M.OWNER_SAFE);
        tl.schedule(stack.proxyAdmin, 0, back, bytes32(0), bytes32(0), R.MAINNET_MIN_DELAY);
        vm.warp(vm.getBlockTimestamp() + R.MAINNET_MIN_DELAY + 1);
        tl.execute(stack.proxyAdmin, 0, back, bytes32(0), bytes32(0));
        vm.stopPrank();
        assertTrue(tl.isOperationDone(idBack));
        UpgradeGangGateway s = new UpgradeGangGateway();
        vm.expectRevert(
            abi.encodeWithSelector(
                UpgradeGangGateway.WiringCheck.selector, "operation done but the proxy does not run this build"
            )
        );
        s.run();
    }
}
