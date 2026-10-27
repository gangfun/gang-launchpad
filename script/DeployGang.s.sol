// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {GangMainnetRefs as M, GangTestnetRefs as T} from "../config/GangDeployRefs.sol";
import {QuoteRegistry} from "../src/launchpad-v2/QuoteRegistry.sol";
import {PlatformFeeBucket as V2PlatformFeeBucket} from "../src/launchpad-v2/PlatformFeeBucket.sol";
import {SharedPlatformFeeBucket} from "../src/common/SharedPlatformFeeBucket.sol";
import {SharedDividendVault} from "../src/common/SharedDividendVault.sol";
import {SharedMigrator} from "../src/common/SharedMigrator.sol";
import {TokenDeployer} from "../src/common/TokenDeployer.sol";
import {GangRouter} from "../src/router/GangRouter.sol";
import {IGangPad} from "../src/gang/interfaces/IGangPad.sol";
import {IGangTaxHandlerOps} from "../src/gang/interfaces/IGangTaxHandlerOps.sol";
import {GangLaunchpad, GangTaxHandler} from "./GangContracts.sol";
import {MockSPCXB} from "../src/launchpad-v2/mocks/MockSPCXB.sol";
import {TestnetBlacklistQuote} from "../src/launchpad-v3/mocks/TestnetBlacklistQuote.sol";
import {TestnetAgentId} from "../src/fair-mint/mocks/TestnetAgentId.sol";

