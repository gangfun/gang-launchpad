// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeployGangSwap} from "../script/DeployGangSwap.s.sol";
import {GangSwapMigrator} from "../src/GangSwapMigrator.sol";
import {IGangSwapFactory} from "../src/interfaces/IGangSwap.sol";
import {MockWBNB, MockBucket} from "./Mocks.sol";

/// @dev The deploy script's checks pass on a fresh chain: predicted addresses, wired(), router wiring, init code hash.
contract DeployGangSwapTest is Test {
    function test_deployScript() public {
        MockWBNB wbnb = new MockWBNB();
        MockBucket bucket = new MockBucket();
        address owner = makeAddr("safe");
        vm.setEnv("GANGSWAP_OWNER", vm.toString(owner));
        vm.setEnv("WBNB", vm.toString(address(wbnb)));
        vm.setEnv("FEE_BUCKET", vm.toString(address(bucket)));
        DeployGangSwap s = new DeployGangSwap();
        (address migrator,,, address factory,) = s.run();
        assertTrue(GangSwapMigrator(migrator).wired());
        assertEq(GangSwapMigrator(migrator).owner(), owner);
        assertEq(s.routerInitHash(), IGangSwapFactory(factory).INIT_CODE_PAIR_HASH());
    }
}
