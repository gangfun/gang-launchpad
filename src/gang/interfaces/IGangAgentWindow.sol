// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IGangAgentWindow — GangLaunchpad 3.0's agent window (docs/SPEC-AGENT-WINDOW-2026-11-20.md)
/// @notice A creator registers a window (in minutes) before creating a curve token; the create writes the token's
///         `openAt` = create time + window. Until then only Agent ID holders trade the token on the curve; from then
///         on any wallet does (contracts included), and the 1% wallet cap is off unless the token has a graduation
///         reward. No window = agent only for good, as before. Nothing changes a token's `openAt` after its create.
interface IGangAgentWindow {
    /// @notice `creator`'s next curve create takes a window of `windowMinutes` (0 = cleared).
    event NextAgentWindowSet(address indexed creator, uint16 windowMinutes);
    /// @notice `token` opens to every wallet at `openAt` (emitted at its create, after `Created`).
    event AgentWindowSet(address indexed token, uint40 openAt);

    /// @notice `windowMinutes` is neither 0 nor within MIN_AGENT_WINDOW_MINUTES..MAX_AGENT_WINDOW_MINUTES.
    error BadAgentWindow();

    /// @notice The caller's next curve create (any curve entry, `createWithSalt` included) gets a window of
    ///         `windowMinutes`; 0 clears it. The registration stays until that create or until cleared: 打新 and
    ///         铸币飞轮 creates neither use nor clear it.
    function setNextAgentWindow(uint16 windowMinutes) external;

    /// @notice What `creator` registered for its next curve create, in minutes (0 = none).
    function nextAgentWindowOf(address creator) external view returns (uint16);

    /// @notice When `token` opens to every wallet; 0 = never (agent only).
    function agentOpenAt(address token) external view returns (uint40);

    /// @notice `token` is open to every wallet now (`agentOpenAt` != 0 and reached).
    function agentWindowOpen(address token) external view returns (bool);

    /// @notice `account` may trade curve token `token` now as far as the Agent gate goes: the pad's gate is off, the
    ///         token is open, or `account` holds an Agent ID. `account` = address(0): a fresh wallet, no Agent check
    ///         (true only if the gate is off or the token is open).
    function canTradeCurve(address token, address account) external view returns (bool);

    /// @notice The 1% wallet cap applies to `token` now: the pad's cap is on and the token is not open, or it has a
    ///         graduation reward.
    function walletCapOn(address token) external view returns (bool);

    function MIN_AGENT_WINDOW_MINUTES() external view returns (uint16);
    function MAX_AGENT_WINDOW_MINUTES() external view returns (uint16);
}
