// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Pad3AgentWindowStore — GangLaunchpad 3.0's agent window (docs/SPEC-AGENT-WINDOW-2026-11-20.md), in its own
///        ERC-7201 namespace
/// @notice A curve token's agent window: until `openAt`, only Agent ID holders trade it on the curve (as every token
///         before this version); from `openAt` on, any wallet does, and the 1% wallet cap is off unless the token has a
///         graduation reward. `openAt` is written once, at the token's create, from what its creator registered with
///         `setNextAgentWindow`; nothing changes it after. Read by CurveLogic3 (every curve trade and quote) and the
///         pad's views; written only by the two `_createCurve`s and `setNextAgentWindow` (served by Pad3GradModule).
///         UPGRADES: members are only ever appended at the end (never reordered, retyped or removed) and SLOT never
///         changes; test/gang3/Pad3AgentWindow.t.sol pins both.
library Pad3AgentWindowStore {
    /// @dev Window bounds, in minutes (1 minute to 24 hours); 0 = no window (agent only for good).
    uint16 internal constant MIN_MINUTES = 1;
    uint16 internal constant MAX_MINUTES = 1440;

    /// @custom:storage-location erc7201:gang.pad3.agentwindow
    struct Layout {
        /// @dev when `token` opens to every wallet; 0 = never (agent only). Written once, at its create.
        mapping(address token => uint40) openAt;
        /// @dev the window `creator`'s next curve create takes, in minutes; 0 = none. Cleared by that create.
        mapping(address creator => uint16) pendingMinutes;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("gang.pad3.agentwindow")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant SLOT = 0xc114e53026874183c08655ed52e95951b04fe39d1186398d53352d417c38d300;

    function layout() internal pure returns (Layout storage l) {
        bytes32 s = SLOT;
        assembly ("memory-safe") {
            l.slot := s
        }
    }

    /// @dev `token` is open to every wallet now.
    function isOpen(address token) internal view returns (bool) {
        uint40 t = layout().openAt[token];
        return t != 0 && block.timestamp >= t;
    }

    /// @dev Called by each `_createCurve` right after the token exists: takes `creator`'s registered window, if any,
    ///      writes the token's `openAt` and clears the registration. Returns the `openAt` written (0 = none).
    function consume(address creator, address token) internal returns (uint40 openAt) {
        Layout storage l = layout();
        uint16 m = l.pendingMinutes[creator];
        if (m == 0) return 0;
        delete l.pendingMinutes[creator];
        openAt = uint40(block.timestamp + uint256(m) * 60);
        l.openAt[token] = openAt;
    }
}
