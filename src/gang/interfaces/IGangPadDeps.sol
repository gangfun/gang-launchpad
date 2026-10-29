// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice The slice of GangToken the pad calls (one token contract for all three kinds of token).
interface IGangPadToken {
    /// @notice Graduation / launch, step 1 (once): transfers unlock for good, the migrator is excluded.
    function unlock(address migrator) external;

    /// @notice Graduation / launch, step 2 (once, taxed tokens only): pool tax and share syncing start.
    function setPair(address pair) external;

    /// @notice 打新 only, before launch: pull a minter's tokens back to the pad (withdraw).
    function reclaim(address from, uint256 amount) external;

    /// @notice Any kind, before graduation / launch only: spend the allowance `owner` gave `spender` and pull `amount`
    ///         from `owner` to the pad (`sellFor` / `withdrawFor`, AUDIT-BRIEF §23).
    function pullFor(address owner, address spender, uint256 amount) external;
}

/// @notice The slice of GangTaxHandler the pad calls.
interface IGangPadHandler {
    /// @param kind 1 = curve (V3), 2 = 打新. 打新 tokens register as (quote, 0, 5000, 2).
    function register(address token, address quote, address recipient, uint16 dividendBps, uint8 kind) external;

    function isListed(address recipient) external view returns (bool);

    /// @dev Only the first two words are read, so a route getter with more fields decodes the same.
    function routeOf(address token) external view returns (address quote, address recipient);
}

/// @notice The slice of TokenDeployer the pad calls.
interface IGangTokenDeployer {
    /// @notice Deploys a GangToken whose launchpad is the caller. V3 taxed: (buy, sell, false); V3 untaxed: (0, 0, false);
    ///         打新: (100, 100, true).
    function deploy(
        string calldata name,
        string calldata symbol,
        string calldata uri,
        address handler,
        uint16 buyTaxBps,
        uint16 sellTaxBps,
        bool reclaimable
    ) external returns (address token);

    function isLaunchToken(address token) external view returns (bool);
}
