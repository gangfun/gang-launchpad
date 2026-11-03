// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {GangMainnetRefs as M} from "../config/GangDeployRefs.sol";
import {TokenDeployer} from "../src/common/TokenDeployer.sol";
import {GangPadRegistry} from "../src/gang/GangPadRegistry.sol";
import {GangLaunchpad3} from "../src/gang/GangLaunchpad3.sol";
import {IGangPad} from "../src/gang/interfaces/IGangPad.sol";
import {IGangLaunchpad} from "../src/gang/interfaces/IGangLaunchpad.sol";
import {IGangLaunchpad3} from "../src/gang/interfaces/IGangLaunchpad3.sol";
import {Pad3CodeCheck as CC} from "./Pad3CodeCheck.sol";
import {Pad3Impl} from "./Pad3Impl.sol";
import {Pad3Module} from "../src/gang/Pad3Module.sol";
import {GangRouterDeployLib as R} from "./GangRouterDeployLib.sol";
import {GangTaxHandler} from "./GangContracts.sol";
import {DeployGangLaunchpad2} from "./DeployGangLaunchpad2.s.sol";

/// @title DeployGangLaunchpad3 — GangLaunchpad 3.0, the upgradeable pad with the aggregator entry built in
/// @notice The 2.0 deploy (DeployGangLaunchpad2: same two phases, checks and Safe batches 1 / 2) with these
///         differences:
///         - the pad is a TransparentUpgradeableProxy over a GangLaunchpad3 implementation (its seven dependencies are
///           implementation immutables, GangPadRegistry included); the proxy's constructor runs `initialize` with the
///           deployer as the pad's owner (Ownable2Step, handed to OWNER as 2.0), and creates the ProxyAdmin owned by
///           OWNER from the start (mainnet: the platform Safe; no timelock, by decision). Its own handler and router
///           (GangRouter 3.0), and fresh CurveLogic3 / FairLogic / LegacyRoute;
///         - its own env names: phase 2 reads GANG_PAD3 / GANG_ROUTER3 / GANG_PAD3_BLOCK (2.0's are ignored);
///         - mainnet phase 1 also needs PAD3_NEW=true (a phase 2 run that forgot GANG_PAD3 must not deploy again);
///         - the proxy is checked as the router proxy is (its code, the ERC-1967 slots, the ProxyAdmin's code and
///           owner, the implementation locked, the proxy initialized once);
///         - once 3.0 is open, phase 2 prints, each simulated first (snapshot, prank, roll back):
///           batch 3 (forward): `setRouter(3.0, true)` on every older pad that has a router list (mainnet: 1.0, 2.0,
///           the vault pad, 铸币飞轮 V1 / V2): 3.0's entry then trades their curve tokens too;
///           batch 4 (callers, when CALLERS is given): `setCaller(c, true)` on 3.0 for aggregator contracts;
///           batch 5 (cut-over, only with CUTOVER=true, once backend / site / CLI / modules use 3.0): 1.0 and 2.0 stop
///           creating. The
///           vault pad and the 铸币飞轮 keep creating (3.0 has neither mode).
/// @dev Link as DeployGangLaunchpad2 (mainnet: PoolCheck only; never CurveLogic3 / FairLogic / LegacyRoute, forge
///      deploys them fresh). Env as DeployGangLaunchpad2 (GANG_PAD = 1.0: the shared contracts are read from it),
///      plus: PAD3_NEW (mainnet phase 1), GANG_PAD3_DEPLOYER_NONCE (phase 2, from phase 1's log; mainnet required),
///      PAD3_LOG_SCAN (optional), CALLER_CODEHASHES (mainnet, with CALLERS), CALLERS_PROXY_OK,
///      CUTOVER (print batch 5), CALLERS (comma-separated contracts, optional; testnet phase 1 lists them
///      itself), LEGACY_PADS (testnet only, comma-separated; default: the registry's pads that have a router list),
///      GANG_PAD2 (testnet only: the 2.0 to stop in the cut-over).
contract DeployGangLaunchpad3 is DeployGangLaunchpad2 {
    address internal constant MAINNET_PAD_2 = 0x770331a9accdb53ACb4a45B6c5B7D151fADCe557;
    address internal constant MAINNET_VAULT_PAD = 0xE90851A90C6278E3d6e4C24320101f8B13D90A11;
    uint8 internal constant PAD3_TOKEN_VERSION = 1;
    uint256 internal constant PAD3_MAX_FEE_RATE = 500;

    function _padName() internal pure override returns (string memory) {
        return "GangLaunchpad 3.0";
    }

    function _padEnv() internal pure override returns (string memory) {
        return "GANG_PAD3";
    }

    function _routerEnv() internal pure override returns (string memory) {
        return "GANG_ROUTER3";
    }

    function _blockEnv() internal pure override returns (string memory) {
        return "GANG_PAD3_BLOCK";
    }

    uint256 internal constant LOG_CHUNK = 5_000;

    function _ctx(bool mainnet) internal view override returns (Ctx memory x) {
        x = super._ctx(mainnet);
        if (mainnet && _envAddr(_padEnv(), address(0)) == address(0)) {
            if (!vm.envOr("PAD3_NEW", false)) revert WiringCheck("phase 1 on mainnet needs PAD3_NEW=true");
            // final audit (deploy) info: a leftover PAD3_NEW with GANG_PAD3 forgotten must not deploy a second 3.0
            address[] memory pads = GangPadRegistry(x.padRegistry).pads();
            for (uint256 i; i < pads.length; i++) {
                address impl = R.implementationOf(pads[i]);
                if (impl.code.length != 0 && _hasSelector(impl.code, GangLaunchpad3.buyTokenAMAP.selector)) {
                    revert WiringCheck("a GangLaunchpad 3.0 is already registered: set GANG_PAD3");
                }
            }
        }
    }

    // ---------------------------------------------------------------- phase 1
    /// @dev The handler, the implementation, the proxy (initialized in its constructor: no window in which anyone else
    ///      could initialize it; ProxyAdmin owned by OWNER), then the router on the proxy.
    function _deploy2(Stack memory s, Cfg memory c) internal override {
        s.handler = address(new GangTaxHandler(c.deployer, s.vault, s.bucket, c.dexRouter));
        // the vault mode module, then the implementation over it (Pad3Impl: the one way both are made)
        address impl = Pad3Impl.deploy(
            Pad3Impl.Deps(
                s.quoteRegistry, s.vault, s.bucket, s.handler, s.tokenDeployer, c.wbnb, _ctx(c.mainnet).padRegistry
            )
        );
        s.pad = address(
            new TransparentUpgradeableProxy(
                impl, c.owner, abi.encodeCall(GangLaunchpad3.initialize, (c.deployer, c.factory))
            )
        );
        s.padBlock = block.number;
        _setRouter(s, R.deploy(s.pad, c.wbnb, c.dexRouter, R.timelockSafe(c.mainnet, c.owner), c.routerDelay));
    }

    /// @dev 2.0's wiring, then (testnet only) CALLERS, and the forward listing on the older pads the deployer owns.
    ///      Mainnet: both are Safe batches once 3.0 is open.
    function _wireOwn(Stack memory s, Cfg memory c, Ctx memory x) internal override {
        super._wireOwn(s, c, x);
        if (c.mainnet) return;
        address[] memory callers = _callers();
        for (uint256 i; i < callers.length; i++) {
            GangLaunchpad3(payable(s.pad)).setCaller(callers[i], true);
        }
        address[] memory pads = _legacyPads(s, x, c);
        for (uint256 i; i < pads.length; i++) {
            if (Ownable(pads[i]).owner() == c.deployer && !IGangPad(pads[i]).routers(s.pad)) {
                IGangPad(pads[i]).setRouter(s.pad, true);
            }
        }
    }

    // ---------------------------------------------------------------- phase 2
    /// @dev The pad from the env must be a 3.0 proxy (its implementation's dispatcher has the entry), before anything.
    function _load2(address pad3, address pad1, Cfg memory c) internal view override returns (Stack memory s) {
        address impl = R.implementationOf(pad3);
        if (impl.code.length == 0 || !_hasSelector(impl.code, GangLaunchpad3.buyTokenAMAP.selector)) {
            revert WiringCheck("GANG_PAD3 is not a GangLaunchpad 3.0 proxy");
        }
        s = super._load2(pad3, pad1, c);
    }

    // ---------------------------------------------------------------- checks
    function _checkPre(Stack memory s, Cfg memory c, Ctx memory x, bool closedOk) internal override {
        super._checkPre(s, c, x, closedOk);
        _checkPad3(s, c, x);
    }

    /// @dev DeployGang's check, on the implementation's code (the proxy's own code has none of the pad's selectors).
    function _checkOriginTrader(Stack memory s) internal view override {
        if (!R.sameCode(s.tokenDeployer, type(TokenDeployer).runtimeCode)) revert WiringCheck("tokenDeployer code");
        bytes memory code = R.implementationOf(s.pad).code;
        if (!_hasSelector(code, IGangPad.sellFor.selector) || !_hasSelector(code, IGangPad.withdrawFor.selector)) {
            revert WiringCheck("pad sellFor / withdrawFor");
        }
    }

    /// @dev The proxy (as the router's: its code, the ProxyAdmin it created with plain OZ code, owned by OWNER — on
    ///      mainnet the platform Safe), the implementation (locked; a 3.0: its version, fee cap, registry), the proxy
    ///      initialized once, and the entry's libraries live: an unknown token goes through LegacyRoute (a missing
    ///      library returns nothing, and the decode reverts) and comes back as "not a Gang token".
    function _checkPad3(Stack memory s, Cfg memory c, Ctx memory x) internal {
        address admin = R.adminOf(s.pad);
        address impl = R.implementationOf(s.pad);
        if (admin != vm.computeCreateAddress(s.pad, 1) || !R.isProxyCode(s.pad, admin)) {
            revert WiringCheck("pad proxy code");
        }
        if (!R.sameCode(admin, type(ProxyAdmin).runtimeCode)) revert WiringCheck("pad ProxyAdmin code");
        address upgrader = ProxyAdmin(admin).owner();
        if (upgrader != c.owner || (c.mainnet && upgrader != M.OWNER_SAFE)) revert WiringCheck("pad ProxyAdmin owner");
        if (impl.code.length == 0) revert WiringCheck("pad implementation");
        _checkImplCode(impl, c.mainnet);
        (uint64 implVersion,) = R.initState(impl);
        if (implVersion != type(uint64).max) revert WiringCheck("pad implementation locked");
        // initialized (1 at deploy; a later upgrade's reinitializer raises it), not mid-initialization
        (uint64 v, bool initializing) = R.initState(s.pad);
        if (v == 0 || initializing) revert WiringCheck("pad initialized");
        GangLaunchpad3 p = GangLaunchpad3(payable(s.pad));
        // at least 1: a later upgrade raises it for new tokens (audit 3C M-1: this read-back must survive upgrades)
        if (p.TOKEN_VERSION() < PAD3_TOKEN_VERSION) revert WiringCheck("pad TOKEN_VERSION");
        if (p.MAX_FEE_RATE() != PAD3_MAX_FEE_RATE) revert WiringCheck("pad MAX_FEE_RATE");
        if (address(p.padRegistry()) != x.padRegistry) revert WiringCheck("pad.padRegistry");
        if (address(GangLaunchpad3(payable(impl)).padRegistry()) != x.padRegistry) revert WiringCheck("impl registry");
        // nobody but the router and the gateway is a router; never the proxy's own parts
        if (p.routers(admin) || p.routers(impl) || p.routers(s.pad)) revert WiringCheck("pad.routers proxy parts");
        address probe = address(uint160(uint256(keccak256("gang.deploy3.unknown-token"))));
        try p.getTokenInfo(probe) returns (uint8 st, address q, address pair, uint256 fee, uint256 left) {
            if (st != 0 || q != address(0) || pair != address(0) || fee != 0 || left != 0) {
                revert WiringCheck("LegacyRoute info");
            }
        } catch {
            revert WiringCheck("LegacyRoute not linked");
        }
        try p.tryBuy(probe, address(0), 0, 1 ether) returns (
            address tm, address, uint256 est, uint256, uint256, uint256, uint256, uint256
        ) {
            if (tm != s.pad || est != 0) revert WiringCheck("entry tryBuy");
        } catch {
            revert WiringCheck("entry tryBuy");
        }
        address[] memory callers = _callers();
        for (uint256 i; i < callers.length; i++) {
            if (!_isContract(callers[i])) revert WiringCheck("CALLERS: not a contract");
        }
        // final audit (deploy) M-3: while the deploy wallet still owns 3.0 (between phase 1 and batch 2), nothing it
        // could have listed on the side may reach the Safe: routers / callers from the pad's own events, recipients
        // from the handler's list
        if (c.owner != c.deployer && Ownable(s.pad).owner() == c.deployer) {
            if (_envAddr(_padEnv(), address(0)) != address(0)) {
                _checkDeployerNonce(s, c);
                if (vm.envOr("PAD3_LOG_SCAN", false)) _scanPadLists(s, x, c);
            }
            if (GangTaxHandler(s.handler).recipients().length != (s.recipient == address(0) ? 0 : 1)) {
                revert WiringCheck("handler recipients listed by the deploy wallet");
            }
        }
    }

    /// @notice The implementation is exactly this build's code (final audit (deploy) M-1 / L-1): byte for byte the
    ///         reference `_refImpl` deploys from this build with the same seven dependencies — immutables, linked
    ///         libraries and all, metadata aside. The libraries forge links here are this build's (CREATE2: an address
    ///         holds only the code it was derived from), so a look-alike implementation, or one linked to other
    ///         libraries, fails. On mainnet the live PoolCheck must be the one linked.
    function _checkImplCode(address impl, bool mainnet) internal {
        _checkNotPreLinked();
        GangLaunchpad3 cur = GangLaunchpad3(payable(impl));
        address ref = _refImpl(cur);
        if (!R.sameCode(impl.code, ref.code)) revert WiringCheck("pad implementation code");
        if (mainnet && !_hasPush20(impl.code, M.POOL_CHECK)) revert WiringCheck("pad PoolCheck");
        // the module it delegates to (Pad3Module): this build's module with the same dependencies (they are its
        // immutables, so equal code means equal dependencies), on the same rule version. It reaches PoolCheck only
        // through CurveLogic3, deployed by this run with the libraries the pad check above pins to the live PoolCheck.
        address m = cur.module();
        if (m.code.length == 0 || !R.sameCode(m.code, _refModule(cur).code)) {
            revert WiringCheck("pad module code");
        }
        if (Pad3Module(m).TOKEN_VERSION() != cur.TOKEN_VERSION()) {
            revert WiringCheck("module TOKEN_VERSION");
        }
    }

    /// @dev Delta review of the deploy fixes (L-1): the reference links the same libraries this run links, so an
    ///      address given for CurveLogic3 / FairLogic / LegacyRoute (--libraries, FOUNDRY_LIBRARIES) would pass with
    ///      it. Those must be left for forge to deploy from this build (they are then link references of this build's
    ///      artifacts); only PoolCheck may be given (the live one, checked above). Both the pad's artifact and its
    ///      module's are read, and each must link exactly the listed libraries: a library added to either later fails
    ///      here until it is listed (vault-mode review L-2: a module library given at build time would be
    ///      delegatecalled in the proxy).
    function _checkNotPreLinked() internal view {
        string[] memory pad = new string[](3);
        (pad[0], pad[1], pad[2]) = ("CurveLogic3", "FairLogic", "LegacyRoute");
        _checkLinks("GangLaunchpad3.sol/GangLaunchpad3.json", pad);
        string[] memory module = new string[](2);
        (module[0], module[1]) = ("CurveLogic3", "FairLogic");
        _checkLinks("Pad3Module.sol/Pad3Module.json", module);
    }

    function _checkLinks(string memory artifact, string[] memory names) internal view {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/out/", artifact));
        for (uint256 i; i < names.length; i++) {
            string memory k =
                string.concat(".deployedBytecode.linkReferences['src/gang/", names[i], ".sol'].", names[i]);
            if (!vm.keyExistsJson(json, k)) {
                revert WiringCheck(string.concat("library given at build time (link PoolCheck only): ", names[i]));
            }
        }
        // every library of every source file (two libraries in one file count as two)
        string[] memory files = vm.parseJsonKeys(json, ".deployedBytecode.linkReferences");
        uint256 n;
        for (uint256 i; i < files.length; i++) {
            string memory f = string.concat(".deployedBytecode.linkReferences['", files[i], "']");
            n += vm.parseJsonKeys(json, f).length;
        }
        // PoolCheck: a link reference unless given (mainnet: given, the live one)
        if (vm.keyExistsJson(json, ".deployedBytecode.linkReferences['src/launchpad-v2/PoolCheck.sol']")) n--;
        if (n != names.length) {
            revert WiringCheck(string.concat("libraries not listed in _checkNotPreLinked: ", artifact));
        }
    }

    /// @dev This build's implementation with `cur`'s dependencies, deployed in the simulation only (every caller runs
    ///      outside the broadcast). A later version deploys its own contract here.
    ///      The reference runs over `cur`'s own module (its address is an immutable of the implementation); the module
    ///      itself is compared with `_refModule`.
    function _refImpl(GangLaunchpad3 cur) internal virtual returns (address) {
        return Pad3Impl.implWith(Pad3Impl.depsOf(cur), cur.module());
    }

    /// @dev This build's vault mode module with `cur`'s dependencies, in the simulation only. A later version deploys
    ///      its own module here.
    function _refModule(GangLaunchpad3 cur) internal virtual returns (address) {
        return Pad3Impl.module(Pad3Impl.depsOf(cur));
    }

    /// @dev `code` holds PUSH20 `a` (0x73 ‖ a), as a library call does.
    function _hasPush20(bytes memory code, address a) internal pure returns (bool) {
        bytes21 want = bytes21(abi.encodePacked(bytes1(0x73), a));
        for (uint256 i; i + 21 <= code.length; i++) {
            bytes21 w;
            assembly ("memory-safe") {
                w := mload(add(add(code, 32), i))
            }
            if (w == want) return true;
        }
        return false;
    }

    /// @dev Only the deploy wallet can list anything on 3.0 or its handler before the Safe accepts them, and each
    ///      such call is a transaction of its own: its nonce must be phase 1's (GANG_PAD3_DEPLOYER_NONCE, printed at
    ///      the end of phase 1; required on mainnet) plus the hand-over calls phase 2 itself sent (one per pending
    ///      owner). Any other transaction from it in between refuses. Needs no log reads.
    function _checkDeployerNonce(Stack memory s, Cfg memory c) internal view {
        uint256 n0 = vm.envOr("GANG_PAD3_DEPLOYER_NONCE", uint256(0));
        if (n0 == 0) {
            if (c.mainnet) revert WiringCheck("GANG_PAD3_DEPLOYER_NONCE required on mainnet");
            return;
        }
        uint256 handOvers = (Ownable2Step(s.pad).pendingOwner() == c.owner ? 1 : 0)
            + (Ownable2Step(s.handler).pendingOwner() == c.owner ? 1 : 0);
        if (vm.getNonce(c.deployer) != n0 + handOvers) {
            revert WiringCheck("deploy wallet sent other transactions after phase 1");
        }
    }

    /// @dev Optional (PAD3_LOG_SCAN=true, with an RPC that serves eth_getLogs completely): every address that ever got
    ///      a RouterSet / CallerSet on the pad since GANG_PAD3_BLOCK: listed now only if
    ///      it is the router or the gateway (routers), or in CALLERS (callers). Needs an RPC that serves eth_getLogs
    ///      completely (public BSC endpoints may drop logs silently).
    function _scanPadLists(Stack memory s, Ctx memory x, Cfg memory c) internal view {
        if (!c.mainnet && vm.envOr("PAD3_SKIP_LOG_SCAN", false)) return;
        if (s.padBlock == 0) revert WiringCheck("GANG_PAD3_BLOCK required (log scan)");
        bytes32[2] memory sigs = [IGangLaunchpad.RouterSet.selector, IGangLaunchpad3.CallerSet.selector];
        bytes32[] memory topics = new bytes32[](1);
        for (uint256 k; k < 2; k++) {
            topics[0] = sigs[k];
            for (uint256 from = s.padBlock; from <= block.number; from += LOG_CHUNK) {
                uint256 to = from + LOG_CHUNK - 1;
                if (to > block.number) to = block.number;
                Vm.EthGetLogs[] memory logs;
                try vm.eth_getLogs(from, to, s.pad, topics) returns (Vm.EthGetLogs[] memory l) {
                    logs = l;
                } catch {
                    revert WiringCheck("pad logs unreadable: phase 2 needs an RPC that serves eth_getLogs");
                }
                address[] memory seen = new address[](logs.length);
                for (uint256 i; i < logs.length; i++) {
                    seen[i] = address(uint160(uint256(logs[i].topics[1])));
                }
                _checkSeen(s, x, k == 0, seen);
            }
        }
    }

    /// @dev `seen` addresses (from RouterSet if `routers`, else CallerSet) listed now beyond the expected ones refuse.
    function _checkSeen(Stack memory s, Ctx memory x, bool routers, address[] memory seen) internal view {
        GangLaunchpad3 p = GangLaunchpad3(payable(s.pad));
        address[] memory callers = _callers();
        for (uint256 i; i < seen.length; i++) {
            address a = seen[i];
            if (routers) {
                if (p.routers(a) && a != s.router && a != x.gateway) {
                    revert WiringCheck("pad.routers: unexpected router");
                }
            } else if (p.isCaller(a)) {
                bool ok;
                for (uint256 j; j < callers.length && !ok; j++) {
                    ok = callers[j] == a;
                }
                if (!ok) revert WiringCheck("pad.isCaller: unexpected caller");
            }
        }
    }

    /// @dev Final audit (deploy) M-2: the owner's GangHandlerAdmin only if it is this build's GangHandlerAdmin code
    ///      (its `handler` immutable aside) with no hand-over pending — a look-alike returning the right `handler()` /
    ///      `owner()` must not pass for it.
    function _isOwnersAdmin(address who, address handler, address owner) internal view override returns (bool) {
        if (!super._isOwnersAdmin(who, handler, owner)) return false;
        (bool ok,) = CC.check(who, "GangHandlerAdmin.sol/GangHandlerAdmin.json", false);
        return ok && Ownable2Step(who).pendingOwner() == address(0);
    }

    // ---------------------------------------------------------------- batches 3–5
    /// @dev Once 3.0 is open: forward (batch 3), callers (batch 4), cut-over (batch 5). Each runs in the simulation
    ///      first, as its owner sends it, and must leave what it is for; then it is rolled back and printed.
    function _printCutover(Stack memory s, Ctx memory x, Cfg memory c) internal override {
        // final audit (deploy) L-3: open is not enough — only once OWNER holds the pad and the handler
        if (!_ownerHolds(s, c)) {
            console.log("\nbatches 3-5 wait until OWNER owns 3.0 and its handler (run batch 2, then phase 2 again)");
            return;
        }
        string memory j = _forwardJson(s, x, c);
        if (bytes(j).length == 0) {
            console.log("\nforward: every older pad lists 3.0 as a router");
        } else {
            console.log("\n=== Safe batch 3 (forward): older pads list 3.0 as a router ===");
            console.log(j);
        }
        j = _callersJson(s, c);
        if (bytes(j).length != 0) {
            console.log("\n=== Safe batch 4 (callers): aggregator contracts that may sell for a user on 3.0 ===");
            console.log(j);
        }
        // audit 3C: printed only on request, once backend / site / CLI / modules use 3.0 (run early, it stops module
        // creates on 1.0 / 2.0 before 3.0 has modules)
        if (!vm.envOr("CUTOVER", false)) {
            console.log(
                "\ncut-over (1.0 / 2.0 stop creating): not printed; re-run phase 2 with CUTOVER=true when ready"
            );
            return;
        }
        j = _cutover3Json(s, x, c);
        if (bytes(j).length == 0) {
            console.log("\ncut-over: 1.0 and 2.0 no longer create");
        } else {
            console.log("\n=== Safe batch 5 (cut-over, only once backend / site / CLI / modules use 3.0) ===");
            console.log(j);
        }
    }

    function _ownerHolds(Stack memory s, Cfg memory c) internal view returns (bool) {
        address ho = Ownable(s.handler).owner();
        return Ownable(s.pad).owner() == c.owner && Ownable2Step(s.pad).pendingOwner() == address(0)
            && (c.mainnet ? c.owner == M.OWNER_SAFE : true)
            && ((ho == c.owner && Ownable2Step(s.handler).pendingOwner() == address(0))
                || _isOwnersAdmin(ho, s.handler, c.owner));
    }

    /// @dev Batch 3: `setRouter(3.0, true)` on each older pad that does not list 3.0 yet ("" when none). One owner for
    ///      all (mainnet: the Safe).
    function _forwardJson(Stack memory s, Ctx memory x, Cfg memory c) internal returns (string memory j) {
        address[] memory pads = _legacyPads(s, x, c);
        address[] memory todo = new address[](pads.length);
        uint256 n;
        address owner;
        for (uint256 i; i < pads.length; i++) {
            address o = Ownable(pads[i]).owner();
            if (c.mainnet && o != M.OWNER_SAFE) revert WiringCheck("legacy pad not owned by the Safe");
            if (IGangPad(pads[i]).routers(s.pad)) continue;
            if (n != 0 && o != owner) revert WiringCheck("legacy pads with different owners");
            owner = o;
            todo[n++] = pads[i];
        }
        if (n == 0) return "";
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < n; i++) {
            vm.prank(owner);
            IGangPad(todo[i]).setRouter(s.pad, true);
        }
        bool ok = true;
        for (uint256 i; i < n; i++) {
            ok = ok && IGangPad(todo[i]).routers(s.pad);
        }
        vm.revertToState(snap);
        if (!ok) revert WiringCheck("forward batch");
        j = _head(c.mainnet, owner, "gang: older pads list GangLaunchpad 3.0 as a router");
        for (uint256 i; i < n; i++) {
            console.log("forward: setRouter(3.0) on", todo[i]);
            j = string.concat(j, _tx(todo[i], abi.encodeCall(IGangPad.setRouter, (s.pad, true)), i != 0));
        }
        j = string.concat(j, "]}");
    }

    /// @dev Batch 4: `setCaller(c, true)` on 3.0 for each CALLERS entry not listed yet ("" when none).
    function _callersJson(Stack memory s, Cfg memory c) internal returns (string memory j) {
        address[] memory callers = _callers();
        GangLaunchpad3 p = GangLaunchpad3(payable(s.pad));
        address[] memory todo = new address[](callers.length);
        uint256 n;
        for (uint256 i; i < callers.length; i++) {
            if (!p.isCaller(callers[i])) todo[n++] = callers[i];
        }
        if (n == 0) return "";
        _checkCallerCode(todo, n, c.mainnet);
        address owner = c.mainnet ? M.OWNER_SAFE : Ownable(s.pad).owner();
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < n; i++) {
            vm.prank(owner);
            p.setCaller(todo[i], true);
        }
        bool ok = true;
        for (uint256 i; i < n; i++) {
            ok = ok && p.isCaller(todo[i]);
        }
        vm.revertToState(snap);
        if (!ok) revert WiringCheck("callers batch");
        j = _head(c.mainnet, owner, "gang: list aggregator callers on GangLaunchpad 3.0");
        for (uint256 i; i < n; i++) {
            console.log("callers: setCaller", todo[i]);
            // audit 3C: the same address may hold other code on another chain: check this hash against the reviewed one
            console.logBytes32(todo[i].codehash);
            j = string.concat(j, _tx(s.pad, abi.encodeCall(GangLaunchpad3.setCaller, (todo[i], true)), i != 0));
        }
        j = string.concat(j, "]}");
    }

    /// @dev Batch 5: 1.0 and 2.0 (those still creating) stop creating ("" when neither does). 3.0 must be creating.
    function _cutover3Json(Stack memory s, Ctx memory x, Cfg memory c) internal returns (string memory j) {
        TokenDeployer td = TokenDeployer(s.tokenDeployer);
        address[2] memory old = [x.pad1, c.mainnet ? MAINNET_PAD_2 : _envAddr("GANG_PAD2", address(0))];
        address[2] memory todo;
        uint256 n;
        for (uint256 i; i < 2; i++) {
            if (old[i] != address(0) && old[i] != s.pad && td.launchpads(old[i])) todo[n++] = old[i];
        }
        if (n == 0) return "";
        address owner = Ownable(s.tokenDeployer).owner();
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < n; i++) {
            vm.prank(owner);
            td.setLaunchpad(todo[i], false);
        }
        bool ok = td.launchpads(s.pad);
        for (uint256 i; i < n; i++) {
            ok = ok && !td.launchpads(todo[i]);
        }
        vm.revertToState(snap);
        if (!ok) revert WiringCheck("cut-over batch");
        j = _head(c.mainnet, owner, "gang: 1.0 / 2.0 stop creating (3.0 is live)");
        for (uint256 i; i < n; i++) {
            console.log("cut-over: stops creating", todo[i]);
            j = string.concat(
                j, _tx(s.tokenDeployer, abi.encodeCall(TokenDeployer.setLaunchpad, (todo[i], false)), i != 0)
            );
        }
        j = string.concat(j, "]}");
    }

    /// @dev Mainnet: the five pads 3.0 forwards to, each in the registry. Testnet: LEGACY_PADS, or the registry's pads
    ///      (3.0 aside) that answer `routers` (the older LaunchpadV2 family has no router list).
    function _legacyPads(Stack memory s, Ctx memory x, Cfg memory c) internal view returns (address[] memory pads) {
        GangPadRegistry reg = GangPadRegistry(x.padRegistry);
        if (c.mainnet) {
            pads = new address[](5);
            pads[0] = MAINNET_PAD_1;
            pads[1] = MAINNET_PAD_2;
            pads[2] = MAINNET_VAULT_PAD;
            pads[3] = M.FLYWHEEL_PAD_V1;
            pads[4] = M.FLYWHEEL_PAD_V2;
            for (uint256 i; i < 5; i++) {
                if (!reg.isPad(pads[i])) revert WiringCheck("legacy pad not in the registry");
            }
            return pads;
        }
        address[] memory env = vm.envOr("LEGACY_PADS", ",", new address[](0));
        if (env.length != 0) return env;
        address[] memory all = reg.pads();
        pads = new address[](all.length);
        uint256 n;
        for (uint256 i; i < all.length; i++) {
            if (all[i] == s.pad) continue;
            try IGangPad(all[i]).routers(address(0)) returns (bool) {
                pads[n++] = all[i];
            } catch {}
        }
        assembly ("memory-safe") {
            mstore(pads, n)
        }
    }

    function _callers() internal view virtual returns (address[] memory) {
        return vm.envOr("CALLERS", ",", new address[](0));
    }

    /// @dev Final audit (deploy) L-4: each caller to list has the codehash it was reviewed with (CALLER_CODEHASHES,
    ///      same order as CALLERS; required on mainnet), and is not an upgradeable proxy unless CALLERS_PROXY_OK=true
    ///      (a proxy's codehash says nothing of the logic behind it).
    function _checkCallerCode(address[] memory todo, uint256 n, bool mainnet) internal view {
        address[] memory callers = _callers();
        bytes32[] memory hashes = vm.envOr("CALLER_CODEHASHES", ",", new bytes32[](0));
        if (hashes.length == 0 && mainnet) revert WiringCheck("CALLER_CODEHASHES required on mainnet");
        if (hashes.length != 0 && hashes.length != callers.length) revert WiringCheck("CALLER_CODEHASHES length");
        for (uint256 i; i < n; i++) {
            if (hashes.length != 0) {
                bool found;
                for (uint256 j; j < callers.length && !found; j++) {
                    found = callers[j] == todo[i] && hashes[j] == todo[i].codehash;
                }
                if (!found) revert WiringCheck("CALLERS: codehash differs from the reviewed one");
            }
            if (
                R.implementationOf(todo[i]) != address(0)
                    || vm.load(todo[i], 0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50) != 0
            ) {
                if (!vm.envOr("CALLERS_PROXY_OK", false)) revert WiringCheck("CALLERS: an upgradeable proxy");
                console.log("callers: WARNING upgradeable proxy, implementation", R.implementationOf(todo[i]));
            }
        }
    }

    function _isContract(address a) internal view returns (bool) {
        bytes memory code = a.code;
        // an EIP-7702 delegated EOA (0xef0100 ‖ address) is not a contract (the pad refuses it too)
        return code.length != 0 && !(code.length == 23 && code[0] == 0xef && code[1] == 0x01 && code[2] == 0x00);
    }

    // ---------------------------------------------------------------- output
    function _log2(Stack memory s, Cfg memory c) internal view override {
        console.log("--- GANGLAUNCHPAD 3.0 (upgradeable; aggregator entry built in) ---");
        console.log("GANG_PAD3 (proxy: the one permanent address)", s.pad);
        console.log("GANG_PAD3_BLOCK", s.padBlock);
        console.log("GANG_PAD3_IMPL", R.implementationOf(s.pad));
        address admin = R.adminOf(s.pad);
        console.log("GANG_PAD3_PROXY_ADMIN", admin);
        if (admin.code.length != 0) console.log("upgrades: ProxyAdmin owner (no timelock)", ProxyAdmin(admin).owner());
        console.log("GANG_TAX_HANDLER3", s.handler);
        console.log("GANG_ROUTER3 (proxy: the pad lists it, users approve it)", s.router);
        console.log("GANG_ROUTER3_IMPL", s.routerImpl);
        console.log("GANG_ROUTER3_PROXY_ADMIN (owner = the timelock)", s.routerAdmin);
        console.log("GANG_ROUTER3_TIMELOCK", s.routerTimelock);
        console.log("router timelock proposer / executor / canceller", R.timelockSafe(c.mainnet, c.owner));
        console.log("shared (1.0's): QUOTE_REGISTRY", s.quoteRegistry);
        console.log("shared (1.0's): PLATFORM_BUCKET", s.bucket);
        console.log("shared (1.0's): DIVIDEND_VAULT", s.vault);
        console.log("shared (1.0's): MIGRATOR", s.migrator);
        console.log("shared (1.0's): TOKEN_DEPLOYER", s.tokenDeployer);
        if (_envAddr(_padEnv(), address(0)) == address(0)) {
            console.log("GANG_PAD3_DEPLOYER_NONCE (set it for phase 2)", vm.getNonce(c.deployer));
        }
        if (s.padBlock != 0) {
            console.log(
                "--- for the keeper / indexer: 3.0 serves both tracks, next to 1.0 / 2.0 (start block below) ---"
            );
            console.log(string.concat("gang:", vm.toString(s.pad), "@", vm.toString(s.padBlock)));
            console.log("indexer: TradeV1 / TokenVersionSet are new; Buy / Sell / Created as 2.0");
        }
        console.log("PENDING: the handler's recipient listings (partners) are not copied; the Safe lists them");
        console.log("PENDING: modules (GangBond, Buyback / Split / LP / Combo factories + a GangHandlerAdmin) for 3.0");
    }
}
