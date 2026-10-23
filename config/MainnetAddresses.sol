// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title MainnetAddresses (BSC chainId 56 reference — NOT for Chapel)
/// @notice Live v4.1 main-track refs + shared deps. LaunchpadU/S OPT5C mainnet addresses are in the README (2026-10-23). This library does not embed those pads. Chapel addresses are not these values.
/// @dev Import for docs / guarded DeployMainnetDraft only. Do NOT treat Chapel tip pads as these values.
library MainnetAddresses {
    // ---- Live v4.1 main track (already on BSC) ----
    address internal constant LAUNCHPAD = 0x315Ba2e8952D06094CC636b2B84229FA32fb23A7;
    address internal constant MIGRATOR = 0xFcB6278b6FE3f2e3F567bb49cBf8d8883bcE96E9;
    address internal constant GANG = 0x0c6302401aa5325C2E36F170f52C00B1d220B405;
    address internal constant FEE_VAULT = 0x3464aa1097Aa46502Db847E4c6d0A2D52a871Af4;
    address internal constant OWNER = 0x4EEdcDF5fab775e10C0D09951b6F59Ab81ba19d3;
    address internal constant AGENT_ID_REGISTRY = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;

    // ---- Shared Pancake / WBNB ----
    address internal constant PANCAKE_V2_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address internal constant PANCAKE_V2_FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address internal constant PANCAKE_SMART_ROUTER = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    // ---- Not yet deployed (this pack targets these) ----
    // LaunchpadU / MigratorU / LaunchpadS / MigratorS
    // QuoteRegistry / DividendVault / PlatformFeeBucket / PostGradTaxHandler / BuybackBurner
}
