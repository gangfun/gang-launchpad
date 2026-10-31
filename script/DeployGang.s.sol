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
import {GangRouterDeployLib as R} from "./GangRouterDeployLib.sol";
import {IGangPad} from "../src/gang/interfaces/IGangPad.sol";
import {IGangLaunchpad} from "../src/gang/interfaces/IGangLaunchpad.sol";
import {IGangTaxHandlerOps} from "../src/gang/interfaces/IGangTaxHandlerOps.sol";
import {GangLaunchpad, GangTaxHandler} from "./GangContracts.sol";
import {MockSPCXB} from "../src/launchpad-v2/mocks/MockSPCXB.sol";
import {TestnetBlacklistQuote} from "../src/launchpad-v3/mocks/TestnetBlacklistQuote.sol";
import {TestnetAgentId} from "../src/fair-mint/mocks/TestnetAgentId.sol";

/// @title DeployGang — the whole merged stack (one GangLaunchpad for V3 and 打新) on BSC testnet (97) or mainnet (56)
/// @notice One run deploys, in this order: QuoteRegistry, SharedPlatformFeeBucket, SharedDividendVault, SharedMigrator,
///         TokenDeployer, GangTaxHandler, GangLaunchpad (+ its external libraries CurveLogic / FairLogic, which forge
///         deploys first and links; PoolCheck is linked by address on mainnet), then the upgradeable GangRouter
///         (GangRouterDeployLib, AUDIT-BRIEF §21: implementation → TimelockController → TransparentUpgradeableProxy
///         initialized in its constructor; the pad lists the proxy). Never the live V2 registry /
///         bucket (their owner is an EOA). Then it wires everything and calls `pad.setMigrator` LAST (A-1: create needs a
///         migrator, so the pad only opens once every fee sink, the vault, the router and the gate accept it), hands
///         ownership to OWNER (Ownable2Step: the owner accepts) and runs the full self-check `_check`.
///         Quotes: mainnet lists nothing (USDT is priced from USDT_REF_POOL at create); testnet lists the test quote and
///         a blacklist quote at a fixed rate (15 units = 15 BNB) and lists the demo treasury as a tax recipient.
///         Router timelock: proposer = executor = canceller = the platform Safe on mainnet (always, also with
///         MAINNET_OWNER_IS_DEPLOYER=true), OWNER on testnet; no admin (the timelock is its own only admin),
///         minDelay 48 h (mainnet fixed; ROUTER_TIMELOCK_DELAY may shorten it on testnet only). The ProxyAdmin the proxy
///         deploys is owned by the timelock from the start: neither needs an acceptOwnership.
///         Re-run on an existing stack: GANG_PAD (+ GANG_ROUTER = the proxy) skips every deploy and wiring step and only hands over
///         ownership again (idempotent; a different OWNER than the pending one is refused, PendingOwnerMismatch) and
///         re-runs `_check` — e.g. to verify a deployment from another machine.
/// @dev Mainnet broadcast is refused unless GANG_MAINNET_OK=true. Mainnet OWNER is the platform Safe
///      0x2866369F7acEFC9760bdE7779362fae5cD68B41E (since 2026-10-27; a WARN line for anything else): every owned contract
///      ends with owner = the deployer and pendingOwner = the Safe, and the log prints the 7 addresses plus a Safe
///      Transaction Builder JSON of the 7 acceptOwnership() calls.
///      Env: DEPLOYER_PRIVATE_KEY; OWNER (required on mainnet; = the deployer only with MAINNET_OWNER_IS_DEPLOYER=true,
///      else OwnerRequired; the flag with another OWNER: OwnerNotDeployer); optional KEEPER (mainnet: must be
///      0xB6f1…cFc7 unless KEEPER_OVERRIDE_OK=true, KeeperNotDefault; testnet default the deployer), FEE_VAULT / BURNER
///      (new bucket's; 0 / unset = the V2 bucket's on mainnet, a WARN line when overridden), RECIPIENT + RECIPIENT_LABEL
///      (listed tax recipient; testnet default the demo treasury), TWAP_WINDOW (default 1800, at least 600); testnet:
///      AGENT_ID, TEST_QUOTE, BLACKLIST_QUOTE, NEW_MOCKS=true (fresh Agent ID registry + test quote); re-run: GANG_PAD,
///      GANG_ROUTER, GANG_PAD_BLOCK (without it the server env lines are not printed); ROUTER_TIMELOCK_DELAY (seconds,
///      default 172800; mainnet refuses any other value, MainnetTimelockDelay).
///      Mainnet: link the live PoolCheck with
///      --libraries src/launchpad-v2/PoolCheck.sol:PoolCheck:0xd2B159820749f178503E4faBCB18A7Ae4492bDb3
///      (CurveLogic / FairLogic are not passed: forge deploys them from the deployer as the first broadcast txs).
contract DeployGang is Script {
    uint256 internal constant MIN_SHARE = 10_000 ether;
    uint256 internal constant TESTNET_QUOTE_PER_15_BNB = 15 ether;
    uint32 internal constant DEFAULT_TWAP_WINDOW = 1800;
    /// @dev Below 10 minutes a V3 reference-pool TWAP is cheap to move within a few blocks.
    uint32 internal constant MIN_TWAP_WINDOW = 600;
    /// @dev What only the real GangLaunchpad answers (the deploy-time stub had none of these).
    uint256 internal constant CURVE_SUPPLY = 800_000_000 ether;
    uint256 internal constant MINT_SUPPLY = 500_000_000 ether;

    struct Stack {
        address quoteRegistry;
        address bucket;
        address vault;
        address migrator;
        address tokenDeployer;
        address handler;
        address pad;
        /// @dev the router PROXY (what the pad lists and users approve)
        address router;
        address routerImpl;
        address routerAdmin;
        address routerTimelock;
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
        /// @dev router timelock minDelay (48 h on mainnet)
        uint256 routerDelay;
    }

    error WrongChain(uint256 chainId);
    error MainnetNotAllowed();
    error OwnerRequired();
    error OwnerNotDeployer();
    error KeeperNotDefault(address keeper);
    error TwapWindowTooShort(uint32 window);
    error WiringCheck(string what);
    error PendingOwnerMismatch(address target);

    /// @dev Set by a script that checks a pad the Safe opens later (DeployGangLaunchpad2 phase 2): `pad.migrator() == 0`
    ///      then passes `_checkPad`. Off here: this script always opens the pad before checking it.
    bool internal allowClosedPad;

    function run() external virtual returns (Stack memory s) {
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
        c.keeper = _keeper(c.mainnet, deployer);
        c.wbnb = c.mainnet ? M.WBNB : T.WBNB;
        c.factory = c.mainnet ? M.PANCAKE_V2_FACTORY : T.PANCAKE_V2_FACTORY;
        c.dexRouter = c.mainnet ? M.PANCAKE_V2_ROUTER : T.PANCAKE_V2_ROUTER;
        c.v3Factory = c.mainnet ? M.PANCAKE_V3_FACTORY : T.PANCAKE_V3_FACTORY;
        c.twapWindow = uint32(vm.envOr("TWAP_WINDOW", uint256(DEFAULT_TWAP_WINDOW)));
        if (c.twapWindow < MIN_TWAP_WINDOW) revert TwapWindowTooShort(c.twapWindow);
        c.burner = _burner(c.mainnet);
        c.feeVault = _feeVault(c.mainnet, deployer);
        c.label = vm.envOr("RECIPIENT_LABEL", string(c.mainnet ? "" : "testnet demo treasury"));
        c.routerDelay = R.minDelayFromEnv(c.mainnet);
    }

    /// @dev No mainnet broadcast without GANG_MAINNET_OK=true (a dry run / fork simulation needs nothing).
    function _mainnetGate(bool mainnet, bool broadcasting) internal view {
        if (mainnet && broadcasting && !vm.envOr("GANG_MAINNET_OK", false)) revert MainnetNotAllowed();
    }

    /// @dev Mainnet: OWNER must be given; leaving every contract on the deploy key needs MAINNET_OWNER_IS_DEPLOYER=true
    ///      (the 2026-10-27 launch: 0x4EEd… deploys and owns). Testnet: OWNER defaults to the deployer.
    ///      MAINNET_OWNER_IS_DEPLOYER=true with an OWNER that is not the deployer is a contradiction: refused.
    function _owner(bool mainnet, address deployer) internal view returns (address owner) {
        owner = _envAddr("OWNER", mainnet ? address(0) : deployer);
        if (mainnet) {
            bool ownerIsDeployer = vm.envOr("MAINNET_OWNER_IS_DEPLOYER", false);
            if (owner == address(0)) revert OwnerRequired();
            if (owner == deployer && !ownerIsDeployer) revert OwnerRequired();
            if (owner != deployer && ownerIsDeployer) revert OwnerNotDeployer();
            if (owner != M.OWNER_SAFE) {
                console.log("WARN mainnet OWNER is not the platform Safe 0x2866...B41E:", owner);
            }
        }
    }

    /// @dev Mainnet: the keeper is the ops keeper M.KEEPER (0xB6f1…cFc7); another one needs KEEPER_OVERRIDE_OK=true
    ///      (setKeeper is one-shot on the bucket and the handler: a wrong one costs a 48 h timelock to fix).
    ///      Testnet: KEEPER, default the deployer.
    function _keeper(bool mainnet, address deployer) internal view returns (address keeper) {
        keeper = _envAddr("KEEPER", mainnet ? M.KEEPER : deployer);
        if (mainnet && keeper != M.KEEPER) {
            if (!vm.envOr("KEEPER_OVERRIDE_OK", false)) revert KeeperNotDefault(keeper);
            console.log("WARN mainnet keeper is NOT the ops keeper 0xB6f1...cFc7 (KEEPER_OVERRIDE_OK=true):", keeper);
        }
    }

    /// @dev R5-5: the burner the new bucket gets AND is checked against: BURNER if set (non-zero), else the V2 bucket's
    ///      on mainnet, none on testnet (collectPlatform then reverts until the owner sets one).
    function _burner(bool mainnet) internal view returns (address burner) {
        burner = _envAddr("BURNER", address(0));
        if (mainnet) {
            address v2 = address(V2PlatformFeeBucket(M.V2_PLATFORM_BUCKET).burner());
            if (burner == address(0)) burner = v2;
            else if (burner != v2) console.log("WARN mainnet BURNER overrides the V2 bucket's burner:", burner);
        }
    }

    /// @dev R5-5: FEE_VAULT if set (non-zero), else the V2 bucket's on mainnet, the deployer on testnet.
    function _feeVault(bool mainnet, address deployer) internal view returns (address feeVault) {
        feeVault = _envAddr("FEE_VAULT", address(0));
        if (feeVault == address(0)) {
            feeVault = mainnet ? V2PlatformFeeBucket(M.V2_PLATFORM_BUCKET).feeVault() : deployer;
        } else if (mainnet && feeVault != V2PlatformFeeBucket(M.V2_PLATFORM_BUCKET).feeVault()) {
            console.log("WARN mainnet FEE_VAULT overrides the V2 bucket's fee vault:", feeVault);
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
        // upgradeable router: impl → timelock (the Safe on mainnet, OWNER on testnet, proposes / executes / cancels)
        // → proxy (initialized)
        _setRouter(s, R.deploy(s.pad, c.wbnb, c.dexRouter, R.timelockSafe(c.mainnet, c.owner), c.routerDelay));

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
        // §21: the router proxy only ever holds a seller's tokens inside one pool sell; excluded, the vault never
        // writes a share for it (saves ~90k gas per routed sell; the handler's sync already gives it none of the tax)
        vault.setExcluded(s.router, true);

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
        address proxy = _envAddr("GANG_ROUTER", address(0));
        if (proxy == address(0)) revert WiringCheck("GANG_ROUTER");
        // impl / ProxyAdmin / timelock are read from the proxy; `_check` then proves what they are
        _setRouter(s, R.load(proxy));
        s.padBlock = vm.envOr("GANG_PAD_BLOCK", uint256(0));
        if (c.mainnet) {
            s.recipient = _envAddr("RECIPIENT", address(0));
        } else {
            s.testQuote = _envAddr("TEST_QUOTE", T.TEST_QUOTE);
            s.blacklistQuote = _envAddr("BLACKLIST_QUOTE", address(0));
            s.recipient = _envAddr("RECIPIENT", T.DEMO_TREASURY);
        }
    }

    function _setRouter(Stack memory s, R.Router memory r) internal pure {
        s.router = r.proxy;
        s.routerImpl = r.impl;
        s.routerAdmin = r.proxyAdmin;
        s.routerTimelock = r.timelock;
    }

    function _router(Stack memory s) internal pure returns (R.Router memory r) {
        r = R.Router({proxy: s.router, impl: s.routerImpl, proxyAdmin: s.routerAdmin, timelock: s.routerTimelock});
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
        _checkLibsUsdt(s, c);
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
        if (s.migrator == address(0)) revert WiringCheck("pad.migrator");
        if (pad.migrator() != s.migrator && !(allowClosedPad && pad.migrator() == address(0))) {
            revert WiringCheck("pad.migrator");
        }
        if (pad.agentIdRegistry() != s.agentId || !pad.agentGateEnabled()) revert WiringCheck("agent gate");
        if (c.mainnet && s.agentId != M.AGENT_ID_REGISTRY) revert WiringCheck("mainnet Agent ID registry");
        if (!pad.walletCapEnabled()) revert WiringCheck("wallet cap");
        if (pad.v3Factory() != c.v3Factory) revert WiringCheck("pad.v3Factory");
        if (pad.twapWindow() != c.twapWindow) revert WiringCheck("pad.twapWindow");
        if (c.mainnet && pad.bridgePoolOf(M.USDT) != M.USDT_WBNB_V3) revert WiringCheck("pad.bridgePool USDT");
        if (!pad.routers(s.router)) revert WiringCheck("pad.routers");
        // the pad trusts the proxy only: never the implementation (nor the ProxyAdmin / timelock)
        if (pad.routers(s.routerImpl) || pad.routers(s.routerAdmin) || pad.routers(s.routerTimelock)) {
            revert WiringCheck("pad.routers impl");
        }
        // one vault floor for both kinds (merge plan §5.3), equal to the one the vault was given
        if (pad.TAXED_MIN_SHARE() != MIN_SHARE || pad.MIN_SHARE_BALANCE() != MIN_SHARE) {
            revert WiringCheck("pad floor constants");
        }
        _checkRealPad(pad);
        _checkOriginTrader(s);
    }

    /// @dev What only the real GangLaunchpad answers: a stand-in with the same setters and views (the old deploy-time
    ///      stub) fails here. checkTaxConfig runs CurveLogic's checkTax (a library call) on one valid and one invalid
    ///      config; checkTaxConfigFor proves the creator-as-recipient rule and the 打新 bounds are the launch ones
    ///      (AUDIT-BRIEF §22).
    function _checkRealPad(IGangPad pad) internal view {
        try pad.CURVE_SUPPLY() returns (uint256 v) {
            if (v != CURVE_SUPPLY) revert WiringCheck("pad.CURVE_SUPPLY");
        } catch {
            revert WiringCheck("pad.CURVE_SUPPLY");
        }
        try pad.MINT_SUPPLY() returns (uint256 v) {
            if (v != MINT_SUPPLY) revert WiringCheck("pad.MINT_SUPPLY");
        } catch {
            revert WiringCheck("pad.MINT_SUPPLY");
        }
        // holder dividend only (no recipient): valid; a 6% buy tax: refused with a reason
        IGangLaunchpad.TaxConfig memory good =
            IGangLaunchpad.TaxConfig({buyTaxBps: 200, sellTaxBps: 300, dividendBps: 10_000, recipient: address(0)});
        IGangLaunchpad.TaxConfig memory bad =
            IGangLaunchpad.TaxConfig({buyTaxBps: 600, sellTaxBps: 300, dividendBps: 10_000, recipient: address(0)});
        try pad.checkTaxConfig(good) returns (bool ok, string memory reason) {
            if (!ok || bytes(reason).length != 0) revert WiringCheck("pad.checkTaxConfig");
        } catch {
            revert WiringCheck("pad.checkTaxConfig");
        }
        try pad.checkTaxConfig(bad) returns (bool ok, string memory reason) {
            if (ok || bytes(reason).length == 0) revert WiringCheck("pad.checkTaxConfig");
        } catch {
            revert WiringCheck("pad.checkTaxConfig");
        }
        // §22: the creator may be its own recipient without a listing (an address no one lists)
        address self = address(uint160(uint256(keccak256("gang.deploy.creator-recipient"))));
        IGangLaunchpad.TaxConfig memory own =
            IGangLaunchpad.TaxConfig({buyTaxBps: 300, sellTaxBps: 300, dividendBps: 0, recipient: self});
        try pad.checkTaxConfigFor(self, own) returns (bool ok, string memory reason) {
            if (!ok || bytes(reason).length != 0) revert WiringCheck("pad.checkTaxConfigFor");
        } catch {
            revert WiringCheck("pad.checkTaxConfigFor");
        }
        // §22: 打新 per-wallet cap 0.25%–1%, hold line 60%–90%
        if (
            pad.MIN_CAP_BPS() != 25 || pad.MAX_CAP_BPS() != 100 || pad.MIN_HOLD_BPS() != 6_000
                || pad.MAX_HOLD_BPS() != 9_000
        ) revert WiringCheck("pad fair bounds");
    }

    /// @dev AUDIT-BRIEF §23: a pre-§23 pad or token deployer must not pass. TokenDeployer has no immutables, so its
    ///      code is this build's (it carries GangToken's creation code, hence `pullFor`), compared with the metadata
    ///      hashes masked (R.sameCode, §24.4: a re-run from another build still matches). The pad has immutables and
    ///      linked libraries, so its code is probed instead: its dispatcher must hold `sellFor` / `withdrawFor`
    ///      (PUSH4 <selector>). A state-changing probe call can't run here (view; `nonReentrant` writes).
    function _checkOriginTrader(Stack memory s) internal view {
        if (!R.sameCode(s.tokenDeployer, type(TokenDeployer).runtimeCode)) revert WiringCheck("tokenDeployer code");
        bytes memory code = s.pad.code;
        if (!_hasSelector(code, IGangPad.sellFor.selector) || !_hasSelector(code, IGangPad.withdrawFor.selector)) {
            revert WiringCheck("pad sellFor / withdrawFor");
        }
    }

    /// @dev True when `code` contains PUSH4 `sel` (0x63 followed by the 4 selector bytes), as a dispatcher does.
    function _hasSelector(bytes memory code, bytes4 sel) internal pure returns (bool) {
        uint256 want = (uint256(0x63) << 32) | uint256(uint32(sel));
        uint256 n = code.length;
        for (uint256 i = 0; i + 5 <= n; i++) {
            uint256 word;
            assembly ("memory-safe") {
                word := shr(216, mload(add(add(code, 32), i)))
            }
            if (word == want) return true;
        }
        return false;
    }

    /// @dev Both external libraries are linked and live: a delegatecall into an address without code returns nothing,
    ///      so the pad's decode of these views reverts (WBNB needs no pool: the default target in BNB → as much WBNB
    ///      (1.0: 15, 2.0: 9), 15 BNB → 10_000 shares).
    function _checkLibs(Stack memory s, Cfg memory c) internal view {
        IGangPad pad = IGangPad(s.pad);
        try pad.graduationAmountOf(c.wbnb, address(0)) returns (uint256 g) {
            if (g == 0 || g != pad.TARGET_GRAD_BNB()) revert WiringCheck("CurveLogic graduationAmountOf");
        } catch {
            revert WiringCheck("CurveLogic not linked (or not this pad's library)");
        }
        try pad.previewCreate(address(0), address(0), 15 ether) returns (uint256 raise, uint256 price) {
            if (raise != 15 ether || price != 15 ether / 10_000) revert WiringCheck("FairLogic previewCreate");
        } catch {
            revert WiringCheck("FairLogic not linked");
        }
    }

    /// @dev Mainnet: a USDT quote priced from its reference pool goes through the PoolCheck the libraries link (runs
    ///      after _checkPlatform, which makes sure USDT has no fixed rate in the registry that would bypass the pool).
    function _checkLibsUsdt(Stack memory s, Cfg memory c) internal view {
        if (!c.mainnet) return;
        IGangPad pad = IGangPad(s.pad);
        try pad.graduationAmountOf(M.USDT, M.USDT_REF_POOL) returns (uint256 g) {
            if (g == 0) revert WiringCheck("CurveLogic USDT graduationAmountOf");
        } catch {
            revert WiringCheck("CurveLogic USDT / PoolCheck");
        }
        try pad.previewCreate(M.USDT, M.USDT_REF_POOL, 5 ether) returns (uint256 raise, uint256 price) {
            if (raise == 0 || price == 0) revert WiringCheck("FairLogic USDT previewCreate");
        } catch {
            revert WiringCheck("FairLogic USDT / PoolCheck");
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
        if (!v.excluded(s.router)) revert WiringCheck("vault excludes router");
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

    /// @dev C-F8: the router proxy is wired on this very pad and WBNB; §21: its ERC-1967 slots point at this build's
    ///      locked GangRouter and at the ProxyAdmin it deployed, owned by a timelock of at least `routerDelay` whose
    ///      only proposer / executor / canceller is OWNER, the deploy wallet holds no role, and only the timelock
    ///      administers its roles (GangRouterDeployLib.check, the names are its WiringCheck strings).
    function _checkRouter(Stack memory s, Cfg memory c) internal view {
        R.check(
            _router(s),
            R.Expect({
                pad: s.pad,
                wbnb: c.wbnb,
                pancakeRouter: c.dexRouter,
                pancakeFactory: c.factory,
                safe: R.timelockSafe(c.mainnet, c.owner),
                deployer: c.deployer,
                minDelay: c.routerDelay,
                mainnet: c.mainnet
            })
        );
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

    /// @dev `PADS=gang:PAD(at)BLOCK` for keeper/.env, nothing else on the line ("" without a known block).
    function _padsLine(Stack memory s) internal pure returns (string memory) {
        if (s.padBlock == 0) return "";
        return string.concat("PADS=gang:", vm.toString(s.pad), "@", vm.toString(s.padBlock));
    }

    function _indexerEnv(Stack memory s) internal pure returns (string[4] memory l) {
        l[0] = string.concat("GANG_V3_PAD=", vm.toString(s.pad));
        l[1] = string.concat("GANG_FAIR_PAD=", vm.toString(s.pad));
        l[2] = string.concat("GANG_V3_START_BLOCK=", vm.toString(s.padBlock));
        l[3] = string.concat("GANG_FAIR_START_BLOCK=", vm.toString(s.padBlock));
    }

    function _log(Stack memory s, Cfg memory c) internal pure {
        console.log("--- GANG ADDRESSES ---");
        console.log("GANG_PAD", s.pad);
        console.log("GANG_PAD_BLOCK", s.padBlock);
        console.log("GANG_TAX_HANDLER", s.handler);
        console.log("GANG_ROUTER (proxy: the pad lists it, users approve it)", s.router);
        console.log("GANG_ROUTER_IMPL", s.routerImpl);
        console.log("GANG_ROUTER_PROXY_ADMIN (owner = the timelock)", s.routerAdmin);
        console.log("GANG_ROUTER_TIMELOCK", s.routerTimelock);
        console.log("router timelock minDelay (s)", c.routerDelay);
        console.log("router timelock proposer / executor / canceller", R.timelockSafe(c.mainnet, c.owner));
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
        // GANG_PAD_BLOCK is the simulated block, at or before the mined one: a safe start block for indexer / keeper.
        // Each env line is printed alone so it can be pasted as is; the comments go on their own lines.
        if (s.padBlock == 0) {
            console.log("--- server env: not printed (re-run without GANG_PAD_BLOCK; pass it to print the lines) ---");
        } else {
            console.log("--- server env (one pad for both tracks) ---");
            console.log("# indexer.env");
            string[4] memory idx = _indexerEnv(s);
            for (uint256 i; i < idx.length; i++) {
                console.log(idx[i]);
            }
            console.log("# keeper/.env (V3_PADS / FAIR_PADS stay empty)");
            console.log(_padsLine(s));
        }
        if (s.recipient == address(0)) {
            console.log("PENDING owner: handler.list(<partner vault>, <label>) before the partner creates taxed tokens");
        }
        if (c.owner != c.deployer) {
            console.log("PENDING owner: acceptOwnership() (0x79ba5097) from", c.owner, "on these 7 contracts:");
            address[7] memory owned = _owned(s);
            string[7] memory names = [
                "QuoteRegistry",
                "SharedPlatformFeeBucket",
                "SharedDividendVault",
                "SharedMigrator",
                "TokenDeployer",
                "GangTaxHandler",
                "GangLaunchpad"
            ];
            for (uint256 i; i < owned.length; i++) {
                console.log(" ", names[i], owned[i]);
            }
            console.log("--- Safe Transaction Builder JSON (save as a .json file, Transaction Builder > Load) ---");
            console.log(_safeAcceptJson(s, c));
            console.log(
                "(router: nothing to accept: the timelock has no owner, the ProxyAdmin's owner is the timelock)"
            );
        }
    }

    /// @dev One Safe Transaction Builder batch: acceptOwnership() (selector 0x79ba5097) on each of the 7 owned contracts.
    function _safeAcceptJson(Stack memory s, Cfg memory c) internal pure returns (string memory j) {
        address[7] memory owned = _owned(s);
        j = string.concat(
            '{"version":"1.0","chainId":"',
            c.mainnet ? "56" : "97",
            '","createdAt":0,"meta":{"name":"gang: accept ownership of the 7 merged GangLaunchpad contracts",',
            '"description":"acceptOwnership() on each contract whose pendingOwner is this Safe","txBuilderVersion":"1.16.5",',
            '"createdFromSafeAddress":"',
            vm.toString(c.owner),
            '"},"transactions":['
        );
        for (uint256 i; i < owned.length; i++) {
            j = string.concat(
                j,
                i == 0 ? "" : ",",
                '{"to":"',
                vm.toString(owned[i]),
                '","value":"0","data":"0x79ba5097","contractMethod":null,"contractInputsValues":null}'
            );
        }
        j = string.concat(j, "]}");
    }
}
