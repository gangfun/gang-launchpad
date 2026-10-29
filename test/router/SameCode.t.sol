// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {TokenDeployer} from "../../src/common/TokenDeployer.sol";
import {GangRouter} from "../../src/router/GangRouter.sol";
import {GangRouterDeployLib as R} from "../../script/GangRouterDeployLib.sol";

/// @notice R.sameCode: equal code with every Solidity metadata hash masked (the trailing one and the one inside
///         TokenDeployer's embedded GangToken creation code); any other byte that differs fails. The fork case reads
///         the live mainnet contracts the deploy checks compare (needs BSC_RPC_URL, skipped without it).
contract SameCodeTest is Test {
    /// @dev The first IPFS metadata marker at or after `from` (type(uint256).max if none).
    function _marker(bytes memory code, uint256 from) internal pure returns (uint256) {
        for (uint256 i = from; i + 42 <= code.length; i++) {
            bytes10 m;
            assembly {
                m := mload(add(add(code, 32), i))
            }
            if (m == R.METADATA_IPFS) return i;
        }
        return type(uint256).max;
    }

    function _copy(bytes memory b) internal pure returns (bytes memory) {
        return bytes.concat(b);
    }

    function test_sameCode_metadataHashesOnly() public pure {
        bytes memory want = type(TokenDeployer).runtimeCode;
        uint256 embedded = _marker(want, 0);
        uint256 trailing = _marker(want, embedded + 42);
        assertLt(embedded, trailing, "two metadata blocks: GangToken's and TokenDeployer's");
        assertEq(_marker(want, trailing + 42), type(uint256).max);

        assertTrue(R.sameCode(_copy(want), want), "identical");
        bytes memory got = _copy(want);
        got[embedded + 10] ^= 0xff; // embedded hash
        got[trailing + 41] ^= 0xff; // trailing hash
        assertTrue(R.sameCode(got, want), "hashes masked");
        assertEq(keccak256(want), keccak256(type(TokenDeployer).runtimeCode), "inputs untouched");
    }

    function test_sameCode_anyOtherByteFails() public pure {
        bytes memory want = type(TokenDeployer).runtimeCode;
        uint256 embedded = _marker(want, 0);
        uint256[5] memory at = [uint256(0), 100, embedded - 1, embedded + 42, want.length - 1];
        for (uint256 i; i < at.length; i++) {
            bytes memory got = _copy(want);
            got[at[i]] ^= 0x01;
            assertFalse(R.sameCode(got, want), "a code byte");
        }
        bytes memory noMarker = _copy(want);
        noMarker[embedded] ^= 0x01; // the marker itself: the hash after it is no longer masked
        assertFalse(R.sameCode(noMarker, want), "marker");
        assertFalse(R.sameCode(bytes.concat(want, hex"00"), want), "length");
        assertFalse(R.sameCode(hex"", hex"00"), "empty");
        assertTrue(R.sameCode(hex"", hex""), "both empty");
    }

    /// @dev The live mainnet contracts were built from another source set: their metadata hashes differ from this
    ///      build's, their code does not.
    function test_fork_sameCode_mainnet() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) vm.skip(true);
        vm.createSelectFork(rpc);
        address router = 0xE040445690Aa56C8b68B7f7038C7b2562B5079C4;
        address admin = R.adminOf(router);
        address tokenDeployer = 0x3A5432c562BcA145Faf21ef956C475c670d14558;
        address timelock = ProxyAdmin(admin).owner();

        assertTrue(tokenDeployer.codehash != keccak256(type(TokenDeployer).runtimeCode), "strict hash would fail");
        assertTrue(R.sameCode(tokenDeployer, type(TokenDeployer).runtimeCode), "TokenDeployer");
        assertTrue(R.sameCode(R.implementationOf(router), type(GangRouter).runtimeCode), "GangRouter impl");
        assertTrue(R.sameCode(admin, type(ProxyAdmin).runtimeCode), "ProxyAdmin");
        assertTrue(R.sameCode(timelock, type(TimelockController).runtimeCode), "timelock");
        assertFalse(R.sameCode(admin, type(TimelockController).runtimeCode), "another contract");
    }
}
