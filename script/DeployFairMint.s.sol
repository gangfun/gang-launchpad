// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {SharedPlatform} from "./SharedPlatform.sol";
import {FairMintMainnetRefs as M, FairMintTestnetRefs as T} from "../config/FairMintDeployRefs.sol";
import {QuoteRegistry} from "../src/launchpad-v2/QuoteRegistry.sol";
import {SharedPlatformFeeBucket as PlatformFeeBucket} from "../src/common/SharedPlatformFeeBucket.sol";
import {MockSPCXB} from "../src/launchpad-v2/mocks/MockSPCXB.sol";
import {FairMintPad} from "../src/fair-mint/FairMintPad.sol";
import {GangTaxHandler} from "../src/gang/GangTaxHandler.sol";
import {TestnetAgentId} from "../src/fair-mint/mocks/TestnetAgentId.sol";

/// @title DeployFairMint — 打新发射 stack on BSC testnet (97) or mainnet (56)
/// @notice New: GangTaxHandler, FairMintPad, and — unless QUOTE_REGISTRY / PLATFORM_BUCKET / DIVIDEND_VAULT /
///         MIGRATOR / TOKEN_DEPLOYER name the ones DeployLaunchpadV3 made — the five contracts shared with LaunchpadV3
///         (see SharedPlatform; never the V2 ones). This core's vault floor is 10k. Quotes: mainnet USDT has no fixed
///         rate — a create prices it from USDT_REF_POOL (Pancake V3 USDT/WBNB 0.01%); testnet lists the mock quote at a
///         fixed rate (15 mock units = 15 BNB, so a sale raises 15 units).
///         Testnet reuses the testnet Agent ID registry and mock quote; NEW_MOCKS=true deploys fresh ones.
///         Everything is wired before setMigrator, the last call, which is what makes the pad usable.
/// @dev Mainnet broadcast is refused unless FAIR_MINT_MAINNET_OK=true (spec: no mainnet broadcast before audit).
///      Env: DEPLOYER_PRIVATE_KEY; OWNER (the multisig, required on mainnet; gets ownership via Ownable2Step and must
///      accept), optional KEEPER, FEE_VAULT, BURNER, QUOTE_REGISTRY + PLATFORM_BUCKET + DIVIDEND_VAULT + MIGRATOR +
///      TOKEN_DEPLOYER + PEER_CORE (reuse), AGENT_ID / TEST_QUOTE
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
        } else {
            // reuse the testnet Agent ID registry and test quote (NEW_MOCKS=true deploys fresh ones)
            bool fresh = vm.envOr("NEW_MOCKS", false);
            s.agentId = fresh ? address(new TestnetAgentId()) : vm.envOr("AGENT_ID", T.AGENT_ID_REGISTRY);
            s.testQuote = fresh ? address(new MockSPCXB()) : vm.envOr("TEST_QUOTE", T.TEST_QUOTE);
            _listQuote(s.quoteRegistry, s.testQuote, TESTNET_QUOTE_PER_15_BNB);
        }

        (s.vault, s.migrator, s.tokenDeployer) = _shared(deployer, factory);
        GangTaxHandler handler = new GangTaxHandler(deployer, s.vault, s.bucket, router);
        FairMintPad pad = new FairMintPad(
            deployer, s.quoteRegistry, s.vault, s.bucket, address(handler), s.tokenDeployer, wbnb, factory
        );
        (s.handler, s.pad) = (address(handler), address(pad));

        _wireCore(s.vault, s.migrator, s.tokenDeployer, s.bucket, s.pad, MIN_SHARE, _ops(s));

        handler.setLaunchpad(address(pad));
        handler.setKeeper(keeper);

        PlatformFeeBucket(s.bucket).setOperator(address(pad), true);
        PlatformFeeBucket(s.bucket).setOperator(address(handler), true);

        pad.setAgentGate(true, s.agentId);
        // reference pools: Pancake V2 pairs and V3 pools on both chains; the USDT → WBNB bridge is mainnet only
        pad.setV3Factory(mainnet ? M.PANCAKE_V3_FACTORY : T.PANCAKE_V3_FACTORY);
        if (mainnet) pad.setBridgePool(M.USDT, M.USDT_WBNB_V3);
        // last: create needs a migrator, so the pad only opens once the fee sinks above accept it
        pad.setMigrator(s.migrator);

        _handOver(owner, deployer, s.vault);
        _handOver(owner, deployer, s.migrator);
        _handOver(owner, deployer, s.tokenDeployer);
        _handOver(owner, deployer, address(handler));
        _handOver(owner, deployer, address(pad));
        _handOver(owner, deployer, s.quoteRegistry);
        _handOver(owner, deployer, s.bucket);

        vm.stopBroadcast();

        _check(s, keeper, owner, mainnet);
        _log(s, owner, deployer);
    }

    /// @dev Vault operator bound to this core: the holder-reward handler (shares and rewards).
    function _ops(Stack memory s) internal pure returns (address[] memory ops) {
        ops = new address[](1);
        ops[0] = s.handler;
    }

    function _check(Stack memory s, address keeper, address owner, bool mainnet) internal view {
        GangTaxHandler handler = GangTaxHandler(s.handler);
        FairMintPad pad = FairMintPad(s.pad);
        _checkCore(s.quoteRegistry, s.vault, s.migrator, s.tokenDeployer, s.bucket, s.pad, MIN_SHARE, _ops(s));
        if (address(pad.dividendVault()) != s.vault || address(pad.tokenDeployer()) != s.tokenDeployer) {
            revert WiringCheck("pad vault / deployer");
        }
        if (address(handler.launchpad()) != s.pad) revert WiringCheck("handler.pad");
        if (handler.keeper() != keeper) revert WiringCheck("handler.keeper");
        if (address(pad.migrator()) != s.migrator) revert WiringCheck("pad.migrator");
        if (address(pad.agentIdRegistry()) != s.agentId || !pad.agentGateEnabled()) revert WiringCheck("agent gate");
        if (pad.taxHandler() != s.handler) revert WiringCheck("pad.taxHandler");
        _checkBucket(mainnet, M.V2_PLATFORM_BUCKET, s.bucket, keeper, s.pad, s.handler);
        address[7] memory owned = [s.vault, s.migrator, s.tokenDeployer, s.handler, s.pad, s.quoteRegistry, s.bucket];
        for (uint256 i = 0; i < owned.length; i++) {
            _checkOwner(owner, owned[i]);
        }
        if (s.testQuote != address(0) && !QuoteRegistry(s.quoteRegistry).isQuoted(s.testQuote)) {
            revert WiringCheck("quote listed");
        }
    }

    function _log(Stack memory s, address owner, address deployer) internal pure {
        console.log("--- FAIR MINT ADDRESSES ---");
        console.log("FAIR_MINT_PAD", s.pad);
        console.log("HOLDER_REWARD_HANDLER", s.handler);
        _logPlatform(s.quoteRegistry, s.bucket);
        _logShared(s.vault, s.migrator, s.tokenDeployer);
        console.log("AGENT_ID", s.agentId);
        if (s.testQuote != address(0)) console.log("TEST_QUOTE", s.testQuote);
        else console.log("USDT_REF_POOL (refPool for a USDT quote)", M.USDT_REF_POOL);
        if (owner != deployer) {
            console.log("PENDING owner: acceptOwnership() on pad, handler, and the five shared contracts");
        }
    }
}
