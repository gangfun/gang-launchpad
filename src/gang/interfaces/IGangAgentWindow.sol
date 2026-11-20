// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IGangAgentWindow — GangLaunchpad 3.0's agent window (docs/SPEC-AGENT-WINDOW-2026-11-20.md)
/// @notice A creator creates a curve token with a window (in minutes) through `createWithAgentWindow`; the token's
///         `openAt` = create time + window. Until then only Agent ID holders trade it on the curve; from then on any
///         wallet does (contracts included), and the 1% wallet cap is off. No window = agent only for good, as before.
///         Nothing changes a token's `openAt` after its create.
interface IGangAgentWindow {
    /// @notice `token` opens to every wallet at `openAt` (emitted at its create, after `Created`).
    event AgentWindowSet(address indexed token, uint40 openAt);

    /// @notice `windowMinutes` is not within MIN_AGENT_WINDOW_MINUTES..MAX_AGENT_WINDOW_MINUTES.
    error BadAgentWindow();
    /// @notice `data` is not a curve create entry (or `createWithSalt`).
    error BadAgentWindowCall();
    /// @notice The call made no curve token for the caller, so the window was not used.
    error AgentWindowNotUsed();

    /// @notice Runs one curve create entry (`create`, `createWithGradTarget`, `createWithVault`, `createWithPromote`,
    ///         `createWithBase`, `createWithGradReward`) or `createWithSalt` around one of them, as the caller, in this
    ///         same call, and gives the token it creates a window of `windowMinutes`: `openAt` = now + windowMinutes
    ///         minutes. Every check and event of the entry still runs. Reverts AgentWindowNotUsed when no curve token
    ///         came out of it for the caller (e.g. a 打新 / 铸币飞轮 create inside `createWithSalt`). Payable only for
    ///         what the entry itself takes (`createWithBase` through `createWithSalt`).
    function createWithAgentWindow(uint16 windowMinutes, bytes calldata data) external payable returns (address token);

    /// @notice When `token` opens to every wallet; 0 = never (agent only).
    function agentOpenAt(address token) external view returns (uint40);

    /// @notice `token` is open to every wallet now (`agentOpenAt` != 0 and reached).
    function agentWindowOpen(address token) external view returns (bool);

    /// @notice `account` may trade curve token `token` now as far as the Agent gate goes: the pad's gate is off, the
    ///         token is open, or `account` holds an Agent ID; never the token's own vault (it can't trade it).
    ///         `account` = address(0): a fresh wallet, no Agent check (true only if the gate is off or the token is open).
    function canTradeCurve(address token, address account) external view returns (bool);

    /// @notice The 1% wallet cap applies to `token` now: the pad's cap is on and the token is not open.
    function walletCapOn(address token) external view returns (bool);

    function MIN_AGENT_WINDOW_MINUTES() external view returns (uint16);
    function MAX_AGENT_WINDOW_MINUTES() external view returns (uint16);
}
