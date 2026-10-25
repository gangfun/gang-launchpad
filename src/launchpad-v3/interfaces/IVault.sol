// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TemplateTypes} from "./TemplateTypes.sol";

/// @notice Per-token vault created by an IVaultFactory. Receives quote (never the launch token) from TaxRouterV3.
interface IVault {
    function token() external view returns (address);

    function quote() external view returns (address);

    function factory() external view returns (address);

    /// @notice Notification only — `amount` of quote is already in the vault.
    /// @dev Called by TaxRouterV3 with capped gas inside try/catch, so it may silently not run (out of gas, revert,
    ///      or a failed push credited via `release`). Vault accounting MUST be balance-based, never callback-based.
    function onTaxReceived(uint256 amount, TemplateTypes.Phase phase) external;

    /// @notice Methods gang.fun / the CLI may show for this vault.
    function uiSchema() external view returns (TemplateTypes.Method[] memory);
}
