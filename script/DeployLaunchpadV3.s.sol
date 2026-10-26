// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {SharedPlatform} from "./SharedPlatform.sol";
import {LaunchpadV3MainnetRefs as M, LaunchpadV3TestnetRefs as T} from "../config/LaunchpadV3DeployRefs.sol";
import {QuoteRegistry} from "../src/launchpad-v2/QuoteRegistry.sol";
import {SharedDividendVault} from "../src/common/SharedDividendVault.sol";
import {PlatformFeeBucket} from "../src/launchpad-v2/PlatformFeeBucket.sol";
import {LaunchpadV3} from "../src/launchpad-v3/LaunchpadV3.sol";
import {TaxRouterV3} from "../src/launchpad-v3/TaxRouterV3.sol";
import {RecipientRegistry} from "../src/launchpad-v3/RecipientRegistry.sol";
import {PostGradTaxHandlerV3} from "../src/launchpad-v3/PostGradTaxHandlerV3.sol";
import {TestnetBlacklistQuote} from "../src/launchpad-v3/mocks/TestnetBlacklistQuote.sol";

/// @title DeployLaunchpadV3 — LaunchpadV3 (tax recipient) on BSC testnet (97) or mainnet (56)
/// @notice New: TaxRouterV3, RecipientRegistry, PostGradTaxHandlerV3, LaunchpadV3, and — unless QUOTE_REGISTRY /
///         PLATFORM_BUCKET / DIVIDEND_VAULT / MIGRATOR / TOKEN_DEPLOYER name the ones DeployFairMint made — the five
///         contracts shared with 打新 (see SharedPlatform; never the V2 ones). This core's vault floor is 10k. Listed
///         quotes: mainnet USDT at a fixed rate (USDT_PER_15_BNB); testnet the test quote and a blacklist quote (15 units = 15 BNB).
///         Testnet reuses the 打新 testnet Agent ID registry and test quote. Everything is wired before setMigrator,
///         the last call, which is what makes the pad usable.
/// @dev Mainnet broadcast is refused unless LAUNCHPAD_V3_MAINNET_OK=true (spec: no mainnet broadcast before audit).
///      Env: DEPLOYER_PRIVATE_KEY; USDT_PER_15_BNB (mainnet: USDT units, 18 decimals, per 15 BNB); OWNER (the multisig, required on mainnet; gets ownership via Ownable2Step and must
///      accept), optional KEEPER, FEE_VAULT, QUOTE_REGISTRY + PLATFORM_BUCKET + DIVIDEND_VAULT + MIGRATOR +
///      TOKEN_DEPLOYER (reuse), RECIPIENT + RECIPIENT_LABEL
///      (listed in RecipientRegistry; testnet default: a fixed demo treasury address).
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

        (s.vault, s.migrator, s.tokenDeployer) = _shared(deployer, factory);
        SharedDividendVault vault = SharedDividendVault(s.vault);
        TaxRouterV3 router = new TaxRouterV3(deployer, address(vault), s.bucket);
        RecipientRegistry recipients = new RecipientRegistry(deployer);
        PostGradTaxHandlerV3 handler = new PostGradTaxHandlerV3(deployer, address(vault), address(router));
        LaunchpadV3 pad = new LaunchpadV3(
            deployer,
            s.quoteRegistry,
            address(vault),
            s.bucket,
            address(handler),
            address(router),
            address(recipients),
            s.tokenDeployer,
            wbnb,
            factory
        );
        (s.router, s.recipients, s.handler, s.pad) = (address(router), address(recipients), address(handler), address(pad));

        _wireCore(s.vault, s.migrator, s.tokenDeployer, s.pad, MIN_SHARE, _ops(s));

        router.setLaunchpad(address(pad));
        router.setSource(address(handler), true);

        handler.setDexRouter(dexRouter);
        handler.setKeeper(keeper);

        PlatformFeeBucket(s.bucket).setOperator(address(pad), true);
        PlatformFeeBucket(s.bucket).setOperator(address(router), true);

        if (s.recipient != address(0)) recipients.list(s.recipient, label);

        pad.setAgentGate(true, s.agentId);
        if (mainnet) {
            pad.setV3Factory(M.PANCAKE_V3_FACTORY);
            pad.setBridgePool(M.USDT, M.USDT_WBNB_V3);
        }
        // last: create needs a migrator, so the pad only opens once the fee sinks above accept it
        pad.setMigrator(s.migrator);

        _handOver(owner, deployer, s.vault);
        _handOver(owner, deployer, s.migrator);
        _handOver(owner, deployer, s.tokenDeployer);
        _handOver(owner, deployer, address(router));
        _handOver(owner, deployer, address(recipients));
        _handOver(owner, deployer, address(handler));
        _handOver(owner, deployer, address(pad));
        _handOver(owner, deployer, s.quoteRegistry);
        _handOver(owner, deployer, s.bucket);

        vm.stopBroadcast();

        _check(s, keeper);
        _log(s, owner, deployer);
    }

    /// @dev Vault operators bound to this core: the tax router (dividend leg) and the post-grad handler (shares).
    function _ops(Stack memory s) internal pure returns (address[] memory ops) {
        ops = new address[](2);
        (ops[0], ops[1]) = (s.router, s.handler);
    }

    function _check(Stack memory s, address keeper) internal view {
        TaxRouterV3 router = TaxRouterV3(s.router);
        LaunchpadV3 pad = LaunchpadV3(s.pad);
        _checkCore(s.vault, s.migrator, s.tokenDeployer, s.pad, MIN_SHARE, _ops(s));
        if (router.launchpad() != s.pad || !router.sources(s.pad) || !router.sources(s.handler)) {
            revert WiringCheck("router launchpad / sources");
        }
        if (PostGradTaxHandlerV3(s.handler).keeper() != keeper) revert WiringCheck("handler.keeper");
        if (address(pad.migrator()) != s.migrator || address(pad.tokenDeployer()) != s.tokenDeployer) {
            revert WiringCheck("migrator / deployer");
        }
        if (address(pad.dividendVault()) != s.vault) revert WiringCheck("pad.dividendVault");
        if (address(pad.agentIdRegistry()) != s.agentId || !pad.agentGateEnabled()) revert WiringCheck("agent gate");
        if (!pad.walletCapEnabled()) revert WiringCheck("wallet cap");
        if (pad.taxHandler() != s.handler || address(pad.router()) != s.router) revert WiringCheck("pad wiring");
        if (s.recipient != address(0) && !RecipientRegistry(s.recipients).isListed(s.recipient)) {
            revert WiringCheck("recipient listed");
        }
        _checkBucket(s.bucket, keeper, s.pad, s.router);
        if (!QuoteRegistry(s.quoteRegistry).isQuoted(s.testQuote == address(0) ? M.USDT : s.testQuote)) {
            revert WiringCheck("quote listed");
        }
    }

    function _log(Stack memory s, address owner, address deployer) internal pure {
        console.log("--- LAUNCHPAD V3 ADDRESSES ---");
        console.log("V3_LAUNCHPAD", s.pad);
        console.log("V3_TAX_ROUTER", s.router);
        console.log("V3_RECIPIENT_REGISTRY", s.recipients);
        console.log("V3_POSTGRAD_HANDLER", s.handler);
        _logPlatform(s.quoteRegistry, s.bucket);
        _logShared(s.vault, s.migrator, s.tokenDeployer);
        console.log("AGENT_ID", s.agentId);
        if (s.testQuote != address(0)) console.log("TEST_QUOTE", s.testQuote);
        if (s.blacklistQuote != address(0)) console.log("BLACKLIST_QUOTE", s.blacklistQuote);
        if (s.recipient != address(0)) {
            console.log("RECIPIENT", s.recipient);
        } else {
            console.log("PENDING owner: recipients.list(<partner vault>, <label>) before the partner creates tokens");
        }
        if (owner != deployer) {
            console.log(
                "PENDING owner: acceptOwnership() on pad, router, recipients, handler, and the five shared contracts"
            );
            console.log("  (run DeployFairMint with the five shared addresses above BEFORE the owner accepts)");
        }
    }
}
