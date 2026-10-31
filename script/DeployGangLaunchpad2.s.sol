// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {GangMainnetRefs as M, GangTestnetRefs as T} from "../config/GangDeployRefs.sol";
import {SharedPlatformFeeBucket} from "../src/common/SharedPlatformFeeBucket.sol";
import {SharedDividendVault} from "../src/common/SharedDividendVault.sol";
import {SharedMigrator} from "../src/common/SharedMigrator.sol";
import {TokenDeployer} from "../src/common/TokenDeployer.sol";
import {GangPadRegistry} from "../src/gang/GangPadRegistry.sol";
import {GangHandlerAdmin} from "../src/gang/GangHandlerAdmin.sol";
import {IGangPad} from "../src/gang/interfaces/IGangPad.sol";
import {IGangLaunchpad} from "../src/gang/interfaces/IGangLaunchpad.sol";
import {IGangTaxHandlerOps} from "../src/gang/interfaces/IGangTaxHandlerOps.sol";
import {GangRouterDeployLib as R} from "./GangRouterDeployLib.sol";
import {GangLaunchpad, GangTaxHandler} from "./GangContracts.sol";
import {DeployGang} from "./DeployGang.s.sol";

/// @title DeployGangLaunchpad2 — GangLaunchpad 2.0 (creator fee) next to the live 1.0, on BSC testnet (97) or mainnet (56)
/// @notice 2.0 is a new pad generation, not a new token kind (docs/SPEC-CURVE-CREATOR-FEE-2026-10-31.md §7): the same
///         GangLaunchpad source with 70% of the curve's 1% fee kept for the creator. It joins the shared contracts of
///         1.0 (read from GANG_PAD: QuoteRegistry, SharedDividendVault, SharedPlatformFeeBucket, SharedMigrator,
///         TokenDeployer — shared so a 1.0 token is never accepted as a 2.0 quote) and the GangPadRegistry, and deploys
///         its own: GangTaxHandler, GangLaunchpad (+ fresh CurveLogic / FairLogic: their buy / sell selectors changed,
///         a 1.0 library would leave the pad unable to trade), and an upgradeable GangRouter (GangRouterDeployLib).
///         Two phases, as DeployFlywheel, because on mainnet only the Safe can list the pad on the shared contracts:
///         1. deploy (no GANG_PAD2): deploy, wire what the deployer owns (handler pad / keeper / recipient, pad routers
///            = the new router and the GangGateway, Agent ID gate, V3 factory, TWAP window, USDT bridge pool). Shared
///            listing: done here when the deployer owns those contracts (testnet), else printed as a Safe batch.
///         2. finish (GANG_PAD2 + GANG_ROUTER2, after that batch ran): check every listing and setting (DeployGang's
///            self-check, with the pad still closed allowed, plus 2.0 probes), start the hand-over of the handler and
///            the pad to OWNER and print the accept batch, which ends with `setMigrator` (the pad opens only once the
///            Safe owns it). OWNER = the deployer (testnet): `setMigrator` right away.
///         Once 2.0 is open (testnet with the deployer owning the shared contracts: phase 1; else a phase-2 run after the listing / batch 2), phase 2 also prints the cut-over batch (`tokenDeployer.setLaunchpad(1.0, false)`: 1.0 stops creating; its
///         tokens trade and graduate as before). The Safe runs it only once the backend, site and CLI use 2.0.
/// @dev Mainnet broadcast needs GANG_MAINNET_OK=true; mainnet GANG_PAD, the registry, OWNER, KEEPER and the gateway
///      must be the known ones, the TWAP window 1.0's, RECIPIENT empty, and the Safe must own every shared contract.
///      Before anything is deployed (both chains) KEEPER must be the shared bucket's keeper. Phase 1 runs every check
///      that needs no shared listing before it prints Safe batch 1 (a failure fails the simulation, nothing is sent).
///      Env: DEPLOYER_PRIVATE_KEY, GANG_PAD, OWNER (required on mainnet, as DeployGang), KEEPER (mainnet default the
///      ops keeper; testnet default the deployer), GANG_GATEWAY (mainnet fixed; testnet optional), GANG_PAD_REGISTRY
///      (testnet optional), RECIPIENT + RECIPIENT_LABEL (testnet), TWAP_WINDOW (default: 1.0's), testnet TEST_QUOTE /
///      BLACKLIST_QUOTE (checked as listed); phase 2: GANG_PAD2, GANG_ROUTER2, GANG_PAD2_BLOCK.
///      Mainnet: link the live PoolCheck only:
///      --libraries src/launchpad-v2/PoolCheck.sol:PoolCheck:0xd2B159820749f178503E4faBCB18A7Ae4492bDb3
///      Never pass CurveLogic / FairLogic: forge deploys them fresh from the deployer.
contract DeployGangLaunchpad2 is DeployGang {
    /// @notice GangLaunchpad 1.0 on BSC 56 (docs/MAINNET-GANG-2026-10-27.md).
    address internal constant MAINNET_PAD_1 = 0x15CFD2dc8278Fb87a1783ef42111618E20874365;
    /// @notice The GangGateway proxy aggregators call (docs/MAINNET-GANG-GATEWAY-2026-10-30.md).
    address internal constant MAINNET_GATEWAY = 0x9dD16b73f624bdd8a210CBB2602FdF70f1B450B8;
    address internal constant TESTNET_PAD_REGISTRY = 0xB11B83C83DEd269B040faecC1D61B4885BA8e56e;
    uint256 internal constant CREATOR_FEE_SHARE_BPS = 7_000;
    uint256 internal constant DEFAULT_GRAD_BNB = 9 ether;

    struct Ctx {
        address pad1;
        address padRegistry;
        address gateway;
    }

    function run() external override returns (Stack memory s) {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address me = vm.addr(pk);
        Ctx memory x = _ctx(block.chainid == 56);
        Cfg memory c = _cfg2(me, x.pad1);
        if (c.mainnet) _requireMainnetInputs(c, x);
        // review 2026-10-31 M-2: the handler's keeper is one-shot and must be the shared bucket's (both chains)
        if (c.keeper != SharedPlatformFeeBucket(IGangPad(x.pad1).platformBucket()).keeper()) {
            revert WiringCheck("KEEPER is not the shared bucket's keeper");
        }
        // audit 2026-10-31 C info-5: a keeper change under way would leave the one-shot handler keeper on the old one
        if (SharedPlatformFeeBucket(IGangPad(x.pad1).platformBucket()).pendingKeeper() != address(0)) {
            revert WiringCheck("bucket keeper change pending");
        }

        console.log("=== DeployGangLaunchpad2 chain", block.chainid, "===");
        console.log("deployer", c.deployer);
        console.log("owner", c.owner);
        console.log("keeper", c.keeper);
        console.log("GangLaunchpad 1.0", x.pad1);

        address existing = _envAddr("GANG_PAD2", address(0));
        vm.startBroadcast(pk);
        if (existing == address(0)) {
            s = _shared(x.pad1, c);
            _deploy2(s, c);
            _wireOwn(s, c, x);
            if (_ownsShared(s, x, me)) _wireShared(s, x);
        } else {
            s = _load2(existing, x.pad1, c);
        }
        bool wired = _sharedWired(s, x);
        if (wired) {
            if (c.owner == me && IGangPad(s.pad).migrator() == address(0)) IGangPad(s.pad).setMigrator(s.migrator);
            _handOver(c.owner, me, s.handler);
            _handOver(c.owner, me, s.pad);
        }
        vm.stopBroadcast();

        _log2(s, c);
        if (!wired) {
            // review 2026-10-31 M-1: batch 1 can't be undone (registry addPad, the vault's operator binding), so every
            // check that needs no shared listing runs first; a failure here fails the simulation: nothing broadcast
            _checkPre(s, c, x, true);
            _checkMine(s, me);
            console.log("\n=== Safe batch 1: list GangLaunchpad 2.0 on the shared contracts, then run phase 2 ===");
            console.log(_wiringJson(s, x, c.mainnet, Ownable(s.vault).owner()));
            return s;
        }
        _check2(s, c, x);
        if (c.owner != me) _printAccept(s, c);
        if (IGangPad(s.pad).migrator() != address(0)) {
            console.log("\n=== Safe batch 3 (cut-over, only once backend / site / CLI use 2.0): 1.0 stops creating ===");
            console.log(_cutoverJson(s, x, c.mainnet, Ownable(s.tokenDeployer).owner()));
        }
    }

    // ---------------------------------------------------------------- config
    function _ctx(bool mainnet) internal view returns (Ctx memory x) {
        x.pad1 = vm.envAddress("GANG_PAD");
        x.padRegistry = _envAddr("GANG_PAD_REGISTRY", mainnet ? M.PAD_REGISTRY : TESTNET_PAD_REGISTRY);
        x.gateway = _envAddr("GANG_GATEWAY", mainnet ? MAINNET_GATEWAY : address(0));
    }

    /// @dev DeployGang's config; the TWAP window defaults to 1.0's (TWAP_WINDOW still overrides it). 2.0 joins the
    ///      shared bucket as it is: its fee vault and burner are what `_checkBucket` expects (the Safe may have changed
    ///      them since 1.0 was deployed; FEE_VAULT / BURNER are not used here).
    function _cfg2(address deployer, address pad1) internal view returns (Cfg memory c) {
        c = _cfg(deployer);
        if (vm.envOr("TWAP_WINDOW", uint256(0)) == 0) c.twapWindow = IGangPad(pad1).twapWindow();
        SharedPlatformFeeBucket b = SharedPlatformFeeBucket(IGangPad(pad1).platformBucket());
        c.feeVault = b.feeVault();
        c.burner = address(b.burner());
    }

    /// @dev Pinned mainnet inputs (as DeployFlywheel, audit C-2): a testnet value left in the env must not reach the
    ///      Safe's contracts; the Safe owns every shared contract (the listing batch is the Safe's).
    function _requireMainnetInputs(Cfg memory c, Ctx memory x) internal view {
        if (x.pad1 != MAINNET_PAD_1) revert WiringCheck("GANG_PAD is not GangLaunchpad 1.0");
        if (x.padRegistry != M.PAD_REGISTRY) revert WiringCheck("GANG_PAD_REGISTRY is not the live registry");
        if (x.gateway != MAINNET_GATEWAY) revert WiringCheck("GANG_GATEWAY is not the live gateway");
        if (c.owner != M.OWNER_SAFE) revert WiringCheck("OWNER is not the platform Safe");
        if (c.keeper != M.KEEPER) revert WiringCheck("KEEPER is not the platform keeper");
        IGangPad p1 = IGangPad(x.pad1);
        if (c.twapWindow != p1.twapWindow()) revert WiringCheck("TWAP_WINDOW differs from 1.0's");
        // partner recipients are the Safe's to list on 2.0, never a leftover env value
        if (_envAddr("RECIPIENT", address(0)) != address(0)) revert WiringCheck("RECIPIENT must be empty on mainnet");
        address[6] memory shared = [
            p1.quoteRegistry(),
            p1.platformBucket(),
            p1.dividendVault(),
            p1.migrator(),
            p1.tokenDeployer(),
            x.padRegistry
        ];
        for (uint256 i; i < shared.length; i++) {
            if (Ownable(shared[i]).owner() != M.OWNER_SAFE) {
                revert WiringCheck("shared contract not owned by the Safe");
            }
        }
    }

    // ---------------------------------------------------------------- phase 1
    /// @dev The shared contracts and settings of 1.0.
    function _shared(address pad1, Cfg memory c) internal view returns (Stack memory s) {
        IGangPad p1 = IGangPad(pad1);
        s.quoteRegistry = p1.quoteRegistry();
        s.bucket = p1.platformBucket();
        s.vault = p1.dividendVault();
        s.migrator = p1.migrator();
        s.tokenDeployer = p1.tokenDeployer();
        s.agentId = c.mainnet ? M.AGENT_ID_REGISTRY : p1.agentIdRegistry();
        _testnetExtras(s, c);
        if (s.migrator == address(0)) revert WiringCheck("1.0 migrator");
    }

    function _testnetExtras(Stack memory s, Cfg memory c) internal view {
        if (c.mainnet) {
            s.recipient = _envAddr("RECIPIENT", address(0));
        } else {
            s.testQuote = _envAddr("TEST_QUOTE", T.TEST_QUOTE);
            s.blacklistQuote = _envAddr("BLACKLIST_QUOTE", address(0));
            s.recipient = _envAddr("RECIPIENT", T.DEMO_TREASURY);
        }
    }

    function _deploy2(Stack memory s, Cfg memory c) internal {
        s.handler = address(new GangTaxHandler(c.deployer, s.vault, s.bucket, c.dexRouter));
        s.pad = address(
            new GangLaunchpad(
                c.deployer, s.quoteRegistry, s.vault, s.bucket, s.handler, s.tokenDeployer, c.wbnb, c.factory
            )
        );
        s.padBlock = block.number;
        _setRouter(s, R.deploy(s.pad, c.wbnb, c.dexRouter, R.timelockSafe(c.mainnet, c.owner), c.routerDelay));
    }

    /// @dev What the deployer owns: the handler (one-shot launchpad and keeper) and the pad's settings.
    function _wireOwn(Stack memory s, Cfg memory c, Ctx memory x) internal {
        IGangTaxHandlerOps h = IGangTaxHandlerOps(s.handler);
        h.setLaunchpad(s.pad);
        h.setKeeper(c.keeper);
        if (s.recipient != address(0)) h.list(s.recipient, c.label);

        IGangPad pad = IGangPad(s.pad);
        pad.setRouter(s.router, true);
        if (x.gateway != address(0)) pad.setRouter(x.gateway, true);
        pad.setAgentGate(true, s.agentId);
        pad.setV3Factory(c.v3Factory);
        if (pad.twapWindow() != c.twapWindow) pad.setTwapWindow(c.twapWindow);
        if (c.mainnet) pad.setBridgePool(M.USDT, M.USDT_WBNB_V3);
    }

    function _ownsShared(Stack memory s, Ctx memory x, address me) internal view returns (bool) {
        return Ownable(s.vault).owner() == me && Ownable(s.migrator).owner() == me && Ownable(s.bucket).owner() == me
            && Ownable(s.tokenDeployer).owner() == me && Ownable(x.padRegistry).owner() == me;
    }

    /// @dev The shared listings (testnet, where the deployer owns them); mainnet: the same calls in Safe batch 1.
    function _wireShared(Stack memory s, Ctx memory x) internal {
        SharedDividendVault v = SharedDividendVault(s.vault);
        v.setLaunchpad(s.pad, true);
        v.setMinimumShareBalance(s.pad, MIN_SHARE);
        v.setOperator(s.handler, s.pad);
        v.setExcluded(s.router, true);
        SharedMigrator(s.migrator).addLaunchpad(s.pad);
        TokenDeployer(s.tokenDeployer).setLaunchpad(s.pad, true);
        SharedPlatformFeeBucket(s.bucket).setOperator(s.pad, true);
        SharedPlatformFeeBucket(s.bucket).setOperator(s.handler, true);
        GangPadRegistry(x.padRegistry).addPad(s.pad);
    }

    // ---------------------------------------------------------------- phase 2
    /// @dev The stack from 2.0 itself (its immutables are the shared contracts); the migrator from 1.0, since 2.0's is
    ///      still 0 until the Safe opens it; the router from GANG_ROUTER2.
    function _load2(address pad2, address pad1, Cfg memory c) internal view returns (Stack memory s) {
        IGangPad pad = IGangPad(pad2);
        s.pad = pad2;
        s.quoteRegistry = pad.quoteRegistry();
        s.bucket = pad.platformBucket();
        s.vault = pad.dividendVault();
        s.tokenDeployer = pad.tokenDeployer();
        s.handler = pad.taxHandler();
        s.migrator = IGangPad(pad1).migrator();
        s.agentId = pad.agentIdRegistry();
        address proxy = _envAddr("GANG_ROUTER2", address(0));
        if (proxy == address(0)) revert WiringCheck("GANG_ROUTER2");
        _setRouter(s, R.load(proxy));
        s.padBlock = vm.envOr("GANG_PAD2_BLOCK", uint256(0));
        _testnetExtras(s, c);
        // the shared contracts must be 1.0's
        IGangPad p1 = IGangPad(pad1);
        if (
            s.quoteRegistry != p1.quoteRegistry() || s.bucket != p1.platformBucket() || s.vault != p1.dividendVault()
                || s.tokenDeployer != p1.tokenDeployer()
        ) revert WiringCheck("2.0 shared contracts != 1.0's");
    }

    function _sharedWired(Stack memory s, Ctx memory x) internal view returns (bool) {
        SharedDividendVault v = SharedDividendVault(s.vault);
        return v.launchpads(s.pad) && v.minimumShareBalanceOf(s.pad) == MIN_SHARE && v.operatorOf(s.handler) == s.pad
            && v.excluded(s.router) && SharedMigrator(s.migrator).launchpads(s.pad)
            && TokenDeployer(s.tokenDeployer).launchpads(s.pad) && SharedPlatformFeeBucket(s.bucket).operators(s.pad)
            && SharedPlatformFeeBucket(s.bucket).operators(s.handler) && GangPadRegistry(x.padRegistry).isPad(s.pad);
    }

    /// @dev DeployGang's self-check minus the shared contracts' owners (the Safe's, not handed over here), with the
    ///      pad allowed to be still closed when the Safe opens it; then the 2.0 probes and the two owned contracts.
    ///      Not view: the probes call state-changing entries (all revert; outside the broadcast).
    function _check2(Stack memory s, Cfg memory c, Ctx memory x) internal {
        _checkPre(s, c, x, c.owner != c.deployer);
        _checkVault(s);
        _checkBucket(s, c);
        _checkPlatform(s, c);
        address[2] memory own = [s.handler, s.pad];
        for (uint256 i; i < 2; i++) {
            Ownable2Step o = Ownable2Step(own[i]);
            // audit 2026-10-31 C info-1: once the modules are in, a GangHandlerAdmin of the owner holds the handler
            if (i == 0 && _isOwnersAdmin(o.owner(), s.handler, c.owner)) {
                if (o.pendingOwner() != address(0)) revert WiringCheck("handler hand-over pending");
                continue;
            }
            if (c.owner == c.deployer) {
                if (o.owner() != c.deployer || o.pendingOwner() != address(0)) revert WiringCheck("owner = deployer");
            } else if (o.owner() != c.owner && o.pendingOwner() != c.owner) {
                revert WiringCheck("owner / pendingOwner");
            }
        }
        console.log("self-check ok");
    }

    /// @dev `who` is a GangHandlerAdmin over `handler`, owned by `owner`.
    function _isOwnersAdmin(address who, address handler, address owner) internal view returns (bool) {
        if (who.code.length == 0) return false;
        try GangHandlerAdmin(who).handler() returns (address h) {
            return h == handler && GangHandlerAdmin(who).owner() == owner;
        } catch {
            return false;
        }
    }

    /// @dev Audit 2026-10-31 C L-1: batch 1 lists the pad and binds its handler for good, so before it is printed both
    ///      must be this deployer's own: deployed by it (a CREATE address of one of its nonces, not a look-alike of the
    ///      same code at another address) and still owned by it, with no handover started.
    function _checkMine(Stack memory s, address me) internal view {
        address[2] memory own = [s.handler, s.pad];
        uint256 nonce = vm.getNonce(me);
        for (uint256 i; i < 2; i++) {
            Ownable2Step o = Ownable2Step(own[i]);
            if (o.owner() != me || o.pendingOwner() != address(0)) revert WiringCheck("2.0 not the deployer's own");
            bool made;
            for (uint256 n; n < nonce && !made; n++) {
                made = vm.computeCreateAddress(me, n) == own[i];
            }
            if (!made) revert WiringCheck("2.0 not deployed by this deployer");
        }
    }

    /// @dev Everything that needs no shared listing: the pad (closed allowed when the Safe opens it), both libraries,
    ///      the handler (its keeper the shared bucket's), the router, the gateway listing, the 2.0 probes. Runs before
    ///      Safe batch 1 is printed (review M-1) and again in phase 2. `closedOk`: the pad may still be closed —
    ///      always before the listing (it opens only after it), and after it when the Safe opens it.
    function _checkPre(Stack memory s, Cfg memory c, Ctx memory x, bool closedOk) internal {
        allowClosedPad = closedOk;
        _checkPad(s, c);
        _checkLibs(s, c);
        _checkLibsUsdt(s, c);
        _checkHandler(s, c);
        if (IGangTaxHandlerOps(s.handler).keeper() != SharedPlatformFeeBucket(s.bucket).keeper()) {
            revert WiringCheck("handler keeper != bucket keeper");
        }
        _checkRouter(s, c);
        if (x.gateway != address(0) && !IGangPad(s.pad).routers(x.gateway)) revert WiringCheck("pad.routers gateway");
        _checkCreatorFee(s.pad);
    }

    /// @dev Audit 2026-10-31 (B low): a 1.0 pad, or a 2.0 pad linked to a 1.0 CurveLogic, must not pass. The constant
    ///      proves the pad source; `buy` / `sell` / `claimCreatorFee` on an unknown token must reach the new library
    ///      and revert there with UnknownToken (a 1.0 library has no such selectors: the delegatecall reverts empty).
    ///      The graduation targets: default 9 BNB, a picked 6 BNB target priced by the library (WBNB: 6 WBNB), and an
    ///      off-tier 10 BNB refused there with BadGradTarget.
    function _checkCreatorFee(address pad) internal {
        try IGangPad(pad).CREATOR_FEE_SHARE_BPS() returns (uint256 v) {
            if (v != CREATOR_FEE_SHARE_BPS) revert WiringCheck("pad.CREATOR_FEE_SHARE_BPS");
        } catch {
            revert WiringCheck("pad.CREATOR_FEE_SHARE_BPS (a 1.0 pad?)");
        }
        if (IGangPad(pad).TARGET_GRAD_BNB() != DEFAULT_GRAD_BNB) revert WiringCheck("pad.TARGET_GRAD_BNB");
        try IGangPad(pad).graduationAmountFor(IGangPad(pad).wbnb(), address(0), 6 ether) returns (uint256 g) {
            if (g != 6 ether) revert WiringCheck("CurveLogic graduationAmountFor");
        } catch {
            revert WiringCheck("CurveLogic is not the 2.0 library");
        }
        (bool okOff, bytes memory retOff) =
            pad.staticcall(abi.encodeCall(IGangPad.graduationAmountFor, (IGangPad(pad).wbnb(), address(0), 10 ether)));
        if (okOff || retOff.length < 4 || bytes4(retOff) != IGangLaunchpad.BadGradTarget.selector) {
            revert WiringCheck("CurveLogic: off-tier target not refused");
        }
        address probe = address(uint160(uint256(keccak256("gang.deploy2.unknown-token"))));
        bytes[3] memory calls = [
            abi.encodeCall(IGangPad.buy, (probe, 1, 0)),
            abi.encodeCall(IGangPad.sell, (probe, 1, 0)),
            abi.encodeCall(IGangPad.claimCreatorFee, (probe, probe))
        ];
        for (uint256 i; i < 3; i++) {
            (bool ok, bytes memory ret) = pad.call(calls[i]);
            if (ok || ret.length < 4 || bytes4(ret) != IGangLaunchpad.UnknownToken.selector) {
                revert WiringCheck("CurveLogic is not the 2.0 library");
            }
        }
    }

    // ---------------------------------------------------------------- output
    function _log2(Stack memory s, Cfg memory c) internal pure {
        console.log("--- GANGLAUNCHPAD 2.0 ---");
        console.log("GANG_PAD2", s.pad);
        console.log("GANG_PAD2_BLOCK", s.padBlock);
        console.log("GANG_TAX_HANDLER2", s.handler);
        console.log("GANG_ROUTER2 (proxy: the pad lists it, users approve it)", s.router);
        console.log("GANG_ROUTER2_IMPL", s.routerImpl);
        console.log("GANG_ROUTER2_PROXY_ADMIN (owner = the timelock)", s.routerAdmin);
        console.log("GANG_ROUTER2_TIMELOCK", s.routerTimelock);
        console.log("router timelock proposer / executor / canceller", R.timelockSafe(c.mainnet, c.owner));
        console.log("shared (1.0's): QUOTE_REGISTRY", s.quoteRegistry);
        console.log("shared (1.0's): PLATFORM_BUCKET", s.bucket);
        console.log("shared (1.0's): DIVIDEND_VAULT", s.vault);
        console.log("shared (1.0's): MIGRATOR", s.migrator);
        console.log("shared (1.0's): TOKEN_DEPLOYER", s.tokenDeployer);
        if (s.padBlock != 0) {
            console.log("--- for the keeper / indexer: 2.0 serves both tracks, next to 1.0 (start block below) ---");
            console.log(string.concat("gang:", vm.toString(s.pad), "@", vm.toString(s.padBlock)));
        }
        console.log("PENDING: the handler's recipient listings of 1.0 (partners) are not copied; the Safe lists them");
        console.log("PENDING: modules (GangBond, Buyback / Split / LP / Combo factories + a GangHandlerAdmin) for 2.0");
    }

    function _printAccept(Stack memory s, Cfg memory c) internal view {
        address handlerOwner = Ownable(s.handler).owner();
        // once the modules are in, the owner's GangHandlerAdmin holds the handler: nothing for the Safe to accept
        bool acceptH = handlerOwner != c.owner && !_isOwnersAdmin(handlerOwner, s.handler, c.owner);
        bool acceptP = Ownable(s.pad).owner() != c.owner;
        bool open = IGangPad(s.pad).migrator() != address(0);
        if (!acceptH && !acceptP && open) {
            console.log(
                "\nnothing left for the Safe: it owns the pad and the handler (itself or through its GangHandlerAdmin), and 2.0 is open"
            );
            return;
        }
        console.log("\n=== Safe batch 2: accept the handler and the pad, open 2.0 (setMigrator) ===");
        console.log(_acceptJson(s, c.mainnet, c.owner, acceptH, acceptP, !open));
    }

    function _wiringJson(Stack memory s, Ctx memory x, bool mainnet, address safe)
        internal
        pure
        returns (string memory j)
    {
        j = _head(mainnet, safe, "gang: list GangLaunchpad 2.0 on the shared contracts");
        j = string.concat(
            j,
            _tx(s.vault, abi.encodeCall(SharedDividendVault.setLaunchpad, (s.pad, true)), false),
            _tx(s.vault, abi.encodeCall(SharedDividendVault.setMinimumShareBalance, (s.pad, MIN_SHARE)), true),
            _tx(s.vault, abi.encodeCall(SharedDividendVault.setOperator, (s.handler, s.pad)), true),
            _tx(s.vault, abi.encodeCall(SharedDividendVault.setExcluded, (s.router, true)), true),
            _tx(s.migrator, abi.encodeCall(SharedMigrator.addLaunchpad, (s.pad)), true)
        );
        j = string.concat(
            j,
            _tx(s.tokenDeployer, abi.encodeCall(TokenDeployer.setLaunchpad, (s.pad, true)), true),
            _tx(s.bucket, abi.encodeCall(SharedPlatformFeeBucket.setOperator, (s.pad, true)), true),
            _tx(s.bucket, abi.encodeCall(SharedPlatformFeeBucket.setOperator, (s.handler, true)), true),
            _tx(x.padRegistry, abi.encodeCall(GangPadRegistry.addPad, (s.pad)), true),
            "]}"
        );
    }

    /// @dev acceptOwnership on the handler and the pad (those not accepted yet), then `setMigrator`: 2.0 opens as the
    ///      Safe takes it.
    function _acceptJson(Stack memory s, bool mainnet, address safe, bool acceptH, bool acceptP, bool openPad)
        internal
        pure
        returns (string memory j)
    {
        j = _head(mainnet, safe, "gang: accept GangLaunchpad 2.0 (handler, pad) and open it");
        bool comma;
        if (acceptH) {
            j = string.concat(j, _tx(s.handler, abi.encodeWithSignature("acceptOwnership()"), comma));
            comma = true;
        }
        if (acceptP) {
            j = string.concat(j, _tx(s.pad, abi.encodeWithSignature("acceptOwnership()"), comma));
            comma = true;
        }
        if (openPad) j = string.concat(j, _tx(s.pad, abi.encodeCall(IGangPad.setMigrator, (s.migrator)), comma));
        j = string.concat(j, "]}");
    }

    /// @dev 1.0 stops creating (TokenDeployer refuses it); its tokens keep trading and graduating.
    function _cutoverJson(Stack memory s, Ctx memory x, bool mainnet, address safe)
        internal
        pure
        returns (string memory j)
    {
        j = _head(mainnet, safe, "gang: GangLaunchpad 1.0 stops creating (2.0 is live)");
        j = string.concat(j, _tx(s.tokenDeployer, abi.encodeCall(TokenDeployer.setLaunchpad, (x.pad1, false)), false));
        j = string.concat(j, "]}");
    }

    function _head(bool mainnet, address safe, string memory name) internal pure returns (string memory) {
        return string.concat(
            '{"version":"1.0","chainId":"',
            mainnet ? "56" : "97",
            '","createdAt":0,"meta":{"name":"',
            name,
            '","txBuilderVersion":"1.16.5","createdFromSafeAddress":"',
            vm.toString(safe),
            '"},"transactions":['
        );
    }

    function _tx(address to, bytes memory data, bool comma) internal pure returns (string memory) {
        return string.concat(
            comma ? "," : "",
            '{"to":"',
            vm.toString(to),
            '","value":"0","data":"',
            vm.toString(data),
            '","contractMethod":null,"contractInputsValues":null}'
        );
    }
}
