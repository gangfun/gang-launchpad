// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {GangModulePadScript} from "./GangModulePadScript.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {GangMainnetRefs as M, GangTestnetRefs as T} from "../config/GangDeployRefs.sol";
import {IGangPad} from "../src/gang/interfaces/IGangPad.sol";
import {GangBond} from "../src/gang/GangBond.sol";

/// @title DeployGangBond — the Agent 押金承诺 contract for an existing GangLaunchpad
/// @notice One contract, no owner, nothing to wire: GangBond only reads the pad and the tokens and trades with their
///         pairs, so the pad, vault and tax handler are left as they are. Checks the pad's WBNB and prints the address
///         for the CLI (GANG_BOND / GANG_TESTNET_BOND) and the server's indexer.
/// @dev Env: DEPLOYER_PRIVATE_KEY, the pad (GangModulePadScript: mainnet GANG_PAD2, a 2.0 pad owned by the Safe; testnet GANG_PAD2 or GANG_PAD); GANG_BOND (re-run: deploy nothing, only check that one); mainnet broadcast
///      needs GANG_MAINNET_OK=true.
contract DeployGangBond is GangModulePadScript {
    error WrongChain(uint256 chainId);
    error MainnetNotAllowed();
    error WiringCheck(string what);

    function run() external returns (GangBond bond) {
        bool mainnet = block.chainid == 56;
        if (!mainnet && block.chainid != 97) revert WrongChain(block.chainid);
        bool broadcasting =
            vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
        if (mainnet && broadcasting && !vm.envOr("GANG_MAINNET_OK", false)) revert MainnetNotAllowed();

        address pad = _modulePad(mainnet); // GangBond binds to one pad for good
        address wbnb = mainnet ? M.WBNB : T.WBNB;
        if (IGangPad(pad).wbnb() != wbnb) revert WiringCheck("pad.wbnb");

        address existing = vm.envOr("GANG_BOND", address(0));
        if (existing != address(0)) {
            bond = GangBond(existing);
        } else {
            vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
            bond = new GangBond(pad, wbnb);
            vm.stopBroadcast();
        }

        if (bond.pad() != pad) revert WiringCheck("bond.pad");
        if (bond.wbnb() != wbnb) revert WiringCheck("bond.wbnb");
        console.log("GangBond", address(bond));
        console.log("  pad   ", pad);
        console.log("  block ", block.number);
    }
}
