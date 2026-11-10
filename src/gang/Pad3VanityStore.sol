// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IGangLaunchpad} from "./interfaces/IGangLaunchpad.sol";

/// @dev Separate from the pad's frozen linear layout. The launch context is cleared before returning.
library Pad3VanityStore {
    bytes32 internal constant SLOT =
        keccak256(abi.encode(uint256(keccak256("gang.pad3.vanity")) - 1)) & ~bytes32(uint256(0xff));

    struct Layout {
        address deployer;
        bytes32 salt;
        bool active;
    }

    function layout() internal pure returns (Layout storage s) {
        bytes32 slot = SLOT;
        assembly ("memory-safe") {
            s.slot := slot
        }
    }

    /// @dev Select the factory only when creating: existing trade paths keep their original dependencies and gas.
    function creationDeps(IGangLaunchpad.Deps memory d) internal view returns (IGangLaunchpad.Deps memory) {
        address deployer = layout().deployer;
        if (deployer != address(0)) d.tokenDeployer = deployer;
        return d;
    }
}
