// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {GangRouterDeployLib as R} from "./GangRouterDeployLib.sol";

/// @title Pad3CodeCheck — is a deployed contract exactly this build's code?
/// @notice Compares `a`'s runtime code with this build's artifact (`out/<file>/<name>.json`): the bytes at the
///         artifact's link references (library addresses) and immutable references (constructor-set values) are
///         taken from `a` (and returned, so the caller can check them), the library call-protection address
///         (a library's leading PUSH20, or via-IR's `library_deploy_address` immutable) likewise, and every Solidity metadata hash is masked (R.sameCode). Every other
///         byte must match. A look-alike with the same views but other code (a backdoor) fails.
library Pad3CodeCheck {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    struct Linked {
        string lib;
        address at;
    }

    /// @param artifact path under `out/`, e.g. "GangLaunchpad3.sol/GangLaunchpad3.json"
    /// @param isLibrary mask the first PUSH20 (a library's own address, written at deploy)
    /// @return ok the code matches
    /// @return libs the library each link reference points at in `a` (one entry per library; all references of a
    ///         library must point at the same address, else ok = false)
    function check(address a, string memory artifact, bool isLibrary)
        internal
        view
        returns (bool ok, Linked[] memory libs)
    {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/out/", artifact));
        bytes memory want = _hex(vm.parseJsonString(json, ".deployedBytecode.object"));
        bytes memory got = a.code;
        if (got.length != want.length || got.length == 0) return (false, libs);
        // legacy codegen: the library's own address is a leading PUSH20; via-IR: the `library_deploy_address`
        // immutable (masked with the other immutables below)
        if (isLibrary && got[0] == 0x73) _copy(got, want, 1, 20);
        (ok, libs) = _links(json, got, want);
        if (!ok) return (false, libs);
        _immutables(json, got, want);
        ok = R.sameCode(got, want);
    }

    function _links(string memory json, bytes memory got, bytes memory want)
        private
        view
        returns (bool ok, Linked[] memory libs)
    {
        string memory base = ".deployedBytecode.linkReferences";
        if (!vm.keyExistsJson(json, base)) return (true, libs);
        string[] memory files = vm.parseJsonKeys(json, base);
        uint256 n;
        for (uint256 i; i < files.length; i++) {
            n += vm.parseJsonKeys(json, string.concat(base, "['", files[i], "']")).length;
        }
        libs = new Linked[](n);
        uint256 k;
        for (uint256 i; i < files.length; i++) {
            string memory fk = string.concat(base, "['", files[i], "']");
            string[] memory names = vm.parseJsonKeys(json, fk);
            for (uint256 j; j < names.length; j++) {
                (bool one, address at) = _link(json, string.concat(fk, ".", names[j]), got, want);
                if (!one) return (false, libs);
                libs[k++] = Linked({lib: names[j], at: at});
            }
        }
        ok = true;
    }

    /// @dev One library's references at `lk`: all must hold the same address in `got`; copied into `want`.
    function _link(string memory json, string memory lk, bytes memory got, bytes memory want)
        private
        view
        returns (bool ok, address at)
    {
        for (uint256 r; vm.keyExistsJson(json, string.concat(lk, "[", vm.toString(r), "]")); r++) {
            uint256 start = vm.parseJsonUint(json, string.concat(lk, "[", vm.toString(r), "].start"));
            address here = _addrAt(got, start);
            if (r == 0) at = here;
            else if (here != at) return (false, at);
            _copy(got, want, start, 20);
        }
        ok = true;
    }

    function _addrAt(bytes memory b, uint256 start) private pure returns (address a) {
        assembly ("memory-safe") {
            a := shr(96, mload(add(add(b, 32), start)))
        }
    }

    function _immutables(string memory json, bytes memory got, bytes memory want) private view {
        string memory base = ".deployedBytecode.immutableReferences";
        if (!vm.keyExistsJson(json, base)) return;
        string[] memory ids = vm.parseJsonKeys(json, base);
        for (uint256 i; i < ids.length; i++) {
            string memory ik = string.concat(base, "['", ids[i], "']");
            for (uint256 r; vm.keyExistsJson(json, string.concat(ik, "[", vm.toString(r), "]")); r++) {
                uint256 start = vm.parseJsonUint(json, string.concat(ik, "[", vm.toString(r), "].start"));
                uint256 len = vm.parseJsonUint(json, string.concat(ik, "[", vm.toString(r), "].length"));
                _copy(got, want, start, len);
            }
        }
    }

    /// @return the library `name` points at in `libs` (address(0) if absent)
    function libAt(Linked[] memory libs, string memory name) internal pure returns (address) {
        for (uint256 i; i < libs.length; i++) {
            if (keccak256(bytes(libs[i].lib)) == keccak256(bytes(name))) return libs[i].at;
        }
        return address(0);
    }

    function _copy(bytes memory from, bytes memory to, uint256 start, uint256 len) private pure {
        for (uint256 i; i < len; i++) {
            to[start + i] = from[start + i];
        }
    }

    /// @dev "0x…" hex with link placeholders (`__$…$__`) read as zero bytes (they are overwritten from `got`).
    function _hex(string memory s) private pure returns (bytes memory out) {
        bytes memory b = bytes(s);
        uint256 off = (b.length >= 2 && b[0] == "0" && (b[1] == "x" || b[1] == "X")) ? 2 : 0;
        out = new bytes((b.length - off) / 2);
        for (uint256 i; i < out.length; i++) {
            out[i] = bytes1((_nib(b[off + 2 * i]) << 4) | _nib(b[off + 2 * i + 1]));
        }
    }

    function _nib(bytes1 c) private pure returns (uint8) {
        uint8 x = uint8(c);
        if (x >= 48 && x <= 57) return x - 48;
        if (x >= 97 && x <= 102) return x - 87;
        if (x >= 65 && x <= 70) return x - 55;
        return 0;
    }
}
