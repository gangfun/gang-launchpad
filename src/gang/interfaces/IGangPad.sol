// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IGangLaunchpad} from "./IGangLaunchpad.sol";
import {IGangPadView} from "./IGangPadView.sol";

/// @notice GangLaunchpad's external surface as the deploy script, the testnet E2E, GangRouter and their tests use it
///         (merge plan §1.3). Names, parameters and return layouts are the old LaunchpadV3 / FairMintPad ones, so
///         selectors and getter decoding are unchanged; contract-typed getters of the old cores are `address` here
///         (same ABI).
/// @dev Types, events and errors come from IGangLaunchpad, and baselineOf / holdBpsOf / kindOf from IGangPadView (the pad
///      inherits both). Every function here was checked against GangLaunchpad's ABI at integration (same selector,
///      same outputs); the pad does not inherit this interface because its contract-typed getters would clash.
interface IGangPad is IGangLaunchpad, IGangPadView {
    // ---------------------------------------------------------------- immutables
    function quoteRegistry() external view returns (address);
    function dividendVault() external view returns (address);
    function platformBucket() external view returns (address);
    function taxHandler() external view returns (address);
    function tokenDeployer() external view returns (address);
    function wbnb() external view returns (address);

    // ---------------------------------------------------------------- config (Config struct, hand-written getters)
    function pairFactory() external view returns (address);
    function v3Factory() external view returns (address);
    function twapWindow() external view returns (uint32);
    function migrator() external view returns (address);
    function agentIdRegistry() external view returns (address);
    function agentGateEnabled() external view returns (bool);
    function walletCapEnabled() external view returns (bool);
    function bridgePoolOf(address asset) external view returns (address);
    function routers(address router) external view returns (bool);

    // ---------------------------------------------------------------- admin (onlyOwner)
    /// @dev One-shot; reverts WrongMigrator unless the migrator lists this pad. The deploy's last call (A-1).
    function setMigrator(address migrator_) external;
    function setPairFactory(address factory_) external;
    function setRouter(address router_, bool enabled) external;
    function setAgentGate(bool enabled, address registry) external;
    function setWalletCapEnabled(bool enabled) external;
    function setV3Factory(address factory_) external;
    function setTwapWindow(uint32 window) external;
    function setBridgePool(address asset, address pool) external;

    // ---------------------------------------------------------------- shared views
    function isAgent(address account) external view returns (bool);
    function tokenCount() external view returns (uint256);
    function allTokens(uint256 i) external view returns (address);
    function logoURIOf(address token) external view returns (string memory);

    // ---------------------------------------------------------------- V3 (curve)
    function create(
        string calldata name,
        string calldata symbol,
        string calldata logoURI,
        string calldata metaURI,
        address quote,
        address refPair,
        TaxConfig calldata tax
    ) external returns (address token);
    function buy(address token, uint256 quoteIn, uint256 minTokensOut) external returns (uint256 tokensOut);
    function buyFor(address trader, address token, uint256 quoteIn, uint256 minTokensOut)
        external
        returns (uint256 tokensOut);
    function sell(address token, uint256 tokensIn, uint256 minQuoteOut) external returns (uint256 quoteOut);
    /// @dev §23: listed router, trader == tx.origin; spends the trader's token allowance to the router; quote → router.
    function sellFor(address trader, address token, uint256 tokensIn, uint256 minQuoteOut)
        external
        returns (uint256 quoteOut);
    /// @dev Creator only, direct; pays everything in `creatorFeeOf(token)` to `to`.
    function claimCreatorFee(address token, address to) external returns (uint256 amount);
    function creatorFeeOf(address token) external view returns (uint256);
    function createWithGradTarget(
        string calldata name,
        string calldata symbol,
        string calldata logoURI,
        string calldata metaURI,
        address quote,
        address refPool,
        TaxConfig calldata tax,
        uint256 gradBnb
    ) external returns (address token);
    function gradTargetOf(address token) external view returns (uint256);
    function graduationAmountFor(address quote, address refPool, uint256 gradBnb) external view returns (uint256);
    function GRAD_BNB_TIERS() external pure returns (uint256[4] memory);

