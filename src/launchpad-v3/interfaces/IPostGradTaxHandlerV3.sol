// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Called by TaxLaunchTokenV3 after taking pool (post-grad) tax. Same contract as V2's IPostGradTaxHandler
///         except `notifyTax` also carries the rate the token charged (its buy or sell tax), so the handler can count
///         the platform's 0.5% of volume without calling back into the token.
/// @dev V2 Finding 2/3: notifyTax only accrues (no swap in the transfer hook); syncShares on every transfer.
interface IPostGradTaxHandlerV3 {
    /// @param rateBps the token's buy tax (`from` is the pair) or sell tax (`to` is the pair) for this transfer
    function notifyTax(address token, address from, address to, uint256 taxAmount, uint16 rateBps) external;

    function syncShares(address token, address from, address to) external;

    /// @dev Keeper/owner only, with a mandatory off-chain `minQuoteOut`.
    function process(address token, uint256 minQuoteOut) external returns (uint256 quoteOut);
}
