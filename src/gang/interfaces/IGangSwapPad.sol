// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice GangLaunchpad 3.0's GangSwap curve tokens (docs/SPEC-GANGSWAP-2026-11-22.md §4, §5), served by Pad3Module.
///         A GangSwap curve token is `kindOf` 4: on its curve it trades as a kind-1 token (same entries, fee, gate,
///         cap, agent window); at graduation it moves into a GangSwap pair (GangSwapMigrator) instead of a Pancake V2
///         pair. After graduation `getTokenInfo` reports status 4 (STATUS_GANGSWAP), the GangSwap pair and a 1% fee.
///         Phase 1: WBNB quote, no tax, no modules (vault, promoter share, base, graduation reward cannot be added).
interface IGangSwapPad {
    event GangSwapMigratorSet(address indexed migrator);
    /// @notice A GangSwap curve token (kindOf 4) was created; its other create events are kind 1's (review 4 #4).
    event GangSwapCreated(address indexed token);

    /// @notice `setGangSwapMigrator` ran already (one-shot).
    error GangSwapMigratorAlreadySet();
    /// @notice The migrator does not list this pad, does not take WBNB, or is not `wired()`.
    error WrongGangSwapMigrator();
    /// @notice `createGangSwap` before the GangSwap migrator is set.
    error GangSwapNotOpen();

    /// @notice One-shot (owner): the GangSwapMigrator every GangSwap curve token graduates through, for good. It must
    ///         list this pad (a migrator that does not would make every such graduation revert), take WBNB and be `wired()`.
    function setGangSwapMigrator(address migrator) external;

    /// @notice The GangSwapMigrator (address(0) = `createGangSwap` closed).
    function gangSwapMigrator() external view returns (address);

    /// @notice `createWithGradTarget(name, symbol, logoURI, metaURI, WBNB, 0, no tax, gradBnb)`, except the token is
    ///         `kindOf` 4 and graduates into GangSwap. `gradBnb` one of GRAD_BNB_TIERS. Also through `createWithSalt`
    ///         and `createWithAgentWindow`.
    function createGangSwap(
        string calldata name,
        string calldata symbol,
        string calldata logoURI,
        string calldata metaURI,
        uint256 gradBnb
    ) external returns (address token);
}
