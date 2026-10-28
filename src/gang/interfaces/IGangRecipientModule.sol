// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IGangRecipientModule — a tax recipient contract made by a factory GangHandlerAdmin lists
/// @notice What every module does the same way, so the keeper, the CLI and the site handle a new kind without new code.
///         A module is the recipient of ONE V3 token: the tax handler pays it the recipient's part in the quote with a
///         plain transfer (no callback, no token tag), so whatever it does happens after the quote arrived.
interface IGangRecipientModule {
    /// @notice What kind of module this is, e.g. "buyback-burn-v1".
    function moduleType() external view returns (bytes32);

    /// @notice The dev it was made for (the token's creator once bound).
    function dev() external view returns (address);

    /// @notice The token it serves (0 until `bind`).
    function token() external view returns (address);

    /// @notice Bind the dev's token (once, anyone): a V3 token the dev created with this module as its recipient.
    function bind(address token) external;

    /// @notice Whether `work` should be called now, and the `minOut` to call it with (the module's own guard on what
    ///         the call gets; 0 when there is nothing to guard).
    function previewWork() external view returns (bool due, uint256 minOut);

    /// @notice The module's periodic step (anyone; the keeper calls it when `previewWork` says it is due).
    function work(uint256 minOut) external;
}
