// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Offline salt search for scripts and fork tests. Never linked into the pad.
library Pad3VanitySalt {
    function find(address factory, address creator, bytes32 initHash)
        internal
        view
        returns (bytes32 salt, address predicted)
    {
        bytes memory buffer = new bytes(85);
        for (uint256 i;; i++) {
            uint256 hash;
            assembly ("memory-safe") {
                let ptr := add(buffer, 32)
                mstore(ptr, creator)
                mstore(add(ptr, 32), i)
                let boundSalt := keccak256(ptr, 64)
                mstore(ptr, shl(248, 0xff))
                mstore(add(ptr, 1), shl(96, factory))
                mstore(add(ptr, 21), boundSalt)
                mstore(add(ptr, 53), initHash)
                hash := keccak256(ptr, 85)
            }
            if (uint16(hash) == 0xabcd && address(uint160(hash)).code.length == 0) {
                return (bytes32(i), address(uint160(hash)));
            }
        }
    }
}
