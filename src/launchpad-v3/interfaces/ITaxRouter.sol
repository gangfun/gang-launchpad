// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @dev Platform's part of every taxed V3 trade (curve and pool) as a share of the trade's volume, out of the tax.
///      The one definition LaunchpadV3 and PostGradTaxHandlerV3 both use.
uint256 constant V3_PLATFORM_TAX_BPS = 50;

/// @notice Single place where every V3 tax payment (bonding or post-grad) is split:
///         platform share (fixed 0.5% of trade volume, computed by the payer) → dividends → tax recipient.
interface ITaxRouter {
    enum Phase {
        Bonding,
        PostGrad
    }

    /// @notice LaunchpadV3 only, once per taxed token at create.
    /// @param recipient    RecipientRegistry-listed address that receives the rest of the tax in quote; 0 only when
    ///                     `dividendBps` is 10_000 (all of the non-platform tax goes to holders).
    /// @param dividendBps  Share of the tax after the platform's part that goes to DividendVault (0 allowed).
    function register(address token, address quote, address recipient, uint16 dividendBps) external;

    /// @notice Sources only (LaunchpadV3 for bonding, the post-grad handler after its swap). Pulls `amount` of the
    ///         token's quote from the caller; `platformAmount` of it is the platform's (≤ amount).
    function distribute(address token, uint256 amount, uint256 platformAmount, Phase phase) external;

    /// @notice Permissionless: push the quote owed to `token`'s recipient (a direct transfer that failed).
    function release(address token) external returns (uint256 amount);

    function previewSplit(address token, uint256 amount, uint256 platformAmount)
        external
        view
        returns (uint256 toPlatform, uint256 toDividend, uint256 toRecipient);
}
