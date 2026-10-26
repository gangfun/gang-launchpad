// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {SharedPlatform} from "./SharedPlatform.sol";
import {FairMintMainnetRefs as M, FairMintTestnetRefs as T} from "../config/FairMintDeployRefs.sol";
import {QuoteRegistry} from "../src/launchpad-v2/QuoteRegistry.sol";
import {DividendVault} from "../src/launchpad-v2/DividendVault.sol";
import {PlatformFeeBucket} from "../src/launchpad-v2/PlatformFeeBucket.sol";
import {MigratorV2} from "../src/launchpad-v2/MigratorV2.sol";
import {MockSPCXB} from "../src/launchpad-v2/mocks/MockSPCXB.sol";
import {FairMintPad} from "../src/fair-mint/FairMintPad.sol";
import {FairTokenDeployer} from "../src/fair-mint/FairToken.sol";
import {HolderRewardHandler} from "../src/fair-mint/HolderRewardHandler.sol";
import {TestnetAgentId} from "../src/fair-mint/mocks/TestnetAgentId.sol";

/// @title DeployFairMint — 打新发射 stack on BSC testnet (97) or mainnet (56)
/// @notice New: DividendVault (floor 10k), HolderRewardHandler, FairTokenDeployer, FairMintPad, MigratorV2, and —
///         unless QUOTE_REGISTRY / PLATFORM_BUCKET name the ones DeployLaunchpadV3 made — the QuoteRegistry and
///         PlatformFeeBucket shared with LaunchpadV3 (see SharedPlatform; never the V2 ones). Listed quotes: mainnet
///         USDT at a fixed rate (USDT_PER_15_BNB); testnet the mock quote (15 mock units = 15 BNB, so a sale raises 15 units).
///         Testnet reuses the testnet Agent ID registry and mock quote; NEW_MOCKS=true deploys fresh ones.
///         Everything is wired before setMigrator, the last call, which is what makes the pad usable.
/// @dev Mainnet broadcast is refused unless FAIR_MINT_MAINNET_OK=true (spec: no mainnet broadcast before audit).
///      Env: DEPLOYER_PRIVATE_KEY; USDT_PER_15_BNB (mainnet: USDT units, 18 decimals, per 15 BNB); OWNER (the multisig, required on mainnet; gets ownership via Ownable2Step and must
///      accept), optional KEEPER, FEE_VAULT, QUOTE_REGISTRY + PLATFORM_BUCKET (reuse), AGENT_ID / TEST_QUOTE
///      (testnet overrides), NEW_MOCKS.
///      Mainnet: link the live PoolCheck with
///      --libraries src/launchpad-v2/PoolCheck.sol:PoolCheck:0xd2B159820749f178503E4faBCB18A7Ae4492bDb3
contract DeployFairMint is SharedPlatform {
    uint256 internal constant MIN_SHARE = 10_000 ether;

    struct Stack {
        address quoteRegistry;
        address bucket;
        address agentId;
        address testQuote;
        address vault;
        address handler;
        address tokenDeployer;
        address pad;
        address migrator;
    }

    function run() external returns (Stack memory s) {
        bool mainnet = block.chainid == 56;
        if (!mainnet && block.chainid != 97) revert WrongChain(block.chainid);
        if (mainnet && _broadcasting() && !vm.envOr("FAIR_MINT_MAINNET_OK", false)) revert MainnetNotAllowed();

        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address owner = _owner(mainnet, deployer);
        address keeper = vm.envOr("KEEPER", mainnet ? M.KEEPER : deployer);
        address wbnb = mainnet ? M.WBNB : T.WBNB;
        address factory = mainnet ? M.PANCAKE_V2_FACTORY : T.PANCAKE_V2_FACTORY;
        address router = mainnet ? M.PANCAKE_V2_ROUTER : T.PANCAKE_V2_ROUTER;

        console.log("=== DeployFairMint chain", block.chainid, "===");
        console.log("deployer", deployer);
        console.log("owner", owner);
        console.log("keeper", keeper);

        vm.startBroadcast(pk);

        (s.quoteRegistry, s.bucket) = _platform(mainnet, deployer, keeper, M.V2_PLATFORM_BUCKET);
        if (mainnet) {
            s.agentId = M.AGENT_ID_REGISTRY;
            _listQuote(s.quoteRegistry, M.USDT, vm.envUint("USDT_PER_15_BNB"));
        } else {
            // reuse the testnet Agent ID registry and test quote (NEW_MOCKS=true deploys fresh ones)
            bool fresh = vm.envOr("NEW_MOCKS", false);
            s.agentId = fresh ? address(new TestnetAgentId()) : vm.envOr("AGENT_ID", T.AGENT_ID_REGISTRY);
            s.testQuote = fresh ? address(new MockSPCXB()) : vm.envOr("TEST_QUOTE", T.TEST_QUOTE);
            _listQuote(s.quoteRegistry, s.testQuote, TESTNET_QUOTE_PER_15_BNB);
        }

        DividendVault vault = new DividendVault(deployer);
        HolderRewardHandler handler = new HolderRewardHandler(deployer, address(vault), s.bucket);
        FairTokenDeployer tokenDeployer = new FairTokenDeployer();
        FairMintPad pad = new FairMintPad(
            deployer, s.quoteRegistry, address(vault), s.bucket, address(handler), address(tokenDeployer), wbnb, factory
        );
        MigratorV2 mig = new MigratorV2(factory, address(pad));
        (s.vault, s.handler, s.tokenDeployer, s.pad, s.migrator) =
        (address(vault), address(handler), address(tokenDeployer), address(pad), address(mig));

        vault.setMinimumShareBalance(MIN_SHARE);
        vault.setLaunchpad(address(pad));
        vault.setOperator(address(handler), true);

        handler.setPad(address(pad));
        handler.setDexRouter(router);
        handler.setKeeper(keeper);

        PlatformFeeBucket(s.bucket).setOperator(address(pad), true);
        PlatformFeeBucket(s.bucket).setOperator(address(handler), true);

        pad.setAgentGate(true, s.agentId);
        if (mainnet) {
            pad.setV3Factory(M.PANCAKE_V3_FACTORY);
            pad.setBridgePool(M.USDT, M.USDT_WBNB_V3);
        }
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
        HolderRewardHandler handler = HolderRewardHandler(s.handler);
        FairMintPad pad = FairMintPad(s.pad);
        if (vault.launchpad() != s.pad) revert WiringCheck("vault.launchpad");
        if (!vault.operators(s.handler)) revert WiringCheck("vault operator handler");
        if (vault.minimumShareBalance() != MIN_SHARE) revert WiringCheck("vault floor");
        if (address(handler.pad()) != s.pad) revert WiringCheck("handler.pad");
        if (handler.keeper() != keeper) revert WiringCheck("handler.keeper");
        if (address(pad.migrator()) != s.migrator) revert WiringCheck("pad.migrator");
        if (MigratorV2(s.migrator).launchpad() != s.pad) revert WiringCheck("migrator.launchpad");
        if (address(pad.agentIdRegistry()) != s.agentId || !pad.agentGateEnabled()) revert WiringCheck("agent gate");
        if (pad.taxHandler() != s.handler) revert WiringCheck("pad.taxHandler");
        _checkBucket(s.bucket, keeper, s.pad, s.handler);
        if (!QuoteRegistry(s.quoteRegistry).isQuoted(s.testQuote == address(0) ? M.USDT : s.testQuote)) {
            revert WiringCheck("quote listed");
        }
    }

    function _log(Stack memory s, address owner, address deployer) internal pure {
        console.log("--- FAIR MINT ADDRESSES ---");
        console.log("FAIR_MINT_PAD", s.pad);
        console.log("FAIR_MINT_MIGRATOR", s.migrator);
        console.log("HOLDER_REWARD_HANDLER", s.handler);
        console.log("FAIR_DIVIDEND_VAULT", s.vault);
        console.log("FAIR_TOKEN_DEPLOYER", s.tokenDeployer);
        _logPlatform(s.quoteRegistry, s.bucket);
        console.log("AGENT_ID", s.agentId);
        if (s.testQuote != address(0)) console.log("TEST_QUOTE", s.testQuote);
        if (owner != deployer) {
            console.log("PENDING owner: acceptOwnership() on pad, handler, vault, quote registry, bucket");
        }
    }
}
