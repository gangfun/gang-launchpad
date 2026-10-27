// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev Platform's part of every taxed Curve (V3) pool trade as a share of the trade's volume, out of the tax.
uint256 constant V3_PLATFORM_TAX_BPS = 50;

/// @notice GangTaxHandler: the pool tax after graduation / launch of every launchpad token (Curve = V3, Fair = 打新).
interface IGangTaxHandler {
    /// @dev `TaxDistributed.phase`. Bonding (0) is never emitted (no curve tax, 2026-10-27); it stays so the event ABI
    ///      and PostGrad's value (1) are unchanged for indexers.
    enum Phase {
        Bonding,
        PostGrad
    }

    // ------------------------------------------------------------ launchpad
    /// @notice Launchpad only, once per taxed token at create. `kind` 1 = Curve, 2 = Fair (registered as
    ///         `(quote, 0, 5000, 2)`).
    /// @param recipient   Curve: listed address that receives the rest of the tax in quote; 0 only when `dividendBps`
    ///                    is 10_000. Fair: 0 (the rest is the platform's).
    /// @param dividendBps Share of the tax after the platform's part that goes to holders (Fair: 5000).
    function register(address token, address quote, address recipient, uint16 dividendBps, uint8 kind) external;

    /// @notice Whether the platform allows `recipient` as a new Curve token's tax recipient.
    function isListed(address recipient) external view returns (bool);

    /// @notice Permissionless: push the quote owed to `token`'s recipient (a direct transfer that failed).
    function release(address token) external returns (uint256 amount);

    // ------------------------------------------------------------ token hooks
    /// @notice The token's hook after taking the pool tax (`taxAmount` already sent here).
    /// @param rateBps the token's buy tax (`from` is the pair) or sell tax (`to` is the pair) for this transfer
    function notifyTax(address token, address from, address to, uint256 taxAmount, uint256 rateBps) external;

    /// @notice The token's hook on every transfer once its pair is set (permissionless, never reverts).
    function syncShares(address token, address from, address to) external;

    /// @dev Only the token, when a taxed sell of `sellAmount` goes into its pair: sells one chunk of accrued tax first.
    function swapBack(address token, uint256 sellAmount) external returns (uint256 quoteOut);

    /// @dev Keeper/owner only: sells `amount` (≤ `maxChunk(token)`) with a mandatory off-chain `minQuoteOut`.
    function process(address token, uint256 amount, uint256 minQuoteOut) external returns (uint256 quoteOut);
}
