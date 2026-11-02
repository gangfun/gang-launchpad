// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {GangMainnetRefs as M} from "../config/GangDeployRefs.sol";
import {IGangPad} from "../src/gang/interfaces/IGangPad.sol";
import {GangGateway} from "../src/router/GangGateway.sol";
import {GangRouterDeployLib as R} from "./GangRouterDeployLib.sol";
import {GangGatewayDeployLib as G} from "./GangGatewayDeployLib.sol";

/// @title UpgradeGangGateway — move the GangGateway proxy to this build (V2: 铸币飞轮 support, AUDIT-BRIEF §26)
/// @notice The proxy, its users' approvals and its storage stay; only the implementation changes, through the 48 h
///         timelock (GangGatewayDeployLib: timelock.schedule → wait minDelay → timelock.execute of
///         ProxyAdmin.upgradeAndCall(proxy, newImpl, "")). Three runs:
///         1. deploy: the new implementation (or GATEWAY_IMPL, already deployed), checked to be this build and locked;
///            then the schedule call — sent here when the deploy wallet is the timelock's proposer (testnet stacks),
///            else printed for the proposer (mainnet: a Safe transaction), with the operation id and the time it can run.
///         2. after the delay: the execute call, sent or printed the same way (same GATEWAY_IMPL).
///         3. once the proxy runs this build: the full read-back self-check (GangGatewayDeployLib.check), then the
///            `setRouter(proxy, true)` of every registered pad that does not list the gateway yet (sent when the deploy
///            wallet owns the pad, else printed for its owner: on mainnet, the flywheel pads' Safe transaction).
///         The run picks its step from the chain: proxy on this build → 3; operation ready → 2; else 1.
///         Step 1 without GATEWAY_IMPL deploys a new implementation every time it is broadcast: pass the first one's
///         address from then on (a second one would be a second operation). Without --broadcast that implementation
///         exists only in the simulation, so the proposer's calls are not printed (audit L-3).
/// @dev Env: DEPLOYER_PRIVATE_KEY; GANG_GATEWAY (mainnet: default and only accepted value M.GANG_GATEWAY);
///      GATEWAY_IMPL (the implementation deployed by step 1; required for steps 1-again and 2); OWNER (the timelock's
///      Safe; mainnet: default and only accepted value M.OWNER_SAFE; testnet: default the deployer);
///      ROUTER_TIMELOCK_DELAY (testnet only, as deployed); mainnet broadcast needs GANG_MAINNET_OK=true.
contract UpgradeGangGateway is Script {
    error WrongChain(uint256 chainId);
    error MainnetNotAllowed();
    error WiringCheck(string what);

    function run() external {
        bool mainnet = block.chainid == 56;
        if (!mainnet && block.chainid != 97) revert WrongChain(block.chainid);
        bool broadcasting =
            vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        if (mainnet && broadcasting && !vm.envOr("GANG_MAINNET_OK", false)) revert MainnetNotAllowed();

        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address proxy = mainnet ? vm.envOr("GANG_GATEWAY", M.GANG_GATEWAY) : vm.envAddress("GANG_GATEWAY");
        if (mainnet && proxy != M.GANG_GATEWAY) revert WiringCheck("GANG_GATEWAY not M.GANG_GATEWAY");
        address safe = vm.envOr("OWNER", mainnet ? M.OWNER_SAFE : deployer);
        if (mainnet && safe != M.OWNER_SAFE) revert WiringCheck("OWNER not the Safe");
        uint256 delay = R.minDelayFromEnv(mainnet);

        G.Gateway memory g = G.load(proxy);
        GangGateway gw = GangGateway(payable(proxy));
        console.log("=== UpgradeGangGateway chain", block.chainid, "===");
        console.log("GANG_GATEWAY", proxy);

        // step 3: the proxy already runs this build
        if (R.sameCode(g.impl, type(GangGateway).runtimeCode)) {
            G.check(
                g,
                G.Expect({
                    registry: address(gw.registry()),
                    wbnb: gw.wbnb(),
                    safe: safe,
                    deployer: deployer,
                    minDelay: delay,
                    mainnet: mainnet
                })
            );
            if (mainnet && address(gw.registry()) != M.PAD_REGISTRY) revert WiringCheck("registry");
            console.log("proxy runs this build; self-check passed. impl", g.impl);
            _listOnPads(gw, deployer, pk);
            return;
        }

        address impl = vm.envOr("GATEWAY_IMPL", address(0));
        bool simulatedImpl = impl == address(0) && !broadcasting;
        if (impl == address(0)) {
            vm.startBroadcast(pk);
            impl = address(new GangGateway());
            vm.stopBroadcast();
        }
        if (!R.sameCode(impl, type(GangGateway).runtimeCode)) revert WiringCheck("GATEWAY_IMPL code");
        (uint64 v,) = R.initState(impl);
        if (v != type(uint64).max) revert WiringCheck("GATEWAY_IMPL not locked");
        console.log("GATEWAY_IMPL (new implementation)", impl);

        TimelockController tl = TimelockController(payable(g.timelock));
        if (tl.getMinDelay() != delay) revert WiringCheck("timelock delay");
        bytes memory call =
            abi.encodeCall(ProxyAdmin.upgradeAndCall, (ITransparentUpgradeableProxy(proxy), impl, bytes("")));
        bytes32 id = tl.hashOperation(g.proxyAdmin, 0, call, bytes32(0), bytes32(0));
        bool proposer = tl.hasRole(tl.PROPOSER_ROLE(), deployer);
        console.log("timelock", g.timelock, "ProxyAdmin", g.proxyAdmin);
        console.log("operation id");
        console.logBytes32(id);

        if (tl.isOperationReady(id)) {
            // step 2
            bytes memory exec =
                abi.encodeCall(TimelockController.execute, (g.proxyAdmin, 0, call, bytes32(0), bytes32(0)));
            if (proposer && tl.hasRole(tl.EXECUTOR_ROLE(), deployer)) {
                vm.startBroadcast(pk);
                tl.execute(g.proxyAdmin, 0, call, bytes32(0), bytes32(0));
                vm.stopBroadcast();
                console.log(
                    broadcasting
                        ? "executed: re-run for the self-check and the pad listings"
                        : "SIMULATION: would execute"
                );
            } else {
                console.log("PENDING a timelock executor (the Safe): to", g.timelock);
                console.logBytes(exec);
            }
        } else if (tl.isOperationPending(id)) {
            console.log("scheduled; ready at (unix)", tl.getTimestamp(id));
        } else if (tl.isOperationDone(id)) {
            // executed, yet the proxy does not run this build: upgraded again since, or another build
            revert WiringCheck("operation done but the proxy does not run this build");
        } else if (simulatedImpl && !proposer) {
            console.log("SIMULATION: this implementation exists only here. Run with --broadcast to deploy it, then");
            console.log("re-run with GATEWAY_IMPL=<its address> to print the proposer's schedule / execute calls.");
        } else {
            // step 1
            bytes memory sched =
                abi.encodeCall(TimelockController.schedule, (g.proxyAdmin, 0, call, bytes32(0), bytes32(0), delay));
            if (proposer) {
                vm.startBroadcast(pk);
                tl.schedule(g.proxyAdmin, 0, call, bytes32(0), bytes32(0), delay);
                vm.stopBroadcast();
                console.log(
                    broadcasting ? "scheduled; ready in seconds" : "SIMULATION: would schedule; ready in seconds", delay
                );
            } else {
                console.log("PENDING timelock proposer", safe, ": to", g.timelock);
                console.logBytes(sched);
                console.log("then, after the delay (seconds)", delay, ", execute: to", g.timelock);
                console.logBytes(
                    abi.encodeCall(TimelockController.execute, (g.proxyAdmin, 0, call, bytes32(0), bytes32(0)))
                );
            }
        }
    }

    /// @dev Lists the gateway on every registered pad that does not list it yet: sent when the deploy wallet owns the
    ///      pad, else printed for the pad's owner.
    function _listOnPads(GangGateway gw, address deployer, uint256 pk) internal {
        address[] memory pads = gw.registry().pads();
        for (uint256 i; i < pads.length; i++) {
            IGangPad p = IGangPad(pads[i]);
            if (p.routers(address(gw))) {
                console.log("listed on pad", pads[i]);
            } else if (Ownable(pads[i]).owner() == deployer) {
                vm.startBroadcast(pk);
                p.setRouter(address(gw), true);
                vm.stopBroadcast();
                console.log("listed now on pad", pads[i]);
            } else {
                console.log("PENDING pad owner", Ownable(pads[i]).owner(), ": on pad", pads[i]);
                console.logBytes(abi.encodeCall(IGangPad.setRouter, (address(gw), true)));
            }
        }
    }
}
