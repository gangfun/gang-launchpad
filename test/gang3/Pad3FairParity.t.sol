// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {GangLaunchpad} from "../../src/gang/GangLaunchpad.sol";
import {GangLaunchpad3} from "../../src/gang/GangLaunchpad3.sol";
import {FairMintTest} from "../fair-mint/FairMint.t.sol";
import {FairMintAuditTest} from "../fair-mint/FairMintAudit.t.sol";
import {FlowReviewFixesTest} from "../fair-mint/FlowReviewFixes.t.sol";

/// @notice The 打新 suites of 2.0, re-run on GangLaunchpad 3.0 (same tests, same expectations).
contract FairMint3Test is FairMintTest {
    function _newFairPad() internal override returns (GangLaunchpad) {
        GangLaunchpad3 impl = new GangLaunchpad3(
            address(registry),
            address(vault),
            address(bucket),
            address(handler),
            address(tokenDeployer),
            address(wbnb),
            makeAddr("padRegistry")
        );
        return GangLaunchpad(
            address(
                new TransparentUpgradeableProxy(
                    address(impl),
                    makeAddr("upgrader"),
                    abi.encodeCall(GangLaunchpad3.initialize, (owner, address(factory)))
                )
            )
        );
    }
}

contract FairMintAudit3Test is FairMintAuditTest {
    function _newFairPad() internal override returns (GangLaunchpad) {
        GangLaunchpad3 impl = new GangLaunchpad3(
            address(registry),
            address(vault),
            address(bucket),
            address(handler),
            address(tokenDeployer),
            address(wbnb),
            makeAddr("padRegistry")
        );
        return GangLaunchpad(
            address(
                new TransparentUpgradeableProxy(
                    address(impl),
                    makeAddr("upgrader"),
                    abi.encodeCall(GangLaunchpad3.initialize, (owner, address(factory)))
                )
            )
        );
    }
}

contract FlowReviewFixes3Test is FlowReviewFixesTest {
    function _newFairPad() internal override returns (GangLaunchpad) {
        GangLaunchpad3 impl = new GangLaunchpad3(
            address(registry),
            address(vault),
            address(bucket),
            address(handler),
            address(tokenDeployer),
            address(wbnb),
            makeAddr("padRegistry")
        );
        return GangLaunchpad(
            address(
                new TransparentUpgradeableProxy(
                    address(impl),
                    makeAddr("upgrader"),
                    abi.encodeCall(GangLaunchpad3.initialize, (owner, address(factory)))
                )
            )
        );
    }
}
