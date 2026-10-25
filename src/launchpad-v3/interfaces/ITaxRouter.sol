// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TemplateTypes} from "./TemplateTypes.sol";

/// @notice Single place where every V3 tax payment (bonding or post-grad) is split.
interface ITaxRouter {
    /// @notice LaunchpadV3 only, once per taxed token at create.
    /// @param vault        0 = no template; then `dividendBps` must be 10_000.
    /// @param author       Template author snapshotted from TemplateRegistry (0 = platform-authored, no author cut).
    /// @param dividendBps  Share of the token side that goes to DividendVault; the rest goes to `vault`.
    function register(address token, address quote, address vault, address author, uint16 dividendBps) external;

    /// @notice Sources only (LaunchpadV3 for bonding, post-grad handler after its swap). Pulls `amount` of the
    ///         token's quote from the caller and splits it.
    function distribute(address token, uint256 amount, TemplateTypes.Phase phase) external;

    /// @notice Permissionless: push quote owed to `account` (template author earnings, or a vault push that failed).
    function release(address account, address quote) external returns (uint256 amount);

    function previewSplit(address token, uint256 amount)
        external
        view
        returns (uint256 toPlatform, uint256 toAuthor, uint256 toDividend, uint256 toVault);
}
