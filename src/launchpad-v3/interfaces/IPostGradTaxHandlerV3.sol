// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Called by TaxLaunchTokenV3 after taking pool (post-grad) tax. Same contract as V2's IPostGradTaxHandler
///         except `notifyTax` also carries the rate the token charged (its buy or sell tax), so the handler can count
///         the platform's 0.5% of volume without calling back into the token.
/// @dev notifyTax only accrues; syncShares on every transfer; swapBack (sell-time chunk) is called by the token, wrapped
///      so a failure never fails the trade.
interface IPostGradTaxHandlerV3 {
    /// @param rateBps the token's buy tax (`from` is the pair) or sell tax (`to` is the pair) for this transfer
    function notifyTax(address token, address from, address to, uint256 taxAmount, uint16 rateBps) external;

    function syncShares(address token, address from, address to) external;

    /// @dev Keeper/owner only: sells `amount` (≤ `maxChunk(token)`) with a mandatory off-chain `minQuoteOut`.
    function process(address token, uint256 amount, uint256 minQuoteOut) external returns (uint256 quoteOut);

    /// @dev Only the token, when a taxed sell of `sellAmount` goes into its pair: sells one chunk of accrued tax first.
    function swapBack(address token, uint256 sellAmount) external returns (uint256 quoteOut);
}