/// @title DeployGang — the whole merged stack (one GangLaunchpad for V3 and 打新) on BSC testnet (97) or mainnet (56)
/// @notice One run deploys, in this order: QuoteRegistry, SharedPlatformFeeBucket, SharedDividendVault, SharedMigrator,
///         TokenDeployer, GangTaxHandler, GangLaunchpad (+ its external libraries CurveLogic / FairLogic, which forge
///         deploys first and links; PoolCheck is linked by address on mainnet), GangRouter. Never the live V2 registry /
///         bucket (their owner is an EOA). Then it wires everything and calls `pad.setMigrator` LAST (A-1: create needs a
///         migrator, so the pad only opens once every fee sink, the vault, the router and the gate accept it), hands
///         ownership to OWNER (Ownable2Step: the owner accepts) and runs the full self-check `_check`.
///         Quotes: mainnet lists nothing (USDT is priced from USDT_REF_POOL at create); testnet lists the test quote and
///         a blacklist quote at a fixed rate (15 units = 15 BNB) and lists the demo treasury as a tax recipient.
///         Re-run on an existing stack: GANG_PAD (+ GANG_ROUTER) skips every deploy and wiring step and only hands over
///         ownership again (idempotent; a different OWNER than the pending one is refused, PendingOwnerMismatch) and
///         re-runs `_check` — e.g. to verify a deployment from another machine.
/// @dev Mainnet broadcast is refused unless GANG_MAINNET_OK=true.
///      Env: DEPLOYER_PRIVATE_KEY; OWNER (required on mainnet; = the deployer only with MAINNET_OWNER_IS_DEPLOYER=true,
///      else OwnerRequired); optional KEEPER (mainnet default 0xB6f1…cFc7, testnet the deployer), FEE_VAULT / BURNER
///      (new bucket's; 0 / unset = the V2 bucket's on mainnet), RECIPIENT + RECIPIENT_LABEL (listed tax recipient;
///      testnet default the demo treasury), TWAP_WINDOW (default 1800); testnet: AGENT_ID, TEST_QUOTE, BLACKLIST_QUOTE,
///      NEW_MOCKS=true (fresh Agent ID registry + test quote); re-run: GANG_PAD, GANG_ROUTER.
///      Mainnet: link the live PoolCheck with
///      --libraries src/launchpad-v2/PoolCheck.sol:PoolCheck:0xd2B159820749f178503E4faBCB18A7Ae4492bDb3
///      (CurveLogic / FairLogic are not passed: forge deploys them from the deployer as the first broadcast txs).
contract DeployGang is Script {
    uint256 internal constant MIN_SHARE = 10_000 ether;
    uint256 internal constant TESTNET_QUOTE_PER_15_BNB = 15 ether;
    uint32 internal constant DEFAULT_TWAP_WINDOW = 1800;

    struct Stack {
        address quoteRegistry;
        address bucket;
        address vault;
        address migrator;
        address tokenDeployer;
        address handler;
        address pad;
        address router;
        address agentId;
        address testQuote;
        address blacklistQuote;
        address recipient;
        /// @dev block.number when the script ran (≤ the mined block): safe as the indexer / keeper start block
        uint256 padBlock;
    }

    struct Cfg {
        bool mainnet;
        address deployer;
        address owner;
        address keeper;
        address wbnb;
        address factory;
        address dexRouter;
        address v3Factory;
        uint32 twapWindow;
        address burner;
        address feeVault;
        string label;
    }

    error WrongChain(uint256 chainId);
    error MainnetNotAllowed();
    error OwnerRequired();
    error WiringCheck(string what);
    error PendingOwnerMismatch(address target);

    function run() external returns (Stack memory s) {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        Cfg memory c = _cfg(vm.addr(pk));

        console.log("=== DeployGang chain", block.chainid, "===");
        console.log("deployer", c.deployer);
        console.log("owner", c.owner);
        console.log("keeper", c.keeper);

        address existing = _envAddr("GANG_PAD", address(0));
        vm.startBroadcast(pk);
        if (existing == address(0)) {
            s = _deploy(c);
            _wire(s, c);
            // last (A-1): create needs a migrator, so the pad only opens once everything above accepts it
            IGangPad(s.pad).setMigrator(s.migrator);
        } else {
            s = _load(existing, c);
        }
        _handOverAll(s, c);
        vm.stopBroadcast();

        _check(s, c);
        _log(s, c);
    }

    // ---------------------------------------------------------------- config
    function _cfg(address deployer) internal view returns (Cfg memory c) {
        c.mainnet = block.chainid == 56;
        if (!c.mainnet && block.chainid != 97) revert WrongChain(block.chainid);
        _mainnetGate(c.mainnet, _broadcasting());
        c.deployer = deployer;
        c.owner = _owner(c.mainnet, deployer);
        c.keeper = _envAddr("KEEPER", c.mainnet ? M.KEEPER : deployer);
        c.wbnb = c.mainnet ? M.WBNB : T.WBNB;
        c.factory = c.mainnet ? M.PANCAKE_V2_FACTORY : T.PANCAKE_V2_FACTORY;
        c.dexRouter = c.mainnet ? M.PANCAKE_V2_ROUTER : T.PANCAKE_V2_ROUTER;
        c.v3Factory = c.mainnet ? M.PANCAKE_V3_FACTORY : T.PANCAKE_V3_FACTORY;
        c.twapWindow = uint32(vm.envOr("TWAP_WINDOW", uint256(DEFAULT_TWAP_WINDOW)));
        c.burner = _burner(c.mainnet);
        c.feeVault = _feeVault(c.mainnet, deployer);
        c.label = vm.envOr("RECIPIENT_LABEL", string(c.mainnet ? "" : "testnet demo treasury"));
    }

    /// @dev No mainnet broadcast without GANG_MAINNET_OK=true (a dry run / fork simulation needs nothing).
    function _mainnetGate(bool mainnet, bool broadcasting) internal view {
        if (mainnet && broadcasting && !vm.envOr("GANG_MAINNET_OK", false)) revert MainnetNotAllowed();
    }

    /// @dev Mainnet: OWNER must be given; leaving every contract on the deploy key needs MAINNET_OWNER_IS_DEPLOYER=true
    ///      (the 2026-10-27 launch: 0x4EEd… deploys and owns). Testnet: OWNER defaults to the deployer.
    function _owner(bool mainnet, address deployer) internal view returns (address owner) {
        owner = _envAddr("OWNER", mainnet ? address(0) : deployer);
        if (mainnet) {
            if (owner == address(0)) revert OwnerRequired();
            if (owner == deployer && !vm.envOr("MAINNET_OWNER_IS_DEPLOYER", false)) revert OwnerRequired();
        }
    }

    /// @dev R5-5: the burner the new bucket gets AND is checked against: BURNER if set (non-zero), else the V2 bucket's
    ///      on mainnet, none on testnet (collectPlatform then reverts until the owner sets one).
    function _burner(bool mainnet) internal view returns (address burner) {
        burner = _envAddr("BURNER", address(0));
        if (burner == address(0) && mainnet) burner = address(V2PlatformFeeBucket(M.V2_PLATFORM_BUCKET).burner());
    }

    /// @dev R5-5: FEE_VAULT if set (non-zero), else the V2 bucket's on mainnet, the deployer on testnet.
    function _feeVault(bool mainnet, address deployer) internal view returns (address feeVault) {
        feeVault = _envAddr("FEE_VAULT", address(0));
        if (feeVault == address(0)) {
            feeVault = mainnet ? V2PlatformFeeBucket(M.V2_PLATFORM_BUCKET).feeVault() : deployer;
        }
    }

    // ---------------------------------------------------------------- deploy
    function _deploy(Cfg memory c) internal returns (Stack memory s) {
        s.quoteRegistry = address(new QuoteRegistry(c.deployer));
        s.bucket = address(new SharedPlatformFeeBucket(c.deployer, c.feeVault));
        s.vault = address(new SharedDividendVault(c.deployer));
        s.migrator = address(new SharedMigrator(c.deployer, c.factory));
        s.tokenDeployer = address(new TokenDeployer(c.deployer));
        s.handler = address(new GangTaxHandler(c.deployer, s.vault, s.bucket, c.dexRouter));
        s.pad = address(
            new GangLaunchpad(
                c.deployer, s.quoteRegistry, s.vault, s.bucket, s.handler, s.tokenDeployer, c.wbnb, c.factory
            )
        );
        s.padBlock = block.number;
        s.router = address(new GangRouter(s.pad, c.wbnb));

        if (c.mainnet) {
            s.agentId = M.AGENT_ID_REGISTRY;
            s.recipient = _envAddr("RECIPIENT", address(0));
        } else {
            bool fresh = vm.envOr("NEW_MOCKS", false);
            s.agentId = fresh ? address(new TestnetAgentId()) : _envAddr("AGENT_ID", T.AGENT_ID_REGISTRY);
            s.testQuote = fresh ? address(new MockSPCXB()) : _envAddr("TEST_QUOTE", T.TEST_QUOTE);
            s.blacklistQuote = _envAddr("BLACKLIST_QUOTE", address(0));
            if (s.blacklistQuote == address(0)) s.blacklistQuote = address(new TestnetBlacklistQuote());
            s.recipient = _envAddr("RECIPIENT", T.DEMO_TREASURY);
        }
    }

    /// @dev Every wiring step before setMigrator (the caller makes that the last call).
    function _wire(Stack memory s, Cfg memory c) internal {
        // fee bucket: the deploy-time burner (R5-5), the one-time keeper (R5-4), operators = pad + handler
        SharedPlatformFeeBucket bucket = SharedPlatformFeeBucket(s.bucket);
        if (c.burner != address(0)) bucket.setBurner(c.burner);
        bucket.setKeeper(c.keeper);
        bucket.setOperator(s.pad, true);
        bucket.setOperator(s.handler, true);

        // dividend vault: the pad (excluded by setLaunchpad), its 10k floor, the handler as its one operator (bound
        // once, F4a; excluded by setOperator); the migrator and the bucket never claim (R2-4 / audit 4 A-F2)
        SharedDividendVault vault = SharedDividendVault(s.vault);
        vault.setLaunchpad(s.pad, true);
        vault.setMinimumShareBalance(s.pad, MIN_SHARE);
        vault.setOperator(s.handler, s.pad);
        vault.setExcluded(s.migrator, true);
        vault.setExcluded(s.bucket, true);

        SharedMigrator(s.migrator).addLaunchpad(s.pad);
        TokenDeployer(s.tokenDeployer).setLaunchpad(s.pad, true);

        // tax handler: the one launchpad (one-shot), the one-time keeper, the recipient whitelist
        IGangTaxHandlerOps handler = IGangTaxHandlerOps(s.handler);
        handler.setLaunchpad(s.pad);
        handler.setKeeper(c.keeper);
        if (s.recipient != address(0)) handler.list(s.recipient, c.label);

        // testnet quotes at a fixed rate; mainnet lists none
        if (!c.mainnet) {
            _listQuote(s.quoteRegistry, s.testQuote, TESTNET_QUOTE_PER_15_BNB);
            _listQuote(s.quoteRegistry, s.blacklistQuote, TESTNET_QUOTE_PER_15_BNB);
        }

        // pad: router, Agent gate, reference pools (V2 pairs and V3 pools on both chains; USDT → WBNB bridge mainnet)
        IGangPad pad = IGangPad(s.pad);
        pad.setRouter(s.router, true);
        pad.setAgentGate(true, s.agentId);
        pad.setV3Factory(c.v3Factory);
        if (pad.twapWindow() != c.twapWindow) pad.setTwapWindow(c.twapWindow);
        if (c.mainnet) pad.setBridgePool(M.USDT, M.USDT_WBNB_V3);
    }

    /// @dev Re-run: the stack is read from the pad itself; only the router (and the testnet extras) come from env.
    function _load(address pad_, Cfg memory c) internal view returns (Stack memory s) {
        IGangPad pad = IGangPad(pad_);
        s.pad = pad_;
        s.quoteRegistry = pad.quoteRegistry();
        s.bucket = pad.platformBucket();
        s.vault = pad.dividendVault();
        s.migrator = pad.migrator();
        s.tokenDeployer = pad.tokenDeployer();
        s.handler = pad.taxHandler();
        s.agentId = pad.agentIdRegistry();
        s.router = _envAddr("GANG_ROUTER", address(0));
        if (s.router == address(0)) revert WiringCheck("GANG_ROUTER");
        s.padBlock = vm.envOr("GANG_PAD_BLOCK", uint256(0));
        if (c.mainnet) {
            s.recipient = _envAddr("RECIPIENT", address(0));
        } else {
            s.testQuote = _envAddr("TEST_QUOTE", T.TEST_QUOTE);
            s.blacklistQuote = _envAddr("BLACKLIST_QUOTE", address(0));
            s.recipient = _envAddr("RECIPIENT", T.DEMO_TREASURY);
        }
    }

    // ---------------------------------------------------------------- ownership
    function _owned(Stack memory s) internal pure returns (address[7] memory) {
        return [s.quoteRegistry, s.bucket, s.vault, s.migrator, s.tokenDeployer, s.handler, s.pad];
    }

    function _handOverAll(Stack memory s, Cfg memory c) internal {
        address[7] memory owned = _owned(s);
        for (uint256 i = 0; i < owned.length; i++) {
            _handOver(c.owner, c.deployer, owned[i]);
        }
    }

    function _handOver(address owner, address deployer, address target) internal {
        if (owner == deployer) return;
        Ownable2Step o = Ownable2Step(target);
        // C-F8: a re-run naming another OWNER must not overwrite the first run's pending owner
        address pending = o.pendingOwner();
        if (pending != address(0) && pending != owner) revert PendingOwnerMismatch(target);
        if (o.owner() == deployer && pending != owner) o.transferOwnership(owner);
    }

    // ---------------------------------------------------------------- self-check
    /// @notice Every wiring step above, read back from chain. Any mismatch reverts with the item's name.
    function _check(Stack memory s, Cfg memory c) internal view {
        _checkPad(s, c);
        _checkLibs(s, c);
        _checkHandler(s, c);
        _checkVault(s);
        _checkBucket(s, c);
        _checkPlatform(s, c);
        _checkRouter(s, c);
        _checkOwners(s, c);
    }

    function _checkPad(Stack memory s, Cfg memory c) internal view {
        IGangPad pad = IGangPad(s.pad);
        if (pad.quoteRegistry() != s.quoteRegistry) revert WiringCheck("pad.quoteRegistry");
        if (pad.dividendVault() != s.vault) revert WiringCheck("pad.dividendVault");
        if (pad.platformBucket() != s.bucket) revert WiringCheck("pad.platformBucket");
        if (pad.taxHandler() != s.handler) revert WiringCheck("pad.taxHandler");
        if (pad.tokenDeployer() != s.tokenDeployer) revert WiringCheck("pad.tokenDeployer");
        if (pad.wbnb() != c.wbnb) revert WiringCheck("pad.wbnb");
        if (pad.pairFactory() != c.factory) revert WiringCheck("pad.pairFactory");
        if (pad.migrator() != s.migrator || s.migrator == address(0)) revert WiringCheck("pad.migrator");
        if (pad.agentIdRegistry() != s.agentId || !pad.agentGateEnabled()) revert WiringCheck("agent gate");
        if (!pad.walletCapEnabled()) revert WiringCheck("wallet cap");
        if (pad.v3Factory() != c.v3Factory) revert WiringCheck("pad.v3Factory");
        if (pad.twapWindow() != c.twapWindow) revert WiringCheck("pad.twapWindow");
        if (c.mainnet && pad.bridgePoolOf(M.USDT) != M.USDT_WBNB_V3) revert WiringCheck("pad.bridgePool USDT");
        if (!pad.routers(s.router)) revert WiringCheck("pad.routers");
        // one vault floor for both kinds (merge plan §5.3), equal to the one the vault was given
        if (pad.TAXED_MIN_SHARE() != MIN_SHARE || pad.MIN_SHARE_BALANCE() != MIN_SHARE) {
            revert WiringCheck("pad floor constants");
        }
    }

    /// @dev Both external libraries are linked and live: a delegatecall into an address without code returns nothing,
    ///      so the pad's decode of these views reverts (WBNB needs no pool: 15 BNB → 15 WBNB, 10_000 shares).
    function _checkLibs(Stack memory s, Cfg memory c) internal view {
        IGangPad pad = IGangPad(s.pad);
        try pad.graduationAmountOf(c.wbnb, address(0)) returns (uint256 g) {
            if (g != 15 ether) revert WiringCheck("CurveLogic graduationAmountOf");
        } catch {
            revert WiringCheck("CurveLogic not linked");
        }
        try pad.previewCreate(address(0), address(0), 15 ether) returns (uint256 raise, uint256 price) {
            if (raise != 15 ether || price != 15 ether / 10_000) revert WiringCheck("FairLogic previewCreate");
        } catch {
            revert WiringCheck("FairLogic not linked");
        }
    }

    function _checkHandler(Stack memory s, Cfg memory c) internal view {
        IGangTaxHandlerOps h = IGangTaxHandlerOps(s.handler);
        if (h.launchpad() != s.pad) revert WiringCheck("handler.launchpad");
        if (h.dividendVault() != s.vault) revert WiringCheck("handler.dividendVault");
        if (h.platformBucket() != s.bucket) revert WiringCheck("handler.platformBucket");
        if (h.keeper() != c.keeper || !h.keeperSet()) revert WiringCheck("handler.keeper");
        if (h.dexRouter() != c.dexRouter || h.pendingDexRouter() != address(0)) {
            revert WiringCheck("handler.dexRouter");
        }
        if (s.recipient != address(0) && !h.isListed(s.recipient)) revert WiringCheck("recipient listed");
    }

    function _checkVault(Stack memory s) internal view {
        SharedDividendVault v = SharedDividendVault(s.vault);
        if (!v.launchpads(s.pad)) revert WiringCheck("vault launchpad");
        if (v.minimumShareBalanceOf(s.pad) != MIN_SHARE) revert WiringCheck("vault floor");
        if (v.operatorFor(s.pad) != s.handler || v.operatorOf(s.handler) != s.pad) {
            revert WiringCheck("vault operator");
        }
        if (!v.excluded(s.vault)) revert WiringCheck("vault excludes itself");
        if (!v.excluded(s.migrator)) revert WiringCheck("vault excludes migrator");
        if (!v.excluded(s.bucket)) revert WiringCheck("vault excludes bucket");
        if (!v.excluded(s.pad)) revert WiringCheck("vault excludes pad");
        if (!v.excluded(s.handler)) revert WiringCheck("vault excludes handler");
    }

    /// @dev C-F8 / R5-5: operators, keeper, and the fee legs' destinations — the same `_burner` / `_feeVault` the
    ///      deploy used (mainnet: the V2 bucket's unless BURNER / FEE_VAULT say otherwise, and a burner is required).
    function _checkBucket(Stack memory s, Cfg memory c) internal view {
        SharedPlatformFeeBucket b = SharedPlatformFeeBucket(s.bucket);
        if (!b.operators(s.pad) || !b.operators(s.handler)) revert WiringCheck("bucket operators");
        if (b.keeper() != c.keeper || !b.keeperSet()) revert WiringCheck("bucket keeper");
        if (b.feeVault() == address(0)) revert WiringCheck("bucket feeVault");
        // testnet: only an explicit FEE_VAULT / BURNER is checked (the testnet default fee vault is the deployer)
        if ((c.mainnet || _envAddr("FEE_VAULT", address(0)) != address(0)) && b.feeVault() != c.feeVault) {
            revert WiringCheck("bucket feeVault");
        }
        if ((c.mainnet || c.burner != address(0)) && (address(b.burner()) != c.burner || c.burner == address(0))) {
            revert WiringCheck("bucket burner");
        }
    }

    function _checkPlatform(Stack memory s, Cfg memory c) internal view {
        if (address(SharedMigrator(s.migrator).factory()) != c.factory) revert WiringCheck("migrator factory");
        if (!SharedMigrator(s.migrator).launchpads(s.pad)) revert WiringCheck("migrator launchpad");
        if (!TokenDeployer(s.tokenDeployer).launchpads(s.pad)) revert WiringCheck("deployer launchpad");
        QuoteRegistry reg = QuoteRegistry(s.quoteRegistry);
        if (c.mainnet) {
            // mainnet lists nothing: USDT is priced from USDT_REF_POOL at create
            if (reg.isQuoted(M.USDT)) revert WiringCheck("mainnet USDT listed");
        } else {
            if (!_listed(reg, s.testQuote)) revert WiringCheck("test quote listed");
            if (s.blacklistQuote != address(0) && !_listed(reg, s.blacklistQuote)) {
                revert WiringCheck("blacklist quote listed");
            }
        }
    }

    /// @dev C-F8: the router is wired on this very pad and WBNB (deployed in the same run; checked again on a re-run).
    function _checkRouter(Stack memory s, Cfg memory c) internal view {
        GangRouter r = GangRouter(payable(s.router));
        if (address(r.pad()) != s.pad || address(r.v3()) != s.pad || address(r.fair()) != s.pad) {
            revert WiringCheck("router pad");
        }
        if (r.wbnb() != c.wbnb) revert WiringCheck("router wbnb");
    }

    /// @dev C-F8: every owned contract is owned by OWNER or has it pending (nothing left for another address); with
    ///      OWNER = the deployer there is no pending owner at all.
    function _checkOwners(Stack memory s, Cfg memory c) internal view {
        address[7] memory owned = _owned(s);
        for (uint256 i = 0; i < owned.length; i++) {
            Ownable2Step o = Ownable2Step(owned[i]);
            if (c.owner == c.deployer) {
                if (o.owner() != c.deployer || o.pendingOwner() != address(0)) revert WiringCheck("owner = deployer");
            } else if (o.owner() != c.owner && o.pendingOwner() != c.owner) {
                revert WiringCheck("owner / pendingOwner");
            }
        }
    }

    // ---------------------------------------------------------------- helpers
    /// @dev A fixed rate for `quote` (quote units per 15 BNB); a listed rate replaces the creator's reference pool.
    function _listQuote(address registry, address quote, uint256 amount) internal {
        QuoteRegistry reg = QuoteRegistry(registry);
        (bool enabled, uint256 current) = reg.quotes(quote);
        if (!enabled || current != amount) reg.setQuote(quote, true, amount);
    }

    function _listed(QuoteRegistry reg, address quote) internal view returns (bool) {
        (bool enabled, uint256 amount) = reg.quotes(quote);
        return enabled && amount == TESTNET_QUOTE_PER_15_BNB;
    }

    /// @dev An address env var; unset or 0 = `fallback_`.
    function _envAddr(string memory name, address fallback_) internal view returns (address a) {
        a = vm.envOr(name, address(0));
        if (a == address(0)) a = fallback_;
    }

    function _broadcasting() internal view returns (bool) {
        return vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
    }

    function _log(Stack memory s, Cfg memory c) internal pure {
        console.log("--- GANG ADDRESSES ---");
        console.log("GANG_PAD", s.pad);
        console.log("GANG_PAD_BLOCK", s.padBlock);
        console.log("GANG_TAX_HANDLER", s.handler);
        console.log("GANG_ROUTER", s.router);
        console.log("QUOTE_REGISTRY", s.quoteRegistry);
        console.log("PLATFORM_BUCKET", s.bucket);
        console.log("DIVIDEND_VAULT", s.vault);
        console.log("MIGRATOR", s.migrator);
        console.log("TOKEN_DEPLOYER", s.tokenDeployer);
        console.log("AGENT_ID", s.agentId);
        if (c.mainnet) console.log("USDT_REF_POOL (refPool for a USDT quote)", M.USDT_REF_POOL);
        if (s.testQuote != address(0)) console.log("TEST_QUOTE", s.testQuote);
        if (s.blacklistQuote != address(0)) console.log("BLACKLIST_QUOTE", s.blacklistQuote);
        if (s.recipient != address(0)) console.log("RECIPIENT", s.recipient);
        // GANG_PAD_BLOCK is the simulated block, at or before the mined one: a safe start block for indexer / keeper
        string memory pb = string.concat(vm.toString(s.pad), "@", vm.toString(s.padBlock));
        console.log("--- server env (one pad for both tracks: indexer.env and keeper/.env) ---");
        console.log(string.concat("GANG_V3_PAD=", vm.toString(s.pad)));
        console.log(string.concat("GANG_FAIR_PAD=", vm.toString(s.pad)));
        console.log(string.concat("GANG_V3_START_BLOCK=", vm.toString(s.padBlock)));
        console.log(string.concat("GANG_FAIR_START_BLOCK=", vm.toString(s.padBlock)));
        console.log(string.concat("PADS=gang:", pb, "   (keeper/.env; V3_PADS / FAIR_PADS stay empty)"));
        if (s.recipient == address(0)) {
            console.log("PENDING owner: handler.list(<partner vault>, <label>) before the partner creates taxed tokens");
        }
        if (c.owner != c.deployer) {
            console.log("PENDING owner: acceptOwnership() on pad, handler, registry, bucket, vault, migrator, deployer");
        }
    }
}
