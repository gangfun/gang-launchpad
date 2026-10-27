// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

/// @notice Storage-layout snapshot of the upgradeable router, read from the compiler's own `storageLayout` output
///         (foundry.toml `extra_output`, the same data `forge inspect GangRouter storageLayout` prints). It locks
///         slot 0 = ReentrancyGuard._status, 1–3 = pad / wbnb / pancakeRouter, 4–50 = __gap (47), and checks that
///         the well-formed next version (GangRouterV2Mock) took its one new slot from the gap: 4 = v2Value,
///         5–50 = __gap (46). Changing the router's layout must change this test on purpose.
contract GangRouterLayoutTest is Test {
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
        // contract types carry the compiler's AST id: compare the prefix
        assertEq(vm.indexOf(e.typ, typ), 0, label);
    }

    function test_layout_v1() public view {
        Entry[] memory e = _layout("GangRouter.sol/GangRouter.json");
        assertEq(e.length, 5, "five entries");
        _is(e[0], "_status", 0, "t_uint256");
        _is(e[1], "pad", 1, "t_contract(IGangPadEntry)");
        _is(e[2], "wbnb", 2, "t_address");
        _is(e[3], "pancakeRouter", 3, "t_contract(IPancakeV2Router)");
        _is(e[4], "__gap", 4, "t_array(t_uint256)47_storage");
        // 4 + 47 = 51 slots in all
    }

    function test_layout_v2FollowsTheGapRule() public view {
        Entry[] memory v1 = _layout("GangRouter.sol/GangRouter.json");
        Entry[] memory v2 = _layout("GangRouterV2Next.sol/GangRouterV2Mock.json");
        assertEq(v2.length, 6);
        for (uint256 i; i < 4; i++) {
            assertEq(v2[i].label, v1[i].label, "same variable");
            assertEq(v2[i].slot, v1[i].slot, "same slot");
        }
        _is(v2[4], "v2Value", 4, "t_uint256");
        _is(v2[5], "__gap", 5, "t_array(t_uint256)46_storage");
    }
}
