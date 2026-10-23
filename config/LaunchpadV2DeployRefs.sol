// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title LaunchpadV2DeployRefs — BSC 56 refs for script/DeployWireMainnetV2.s.sol
/// @notice Historical deploy/wire inputs from the 2026-10-23 REFPOOL pack.
///         Live LaunchpadV2 addresses are in MainnetAddresses and
///         docs/MAINNET-LAUNCHPAD-V2-ADDRESSES-2026-10-23.md.
/// @dev LEGACY_SOFT / LEGACY_U / LEGACY_S are the do-not-touch list recorded by that
///      pack. They are not the Soft/U/S addresses in README Appendix B/C.
///      Do not rebroadcast this script.
library LaunchpadV2DeployRefs {
    address internal constant LEGACY_OWNER = 0x4EEdcDF5fab775e10C0D09951b6F59Ab81ba19d3;
    address internal constant GANG = 0x0c6302401aa5325C2E36F170f52C00B1d220B405;
    address internal constant FEE_VAULT = 0x3464aa1097Aa46502Db847E4c6d0A2D52a871Af4;
    /// @notice Live BuybackBurner — REUSE, do not redeploy
    address internal constant BUYBACK_BURNER = 0x2aC14C462901F990ae7647D6AcafEaf50Cc8f8dF;
    address internal constant AGENT_ID_REGISTRY = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;

    address internal constant PANCAKE_V2_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address internal constant PANCAKE_V2_FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address internal constant PANCAKE_SMART_ROUTER = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;
    address internal constant PANCAKE_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;

    // Do-not-touch list from the V2 deploy pack (not README Appendix B/C).
    address internal constant LEGACY_SOFT = 0x4E6f13c8A453c1b8b4E20b590082bb233a5b80d7;
    address internal constant LEGACY_U = 0xF81C4E51c48466c6025B0165b1Ea0F6978c712cb;
    address internal constant LEGACY_S = 0x60aee38576035E757deD30fF8db8A8DA476430C1;
}
