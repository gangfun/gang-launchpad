// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Pad3BaseStore — GangLaunchpad 3.0's opening base state (docs/SPEC-BASE-VAULT-V2-2026-11-12.md), in its own
///        ERC-7201 namespace
/// @notice Written only by Pad3Module (`setBaseVaultImpl`, `createWithBase`), running in the proxy's storage.
///         UPGRADES: members are only ever appended at the end (never reordered, retyped or removed) and SLOT never
///         changes; test/gang3/Pad3Base.t.sol pins both.
library Pad3BaseStore {
    /// @custom:storage-location erc7201:gang.pad3.base
    struct Layout {
        /// @dev the GangBaseVault implementation new base vaults are cloned from; 0 = createWithBase closed
        address vaultImpl;
        /// @dev the token's base vault, written once at its create
        mapping(address token => address) vaultOf;
        /// @dev the tokens the base vault bought at create
        mapping(address token => uint256) baseOf;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("gang.pad3.base")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant SLOT = 0xdc89c1b6d1129f3b85e599aa83f55f4c7dd08fd098d37bcd26d64f6effeca700;

    function layout() internal pure returns (Layout storage l) {
        bytes32 s = SLOT;
        assembly ("memory-safe") {
            l.slot := s
        }
    }
}
