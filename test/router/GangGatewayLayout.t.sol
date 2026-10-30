// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

/// @notice Storage-layout snapshot of the upgradeable gateway, read from the compiler's `storageLayout` output (as
///         GangRouterLayoutTest): slot 0 = ReentrancyGuard._status, 1–2 = registry / wbnb, 3–5 = owner /
///         pendingOwner / isCaller, 6–49 = __gap (44).
///         Changing the gateway's layout must change this test on purpose.
contract GangGatewayLayoutTest is Test {
    function test_layout_v1() public view {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/out/GangGateway.sol/GangGateway.json"));
        string[7] memory labels = ["_status", "registry", "wbnb", "owner", "pendingOwner", "isCaller", "__gap"];
        string[7] memory types = [
            "t_uint256",
            "t_contract(IGangPadRegistry)",
            "t_address",
            "t_address",
            "t_address",
            "t_mapping(t_address,t_bool)",
            "t_array(t_uint256)44_storage"
        ];
        uint256[7] memory slots = [uint256(0), 1, 2, 3, 4, 5, 6];
        assertFalse(vm.keyExistsJson(json, ".storageLayout.storage[7]"), "seven entries");
        for (uint256 i; i < 7; i++) {
            string memory k = string.concat(".storageLayout.storage[", vm.toString(i), "]");
            assertEq(vm.parseJsonString(json, string.concat(k, ".label")), labels[i], "label");
            assertEq(vm.parseUint(vm.parseJsonString(json, string.concat(k, ".slot"))), slots[i], labels[i]);
            assertEq(vm.parseJsonUint(json, string.concat(k, ".offset")), 0, labels[i]);
            // contract types carry the compiler's AST id: compare the prefix
            assertEq(vm.indexOf(vm.parseJsonString(json, string.concat(k, ".type")), types[i]), 0, labels[i]);
        }
    }
}
