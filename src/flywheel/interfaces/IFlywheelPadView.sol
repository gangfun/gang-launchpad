// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice What FlywheelTaxHandler reads from its pad.
interface IFlywheelPadView {
    /// @notice Tokens `user` got by minting (before and after launch) since it last qualified; 0 for everyone else.
    function baselineOf(address token, address user) external view returns (uint256);

    /// @notice The token's hold line (bps of the baseline): below it, a minter is out until it mints again.
    function holdBpsOf(address token) external view returns (uint16);
}
