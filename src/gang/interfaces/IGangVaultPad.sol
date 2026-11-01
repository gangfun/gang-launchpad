// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IGangLaunchpad} from "./IGangLaunchpad.sol";

/// @notice The vault entries of GangVaultLaunchpad (GangLaunchpad 2.0 + a vault per curve token, SPEC-VAULT-LOCK).
interface IGangVaultPad {
    event VaultSet(address indexed vault, bool enabled);
    event VaultBound(address indexed token, address indexed vault);
    event VaultLocked(address indexed token, address indexed vault, address indexed user, uint256 amount);
    event VaultReleased(address indexed token, address indexed vault, address indexed user, uint256 amount);

    /// @notice The caller is not `token`'s vault, or (create) the vault is not listed.
    error NotVault();
    /// @notice The vault was delisted: no new locks (releases stay open).
    error VaultDelisted();
    /// @notice A vault must be a contract.
    error VaultNotContract();
    /// @notice A vault can't be a router, and a router can't be listed as a vault.
    error VaultIsRouter();
    /// @notice A token's own vault never buys or sells it on the curve.
    error VaultCannotTrade();
    /// @notice This pad only creates through `createWithVault`.
    error UseVaultCreate();

    function isVault(address vault) external view returns (bool);
    function vaultOf(address token) external view returns (address);
    function lockedOf(address token, address user) external view returns (uint256);

    /// @notice `createWithGradTarget` with the token bound to `vault` (listed) for good; the only create of this pad.
    function createWithVault(
        string calldata name,
        string calldata symbol,
        string calldata logoURI,
        string calldata metaURI,
        address quote,
        address refPool,
        IGangLaunchpad.TaxConfig calldata tax,
        uint256 gradBnb,
        address vault
    ) external returns (address token);

    function setVault(address vault, bool enabled) external;
    function vaultLock(address token, address user, uint256 amount) external;
    function vaultRelease(address token, address user, uint256 amount) external;
}
