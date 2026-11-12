// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {GangBaseVault} from "../src/gang/GangBaseVault.sol";

/// @notice Deploy only the base vault implementation (docs/SPEC-BASE-VAULT-V2-2026-11-12.md §8 step 1), its pad fixed
///         to GANG_PAD3. Then run UpgradeGangLaunchpad3 with PAD3_BASE_VAULT_IMPL set to its address: that script
///         checks its code against this build, simulates `setBaseVaultImpl` after the upgrade, and appends it to the
///         owner batch. Nothing uses the implementation until that call.
contract DeployGangBaseVault is Script {
    function run() external returns (address impl) {
        if (block.chainid == 56) require(vm.envOr("GANG_MAINNET_OK", false), "GANG_MAINNET_OK");
        address pad = vm.envAddress("GANG_PAD3");
        require(pad.code.length != 0, "GANG_PAD3 has no code");
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        impl = address(new GangBaseVault(pad));
        vm.stopBroadcast();
        console.log("PAD3_BASE_VAULT_IMPL", impl);
    }
}
