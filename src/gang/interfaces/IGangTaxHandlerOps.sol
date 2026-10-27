// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice GangTaxHandler's admin and read surface as the deploy script, the testnet E2E and their tests use it
///         (merge plan §1.4 / §2.2: the base PostGradHandlerBase getters plus TaxHandlerV3 + HolderRewardHandler's).
/// @dev Written against feat/merge-handler's GangTaxHandler (constructor `(owner, dividendVault, platformBucket,
///      dexRouter)`); at integration, check every line against the real handler.
interface IGangTaxHandlerOps {
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
    function isListed(address recipient) external view returns (bool);
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

    // ---------------------------------------------------------------- keeper / anyone
    function process(address token, uint256 amount, uint256 minQuoteOut) external returns (uint256 quoteOut);
    function release(address token) external returns (uint256 amount);
    function syncShares(address token, address from, address to) external;
}