    /// @dev Same 12 fields, same order as LaunchpadV3.curves (GangRouter decodes field 2, the indexer all of them).
    function curves(address token)
        external
        view
        returns (
            address creator,
            address quote,
            uint128 realQuote,
            uint128 sold,
            uint128 gradAmt,
            uint128 virtualQuote,
            bool graduated,
            uint16 buyTaxBps,
            uint16 sellTaxBps,
            uint16 dividendBps,
            address pair,
            address refPair
        );
    function checkTaxConfig(TaxConfig calldata tax) external view returns (bool ok, string memory reason);
    function checkTaxConfigFor(address creator, TaxConfig calldata tax)
        external
        view
        returns (bool ok, string memory reason);
    function walletRoom(address token, address buyer) external view returns (uint256);
    function gradAmtOf(address token) external view returns (uint256);
    function graduationRemaining(address token) external view returns (uint256);
    /// @dev Goes through CurveLogic: the deploy's self-check calls it to prove the library is linked and live.
    function graduationAmountOf(address quote, address refPool) external view returns (uint256);

    function TOTAL_SUPPLY() external view returns (uint256);
    function MAX_PER_WALLET() external view returns (uint256);
    function TAXED_MIN_SHARE() external view returns (uint256);
    function TARGET_GRAD_BNB() external view returns (uint256);
    function CREATOR_FEE_SHARE_BPS() external view returns (uint256);

    // ---------------------------------------------------------------- 打新
    function create(
        string calldata name,
        string calldata symbol,
        string calldata logoURI,
        string calldata metaURI,
        address quote,
        address refPool,
        MintConfig calldata cfg,
        uint256 devShares
    ) external returns (address token);
    function mint(address token, uint256 shares, uint256 minShares) external returns (uint256 accepted);
    function mintFor(address trader, address token, uint256 shares, uint256 minShares)
        external
        returns (uint256 accepted);
    function withdraw(address token, uint256 shares, uint256 minPayout) external returns (uint256 payout);
    /// @dev §23: listed router, trader == tx.origin; spends the trader's allowance to the router; payout → router.
    function withdrawFor(address trader, address token, uint256 shares, uint256 minPayout)
        external
        returns (uint256 payout);
    function flushFees(address quote) external returns (uint256 amount);

    /// @dev Same 14 fields, same order as FairMintPad.sales (GangRouter decodes field 5, the indexer all of them).
    function sales(address token)
        external
        view
        returns (
            address creator,
            uint64 progressAt,
            uint16 capShares,
            uint16 holdBps,
            address quote,
            uint16 sold,
            bool launched,
            uint16 mintFeeBps,
            uint16 exitFeeBps,
            address gate,
            uint128 sharePrice,
            address pair,
            address refPool,
            uint16 markSold
        );
    function positions(address token, address user) external view returns (uint16 shares);
    function owedFee(address quote) external view returns (uint256);
    function checkConfig(MintConfig calldata cfg, uint256 devShares)
        external
        view
        returns (bool ok, string memory reason);
    /// @dev Goes through FairLogic: the deploy's self-check calls it to prove the library is linked and live.
    function previewCreate(address quote, address refPool, uint256 raiseBnb)
        external
        view
        returns (uint256 raiseQuote, uint256 sharePrice);
    function previewMint(address token, address user, uint256 shares)
        external
        view
        returns (uint256 accepted, uint256 cost, uint256 fee);
    function previewWithdraw(address token, address user, uint256 shares)
        external
        view
        returns (uint256 payout, uint256 fee);
    function exitFeeBpsOf(address token) external view returns (uint256);
    function status(address token) external view returns (Status);

    function CURVE_SUPPLY() external view returns (uint256);
    function MINT_SUPPLY() external view returns (uint256);
    function TOTAL_SHARES() external view returns (uint256);
    function TOKENS_PER_SHARE() external view returns (uint256);
    function MIN_SHARE_BALANCE() external view returns (uint256);
    function MIN_CAP_BPS() external view returns (uint16);
    function MAX_CAP_BPS() external view returns (uint16);
    function MIN_HOLD_BPS() external view returns (uint16);
    function MAX_HOLD_BPS() external view returns (uint16);
}
