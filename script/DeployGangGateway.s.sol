// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {GangMainnetRefs as M, GangTestnetRefs as T} from "../config/GangDeployRefs.sol";
import {IGangPad} from "../src/gang/interfaces/IGangPad.sol";
import {IGangPadRegistry} from "../src/gang/interfaces/IGangPadRegistry.sol";
import {GangRouterDeployLib as R} from "./GangRouterDeployLib.sol";
import {GangGatewayDeployLib as G} from "./GangGatewayDeployLib.sol";
import {GangPadRegistryDeployLib as RG} from "./GangPadRegistryDeployLib.sol";

/// @title DeployGangGateway — the upgradeable four.meme-style curve entry for aggregators (AUDIT-BRIEF §25)
/// @notice Deploys implementation → 48 h TimelockController (the Safe) → TransparentUpgradeableProxy initialized with
///         the pad registry and WBNB, then reads everything back (GangGatewayDeployLib.check) and refuses to finish if
///         anything differs. Then, for every pad the registry knows (only GANG_PAD when set): when the deploy wallet owns the pad (testnet
///         stacks) it lists the gateway (`setRouter(proxy, true)`); otherwise it prints that call for the pad owner
///         (mainnet: a Safe transaction). The gateway serves a pad only once that pad lists it.
///         The registry is checked first (GangPadRegistryDeployLib.check: this build's code, its ProxyAdmin, owner and
///         pads); on mainnet it must be M.PAD_REGISTRY owned by the Safe — a wrong one would take a 48 h upgrade to fix.
/// @dev Env: DEPLOYER_PRIVATE_KEY, GANG_PAD_REGISTRY (mainnet: default and only accepted value M.PAD_REGISTRY);
///      OWNER (the timelock's proposer / executor / canceller; mainnet:
///      default and only accepted value the Safe, else OwnerNotSafe; testnet: default the deployer);
///      ROUTER_TIMELOCK_DELAY (seconds, default 48 h; mainnet: 48 h only); GANG_GATEWAY (re-run: deploy nothing, only
///      check that proxy and print what is pending); GANG_PAD (optional: list the gateway on this registered pad
///      only, e.g. leave another team's testnet pad alone; the others are printed as pending); mainnet broadcast needs
///      GANG_MAINNET_OK=true.
contract DeployGangGateway is Script {
    error WrongChain(uint256 chainId);
    error MainnetNotAllowed();
    error WiringCheck(string what);
    error OwnerNotSafe(address owner);

    function run() external returns (G.Gateway memory g) {
        bool mainnet = block.chainid == 56;
        if (!mainnet && block.chainid != 97) revert WrongChain(block.chainid);
        bool broadcasting =
            vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        if (mainnet && broadcasting && !vm.envOr("GANG_MAINNET_OK", false)) revert MainnetNotAllowed();

        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address wbnb = mainnet ? M.WBNB : T.WBNB;
        IGangPadRegistry registry = IGangPadRegistry(
            mainnet ? vm.envOr("GANG_PAD_REGISTRY", M.PAD_REGISTRY) : vm.envAddress("GANG_PAD_REGISTRY")
        );
        if (mainnet && address(registry) != M.PAD_REGISTRY) revert WiringCheck("registry not M.PAD_REGISTRY");
        address[] memory pads = registry.pads();
        if (pads.length == 0) revert WiringCheck("registry has no pad");
        // the registry decides which pad gets the callers' funds: this build's code, owned as expected
        address registryOwner = registry.owner();
        if (mainnet && registryOwner != M.OWNER_SAFE) revert WiringCheck("registry owner not the Safe");
        RG.check(RG.load(address(registry)), registryOwner, pads);
        address only = vm.envOr("GANG_PAD", address(0));
        if (only != address(0) && !registry.isPad(only)) revert WiringCheck("GANG_PAD not in the registry");
        for (uint256 i; i < pads.length; i++) {
            if ((only == address(0) || pads[i] == only) && IGangPad(pads[i]).wbnb() != wbnb) {
                revert WiringCheck("pad.wbnb");
            }
        }

        address owner = vm.envOr("OWNER", mainnet ? M.OWNER_SAFE : deployer);
        // mainnet: upgrades go through the platform Safe's timelock and nobody else's
        if (mainnet && owner != M.OWNER_SAFE) revert OwnerNotSafe(owner);
        if (mainnet && owner.code.length == 0) revert WiringCheck("owner safe code");
        uint256 delay = R.minDelayFromEnv(mainnet);

        address existing = vm.envOr("GANG_GATEWAY", address(0));
        if (existing != address(0)) {
            g = G.load(existing);
        } else {
            vm.startBroadcast(pk);
            g = G.deploy(address(registry), wbnb, owner, delay);
            for (uint256 i; i < pads.length; i++) {
                if ((only == address(0) || pads[i] == only) && Ownable(pads[i]).owner() == deployer) {
                    IGangPad(pads[i]).setRouter(g.proxy, true);
                }
            }
            vm.stopBroadcast();
        }
        G.check(
            g,
            G.Expect({
                registry: address(registry),
                wbnb: wbnb,
                safe: owner,
                deployer: deployer,
                minDelay: delay,
                mainnet: mainnet
            })
        );

        console.log("=== DeployGangGateway chain", block.chainid, "===");
        console.log("GANG_PAD_REGISTRY", address(registry));
        console.log("GANG_GATEWAY (proxy: users approve it, aggregators call it)", g.proxy);
        console.log("GANG_GATEWAY_IMPL", g.impl);
        console.log("GANG_GATEWAY_PROXY_ADMIN (owner = the timelock)", g.proxyAdmin);
        console.log("GANG_GATEWAY_TIMELOCK", g.timelock);
        console.log("timelock proposer / executor / canceller", owner);
        for (uint256 i; i < pads.length; i++) {
            if (IGangPad(pads[i]).routers(g.proxy)) {
                console.log("listed on pad", pads[i]);
            } else {
                console.log("PENDING pad owner", Ownable(pads[i]).owner(), ": on pad", pads[i]);
                console.logBytes(abi.encodeCall(IGangPad.setRouter, (g.proxy, true)));
            }
        }
    }
}
