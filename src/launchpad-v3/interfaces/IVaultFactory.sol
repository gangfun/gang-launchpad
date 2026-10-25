// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TemplateTypes} from "./TemplateTypes.sol";

/// @notice An economic template. Must be listed in TemplateRegistry before LaunchpadV3 accepts it.
/// @dev Deployed once per template version; never upgradeable. A new version is a new factory address.
interface IVaultFactory {
    /// @notice LaunchpadV3 only. Deploys the vault that receives the token side of every tax payment.
    /// @param data abi-encoded params described by `dataSchema()`.
    /// @return vault Must report `token()` == `token` and `quote()` == `quote`.
    function createVault(address token, address quote, address creator, bytes calldata data)
        external
        returns (address vault);

    /// @notice Preflight for the CLI / pad: same checks `createVault` would revert on, without reverting.
    function validate(bytes calldata data) external view returns (bool ok, string memory reason);

    function metadata() external view returns (TemplateTypes.Metadata memory);

    /// @notice Create params, in abi-encoding order.
    function dataSchema() external view returns (TemplateTypes.Field[] memory);
}
