// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

/// @notice Storage-layout snapshot of GangLaunchpad 3.0 (proxy storage), from the compiler's `storageLayout` output
///         (foundry.toml `extra_output`). Locks 0 = Ownable._owner, 1 = Ownable2Step._pendingOwner,
///         2 = ReentrancyGuard._status, then 3.0's variables from slot 3 (`_config` takes 3–6), and checks that the
///         well-formed next version (GangLaunchpad3V2Mock) appended its one new variable after the last one. Changing
///         the pad's layout must change this test on purpose. Pad3Module (delegatecalled from the pad's fallback) must
///         mirror the layout exactly.
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
        string memory a = "GangLaunchpad3.sol/GangLaunchpad3.json";
        Entry[] memory e = _layout(a);
        assertEq(e.length, 17, "seventeen entries");
        _v1(e);
        _structs(a, e);
    }

    function test_layout_nextVersionAppends() public view {
        string memory a = "GangLaunchpad3V2Mock.sol/GangLaunchpad3V2Mock.json";
        Entry[] memory e = _layout(a);
        assertEq(e.length, 18);
        _v1(e);
        _structs(a, e);
        _is(e[17], "v2Value", 20, "t_uint256");
    }

    /// @dev Pad3Module runs by delegatecall in the proxy's storage: it must declare exactly the pad's variables, in the
    ///      pad's order and types (struct members included), and nothing else (its own state is in ERC-7201 namespaces).
    function test_layout_moduleMirrorsPad() public view {
        Entry[] memory p = _layout("GangLaunchpad3.sol/GangLaunchpad3.json");
        Entry[] memory m = _layout("Pad3Module.sol/Pad3Module.json");
        assertEq(m.length, p.length, "same number of variables");
        for (uint256 i; i < p.length; i++) {
            assertEq(m[i].label, p[i].label, "label");
            assertEq(m[i].slot, p[i].slot, p[i].label);
            assertEq(m[i].offset, p[i].offset, p[i].label);
            assertEq(m[i].typ, p[i].typ, p[i].label);
        }
        _v1(m);
        _structs("Pad3Module.sol/Pad3Module.json", m);
    }

    /// @dev A next version with two struct members swapped (Curve: creator / quote; Config: pairFactory / migrator)
    ///      keeps every top-level slot, and is refused by the member check (audit 3C L-1 PoC).
    function test_layout_structReorderCaught() public {
        string memory a = "GangLaunchpad3StructReorderMock.sol/Pad3StructReorderMock.json";
        Entry[] memory e = _layout(a);
        _v1(e);
        vm.expectRevert();
        this.structsOf(a);
    }

    function structsOf(string memory artifact) external view {
        _structs(artifact, _layout(artifact));
    }

    // ---------------------------------------------------------------- struct members (audit 3C L-1)
    /// @dev Every member of the four stored structs: label, slot within the struct, byte offset, type. A reordered,
    ///      retyped or inserted member moves every existing token's record; only appending at the end is safe (and
    ///      `Config`, held inline at slots 3–6, has no room to grow: a new setting goes into a new variable).
    function _structs(string memory artifact, Entry[] memory e) internal view {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/out/", artifact));
        _members(
            json,
            e[3].typ,
            "Config",
            "pairFactory:0:0:t_address,v3Factory:1:0:t_address,twapWindow:1:20:t_uint32,migrator:2:0:t_address,"
            "agentIdRegistry:3:0:t_address,agentGateEnabled:3:20:t_bool,walletCapEnabled:3:21:t_bool"
        );
        _members(
            json,
            _valueType(json, e[7].typ),
            "Curve",
            "creator:0:0:t_address,quote:1:0:t_address,realQuote:2:0:t_uint128,sold:2:16:t_uint128,"
            "gradAmt:3:0:t_uint128,virtualQuote:3:16:t_uint128,graduated:4:0:t_bool,buyTaxBps:4:1:t_uint16,"
            "sellTaxBps:4:3:t_uint16,dividendBps:4:5:t_uint16,pair:4:7:t_address,refPair:5:0:t_address"
        );
        _members(
            json,
            _valueType(json, e[8].typ),
            "Sale",
            "creator:0:0:t_address,progressAt:0:20:t_uint64,capShares:0:28:t_uint16,holdBps:0:30:t_uint16,"
            "quote:1:0:t_address,sold:1:20:t_uint16,launched:1:22:t_bool,mintFeeBps:1:23:t_uint16,"
            "exitFeeBps:1:25:t_uint16,gate:2:0:t_address,sharePrice:3:0:t_uint128,pair:4:0:t_address,"
            "refPool:5:0:t_address,markSold:5:20:t_uint16"
        );
        _members(json, _valueType(json, _valueType(json, e[9].typ)), "Position", "shares:0:0:t_uint16");
    }

    function _valueType(string memory json, string memory mappingType) internal view returns (string memory) {
        return vm.parseJsonString(json, string.concat(".storageLayout.types['", mappingType, "'].value"));
    }

    /// @param want "label:slot:offset:type" per member, comma-separated, in declaration order
    function _members(string memory json, string memory typeKey, string memory name, string memory want) internal view {
        assertEq(vm.indexOf(typeKey, string.concat("t_struct(", name, ")")), 0, name);
        string memory k = string.concat(".storageLayout.types['", typeKey, "'].members");
        string[] memory w = vm.split(want, ",");
        assertFalse(vm.keyExistsJson(json, string.concat(k, "[", vm.toString(w.length), "]")), name);
        for (uint256 i; i < w.length; i++) {
            string memory m = string.concat(k, "[", vm.toString(i), "]");
            string memory got = string.concat(
                vm.parseJsonString(json, string.concat(m, ".label")),
                ":",
                vm.parseJsonString(json, string.concat(m, ".slot")),
                ":",
                vm.toString(vm.parseJsonUint(json, string.concat(m, ".offset"))),
                ":",
                vm.parseJsonString(json, string.concat(m, ".type"))
            );
            assertEq(got, w[i], name);
        }
    }
}
