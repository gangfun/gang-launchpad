// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Called by TaxLaunchToken after taking outer (post-grad) transfer tax.
/// @dev Finding 2/3 (2026-10-23): notifyTax ONLY accumulates — never swaps inside the transfer hook.
///      Keeper/anyone calls process() later to sell via router (or fee-aware pair). syncShares on every transfer.
interface IPostGradTaxHandler {
    /// @dev `taxAmount` of `token` already credited to the handler. Accrue only; no DEX call.
    function notifyTax(address token, address from, address to, uint256 taxAmount) external;

    /// @dev Sync DividendVault shares for non-excluded from/to (wallet↔wallet included).
    function syncShares(address token, address from, address to) external;

    /// @dev Keeper/owner only. Sell accrued tax tokens for quote and split 50/50 vault/bucket.
    ///      minQuoteOut is mandatory (> 0) and must come from an off-chain quote.
    function process(address token, uint256 minQuoteOut) external returns (uint256 quoteOut);
}
