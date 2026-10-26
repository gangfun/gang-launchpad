// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {SharedPlatform} from "./SharedPlatform.sol";
import {LaunchpadV3MainnetRefs as M, LaunchpadV3TestnetRefs as T} from "../config/LaunchpadV3DeployRefs.sol";
import {QuoteRegistry} from "../src/launchpad-v2/QuoteRegistry.sol";
import {DividendVault} from "../src/launchpad-v2/DividendVault.sol";
import {PlatformFeeBucket} from "../src/launchpad-v2/PlatformFeeBucket.sol";
import {MigratorV2} from "../src/launchpad-v2/MigratorV2.sol";
import {LaunchpadV3} from "../src/launchpad-v3/LaunchpadV3.sol";
import {TaxTokenDeployerV3} from "../src/launchpad-v3/TaxLaunchTokenV3.sol";
import {TaxHandlerV3} from "../src/launchpad-v3/TaxHandlerV3.sol";
import {TestnetBlacklistQuote} from "../src/launchpad-v3/mocks/TestnetBlacklistQuote.sol";

/// @title DeployLaunchpadV3 — LaunchpadV3 (tax recipient) on BSC testnet (97) or mainnet (56)
/// @notice New: DividendVault (floor 10k), TaxHandlerV3 (recipients, split, pool tax), TaxTokenDeployerV3,
///         LaunchpadV3, MigratorV2, and — unless QUOTE_REGISTRY / PLATFORM_BUCKET name the ones DeployFairMint made —
///         the QuoteRegistry and PlatformFeeBucket shared with 打新 (see SharedPlatform; never the V2 ones). Listed
///         quotes: mainnet USDT at a fixed rate (USDT_PER_15_BNB); testnet the test quote and a blacklist quote (15 units = 15 BNB).
///         Testnet reuses the 打新 testnet Agent ID registry and test quote. Everything is wired before setMigrator,
///         the last call, which is what makes the pad usable.
/// @dev Mainnet broadcast is refused unless LAUNCHPAD_V3_MAINNET_OK=true (spec: no mainnet broadcast before audit).
///      Env: DEPLOYER_PRIVATE_KEY; USDT_PER_15_BNB (mainnet: USDT units, 18 decimals, per 15 BNB); OWNER (the multisig, required on mainnet; gets ownership via Ownable2Step and must
///      accept), optional KEEPER, FEE_VAULT, QUOTE_REGISTRY + PLATFORM_BUCKET (reuse), RECIPIENT + RECIPIENT_LABEL
///      (listed in TaxHandlerV3; testnet default: a fixed demo treasury address).
///      Mainnet: link the live PoolCheck with
///      --libraries src/launchpad-v2/PoolCheck.sol:PoolCheck:0xd2B159820749f178503E4faBCB18A7Ae4492bDb3
contract DeployLaunchpadV3 is SharedPlatform {
    uint256 internal constant MIN_SHARE = 10_000 ether;

    struct Stack {
        address quoteRegistry;
        address bucket;
        address agentId;
        address testQuote;
        address blacklistQuote;
        address vault;
        address handler;
        address tokenDeployer;
        address pad;
        address migrator;
        address recipient;
    }

    function run() external returns (Stack memory s) {
        bool mainnet = block.chainid == 56;
        if (!mainnet && block.chainid != 97) revert WrongChain(block.chainid);
        if (mainnet && _broadcasting() && !vm.envOr("LAUNCHPAD_V3_MAINNET_OK", false)) revert MainnetNotAllowed();

        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address owner = _owner(mainnet, deployer);
        address keeper = vm.envOr("KEEPER", mainnet ? M.KEEPER : deployer);
        address wbnb = mainnet ? M.WBNB : T.WBNB;
        address factory = mainnet ? M.PANCAKE_V2_FACTORY : T.PANCAKE_V2_FACTORY;
        address dexRouter = mainnet ? M.PANCAKE_V2_ROUTER : T.PANCAKE_V2_ROUTER;
        s.recipient = vm.envOr("RECIPIENT", mainnet ? address(0) : T.DEMO_TREASURY);
        string memory label = vm.envOr("RECIPIENT_LABEL", string(mainnet ? "" : "testnet demo treasury"));

        console.log("=== DeployLaunchpadV3 chain", block.chainid, "===");
        console.log("deployer", deployer);
        console.log("owner", owner);
        console.log("keeper", keeper);

        vm.startBroadcast(pk);

        (s.quoteRegistry, s.bucket) = _platform(mainnet, deployer, keeper, M.V2_PLATFORM_BUCKET);
        if (mainnet) {
            s.agentId = M.AGENT_ID_REGISTRY;
            _listQuote(s.quoteRegistry, M.USDT, vm.envUint("USDT_PER_15_BNB"));
        } else {
            s.agentId = vm.envOr("AGENT_ID", T.AGENT_ID_REGISTRY);
            s.testQuote = vm.envOr("TEST_QUOTE", T.TEST_QUOTE);
            s.blacklistQuote = address(new TestnetBlacklistQuote());
            _listQuote(s.quoteRegistry, s.testQuote, TESTNET_QUOTE_PER_15_BNB);
            _listQuote(s.quoteRegistry, s.blacklistQuote, TESTNET_QUOTE_PER_15_BNB);
        }

        DividendVault vault = new DividendVault(deployer);
        TaxHandlerV3 handler = new TaxHandlerV3(deployer, address(vault), s.bucket);
        TaxTokenDeployerV3 tokenDeployer = new TaxTokenDeployerV3();
        LaunchpadV3 pad = new LaunchpadV3(
            deployer,
            s.quoteRegistry,
            address(vault),
            s.bucket,
            address(handler),
            address(tokenDeployer),
            wbnb,
            factory
        );
        MigratorV2 mig = new MigratorV2(factory, address(pad));
        (s.vault, s.handler, s.tokenDeployer, s.pad, s.migrator) =
        (
            address(vault),
            address(handler),
            address(tokenDeployer),
            address(pad),
            address(mig)
        );

        vault.setMinimumShareBalance(MIN_SHARE);
        vault.setLaunchpad(address(pad));
        vault.setOperator(address(handler), true);
        // the migrator is tax-exempt and can never claim: a bag sent there would earn dividends that stay stuck
        vault.setExcluded(address(mig), true);

        handler.setLaunchpad(address(pad));
        handler.setDexRouter(dexRouter);
        handler.setKeeper(keeper);

        PlatformFeeBucket(s.bucket).setOperator(address(pad), true);
        PlatformFeeBucket(s.bucket).setOperator(address(handler), true);

        if (s.recipient != address(0)) handler.list(s.recipient, label);

        pad.setAgentGate(true, s.agentId);
        // reference pools: Pancake V2 pairs and V3 pools on both chains; the USDT → WBNB bridge is mainnet only
        pad.setV3Factory(mainnet ? M.PANCAKE_V3_FACTORY : T.PANCAKE_V3_FACTORY);
        if (mainnet) pad.setBridgePool(M.USDT, M.USDT_WBNB_V3);
        // last: create needs a migrator, so the pad only opens once the fee sinks above accept it
        pad.setMigrator(address(mig));

        _handOver(owner, deployer, address(vault));
        _handOver(owner, deployer, address(handler));
        _handOver(owner, deployer, address(pad));
        _handOver(owner, deployer, s.quoteRegistry);
        _handOver(owner, deployer, s.bucket);

        vm.stopBroadcast();

        _check(s, keeper);
        _log(s, owner, deployer);
    }

    function _check(Stack memory s, address keeper) internal view {
        DividendVault vault = DividendVault(s.vault);
        TaxHandlerV3 handler = TaxHandlerV3(s.handler);
        LaunchpadV3 pad = LaunchpadV3(s.pad);
        if (vault.launchpad() != s.pad) revert WiringCheck("vault.launchpad");
        if (!vault.operators(s.handler)) revert WiringCheck("vault operators");
        if (vault.minimumShareBalance() != MIN_SHARE) revert WiringCheck("vault floor");
        if (!vault.excluded(s.migrator)) revert WiringCheck("vault excludes migrator");
        if (handler.launchpad() != s.pad) revert WiringCheck("handler.launchpad");
        if (handler.keeper() != keeper) revert WiringCheck("handler.keeper");
        if (address(pad.migrator()) != s.migrator || MigratorV2(s.migrator).launchpad() != s.pad) {
            revert WiringCheck("migrator");
        }
        if (address(pad.agentIdRegistry()) != s.agentId || !pad.agentGateEnabled()) revert WiringCheck("agent gate");
        if (!pad.walletCapEnabled()) revert WiringCheck("wallet cap");
        if (address(pad.taxHandler()) != s.handler) revert WiringCheck("pad wiring");
        if (s.recipient != address(0) && !handler.isListed(s.recipient)) {
            revert WiringCheck("recipient listed");
        }
        _checkBucket(s.bucket, keeper, s.pad, s.handler);
        if (!QuoteRegistry(s.quoteRegistry).isQuoted(s.testQuote == address(0) ? M.USDT : s.testQuote)) {
            revert WiringCheck("quote listed");
        }
    }

    function _log(Stack memory s, address owner, address deployer) internal pure {
        console.log("--- LAUNCHPAD V3 ADDRESSES ---");
        console.log("V3_LAUNCHPAD", s.pad);
        console.log("V3_TAX_HANDLER", s.handler);
        console.log("V3_DIVIDEND_VAULT", s.vault);
        console.log("V3_MIGRATOR", s.migrator);
        console.log("V3_TOKEN_DEPLOYER", s.tokenDeployer);
        _logPlatform(s.quoteRegistry, s.bucket);
        console.log("AGENT_ID", s.agentId);
        if (s.testQuote != address(0)) console.log("TEST_QUOTE", s.testQuote);
        if (s.blacklistQuote != address(0)) console.log("BLACKLIST_QUOTE", s.blacklistQuote);
        if (s.recipient != address(0)) {
            console.log("RECIPIENT", s.recipient);
        } else {
            console.log("PENDING owner: handler.list(<partner vault>, <label>) before the partner creates tokens");
        }
        if (owner != deployer) {
            console.log(
                "PENDING owner: acceptOwnership() on pad, tax handler, vault, quote registry, bucket"
            );
            console.log("  (run DeployFairMint with QUOTE_REGISTRY / PLATFORM_BUCKET above BEFORE the owner accepts)");
        }
    }
}
