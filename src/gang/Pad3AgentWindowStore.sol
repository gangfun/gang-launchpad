// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Pad3AgentWindowStore — GangLaunchpad 3.0's agent window (docs/SPEC-AGENT-WINDOW-2026-11-20.md), in its own
///        ERC-7201 namespace
/// @notice A curve token's agent window: until `openAt`, only Agent ID holders trade it on the curve (as every token
///         before this version); from `openAt` on, any wallet does, and the 1% wallet cap is off. `openAt` is written
///         once, at the token's create, from the window its creator passed to `createWithAgentWindow` in the same
///         transaction; nothing changes it after. Read by CurveLogic3 (every curve trade and quote) and the pad's
///         views; written only by the two `_createCurve`s.
///         The window being created is held in TRANSIENT storage for the one `createWithAgentWindow` call: it can't be
///         left over for a later create, and a revert discards it.
///         UPGRADES: members are only ever appended at the end (never reordered, retyped or removed) and SLOT never
///         changes; test/gang3/Pad3AgentWindow.t.sol pins both.
library Pad3AgentWindowStore {
    /// @dev Window bounds, in minutes (1 minute to 24 hours).
    uint16 internal constant MIN_MINUTES = 1;
    uint16 internal constant MAX_MINUTES = 1440;

    /// @custom:storage-location erc7201:gang.pad3.agentwindow
    struct Layout {
        /// @dev when `token` opens to every wallet; 0 = never (agent only). Written once, at its create.
        mapping(address token => uint40) openAt;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("gang.pad3.agentwindow")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant SLOT = 0xc114e53026874183c08655ed52e95951b04fe39d1186398d53352d417c38d300;
    /// @dev Transient: the window `createWithAgentWindow` is creating, `creator | minutes << 160`; 0 = none.
    ///      keccak256("gang.pad3.agentwindow.pending")
    bytes32 internal constant PENDING_TSLOT = keccak256("gang.pad3.agentwindow.pending");

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

    /// @dev The window being created in this transaction (0, 0 = none).
    function pending() internal view returns (address creator, uint16 minutes_) {
        bytes32 s = PENDING_TSLOT;
        uint256 v;
        assembly ("memory-safe") {
            v := tload(s)
        }
        creator = address(uint160(v));
        minutes_ = uint16(v >> 160);
    }

    function setPending(address creator, uint16 minutes_) internal {
        bytes32 s = PENDING_TSLOT;
        uint256 v = uint256(uint160(creator)) | (uint256(minutes_) << 160);
        assembly ("memory-safe") {
            tstore(s, v)
        }
    }

    /// @dev Called by each `_createCurve` right after the token exists: if `creator` is creating it inside
    ///      `createWithAgentWindow`, takes that window (once), writes the token's `openAt`. Returns it (0 = none).
    function consume(address creator, address token) internal returns (uint40 openAt) {
        (address c, uint16 m) = pending();
        if (m == 0 || c != creator) return 0;
        setPending(address(0), 0);
        openAt = uint40(block.timestamp + uint256(m) * 60);
        layout().openAt[token] = openAt;
    }
}
