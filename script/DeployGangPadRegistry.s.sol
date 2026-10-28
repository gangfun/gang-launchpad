// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {GangMainnetRefs as M, GangTestnetRefs as T} from "../config/GangDeployRefs.sol";
import {IGangPad} from "../src/gang/interfaces/IGangPad.sol";
import {GangPadRegistry} from "../src/gang/GangPadRegistry.sol";
import {GangPadRegistryDeployLib as G} from "./GangPadRegistryDeployLib.sol";

/// @title DeployGangPadRegistry — the upgradeable pad registry aggregators read (`padOf`, `isPad`, curve quotes)
/// @notice Deploys implementation → TransparentUpgradeableProxy initialized with the owner and the live pad, then reads
///         everything back (GangPadRegistryDeployLib.check) and refuses to finish if anything differs. Nothing on the
///         pad changes: the registry only reads it.
///         Mainnet: the owner (registry and its ProxyAdmin) is the platform Safe itself (M.OWNER_SAFE, 2 of 3), no
///         timelock: a new pad or a new version takes effect as soon as the Safe executes it.
/// @dev Env: DEPLOYER_PRIVATE_KEY, GANG_PAD; OWNER (mainnet: default and only accepted value the Safe, else
///      OwnerNotSafe; testnet: default the deployer); GANG_PAD_REGISTRY (re-run: deploy nothing, only check that
///      proxy); mainnet broadcast needs GANG_MAINNET_OK=true.
contract DeployGangPadRegistry is Script {
    error WrongChain(uint256 chainId);
    error MainnetNotAllowed();
    error WiringCheck(string what);
    error OwnerNotSafe(address owner);

    function run() external returns (G.Registry memory r) {
        bool mainnet = block.chainid == 56;
        if (!mainnet && block.chainid != 97) revert WrongChain(block.chainid);
        bool broadcasting =
            vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        if (mainnet && broadcasting && !vm.envOr("GANG_MAINNET_OK", false)) revert MainnetNotAllowed();

        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address pad = vm.envAddress("GANG_PAD");
        if (IGangPad(pad).wbnb() != (mainnet ? M.WBNB : T.WBNB)) revert WiringCheck("pad.wbnb");

        address owner = vm.envOr("OWNER", mainnet ? M.OWNER_SAFE : deployer);
        // mainnet: the registry and its upgrades belong to the platform Safe and nobody else
        if (mainnet && owner != M.OWNER_SAFE) revert OwnerNotSafe(owner);
        if (mainnet && owner.code.length == 0) revert WiringCheck("owner safe code");

        address[] memory pads = new address[](1);
        pads[0] = pad;

        address existing = vm.envOr("GANG_PAD_REGISTRY", address(0));
        if (existing != address(0)) {
            r = G.load(existing);
        } else {
            vm.startBroadcast(pk);
            r = G.deploy(owner, pads);
            vm.stopBroadcast();
        }
        G.check(r, owner, pads);
        GangPadRegistry g = GangPadRegistry(r.proxy);
        if (g.padOf(pad) != address(0)) revert WiringCheck("padOf(pad)");
        uint256 n = IGangPad(pad).tokenCount();
        if (n > 0) {
            address last = IGangPad(pad).allTokens(n - 1);
            if (g.padOf(last) != pad) revert WiringCheck("padOf(last token)");
        }

        console.log("=== DeployGangPadRegistry chain", block.chainid, "===");
        console.log("GANG_PAD", pad);
        console.log("GANG_PAD_REGISTRY (proxy: aggregators keep this address)", r.proxy);
        console.log("GANG_PAD_REGISTRY_IMPL", r.impl);
        console.log("GANG_PAD_REGISTRY_PROXY_ADMIN (owner below)", r.proxyAdmin);
        console.log("owner (addPad, upgrades)", owner);
    }
}
