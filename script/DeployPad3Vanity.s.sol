// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {GangLaunchpad3} from "../src/gang/GangLaunchpad3.sol";
import {Pad3Module} from "../src/gang/Pad3Module.sol";
import {Pad3FlyModule} from "../src/gang/Pad3FlyModule.sol";
import {Pad3VanityDeployer} from "../src/gang/Pad3VanityDeployer.sol";

/// @notice Deploy only the abcd factory. Then run UpgradeGangLaunchpad3 with PAD3_ABCD_DEPLOYER set to its address:
///         that script checks its code and references, simulates activation, and appends it to the owner batch.
contract DeployPad3Vanity is Script {
    function run() external returns (address deployer) {
        if (block.chainid == 56) require(vm.envOr("GANG_MAINNET_OK", false), "GANG_MAINNET_OK");
        GangLaunchpad3 p = GangLaunchpad3(payable(vm.envAddress("GANG_PAD3")));
        address oldMint = Pad3FlyModule(Pad3Module(payable(p.module())).flyModule()).flyTokenDeployer();
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        deployer = address(new Pad3VanityDeployer(address(p), p.tokenDeployer(), oldMint));
        vm.stopBroadcast();
        console.log("PAD3_ABCD_DEPLOYER", deployer);
    }
}
