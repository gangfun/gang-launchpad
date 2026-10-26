// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title FairMintMainnetRefs — BSC 56 inputs for script/DeployFairMint.s.sol
/// @notice The new pads get their own multisig-owned QuoteRegistry and PlatformFeeBucket (script/SharedPlatform.sol),
///         not the live V2 ones (owner 0x4EEd…, an EOA). Addresses from docs/MAINNET-LAUNCHPAD-V2-ADDRESSES-2026-10-23.md,
///         read on-chain 2026-10-26.
library FairMintMainnetRefs {
    /// @notice The live V2 bucket — NOT used by the new pads; only read for its feeVault / burner (SharedPlatform).
    address internal constant V2_PLATFORM_BUCKET = 0xBDDd8F275D7Cb65f5454D0bEDf0463792878F111;
    /// @notice Already-deployed PoolCheck library; link with
    ///         --libraries src/launchpad-v2/PoolCheck.sol:PoolCheck:0xd2B159820749f178503E4faBCB18A7Ae4492bDb3
    address internal constant POOL_CHECK = 0xd2B159820749f178503E4faBCB18A7Ae4492bDb3;
    address internal constant AGENT_ID_REGISTRY = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;
    address internal constant KEEPER = 0xB6f1F1BFb92476Abb0998B425dE0deC5F927cFc7;

    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant USDT_WBNB_V3 = 0x36696169C63e42cd08ce11f5deeBbCeBae652050;
    /// @dev USDT/WBNB Pancake V3 0.01%: the deepest pool, counter WBNB (no bridge) — the refPool for a USDT quote
    address internal constant USDT_REF_POOL = 0x172fcD41E0913e95784454622d1c3724f546f849;
    address internal constant PANCAKE_V2_FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address internal constant PANCAKE_V2_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address internal constant PANCAKE_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
}

/// @title FairMintTestnetRefs — BSC 97 (PancakeSwap testnet, checked on-chain 2026-10-26: router.factory / WETH match)
library FairMintTestnetRefs {
    address internal constant WBNB = 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd;
    address internal constant PANCAKE_V2_FACTORY = 0x6725F303b657a9451d8BA641348b6761A6CC7a17;
    address internal constant PANCAKE_V2_ROUTER = 0xD99D1c33F9fC3444f8101754aBC46c52416550D1;
    /// @dev Same address as mainnet (PancakeSwap V3 deploys deterministically); checked on chain 2026-10-27.
    address internal constant PANCAKE_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    /// @notice From the first 打新 testnet deployment (docs/TESTNET-FAIR-MINT-2026-10-26.md); later stacks reuse them so
    ///         wallets registered once work everywhere (LaunchpadV3 testnet uses the same two).
    address internal constant AGENT_ID_REGISTRY = 0x24D0A2106AC3Ebf7d770d19f4aF0a5149ebe5B2a;
    address internal constant TEST_QUOTE = 0x02B3dE73aF2c1F99c7EFbDb65bcB960AACF4CF1c;
}
