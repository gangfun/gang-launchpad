// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IGangTaxHandler} from "./IGangTaxHandler.sol";

/// @notice GangTaxHandler's admin and read surface as the deploy script, the testnet E2E and their tests use it
///         (merge plan §1.4 / §2.2: the base PostGradHandlerBase getters plus TaxHandlerV3 + HolderRewardHandler's).
/// @dev Extends IGangTaxHandler (what tokens and the pad call: register, notifyTax, swapBack, process, release,
///      syncShares, isListed). Every function was checked against GangTaxHandler's ABI at integration.
interface IGangTaxHandlerOps is IGangTaxHandler {
    // ---------------------------------------------------------------- wiring
    function launchpad() external view returns (address);
    function dividendVault() external view returns (address);
    function platformBucket() external view returns (address);
    function dexRouter() external view returns (address);
    function pendingDexRouter() external view returns (address);
    function keeper() external view returns (address);
    function pendingKeeper() external view returns (address);
    function keeperSet() external view returns (bool);

    // ---------------------------------------------------------------- admin (onlyOwner)
    /// @dev One-shot (LaunchpadAlreadySet).
    function setLaunchpad(address launchpad_) external;
    /// @dev Once in the contract's life (KeeperAlreadySet); later changes take propose → 48 h → accept.
    function setKeeper(address keeper_) external;
    function list(address recipient, string calldata label) external;
    function delist(address recipient) external;
    function proposeDexRouter(address router_) external;

    // ---------------------------------------------------------------- views
    /// @dev The 4th field is the kind (1 curve, 2 打新); 3-word decoders read the same first three.
    function routeOf(address token)
        external
        view
        returns (address quote, address recipient, uint16 dividendBps, uint8 kind);
    function owedOf(address token) external view returns (uint256);
    function owedTotalOf(address quote) external view returns (uint256);
    function accruedTax(address token) external view returns (uint256);
    function accruedPlatformTax(address token) external view returns (uint256);
    function isOut(address token, address user) external view returns (bool);
    function eligibleShare(address token, address user) external view returns (uint256);
    function maxChunk(address token) external view returns (uint256);
    function previewSell(address token, uint256 amountIn) external view returns (uint256 quoteOut, uint256 chunk);
    // keeper / anyone: process, release, syncShares (IGangTaxHandler)
}
