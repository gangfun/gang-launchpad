// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IGangLaunchpad} from "./IGangLaunchpad.sol";

/// @notice GangLaunchpad 3.0's opening base (docs/SPEC-BASE-VAULT-V2-2026-11-12.md): a creator can buy 5% or 10% of the
///         supply on the curve in its token's create tx, for a vault that releases it to the creator linearly after
///         graduation. Pad3Module's functions, reached through the pad.
interface IGangBasePad {
    /// @notice Fixed at create. `baseBps`: 500 or 1000 (of the total supply). `vestDays`: 30 / 90 / 180 for 500,
    ///         90 / 180 for 1000.
    struct BaseConfig {
        uint16 baseBps;
        uint32 vestDays;
    }

    event BaseVaultImplSet(address indexed impl);
    /// @notice Emitted before the base buy's `Buy` / `TradeV1`, whose trader is `vault`.
    event BaseCreated(
        address indexed token, address indexed vault, uint256 tokens, uint256 cost, uint16 baseBps, uint32 vestDays
    );

    /// @notice `createWithBase` while no vault implementation is set.
    error BaseNotOpen();
    /// @notice A base size / period pair that is not offered, or a dividend tax config.
    error BadBaseConfig();
    /// @notice `setBaseVaultImpl`: not a base-v1 vault of this pad.
    error WrongBaseVaultImpl();
    /// @notice The base buy found the curve already traded, or a cost that is not `baseCost` (never reached from
    ///         `createWithBase`).
    error BaseBuyRefused();

    /// @notice Owner. Only tokens created afterwards use it; 0 closes `createWithBase`.
    function setBaseVaultImpl(address impl) external;

    /// @notice `createWithGradTarget` for a WBNB-quoted token (no reference pool), plus the opening base bought for a new
    ///         base vault in the same tx. msg.value must be exactly `previewBaseCost(gradBnb, base.baseBps)`
    ///         (BadMsgValue). Not for dividend tokens. With abcd on, only through `createWithSalt`.
    function createWithBase(
        string calldata name,
        string calldata symbol,
        string calldata logoURI,
        string calldata metaURI,
        IGangLaunchpad.TaxConfig calldata tax,
        uint256 gradBnb,
        BaseConfig calldata base
    ) external payable returns (address token);

    function baseVaultImpl() external view returns (address);
    /// @notice The token's base vault (0: no base).
    function baseVaultOf(address token) external view returns (address);
    /// @notice The tokens the base vault bought at create.
    function baseOf(address token) external view returns (uint256);
    /// @notice BNB `createWithBase` takes for `baseBps` at the graduation target `gradBnb`, the fee included.
    function previewBaseCost(uint256 gradBnb, uint16 baseBps) external view returns (uint256);
}
