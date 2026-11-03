// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {GangMainnetRefs as M} from "../config/GangDeployRefs.sol";
import {TokenDeployer} from "../src/common/TokenDeployer.sol";
import {GangPadRegistry} from "../src/gang/GangPadRegistry.sol";
import {GangLaunchpad3} from "../src/gang/GangLaunchpad3.sol";
import {IGangPad} from "../src/gang/interfaces/IGangPad.sol";
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
///      plus: PAD3_NEW (mainnet phase 1), CUTOVER (print batch 5), CALLERS (comma-separated contracts, optional; testnet phase 1 lists them
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

    function _ctx(bool mainnet) internal view override returns (Ctx memory x) {
        x = super._ctx(mainnet);
        if (mainnet && _envAddr(_padEnv(), address(0)) == address(0) && !vm.envOr("PAD3_NEW", false)) {
            revert WiringCheck("phase 1 on mainnet needs PAD3_NEW=true");
        }
    }

    // ---------------------------------------------------------------- phase 1
    /// @dev The handler, the implementation, the proxy (initialized in its constructor: no window in which anyone else
    ///      could initialize it; ProxyAdmin owned by OWNER), then the router on the proxy.
    function _deploy2(Stack memory s, Cfg memory c) internal override {
        s.handler = address(new GangTaxHandler(c.deployer, s.vault, s.bucket, c.dexRouter));
        address impl = address(
            new GangLaunchpad3(
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
    function _checkPad3(Stack memory s, Cfg memory c, Ctx memory x) internal view {
        address admin = R.adminOf(s.pad);
        address impl = R.implementationOf(s.pad);
        if (admin != vm.computeCreateAddress(s.pad, 1) || !R.isProxyCode(s.pad, admin)) {
            revert WiringCheck("pad proxy code");
        }
        if (!R.sameCode(admin, type(ProxyAdmin).runtimeCode)) revert WiringCheck("pad ProxyAdmin code");
        address upgrader = ProxyAdmin(admin).owner();
        if (upgrader != c.owner || (c.mainnet && upgrader != M.OWNER_SAFE)) revert WiringCheck("pad ProxyAdmin owner");
        if (impl.code.length == 0) revert WiringCheck("pad implementation");
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
    }

    // ---------------------------------------------------------------- batches 3–5
    /// @dev Once 3.0 is open: forward (batch 3), callers (batch 4), cut-over (batch 5). Each runs in the simulation
    ///      first, as its owner sends it, and must leave what it is for; then it is rolled back and printed.
    function _printCutover(Stack memory s, Ctx memory x, Cfg memory c) internal override {
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
        address owner = Ownable(s.pad).owner();
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

    function _callers() internal view returns (address[] memory) {
        return vm.envOr("CALLERS", ",", new address[](0));
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
