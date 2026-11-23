// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Pad3GangSwapStore — GangLaunchpad 3.0's GangSwap curve tokens (docs/SPEC-GANGSWAP-2026-11-22.md), in their
///        own ERC-7201 namespace
/// @notice A GangSwap curve token (`kindOf` 4) trades on its curve exactly as a kind-1 token; at graduation it migrates
///         through `migrator` (GangSwapMigrator: a GangSwap pair with a virtual reserve, the rest to its buy-back)
///         instead of `Config.migrator`, and is never taxed (no `setPair`). Phase 1: WBNB only, no tax, no modules
///         (spec D2, D3). Kept out of `Config` (shared by the pads and re-declared by every module, spec §5).
///         Written only by Pad3Module (`setGangSwapMigrator`, once; `createGangSwap`), read by CurveLogic3's
///         graduation (so `buy`'s signature stays as it is, review N8), all in the proxy's storage.
///         UPGRADES: members are only ever appended at the end (never reordered, retyped or removed) and SLOT never
///         changes; test/gang3/Pad3GangSwap.t.sol pins both.
library Pad3GangSwapStore {
    /// @dev `kindOf` of a GangSwap curve token (1 = curve, 2 = 打新, 3 = 铸币飞轮).
    uint8 internal constant KIND = 4;

    /// @custom:storage-location erc7201:gang.pad3.gangswap
    struct Layout {
        /// @dev the GangSwapMigrator; set once by the owner (0 = createGangSwap closed), never changed after
        address migrator;
        /// @dev a GangSwap curve token of this pad, written once at its create
        mapping(address token => bool) isGangSwap;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("gang.pad3.gangswap")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant SLOT = 0x0fa245e530fbebe86ae83a9320d4e2f402f8d74684729a02445dda5fc9dc4200;

    function layout() internal pure returns (Layout storage l) {
        bytes32 s = SLOT;
        assembly ("memory-safe") {
            l.slot := s
        }
    }

    /// @dev The migrator `token` graduates through when it is a GangSwap curve token, else address(0).
    function migratorOf(address token) internal view returns (address) {
        Layout storage l = layout();
        return l.isGangSwap[token] ? l.migrator : address(0);
    }
}
