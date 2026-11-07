// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Pad3PromoteStore — GangLaunchpad 3.0's promoter share state, in its own ERC-7201 namespace
/// @notice Shared by CurveLogic3 (every curve trade reads the terms; a token with a promoter share also books the
///         binding and the fee) and Pad3Module (the create, the buy that names a promoter, the claim and the views), all
///         running in the proxy's storage. UPGRADES: members
///         are only ever appended at the end (never reordered, retyped or removed) and SLOT never changes;
///         test/gang3/Pad3Promote.t.sol pins both.
library Pad3PromoteStore {
    /// @dev A token's terms, fixed at its create (`shareBps` 0 = no promoter share).
    struct Terms {
        /// @dev the promoter's part of the creator's fee
        uint16 shareBps;
        /// @dev how long, from the binding, a bound wallet's trades pay the promoter (seconds)
        uint32 window;
    }

    /// @dev One wallet on one token. Written only for tokens with a promoter share.
    struct Binding {
        /// @dev set once, at the wallet's first trade of the token, or never
        address promoter;
        uint40 boundAt;
        /// @dev the wallet has traded the token: too late to bind it
        bool traded;
    }

    /// @custom:storage-location erc7201:gang.pad3.promote
    struct Layout {
        mapping(address token => Terms) termsOf;
        mapping(address token => mapping(address wallet => Binding)) bindingOf;
        /// @dev earned and not claimed yet, in the token's quote
        mapping(address token => mapping(address promoter => uint256)) feeOf;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("gang.pad3.promote")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant SLOT = 0x425b3ef806cb075f83ec70cdf81a0d371b31f45f3c5fb2d306b40e4b7e72d100;

    function layout() internal pure returns (Layout storage l) {
        bytes32 s = SLOT;
        assembly ("memory-safe") {
            l.slot := s
        }
    }
}
