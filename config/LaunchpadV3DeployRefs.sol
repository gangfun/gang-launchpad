// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title LaunchpadV3MainnetRefs — BSC 56 inputs for script/DeployLaunchpadV3.s.sol
/// @notice Reuses the live V2 QuoteRegistry (read-only) and PlatformFeeBucket (adds the pad and router as operators).
///         Addresses from docs/MAINNET-LAUNCHPAD-V2-ADDRESSES-2026-10-23.md (bucket / registry owner = 0x4EEd…, an EOA).
library LaunchpadV3MainnetRefs {
    address internal constant QUOTE_REGISTRY = 0x053C2868e54921afEd7742bbb4c4fDA99a12060D;
    address internal constant PLATFORM_BUCKET = 0xBDDd8F275D7Cb65f5454D0bEDf0463792878F111;
    address internal constant AGENT_ID_REGISTRY = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;
    address internal constant KEEPER = 0xB6f1F1BFb92476Abb0998B425dE0deC5F927cFc7;
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant USDT_WBNB_V3 = 0x36696169C63e42cd08ce11f5deeBbCeBae652050;
    address internal constant PANCAKE_V2_FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address internal constant PANCAKE_V2_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address internal constant PANCAKE_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
}

/// @title LaunchpadV3TestnetRefs — BSC 97. Agent ID registry and test quote are the ones the 打新 testnet deployment
///         made (gang-launchpad docs/TESTNET-FAIR-MINT-2026-10-26.md), so testnet wallets that registered there work here.
library LaunchpadV3TestnetRefs {
    address internal constant WBNB = 0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd;
    address internal constant PANCAKE_V2_FACTORY = 0x6725F303b657a9451d8BA641348b6761A6CC7a17;
    address internal constant PANCAKE_V2_ROUTER = 0xD99D1c33F9fC3444f8101754aBC46c52416550D1;
    address internal constant AGENT_ID_REGISTRY = 0x24D0A2106AC3Ebf7d770d19f4aF0a5149ebe5B2a;
    address internal constant TEST_QUOTE = 0x02B3dE73aF2c1F99c7EFbDb65bcB960AACF4CF1c;
    /// @dev Demo treasury (listed tax recipient): an address nobody holds a key for, so its balance only ever grows
    ///      from tax pushes. = 0xe22eEE60677911Ef25a359285Fb09786AC728c77
    address internal constant DEMO_TREASURY = address(uint160(uint256(keccak256("gang-v3-testnet-treasury"))));
}
