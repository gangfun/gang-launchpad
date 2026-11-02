// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

/// @notice Storage-layout snapshot of GangLaunchpad 3.0 (proxy storage), from the compiler's `storageLayout` output
///         (foundry.toml `extra_output`). Locks 0 = Ownable._owner, 1 = Ownable2Step._pendingOwner,
///         2 = ReentrancyGuard._status, then 3.0's variables from slot 3 (`_config` takes 3–6), and checks that the
///         well-formed next version (GangLaunchpad3V2Mock) appended its one new variable after the last one. Changing
///         the pad's layout must change this test on purpose.
contract GangLaunchpad3LayoutTest is Test {
    struct Entry {
        string label;
        uint256 slot;
        uint256 offset;
        string typ;
    }

    function _layout(string memory artifact) internal view returns (Entry[] memory e) {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/out/", artifact));
        uint256 n;
        while (vm.keyExistsJson(json, string.concat(".storageLayout.storage[", vm.toString(n), "]"))) n++;
        e = new Entry[](n);
        for (uint256 i; i < n; i++) {
            string memory k = string.concat(".storageLayout.storage[", vm.toString(i), "]");
            e[i].label = vm.parseJsonString(json, string.concat(k, ".label"));
            e[i].slot = vm.parseUint(vm.parseJsonString(json, string.concat(k, ".slot")));
            e[i].offset = vm.parseJsonUint(json, string.concat(k, ".offset"));
            e[i].typ = vm.parseJsonString(json, string.concat(k, ".type"));
        }
    }

    function _is(Entry memory e, string memory label, uint256 slot, string memory typ) internal pure {
        assertEq(e.label, label, "label");
        assertEq(e.slot, slot, label);
        assertEq(e.offset, 0, label);
        assertEq(vm.indexOf(e.typ, typ), 0, label);
    }

    function _v1(Entry[] memory e) internal pure {
        _is(e[0], "_owner", 0, "t_address");
        _is(e[1], "_pendingOwner", 1, "t_address");
        _is(e[2], "_status", 2, "t_uint256");
        _is(e[3], "_config", 3, "t_struct(Config)");
        _is(e[4], "bridgePoolOf", 7, "t_mapping(t_address,t_address)");
        _is(e[5], "routers", 8, "t_mapping(t_address,t_bool)");
        _is(e[6], "kindOf", 9, "t_mapping(t_address,t_uint8)");
        _is(e[7], "curves", 10, "t_mapping(t_address,t_struct(Curve)");
        _is(e[8], "sales", 11, "t_mapping(t_address,t_struct(Sale)");
        _is(e[9], "positions", 12, "t_mapping(t_address,t_mapping(t_address,t_struct(Position)");
        _is(e[10], "logoURIOf", 13, "t_mapping(t_address,t_string_storage)");
        _is(e[11], "owedFee", 14, "t_mapping(t_address,t_uint256)");
        _is(e[12], "allTokens", 15, "t_array(t_address)dyn_storage");
        _is(e[13], "creatorFeeOf", 16, "t_mapping(t_address,t_uint256)");
        _is(e[14], "gradTargetOf", 17, "t_mapping(t_address,t_uint256)");
        _is(e[15], "tokenVersionOf", 18, "t_mapping(t_address,t_uint8)");
        _is(e[16], "isCaller", 19, "t_mapping(t_address,t_bool)");
    }

    function test_layout_v1() public view {
        Entry[] memory e = _layout("GangLaunchpad3.sol/GangLaunchpad3.json");
        assertEq(e.length, 17, "seventeen entries");
        _v1(e);
    }

    function test_layout_nextVersionAppends() public view {
        Entry[] memory e = _layout("GangLaunchpad3V2Mock.sol/GangLaunchpad3V2Mock.json");
        assertEq(e.length, 18);
        _v1(e);
        _is(e[17], "v2Value", 20, "t_uint256");
    }
}
