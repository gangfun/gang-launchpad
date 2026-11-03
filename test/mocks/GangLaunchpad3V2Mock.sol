// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {GangLaunchpad3} from "../../src/gang/GangLaunchpad3.sol";

/// @dev A well-formed next version of GangLaunchpad 3.0 (test only): same inheritance, every 3.0 variable in place,
///      one new variable appended after the last one and set by `reinitializer(2)` through
///      ProxyAdmin.upgradeAndCall. GangLaunchpad3Layout.t.sol checks it follows the append rule;
///      GangLaunchpad3.t.sol upgrades a live proxy to it and checks nothing of 3.0's state moved.
contract GangLaunchpad3V2Mock is GangLaunchpad3 {
    uint256 public v2Value;

    constructor(
        address quoteRegistry_,
        address dividendVault_,
        address platformBucket_,
        address taxHandler_,
        address tokenDeployer_,
        address wbnb_,
        address padRegistry_
    )
        GangLaunchpad3(
            quoteRegistry_, dividendVault_, platformBucket_, taxHandler_, tokenDeployer_, wbnb_, padRegistry_
        )
    {}

    function initializeV2(uint256 v) external reinitializer(2) {
        v2Value = v;
    }

    function initVersion() external pure override returns (uint64) {
        return 2;
    }
}
