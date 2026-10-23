// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title MainnetAddresses (BSC chainId 56 reference — NOT for Chapel)
/// @notice Live v4.1 main-track refs, shared deps, and LaunchpadV2 (2026-10-23). LaunchpadU/S OPT5C addresses stay in the README. Chapel addresses are not these values.
/// @dev Import for docs / guarded scripts only. Do NOT treat Chapel tip pads as these values. LaunchpadV2 deploy-script refs (including that pack's do-not-touch list) are in LaunchpadV2DeployRefs.
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

    // ---- LaunchpadV2 REFPOOL (deployed 2026-10-23, startBlock 129311617) ----
    // Table: docs/MAINNET-LAUNCHPAD-V2-ADDRESSES-2026-10-23.md
    address internal constant LAUNCHPAD_V2 = 0x1B8F3f69DFa0a7F63d308C7EB0Fd38D8b099966E;
    address internal constant MIGRATOR_V2 = 0x2D54351657647824c92a36c309A8ed40715968F6;
    address internal constant QUOTE_REGISTRY_V2 = 0x053C2868e54921afEd7742bbb4c4fDA99a12060D;
    address internal constant DIVIDEND_VAULT_V2 = 0x5e2Dd1D439b251d64B4147D8947445f83f3A2D62;
    address internal constant PLATFORM_FEE_BUCKET_V2 = 0xBDDd8F275D7Cb65f5454D0bEDf0463792878F111;
    address internal constant POST_GRAD_TAX_HANDLER_V2 = 0xa2bd8e511Cf01aA8F9693a841FD6ee6E30253e29;
    address internal constant POOL_CHECK_V2 = 0xd2B159820749f178503E4faBCB18A7Ae4492bDb3;
    /// @notice Reused by LaunchpadV2. Not the LaunchpadU / LaunchpadS burners.
    address internal constant BUYBACK_BURNER_V2 = 0x2aC14C462901F990ae7647D6AcafEaf50Cc8f8dF;
}
