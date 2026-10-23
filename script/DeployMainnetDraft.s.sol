// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {MainnetAddresses as A} from "../config/MainnetAddresses.sol";
import {LaunchpadU} from "../src/stocks/LaunchpadU.sol";
import {LaunchpadS} from "../src/stocks/LaunchpadS.sol";
import {MigratorS} from "../src/stocks/MigratorS.sol";
import {QuoteRegistry} from "../src/stocks/QuoteRegistry.sol";
import {DividendVault} from "../src/stocks/DividendVault.sol";
import {PlatformFeeBucket} from "../src/stocks/PlatformFeeBucket.sol";
import {PostGradTaxHandler} from "../src/stocks/PostGradTaxHandler.sol";
import {BuybackBurner} from "../src/stocks/BuybackBurner.sol";

/// @title DeployMainnetDraft — DRAFT ONLY, broadcast intentionally disabled
/// @notice Documents constructor wiring for Gang Pair (U untaxed/taxed + S whitelist).
/// @dev HARD GUARD: `run()` always reverts. Do NOT remove the guard without Lazy explicit approve + separate PR.
///      Never use Chapel MockWBNB / MockQUOTE / MockPairFactory / MockAgentId / MockGANG here.
///      CHECKLIST before any real broadcast: setDev; setOperator(handler) on U+S div+bucket (L2);
///      taxHandler(U/S).setRouter(Pancake)+setKeeper; burner.setRouter/setWbnb/setGang; pad.setPlatformToken(liveGANG) OR seed.
contract DeployMainnetDraft is Script {
    error BroadcastDisabled(string reason);

    function run() external {
        // ---- HARD STOP: this script must never broadcast to chain 56 ----
        revert BroadcastDisabled(unicode"DeployMainnetDraft: no mainnet broadcast — Lazy approve + remove this guard in a separate change");

        // Unreachable reference wiring (kept for developer review):
        // address owner = A.OWNER;
        // address feeVault = A.FEE_VAULT;
        // address agent = A.AGENT_ID_REGISTRY;
        // address wbnb = A.WBNB;
        // address factory = A.PANCAKE_V2_FACTORY;
        // address gang = A.GANG;
        //
        // QuoteRegistry regU = new QuoteRegistry(owner);
        // DividendVault divU = new DividendVault(owner);
        // PlatformFeeBucket bucketU = new PlatformFeeBucket(owner, feeVault);
        // PostGradTaxHandler handler = new PostGradTaxHandler(owner, address(divU), address(bucketU));
        // BuybackBurner burner = new BuybackBurner(owner);
        // burner.setRouter(A.PANCAKE_V2_ROUTER);
        // burner.setWbnb(wbnb);
        // burner.setGang(gang); // R5: real GANG only — real quote→GANG Pancake swap
        // burner.setSmartRouter(0x13f4EA83D0bd40E75C8222255bc855a974568Dd4); // OPT5B default already set in ctor
        // bucketU.setBurner(address(burner));
        // // OPT5B: keeper collectPlatformSmart(quote, minGangOut, swapData) for bStock V3 routes
        // // OPT5B flush: bucket.requestFlush(quote); wait 7d; bucket.flushStuckQuoteToTreasury(quote)
        // //             successful collectPlatform/Smart clears flush request
        //
        // LaunchpadU padU = new LaunchpadU(owner, address(regU), address(divU), address(bucketU), address(handler), wbnb, factory);
        // MigratorS migU = new MigratorS(factory, address(padU));
        // padU.setMigrator(address(migU));
        // padU.setAgentGate(true, agent);   // bind registry (gate already defaults true)
        // padU.setDev(<BAW_DEV_WALLET>, true); // REQUIRED — create is Dev-allowlist only
        // // walletCapEnabled already true
        // divU.setLaunchpad(address(padU));
        // bucketU.setLaunchpad(address(padU));
        // // L2 REQUIRED (Finding L2 / Tip B): handler must be operator or depositReward/notifyAccrual revert OnlyLaunchpad
        // divU.setOperator(address(handler), true);
        // bucketU.setOperator(address(handler), true);
        // // Finding 2: taxHandler.setRouter(A.PANCAKE_V2_ROUTER); then keeper calls process(token, minOut)
        // // H1 REQUIRED: handler.setKeeper(<KEEPER>); process() is keeper/owner-only and minOut must be > 0
        //
        // // LaunchpadS mirror (product D: inner+outer 1% tax; whitelist quotes via QuoteRegistry)
        // QuoteRegistry regS = new QuoteRegistry(owner);
        // DividendVault divS = new DividendVault(owner);
        // PlatformFeeBucket bucketS = new PlatformFeeBucket(owner, feeVault);
        // PostGradTaxHandler handlerS = new PostGradTaxHandler(owner, address(divS), address(bucketS));
        // BuybackBurner burnerS = new BuybackBurner(owner);
        // burnerS.setRouter(A.PANCAKE_V2_ROUTER);
        // burnerS.setWbnb(wbnb);
        // burnerS.setGang(gang);
        // bucketS.setBurner(address(burnerS));
        // LaunchpadS padS = new LaunchpadS(owner, address(regS), address(divS), address(bucketS), address(handlerS), wbnb, factory);
        // MigratorS migS = new MigratorS(factory, address(padS));
        // padS.setMigrator(address(migS));
        // padS.setAgentGate(true, agent);   // bind registry (gate already defaults true)
        // // OPT5 QuoteRegistry ops override (bStock appendix C) — amount>0 locks that gradAmt (skips V2 spot):
        // // regU/regS.setQuote(NVDAB, true, <≈15BNB-equiv quote units>);
        // // NVDAB 0x02Fca66C1D1aFB4E2A7884261eB00F63598a7436
        // // TSLAB 0x5b1910eAaD6450E50f816082Aa078C41F10C292f
        // // CRCLB 0x80f3D493EBCe97e343c53D29a137942416B4ffC0
        // // MUB   0xcdf2f3e0fa43C47A6662a91C9E4a7C5f69762699
        // // SNDKB 0x3eE4dF61bd4F867E349BEaE8bFE07bc31b4850fb
        // // SPCXB 0xbe9d156892e55e7154bcd3cb0fea677f9d3103e1
        // // S whitelist still needs setQuote(..., true, ...); U uses same registry for override only.
        // // OPT5B: bucket.requestFlush(quote) then after 7d flushStuckQuoteToTreasury(quote)
        // // burnerS.setSmartRouter(...); keeper uses collectPlatformSmart for bStock
        // padS.setDev(<BAW_DEV_WALLET>, true);
        // divS.setLaunchpad(address(padS));
        // bucketS.setLaunchpad(address(padS));
        // // L2 REQUIRED: handler operator on S vault/bucket (same as U)
        // divS.setOperator(address(handlerS), true);
        // bucketS.setOperator(address(handlerS), true);
        // // H1 REQUIRED: handlerS.setRouter(A.PANCAKE_V2_ROUTER); handlerS.setKeeper(<KEEPER>);
        //
        // console.log("padU", address(padU));
        // console.log("padS", address(padS));
    }
}
