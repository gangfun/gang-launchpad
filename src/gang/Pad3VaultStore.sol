// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Pad3VaultStore — GangLaunchpad 3.0's vault-mode state, in its own ERC-7201 namespace
/// @notice Shared by the pad (the 1% cap counts `lockedOf`, a token's vault never trades it, an address ever listed as
///         a vault never becomes a router) and Pad3Module (the vault entries), both running in the proxy's storage.
///         A namespace instead of appended variables: the module mirrors the pad's sequential layout, and anything new
///         stays out of it. UPGRADES: members are only ever appended at the end (never reordered, retyped or removed)
///         and SLOT never changes; test/gang3/Pad3Vault.t.sol pins both (the compiler's storage layout doesn't show
///         namespaces).
library Pad3VaultStore {
    /// @custom:storage-location erc7201:gang.pad3.vault
    struct Layout {
        /// @dev listed vaults (may bind new tokens, may lock)
        mapping(address vault => bool) isVault;
        /// @dev the vault each vault-bound curve token was created with, fixed for good (0 = none)
        mapping(address token => address) vaultOf;
        /// @dev what `user` locked into `token`'s vault (counted against `user`'s 1% with the wallet balance)
        mapping(address token => mapping(address user => uint256)) lockedOf;
        /// @dev ever listed as a vault (never cleared): such an address can never become a router
        mapping(address vault => bool) everVault;
        /// @dev the wallet the owner named to create the next token bound to `vault` (single use)
        mapping(address vault => address) vaultCreator;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("gang.pad3.vault")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant SLOT = 0x6960426a3a4d672de9297267c6a28e6cf58ed750fc4f11036069865c18f91100;

    function layout() internal pure returns (Layout storage l) {
        bytes32 s = SLOT;
        assembly ("memory-safe") {
            l.slot := s
        }
    }
}
