// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {GangMainnetRefs as M, GangTestnetRefs as T} from "../config/GangDeployRefs.sol";
import {IGangPad} from "../src/gang/interfaces/IGangPad.sol";
import {GangPadRegistry} from "../src/gang/GangPadRegistry.sol";

interface IOwnableLike {
    function owner() external view returns (address);
}

/// @title GangModulePadScript — which pad a module deploy (handler admin, factories, GangBond) binds to
/// @notice Each of these binds to one pad for good. 1.0's modules are deployed (review them at the commit that
///         deployed them). On mainnet they now bind only to GangLaunchpad 2.0, read from GANG_PAD2: in the shell of a
///         2.0 deploy, GANG_PAD is 1.0, and a leftover value must not bind a new module to it (audit 2026-10-31 L-3).
/// @dev Mainnet: GANG_PAD2 must be a 2.0 pad (CREATOR_FEE_SHARE_BPS 7000), not 1.0, registered in the live pad
///      registry and owned by the Safe (so after Safe batch 2). Testnet: GANG_PAD2, else GANG_PAD, a pad over the
///      testnet WBNB.
abstract contract GangModulePadScript is Script {
    address internal constant MAINNET_PAD_1 = 0x15CFD2dc8278Fb87a1783ef42111618E20874365;

    function _modulePad(bool mainnet) internal view returns (address pad) {
        if (!mainnet) {
            pad = vm.envOr("GANG_PAD2", address(0));
            if (pad == address(0)) pad = vm.envAddress("GANG_PAD");
            if (IGangPad(pad).wbnb() != T.WBNB) revert ModulePad("pad");
            return pad;
        }
        pad = vm.envAddress("GANG_PAD2");
        if (pad == MAINNET_PAD_1 || pad.code.length == 0) revert ModulePad("GANG_PAD2 is not GangLaunchpad 2.0");
        try IGangPad(pad).CREATOR_FEE_SHARE_BPS() returns (uint256 bps) {
            if (bps != 7_000) revert ModulePad("pad.CREATOR_FEE_SHARE_BPS");
        } catch {
            revert ModulePad("GANG_PAD2 is not GangLaunchpad 2.0");
        }
        if (!GangPadRegistry(M.PAD_REGISTRY).isPad(pad)) revert ModulePad("pad not in the registry");
        if (IOwnableLike(pad).owner() != M.OWNER_SAFE) revert ModulePad("pad not owned by the Safe");
    }

    error ModulePad(string what);
}
