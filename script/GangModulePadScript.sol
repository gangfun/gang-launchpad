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
/// @notice Each of these binds to one pad for good. 1.0's and 2.0's modules are deployed (review them at the commit
///         that deployed them). On mainnet they bind only to GangLaunchpad 3.0 (GANG_PAD3) or 2.0 (GANG_PAD2), never
///         to 1.0: in the shell of a 2.0 / 3.0 deploy, GANG_PAD is 1.0, and a leftover value must not bind a new module
///         to it (audit 2026-10-31 L-3). Set one of GANG_PAD3 / GANG_PAD2, not both.
/// @dev Mainnet: GANG_PAD3 must be the 3.0 proxy; GANG_PAD2 a 2.0 pad (CREATOR_FEE_SHARE_BPS 7000), not 1.0, 3.0 or
///      the vault pad (registered, Safe-owned and with 2.0's creator share, it would pass the other checks). Either
///      registered in the live pad registry and owned by the Safe. Testnet: GANG_PAD3, else GANG_PAD2, else
///      GANG_PAD, a pad over the testnet WBNB.
abstract contract GangModulePadScript is Script {
    address internal constant MAINNET_PAD_1 = 0x15CFD2dc8278Fb87a1783ef42111618E20874365;
    /// @dev GangVaultLaunchpad (docs/MAINNET-GANG-VAULT-LAUNCHPAD-2026-11-02.md): 2.0's rules, not a 2.0 to bind to
    address internal constant MAINNET_VAULT_PAD = 0xE90851A90C6278E3d6e4C24320101f8B13D90A11;
    /// @dev GangLaunchpad 3.0 (proxy, the permanent address; docs/MAINNET-GANG-LAUNCHPAD-3-2026-11-03.md)
    address internal constant MAINNET_PAD_3 = 0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29;

    function _modulePad(bool mainnet) internal view returns (address pad) {
        address pad3 = vm.envOr("GANG_PAD3", address(0));
        address pad2 = vm.envOr("GANG_PAD2", address(0));
        if (pad3 != address(0) && pad2 != address(0)) revert ModulePad("set GANG_PAD3 or GANG_PAD2, not both");
        if (!mainnet) {
            pad = pad3 != address(0) ? pad3 : pad2;
            if (pad == address(0)) pad = vm.envAddress("GANG_PAD");
            if (IGangPad(pad).wbnb() != T.WBNB) revert ModulePad("pad");
            return pad;
        }
        if (pad3 != address(0)) {
            if (pad3 != MAINNET_PAD_3) revert ModulePad("GANG_PAD3 is not GangLaunchpad 3.0");
            pad = pad3;
        } else {
            pad = pad2;
            if (pad == MAINNET_PAD_1 || pad == MAINNET_PAD_3 || pad == MAINNET_VAULT_PAD || pad.code.length == 0) {
                revert ModulePad("GANG_PAD2 is not GangLaunchpad 2.0");
            }
            try IGangPad(pad).CREATOR_FEE_SHARE_BPS() returns (uint256 bps) {
                if (bps != 7_000) revert ModulePad("pad.CREATOR_FEE_SHARE_BPS");
            } catch {
                revert ModulePad("GANG_PAD2 is not GangLaunchpad 2.0");
            }
        }
        if (!GangPadRegistry(M.PAD_REGISTRY).isPad(pad)) revert ModulePad("pad not in the registry");
        if (IOwnableLike(pad).owner() != M.OWNER_SAFE) revert ModulePad("pad not owned by the Safe");
    }

    error ModulePad(string what);
}
