// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {LaunchpadV3MainnetRefs as M, LaunchpadV3TestnetRefs as T} from "../config/LaunchpadV3DeployRefs.sol";
import {QuoteRegistry} from "../src/launchpad-v2/QuoteRegistry.sol";
import {DividendVault} from "../src/launchpad-v2/DividendVault.sol";
import {PlatformFeeBucket} from "../src/launchpad-v2/PlatformFeeBucket.sol";
import {MigratorV2} from "../src/launchpad-v2/MigratorV2.sol";
import {LaunchpadV3} from "../src/launchpad-v3/LaunchpadV3.sol";
import {TaxTokenDeployerV3} from "../src/launchpad-v3/TaxLaunchTokenV3.sol";
import {TaxRouterV3} from "../src/launchpad-v3/TaxRouterV3.sol";
import {RecipientRegistry} from "../src/launchpad-v3/RecipientRegistry.sol";
import {PostGradTaxHandlerV3} from "../src/launchpad-v3/PostGradTaxHandlerV3.sol";
import {TestnetBlacklistQuote} from "../src/launchpad-v3/mocks/TestnetBlacklistQuote.sol";

/// @title DeployLaunchpadV3 — LaunchpadV3 (tax recipient) on BSC testnet (97) or mainnet (56)
/// @notice New on both: DividendVault (floor 10k), TaxRouterV3, RecipientRegistry, PostGradTaxHandlerV3,
///         TaxTokenDeployerV3, LaunchpadV3, MigratorV2. Mainnet reuses the live V2 QuoteRegistry (read-only) and
///         PlatformFeeBucket (its owner adds the pad and router as operators — done here when the deployer is that
///         owner, else printed as pending). Testnet also deploys QuoteRegistry, PlatformFeeBucket and a blacklist quote,
///         and reuses the 打新 testnet Agent ID registry and test quote (QuoteRegistry override: 15 units = 15 BNB).
/// @dev Mainnet broadcast is refused unless LAUNCHPAD_V3_MAINNET_OK=true (spec: no mainnet broadcast before audit).
///      Env: DEPLOYER_PRIVATE_KEY; optional OWNER (gets ownership via Ownable2Step, must accept), KEEPER, FEE_VAULT,
///      RECIPIENT + RECIPIENT_LABEL (listed in RecipientRegistry; testnet default: a fixed demo treasury address).
///      Mainnet: link the live PoolCheck with
///      --libraries src/launchpad-v2/PoolCheck.sol:PoolCheck:0xd2B159820749f178503E4faBCB18A7Ae4492bDb3
contract DeployLaunchpadV3 is Script {
    uint256 internal constant MIN_SHARE = 10_000 ether;
    uint256 internal constant TESTNET_QUOTE_PER_15_BNB = 15 ether;

    error WrongChain(uint256 chainId);
    error MainnetNotAllowed();
    error WiringCheck(string what);

    struct Stack {
        address quoteRegistry;
        address bucket;
        address agentId;
        address testQuote;
        address blacklistQuote;
        address vault;
        address router;
        address recipients;
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
        address owner = vm.envOr("OWNER", deployer);
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

        if (mainnet) {
            s.quoteRegistry = M.QUOTE_REGISTRY;
            s.bucket = M.PLATFORM_BUCKET;
            s.agentId = M.AGENT_ID_REGISTRY;
        } else {
            QuoteRegistry reg = new QuoteRegistry(deployer);
            s.quoteRegistry = address(reg);
            s.bucket = address(new PlatformFeeBucket(deployer, vm.envOr("FEE_VAULT", deployer)));
            s.agentId = vm.envOr("AGENT_ID", T.AGENT_ID_REGISTRY);
            s.testQuote = vm.envOr("TEST_QUOTE", T.TEST_QUOTE);
            s.blacklistQuote = address(new TestnetBlacklistQuote());
            reg.setQuote(s.testQuote, true, TESTNET_QUOTE_PER_15_BNB);
            reg.setQuote(s.blacklistQuote, true, TESTNET_QUOTE_PER_15_BNB);
        }

        DividendVault vault = new DividendVault(deployer);
        TaxRouterV3 router = new TaxRouterV3(deployer, address(vault), s.bucket);
        RecipientRegistry recipients = new RecipientRegistry(deployer);
        PostGradTaxHandlerV3 handler = new PostGradTaxHandlerV3(deployer, address(vault), address(router));
        TaxTokenDeployerV3 tokenDeployer = new TaxTokenDeployerV3();
        LaunchpadV3 pad = new LaunchpadV3(
            deployer,
            s.quoteRegistry,
            address(vault),
            s.bucket,
            address(handler),
            address(router),
            address(recipients),
            address(tokenDeployer),
            wbnb,
            factory
        );
        MigratorV2 mig = new MigratorV2(factory, address(pad));
        (s.vault, s.router, s.recipients, s.handler, s.tokenDeployer, s.pad, s.migrator) =
        (
            address(vault),
            address(router),
            address(recipients),
            address(handler),
            address(tokenDeployer),
            address(pad),
            address(mig)
        );

        vault.setMinimumShareBalance(MIN_SHARE);
        vault.setLaunchpad(address(pad));
        vault.setOperator(address(router), true);
        vault.setOperator(address(handler), true);

        router.setLaunchpad(address(pad));
        router.setSource(address(handler), true);

        handler.setDexRouter(dexRouter);
        handler.setKeeper(keeper);

        pad.setMigrator(address(mig));
        pad.setAgentGate(true, s.agentId);
        if (mainnet) {
            pad.setV3Factory(M.PANCAKE_V3_FACTORY);
            pad.setBridgePool(M.USDT, M.USDT_WBNB_V3);
        }

        if (s.recipient != address(0)) recipients.list(s.recipient, label);

        bool bucketWired = PlatformFeeBucket(s.bucket).owner() == deployer;
        if (bucketWired) {
            PlatformFeeBucket(s.bucket).setOperator(address(pad), true);
            PlatformFeeBucket(s.bucket).setOperator(address(router), true);
        }

        if (owner != deployer) {
            vault.transferOwnership(owner);
            router.transferOwnership(owner);
            recipients.transferOwnership(owner);
            handler.transferOwnership(owner);
            pad.transferOwnership(owner);
            if (!mainnet) {
                QuoteRegistry(s.quoteRegistry).transferOwnership(owner);
                PlatformFeeBucket(s.bucket).transferOwnership(owner);
            }
        }

        vm.stopBroadcast();

        _check(s, keeper, bucketWired);
        _log(s, owner, deployer, bucketWired, mainnet);
    }

    function _check(Stack memory s, address keeper, bool bucketWired) internal view {
        DividendVault vault = DividendVault(s.vault);
        TaxRouterV3 router = TaxRouterV3(s.router);
        LaunchpadV3 pad = LaunchpadV3(s.pad);
        if (vault.launchpad() != s.pad) revert WiringCheck("vault.launchpad");
        if (!vault.operators(s.router) || !vault.operators(s.handler)) revert WiringCheck("vault operators");
        if (vault.minimumShareBalance() != MIN_SHARE) revert WiringCheck("vault floor");
        if (router.launchpad() != s.pad || !router.sources(s.pad) || !router.sources(s.handler)) {
            revert WiringCheck("router launchpad / sources");
        }
        if (PostGradTaxHandlerV3(s.handler).keeper() != keeper) revert WiringCheck("handler.keeper");
        if (address(pad.migrator()) != s.migrator || MigratorV2(s.migrator).launchpad() != s.pad) {
            revert WiringCheck("migrator");
        }
        if (address(pad.agentIdRegistry()) != s.agentId || !pad.agentGateEnabled()) revert WiringCheck("agent gate");
        if (!pad.walletCapEnabled()) revert WiringCheck("wallet cap");
        if (pad.taxHandler() != s.handler || address(pad.router()) != s.router) revert WiringCheck("pad wiring");
        if (s.recipient != address(0) && !RecipientRegistry(s.recipients).isListed(s.recipient)) {
            revert WiringCheck("recipient listed");
        }
        if (bucketWired) {
            PlatformFeeBucket b = PlatformFeeBucket(s.bucket);
            if (!b.operators(s.pad) || !b.operators(s.router)) revert WiringCheck("bucket operators");
        }
    }

    function _log(Stack memory s, address owner, address deployer, bool bucketWired, bool mainnet) internal pure {
        console.log("--- LAUNCHPAD V3 ADDRESSES ---");
        console.log("V3_LAUNCHPAD", s.pad);
        console.log("V3_TAX_ROUTER", s.router);
        console.log("V3_RECIPIENT_REGISTRY", s.recipients);
        console.log("V3_POSTGRAD_HANDLER", s.handler);
        console.log("V3_DIVIDEND_VAULT", s.vault);
        console.log("V3_MIGRATOR", s.migrator);
        console.log("V3_TOKEN_DEPLOYER", s.tokenDeployer);
        console.log("QUOTE_REGISTRY", s.quoteRegistry);
        console.log("PLATFORM_BUCKET", s.bucket);
        console.log("AGENT_ID", s.agentId);
        if (s.testQuote != address(0)) console.log("TEST_QUOTE", s.testQuote);
        if (s.blacklistQuote != address(0)) console.log("BLACKLIST_QUOTE", s.blacklistQuote);
        if (s.recipient != address(0)) {
            console.log("RECIPIENT", s.recipient);
        } else {
            console.log("PENDING owner: recipients.list(<partner vault>, <label>) before the partner creates tokens");
        }
        if (!bucketWired) {
            console.log("PENDING bucket owner: setOperator(V3_LAUNCHPAD, true) and setOperator(V3_TAX_ROUTER, true)");
        }
        if (owner != deployer) {
            console.log("PENDING owner: acceptOwnership() on pad, router, recipients, handler, vault");
            if (!mainnet) console.log("PENDING owner: acceptOwnership() on quote registry, bucket");
        }
    }

    function _broadcasting() internal view returns (bool) {
        return vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
    }
}
