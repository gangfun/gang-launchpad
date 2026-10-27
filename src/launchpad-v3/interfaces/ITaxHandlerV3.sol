// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev Platform's part of every taxed V3 pool trade (after graduation; the curve charges no tax) as a share of the
///      trade's volume, out of the tax. The one definition LaunchpadV3 and TaxHandlerV3 both use.
uint256 constant V3_PLATFORM_TAX_BPS = 50;

/// @notice What LaunchpadV3 calls on TaxHandlerV3, the one place every V3 tax payment is split: platform share (fixed
///         0.5% of trade volume) → dividends → tax recipient. Only the pool (post-grad) is taxed; the curve is not.
interface ITaxHandlerV3 {
    /// @dev `TaxDistributed.phase`. Bonding (0) is no longer emitted since the curve charges no tax (2026-10-27); it
    ///      stays so the event ABI and PostGrad's value (1) are unchanged for indexers.
    enum Phase {
        Bonding,
        PostGrad
    }

    /// @notice LaunchpadV3 only, once per taxed token at create.
    /// @param recipient    Listed address that receives the rest of the tax in quote; 0 only when `dividendBps` is
    ///                     10_000 (all of the non-platform tax goes to holders).
    /// @param dividendBps  Share of the tax after the platform's part that goes to the shared dividend vault (0 allowed).
    function register(address token, address quote, address recipient, uint16 dividendBps) external;

    /// @notice Permissionless: push the quote owed to `token`'s recipient (a direct transfer that failed).
    function release(address token) external returns (uint256 amount);

    /// @notice Whether the platform allows `recipient` as a new token's tax recipient.
    function isListed(address recipient) external view returns (bool);
}
