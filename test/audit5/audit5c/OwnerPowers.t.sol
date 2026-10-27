// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {LaunchpadV3Test} from "../../launchpad-v3/LaunchpadV3.t.sol";
import {GangLaunchpad as LaunchpadV3} from "../../../src/gang/GangLaunchpad.sol";
import {IGangLaunchpad} from "../../../src/gang/interfaces/IGangLaunchpad.sol";
import {SharedDividendVault} from "../../../src/common/SharedDividendVault.sol";

/// @notice Internal audit 5 C owner-power PoCs, turned into regressions.
contract Audit5cOwnerPowers is LaunchpadV3Test {
    /// C-F4: a V3 floor raised above TAXED_MIN_SHARE no longer creates a dividend token with no shareholders (whose
    /// holders' tax would all go elsewhere): create refuses it, as FairMintPad does.
    function test_audit5c_v3FloorAboveMaxRefusesCreate() public {
        vm.prank(owner);
        divVault.setMinimumShareBalance(address(pad), type(uint256).max);
        vm.prank(agent);
        vm.expectRevert(IGangLaunchpad.VaultFloorTooHigh.selector);
        pad.create("T", "T", "", "", address(0), address(0), _tax(500, 500, 10_000, address(0)));
        // a token without dividends doesn't use the floor
        _create(_tax(500, 500, 0, treasury));
    }

    /// C-F5: the vault owner can no longer exclude wallets to steer every future dividend to chosen holders; only
    /// contracts (pools, lockers) can be excluded.
    function test_audit5c_excludeOnlyContracts() public {
        address t = _create(_tax(500, 500, 10_000, address(0)));
        vm.prank(agent);
        pad.buy(t, 0.01 ether, 0);
        vm.prank(agent2);
        pad.buy(t, 0.01 ether, 0);
        vm.prank(owner);
        vm.expectRevert(SharedDividendVault.NotAContract.selector);
        divVault.setExcluded(agent2, true);
        vm.prank(owner);
        divVault.setExcluded(address(this), true); // a contract: allowed
        vm.prank(owner);
        divVault.setExcluded(address(this), false); // un-excluding is free
        assertGt(divVault.shares(t, agent2), 0);
    }
}
