// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {Launchpad} from "../src/Launchpad.sol";
import {Migrator} from "../src/Migrator.sol";

/// Launchpad v4 mainnet/test deploy.
/// Required env: DEPLOYER_PRIVATE_KEY, FEE_VAULT (opsTreasury / 20% sink)
/// Optional: OWNER (defaults to deployer), PLATFORM_NAME (default Gang), PLATFORM_SYMBOL (default GANG)
///
/// forge script script/Deploy.s.sol --rpc-url $BSC_RPC --broadcast [--verify]
contract Deploy is Script {
    address constant PANCAKE_V2_FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address constant PANCAKE_V2_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant AGENT_ID = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F; // SPACE ID Agent ID (.ai)

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address vault = vm.envAddress("FEE_VAULT");
        address owner = vm.envOr("OWNER", vm.addr(pk));
        string memory name_ = vm.envOr("PLATFORM_NAME", string("Gang"));
        string memory symbol_ = vm.envOr("PLATFORM_SYMBOL", string("GANG"));

        vm.startBroadcast(pk);
        Launchpad pad = new Launchpad(owner, vault, AGENT_ID);
        Migrator migrator = new Migrator(PANCAKE_V2_FACTORY, WBNB, address(pad));
        pad.setMigrator(address(migrator));
        pad.setPancakeRouter(PANCAKE_V2_ROUTER);
        address gang = pad.seedPlatformToken(name_, symbol_);
        vm.stopBroadcast();

        console.log("Launchpad:", address(pad));
        console.log("Migrator: ", address(migrator));
        console.log("GANG:     ", gang);
        console.log("Router:   ", PANCAKE_V2_ROUTER);
        console.log("FeeVault: ", vault);
        console.log("Owner:    ", owner);
    }
}
