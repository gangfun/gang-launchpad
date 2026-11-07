// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {GangMainnetRefs as M} from "../config/GangDeployRefs.sol";
import {GangLaunchpad3} from "../src/gang/GangLaunchpad3.sol";
import {GangRouterDeployLib as R} from "./GangRouterDeployLib.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pad3Module} from "../src/gang/Pad3Module.sol";
import {FlywheelTaxHandler} from "../src/flywheel/FlywheelTaxHandler.sol";
import {MintTokenDeployer} from "../src/flywheel/MintTokenDeployer.sol";
import {SharedDividendVault} from "../src/common/SharedDividendVault.sol";
import {SharedPlatformFeeBucket} from "../src/common/SharedPlatformFeeBucket.sol";
import {Pad3FlyVaultCore} from "../src/gang/Pad3FlyVaultCore.sol";
import {Pad3FlyModule} from "../src/gang/Pad3FlyModule.sol";
import {Pad3Impl} from "./Pad3Impl.sol";
import {DeployGangLaunchpad3} from "./DeployGangLaunchpad3.s.sol";

/// @title UpgradeGangLaunchpad3 — move the GangLaunchpad 3.0 proxy to a new implementation, checked before the Safe
///        signs (audit 3C M-1 / L-3)
/// @notice The proxy, its tokens, approvals and storage stay; only the implementation changes, at once (no timelock,
///         by decision), through ProxyAdmin.upgradeAndCall(proxy, impl, PAD3_INIT_CALL) sent by the ProxyAdmin's owner
///         (mainnet: the platform Safe). Before the call is sent or printed:
///         1. the new implementation (PAD3_IMPL, or deployed here from this build with the current implementation's
///            dependencies read from its code) has exactly the seven dependencies of the current one, is locked, is not
///            the current one, and carries the entry (its dispatcher);
///         2. the upgrade runs in the simulation as the ProxyAdmin's owner sends it — with the set-up call in the SAME
///            transaction (a reinitializer left for a later call could be front-run) — and afterwards:
///            - the proxy's initialized version is the new implementation's `initVersion()`, not mid-initialization
///              (a new reinitializer without PAD3_INIT_CALL, or a set-up call without one, is refused before that);
///            - the pad's settings (owner / pending owner, factories, gate, cap, routers, listed CALLERS, …) and, for
///              the newest 25 tokens, their raw records AND what the named views derive from them (status, quote, pair,
///              graduation amount / remaining, tax config, quotes for a fixed buy and sell, wallet room, 打新 mint
///              preview, exit fee and hold line) read back as
///              before. This catches a moved variable or a struct member read in another place; two members of the
///              same type swapped can still slip past the raw bytes, and only the named views or the layout test see
///              it;
///            - a token with a promoter share in that sample keeps its terms, and each pair in PAD3_PROMOTE_PROBES
///              (token, wallet) its terms, binding and earnings: set it once tokens with a share exist, from their
///              `PromoterBound` logs (the pad can't list them; test/gang3/Pad3Promote.t.sol pins the namespace);
///            - the whole phase-2 read-back of DeployGangLaunchpad3 passes on the upgraded proxy;
///            then it is rolled back. Testnet with the deploy wallet owning the ProxyAdmin: sent. Otherwise: printed as
///         a Safe batch. Run test/gang3/GangLaunchpad3Layout.t.sol against the new implementation too: it pins every
///         slot and struct member; this script checks real data only.
/// @dev Env: as DeployGangLaunchpad3 phase 2 (DEPLOYER_PRIVATE_KEY, GANG_PAD = 1.0, GANG_PAD3, GANG_ROUTER3, OWNER,
///      KEEPER, GANG_GATEWAY, GANG_PAD_REGISTRY, CALLERS), plus PAD3_IMPL (optional), PAD3_INIT_CALL (optional
///      calldata: the new implementation's reinitializer), PAD3_PROMOTE_PROBES (optional, above), PAD3_FLY_HANDLER / PAD3_FLY_TOKEN_DEPLOYER / PAD3_FLY_VAULT_CORE (optional; see
///      `_resolveFly`; testnet's first 铸币飞轮 upgrade needs the deployer). A later version replaces `_newImpl` with
///      its own contract. Mainnet broadcast needs GANG_MAINNET_OK=true (only the deployments are broadcast there; the
///      listings and the upgrade are the Safe's). A run that deploys prints no batch: re-run read-only with the
///      deployed addresses, and again right before the Safe signs.
contract UpgradeGangLaunchpad3 is DeployGangLaunchpad3 {
    uint256 internal constant SAMPLE = 25;

    /// @dev One upgrade as `_simulate` runs it.
    struct Up {
        address admin;
        address upgrader;
        address impl;
        bytes init;
        uint64 wantVersion;
        address[] prepTo;
        bytes[] prepCall;
    }

    /// @dev The 铸币飞轮 module's own three dependencies for the implementation `_newImpl` deploys (`_resolveFly`).
    Pad3Impl.FlyDeps internal _fly;

    struct Snapshot {
        bytes32 settings;
        bytes32[] tokens;
        /// @dev whether the vault state was read (the current implementation serves the vault mode)
        bool vault;
        /// @dev per sampled token: a gated 打新 sale the CURRENT implementation doesn't trade through the entry (status
        ///      3); its entry views (getTokenInfo, tryBuy) change on purpose with the upgrade to the 打新 entry
        bool[] newFairEntry;
    }

    function run() external override returns (Stack memory s) {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address me = vm.addr(pk);
        bool mainnet = block.chainid == 56;
        Ctx memory x = _ctx(mainnet);
        Cfg memory c = _cfg2(me, x.pad1);
        if (c.mainnet) _requireMainnetInputs(c, x);
        address proxy = _envAddr(_padEnv(), address(0));
        if (proxy == address(0)) revert WiringCheck("GANG_PAD3");
        s = _load2(proxy, x.pad1, c);
        address admin = R.adminOf(proxy);
        address upgrader = ProxyAdmin(admin).owner();
        if (c.mainnet && upgrader != M.OWNER_SAFE) revert WiringCheck("ProxyAdmin owner is not the Safe");
        address current = R.implementationOf(proxy);
        bytes memory init = vm.envOr("PAD3_INIT_CALL", bytes(""));
        (uint64 v0,) = R.initState(proxy);

        console.log("=== UpgradeGangLaunchpad3 chain", block.chainid, "===");
        console.log("GANG_PAD3", proxy);
        console.log("current implementation", current);
        console.log("ProxyAdmin / owner", admin, upgrader);

        address impl = _envAddr("PAD3_IMPL", address(0));
        bool deployed = _resolveFly(GangLaunchpad3(payable(current)), impl, s, c, pk, upgrader);
        (address[] memory prepTo, bytes[] memory prepCall) = _flyPrep(s, c.keeper, c.dexRouter, upgrader);

        if (impl == address(0)) {
            vm.startBroadcast(pk);
            impl = _newImpl(GangLaunchpad3(payable(current)));
            vm.stopBroadcast();
            deployed = true;
            console.log("new implementation (deployed now; pass it as PAD3_IMPL on any re-run)", impl);
        } else {
            console.log("new implementation (PAD3_IMPL)", impl);
        }
        if (init.length != 0) {
            console.log("set-up call in the upgrade, selector:");
            console.logBytes4(bytes4(init));
        }
        _checkImpl(current, impl);
        {
            (, Pad3Impl.FlyDeps memory f) = Pad3Impl.flyDepsOf(GangLaunchpad3(payable(impl)));
            if (
                f.flyTaxHandler != _fly.flyTaxHandler || f.flyTokenDeployer != _fly.flyTokenDeployer
                    || f.flyVaultCore != _fly.flyVaultCore
            ) {
                revert WiringCheck("PAD3_IMPL fly dependencies are not the resolved ones");
            }
        }
        _simulate(s, c, x, Up(admin, upgrader, impl, init, _wantVersion(impl, v0, init), prepTo, prepCall));

        bytes memory call = abi.encodeCall(ProxyAdmin.upgradeAndCall, (ITransparentUpgradeableProxy(proxy), impl, init));
        if (!c.mainnet && upgrader == me) {
            vm.startBroadcast(pk);
            _sendPrep(prepTo, prepCall, upgrader, false);
            ProxyAdmin(admin).upgradeAndCall(ITransparentUpgradeableProxy(proxy), impl, init);
            vm.stopBroadcast();
            console.log("upgraded (testnet, the deploy wallet owns the ProxyAdmin)");
            return s;
        }
        // audit C M-2: a batch is only printed from a run that deployed nothing, i.e. from the addresses on chain
        if (deployed) {
            console.log("\nDeployed in this run: once mined, re-run read-only with PAD3_IMPL, PAD3_FLY_HANDLER and");
            console.log("PAD3_FLY_VAULT_CORE set to the addresses above to print the Safe batch.");
            return s;
        }
        console.log("\n=== Safe batch: upgrade GangLaunchpad 3.0 (ProxyAdmin.upgradeAndCall, effective at once) ===");
        if (prepTo.length != 0) console.log("(the fly-mode listings first, then the upgrade, in one batch)");
        console.log(_batchJson(c.mainnet, upgrader, prepTo, prepCall, admin, call));
    }

    /// @dev The upgrade in the simulation, as the owner sends it (the 铸币飞轮 listings first); checked; rolled back.
    function _simulate(Stack memory s, Cfg memory c, Ctx memory x, Up memory u) internal {
        GangLaunchpad3 p = GangLaunchpad3(payable(s.pad));
        Snapshot memory before = _snapshot(p, s, _servesVaultMode(s.pad), new bool[](0));
        _warnNoPromoteProbes(p);
        uint256 snap = vm.snapshotState();
        _sendPrep(u.prepTo, u.prepCall, u.upgrader, true);
        vm.prank(u.upgrader);
        ProxyAdmin(u.admin).upgradeAndCall(ITransparentUpgradeableProxy(s.pad), u.impl, u.init);
        if (R.implementationOf(s.pad) != u.impl) revert WiringCheck("upgrade: implementation slot");
        (uint64 v1, bool initializing) = R.initState(s.pad);
        if (v1 != u.wantVersion || initializing) revert WiringCheck("upgrade: initialized version");
        Snapshot memory afterUp = _snapshot(p, s, before.vault, before.newFairEntry);
        if (afterUp.settings != before.settings) revert WiringCheck("upgrade: settings changed");
        for (uint256 i; i < before.tokens.length; i++) {
            if (afterUp.tokens[i] != before.tokens[i]) revert WiringCheck("upgrade: a token's record changed");
        }
        _checkNewFairEntry(p, before.newFairEntry);
        // final audit (deploy) L-5: the proxy, implementation, libraries and wiring of 3.0 itself, not the deploy-time
        // pins (TWAP, keeper, gate…) the Safe may have changed since: drift is what the snapshot above compares
        _checkPad3(s, c, x);
        _checkLibs(s, c);
        _checkOriginTrader(s);
        vm.revertToState(snap);
        console.log("simulated: upgrade + read-back ok; tokens compared", before.tokens.length);
    }

    /// @dev The listings `_flyPrep` found, as the ProxyAdmin's owner sends them: pranked (the simulation) or broadcast
    ///      (testnet, the deploy wallet owns them all).
    function _sendPrep(address[] memory to, bytes[] memory data, address upgrader, bool prank) internal {
        for (uint256 i; i < to.length; i++) {
            if (prank) vm.prank(upgrader);
            (bool ok,) = to[i].call(data[i]);
            if (!ok) revert WiringCheck("fly listing call failed");
        }
    }

    function _batchJson(
        bool mainnet,
        address upgrader,
        address[] memory to,
        bytes[] memory data,
        address admin,
        bytes memory call
    ) internal pure returns (string memory j) {
        j = _head(mainnet, upgrader, "gang: upgrade GangLaunchpad 3.0");
        for (uint256 i; i < to.length; i++) {
            j = string.concat(j, _tx(to[i], data[i], i != 0));
        }
        j = string.concat(j, _tx(admin, call, to.length != 0), "]}");
    }

    /// @dev The 铸币飞轮 module's own three dependencies (`_fly`).
    ///      - Once the current module has a 铸币飞轮 module: its three, always (audit C H-1: a 铸币飞轮 token's handler
    ///        and vault core are fixed in the token and the vault, so a later upgrade can never move them);
    ///        PAD3_FLY_HANDLER / PAD3_FLY_TOKEN_DEPLOYER / PAD3_FLY_VAULT_CORE, if given, must equal them.
    ///      - The first upgrade with one: those env values, else PAD3_IMPL's, else V2's MintTokenDeployer (mainnet: only
    ///        it), a FlywheelTaxHandler deployed now (owned by the ProxyAdmin's owner from the start — audit C M-1: the
    ///        deploy wallet never holds it — over the shared vault, the pad's bucket and the DEX router; its launchpad
    ///        and keeper are set in the batch) and a Pad3FlyVaultCore of the proxy deployed now. Returns whether
    ///        anything was deployed (broadcast).
    function _resolveFly(
        GangLaunchpad3 cur,
        address implEnv,
        Stack memory s,
        Cfg memory c,
        uint256 pk,
        address upgrader
    ) internal returns (bool deployed) {
        (bool has, Pad3Impl.FlyDeps memory f) = Pad3Impl.flyDepsOf(cur);
        Pad3Impl.FlyDeps memory e = Pad3Impl.FlyDeps(
            _envAddr("PAD3_FLY_HANDLER", address(0)),
            _envAddr("PAD3_FLY_TOKEN_DEPLOYER", address(0)),
            _envAddr("PAD3_FLY_VAULT_CORE", address(0))
        );
        if (has) {
            if (
                (e.flyTaxHandler != address(0) && e.flyTaxHandler != f.flyTaxHandler)
                    || (e.flyTokenDeployer != address(0) && e.flyTokenDeployer != f.flyTokenDeployer)
                    || (e.flyVaultCore != address(0) && e.flyVaultCore != f.flyVaultCore)
            ) revert WiringCheck("PAD3_FLY_* differ from the current module's");
        } else if (implEnv != address(0)) {
            (, f) = Pad3Impl.flyDepsOf(GangLaunchpad3(payable(implEnv)));
        }
        address d = e.flyTokenDeployer != address(0) ? e.flyTokenDeployer : f.flyTokenDeployer;
        if (d == address(0) && c.mainnet) d = M.FLYWHEEL_TOKEN_DEPLOYER;
        if (d == address(0)) revert WiringCheck("PAD3_FLY_TOKEN_DEPLOYER");
        if (c.mainnet && d != M.FLYWHEEL_TOKEN_DEPLOYER) revert WiringCheck("fly token deployer is not V2's");
        address h = e.flyTaxHandler != address(0) ? e.flyTaxHandler : f.flyTaxHandler;
        address core = e.flyVaultCore != address(0) ? e.flyVaultCore : f.flyVaultCore;
        if (h == address(0) || core == address(0)) {
            vm.startBroadcast(pk);
            if (h == address(0)) h = address(new FlywheelTaxHandler(upgrader, s.vault, s.bucket, c.dexRouter));
            if (core == address(0)) core = address(new Pad3FlyVaultCore(s.vault, s.pad));
            vm.stopBroadcast();
            deployed = true;
        }
        console.log("fly tax handler (PAD3_FLY_HANDLER)", h);
        console.log("fly vault core (PAD3_FLY_VAULT_CORE)", core);
        console.log("fly token deployer", d);
        if (Ownable(h).owner() != upgrader) revert WiringCheck("fly handler not owned by the ProxyAdmin owner");
        _fly = Pad3Impl.FlyDeps(h, d, core);
    }

    /// @dev What the ProxyAdmin's owner still has to do for the 铸币飞轮 dependencies, before the upgrade: the handler's
    ///      one-shot launchpad (the proxy) and first keeper, 3.0 listed on the token deployer, the handler a bucket
    ///      operator, the vault core listed in the vault and the handler bound as its operator (which also excludes
    ///      the handler from shares). Each contract must be the owner's (mainnet: the Safe owns all).
    function _flyPrep(Stack memory s, address keeper, address dexRouter, address upgrader)
        internal
        view
        returns (address[] memory to, bytes[] memory data)
    {
        FlywheelTaxHandler h = FlywheelTaxHandler(_fly.flyTaxHandler);
        address d = _fly.flyTokenDeployer;
        address core = _fly.flyVaultCore;
        SharedDividendVault v = SharedDividendVault(s.vault);
        to = new address[](6);
        data = new bytes[](6);
        uint256 n;
        address lp = h.launchpad();
        if (lp != address(0) && lp != s.pad) revert WiringCheck("fly handler serves another launchpad");
        if (lp == address(0)) {
            // first wiring (re-review L-1): the router is set at construction, undelayed, outside the code check, so a
            // look-alike handler given as PAD3_FLY_HANDLER must not bring its own
            if (address(h.dexRouter()) != dexRouter || h.dexRouterEta() != 0) {
                revert WiringCheck("fly handler router is not the DEX router");
            }
            (to[n], data[n++]) =
            (_ownedBy(address(h), upgrader), abi.encodeCall(FlywheelTaxHandler.setLaunchpad, (s.pad)));
        }
        if (!h.keeperSet()) {
            (to[n], data[n++]) = (_ownedBy(address(h), upgrader), abi.encodeWithSignature("setKeeper(address)", keeper));
        }
        if (!MintTokenDeployer(d).launchpads(s.pad)) {
            (to[n], data[n++]) = (_ownedBy(d, upgrader), abi.encodeCall(MintTokenDeployer.setLaunchpad, (s.pad, true)));
        }
        if (!SharedPlatformFeeBucket(s.bucket).operators(address(h))) {
            (to[n], data[n++]) =
            (_ownedBy(s.bucket, upgrader), abi.encodeCall(SharedPlatformFeeBucket.setOperator, (address(h), true)));
        }
        if (!v.launchpads(core)) {
            (to[n], data[n++]) =
            (_ownedBy(s.vault, upgrader), abi.encodeCall(SharedDividendVault.setLaunchpad, (core, true)));
        }
        // the binding is once and for good: refuse a core or handler already bound to anything else
        address boundOp = v.operatorFor(core);
        address boundCore = v.operatorOf(address(h));
        if ((boundOp != address(0) && boundOp != address(h)) || (boundCore != address(0) && boundCore != core)) {
            revert WiringCheck("fly handler / vault core bound elsewhere in the vault");
        }
        if (boundOp == address(0)) {
            (to[n], data[n++]) =
            (_ownedBy(s.vault, upgrader), abi.encodeCall(SharedDividendVault.setOperator, (address(h), core)));
        }
        assembly ("memory-safe") {
            mstore(to, n)
            mstore(data, n)
        }
    }

    function _ownedBy(address target, address upgrader) internal view returns (address) {
        if (Ownable(target).owner() != upgrader) {
            revert WiringCheck("fly dependency not owned by the ProxyAdmin owner");
        }
        return target;
    }

    /// @dev Review 3: the version the new implementation leaves the proxy at (`initVersion`) decides whether a set-up
    ///      call is due: a new reinitializer must run inside the upgrade, and a set-up call needs one.
    function _wantVersion(address impl, uint64 current, bytes memory init) internal view returns (uint64 want) {
        want = GangLaunchpad3(payable(impl)).initVersion();
        if (want < current) revert WiringCheck("PAD3_IMPL initVersion below the proxy's");
        if (want > current && init.length == 0) revert WiringCheck("PAD3_INIT_CALL missing: reinitializer left open");
        if (want == current && init.length != 0) revert WiringCheck("PAD3_INIT_CALL without a new reinitializer");
    }

    /// @dev The reference the new implementation must match is what this script would deploy (`_newImpl`).
    function _refImpl(GangLaunchpad3 cur) internal override returns (address) {
        return _newImplWith(cur, cur.module());
    }

    /// @dev This build's GangLaunchpad3 with the current implementation's seven dependencies (read from its code, never
    ///      typed in). A later version deploys its own contract here.
    function _newImpl(GangLaunchpad3 cur) internal returns (address) {
        return _newImplWith(cur, Pad3Impl.module(Pad3Impl.depsOf(cur), _fly));
    }

    /// @dev This build's implementation with `cur`'s dependencies over `module` (a new module for the upgrade; the
    ///      checked implementation's own for the reference). A later version deploys its own contract here.
    function _newImplWith(GangLaunchpad3 cur, address module) internal virtual returns (address) {
        return Pad3Impl.implWith(Pad3Impl.depsOf(cur), module);
    }

    function _checkImpl(address current, address impl) internal {
        if (impl == current) revert WiringCheck("PAD3_IMPL is the current implementation");
        if (impl.code.length == 0) revert WiringCheck("PAD3_IMPL has no code");
        if (!_hasSelector(impl.code, GangLaunchpad3.buyTokenAMAP.selector)) revert WiringCheck("PAD3_IMPL not a 3.x");
        // rule versions only go up: a new implementation never creates tokens under an older version's number
        if (GangLaunchpad3(payable(impl)).TOKEN_VERSION() < GangLaunchpad3(payable(current)).TOKEN_VERSION()) {
            revert WiringCheck("PAD3_IMPL TOKEN_VERSION below the current one");
        }
        (uint64 locked,) = R.initState(impl);
        if (locked != type(uint64).max) revert WiringCheck("PAD3_IMPL not locked");
        GangLaunchpad3 a = GangLaunchpad3(payable(current));
        GangLaunchpad3 b = GangLaunchpad3(payable(impl));
        if (
            address(a.quoteRegistry()) != address(b.quoteRegistry())
                || address(a.dividendVault()) != address(b.dividendVault())
                || address(a.platformBucket()) != address(b.platformBucket()) || a.taxHandler() != b.taxHandler()
                || a.tokenDeployer() != b.tokenDeployer() || a.wbnb() != b.wbnb()
                || address(a.padRegistry()) != address(b.padRegistry())
        ) revert WiringCheck("PAD3_IMPL dependencies differ");
        // final audit (deploy) M-1: this build's code (what `_newImpl` deploys), with this build's libraries — never a
        // look-alike at an address someone slipped into the env
        _checkImplCode(impl, block.chainid == 56);
    }

    /// @dev The settings every token trades under, and for the newest SAMPLE tokens both their raw records (as their
    ///      getters return them) and what the named views derive from them (a member read from another place changes
    ///      a derived value even when the raw bytes do not); with `vault`, each token's vault state too (vault-mode
    ///      review: Pad3VaultStore's namespace is not in the compiler's layout, so only real data shows a moved
    ///      member). `vault` is whether the CURRENT implementation serves the vault mode: the first upgrade to it has
    ///      no vault state to compare (the views don't exist before it), every later one compares it.
    ///      `newFairEntry` (empty before the upgrade, `before.newFairEntry` after it): the sampled 打新 sales whose entry
    ///      views are left out of both snapshots — the first upgrade to the 打新 entry changes them on purpose (status
    ///      3 → 1, the quote); their records and every other view are still compared, and `_checkNewFairEntry` checks
    ///      them after. Once the current implementation trades them (status 1), nothing is left out.
    function _snapshot(GangLaunchpad3 p, Stack memory s, bool vault, bool[] memory newFairEntry)
        internal
        view
        returns (Snapshot memory snap)
    {
        snap.vault = vault;
        address[] memory callers = _callers();
        bool[] memory listed = new bool[](callers.length);
        for (uint256 i; i < callers.length; i++) {
            listed[i] = p.isCaller(callers[i]);
        }
        snap.settings = keccak256(
            abi.encode(
                _promoteProbes(p, _promoteProbeList()),
                abi.encode(
                    p.owner(),
                    p.pendingOwner(),
                    p.pairFactory(),
                    p.v3Factory(),
                    p.twapWindow(),
                    address(p.migrator()),
                    address(p.agentIdRegistry()),
                    p.agentGateEnabled(),
                    p.walletCapEnabled()
                ),
                p.tokenCount(),
                p.routers(s.router),
                p.bridgePoolOf(M.USDT),
                listed
            )
        );
        uint256 n = p.tokenCount();
        uint256 k = n < SAMPLE ? n : SAMPLE;
        snap.tokens = new bytes32[](k);
        bool given = newFairEntry.length == k;
        snap.newFairEntry = given ? newFairEntry : new bool[](k);
        for (uint256 i; i < k; i++) {
            address t = p.allTokens(n - 1 - i);
            if (!given) snap.newFairEntry[i] = _fairNotYetRouted(p, t);
            snap.tokens[i] = keccak256(
                abi.encode(
                    _raw(p, t),
                    _derived(p, t, snap.newFairEntry[i]),
                    vault ? _vaultState(p, t) : bytes(""),
                    p.kindOf(t) == 3 ? _flyState(p, t) : bytes(""),
                    _promoteState(p, t)
                )
            );
        }
    }

    /// @dev A gated 打新 sale still minting that `p` reports as not traded through its entry (status 3).
    function _fairNotYetRouted(GangLaunchpad3 p, address t) internal view returns (bool) {
        if (p.kindOf(t) != 2) return false;
        (,,,,,, bool launched,,, address gate,,,,) = p.sales(t);
        if (launched || gate == address(0)) return false;
        (uint8 status,,,,) = p.getTokenInfo(t);
        return status == 3;
    }

    /// @dev After the upgrade, each sale `_fairNotYetRouted` found is traded through the entry (status 1).
    function _checkNewFairEntry(GangLaunchpad3 p, bool[] memory newFairEntry) internal view {
        uint256 n = p.tokenCount();
        for (uint256 i; i < newFairEntry.length; i++) {
            if (!newFairEntry[i]) continue;
            address t = p.allTokens(n - 1 - i);
            (uint8 status,,, uint256 feeBps, uint256 left) = p.getTokenInfo(t);
            (,,,,, uint16 sold,, uint16 mintFeeBps,,, uint128 price,,,) = p.sales(t);
            if (status != 1 || feeBps != mintFeeBps || left != (10_000 - uint256(sold)) * price) {
                revert WiringCheck("upgrade: a gated fair-mint sale not traded through the entry");
            }
        }
    }

    /// @dev Whether the pad behind `proxy` answers the vault mode's views now.
    function _servesVaultMode(address proxy) internal view returns (bool) {
        (bool ok, bytes memory ret) = proxy.staticcall(abi.encodeCall(Pad3Module.vaultOf, (address(0))));
        return ok && ret.length == 32;
    }

    /// @dev `t`'s vault and its listing, grant and history, and what the token's creator locked into it.
    function _vaultState(GangLaunchpad3 p, address t) internal view returns (bytes memory) {
        Pad3Module m = Pad3Module(payable(address(p)));
        address v = m.vaultOf(t);
        (address creator,,,,,,,,,,,) = p.curves(t);
        return abi.encode(v, m.isVault(v), m.everVault(v), m.vaultCreator(v), m.lockedOf(t, creator));
    }

    /// @dev A 铸币飞轮 token's state in its namespace (audit C L-4; `sales` is in `_raw`): the creator's account, the
    ///      dev cut owed, the post-launch rules. None exist before the first upgrade with the 铸币飞轮 mode.
    function _flyState(GangLaunchpad3 p, address t) internal view returns (bytes memory) {
        Pad3FlyModule f = Pad3FlyModule(address(p));
        address creator = f.sales(t).creator;
        (uint16 guardBps, uint32 twapWindow) = f.postRulesOf(t);
        return abi.encode(f.accounts(t, creator), f.owedDev(t), guardBps, twapWindow);
    }

    /// @dev A token with a promoter share: its terms. Empty for any other token, and before the first upgrade with the
    ///      promoter share, so tokens without one hash the same across that upgrade; terms that move read as 0, and that
    ///      shows. Bindings and earnings can't be listed from the pad: `_promoteProbes`.
    function _promoteState(GangLaunchpad3 p, address t) internal view returns (bytes memory) {
        (bool ok, bytes memory ret) = address(p).staticcall(abi.encodeCall(Pad3Module.promoteOf, (t)));
        if (!ok || ret.length != 64) return "";
        (uint16 share,) = abi.decode(ret, (uint16, uint32));
        return share == 0 ? bytes("") : ret;
    }

    /// @dev PAD3_PROMOTE_PROBES: token,wallet,token,wallet,… (from `PromoterBound` logs: older tokens beyond the sample
    ///      too).
    function _promoteProbeList() internal view virtual returns (address[] memory) {
        return vm.envOr("PAD3_PROMOTE_PROBES", ",", new address[](0));
    }

    /// @dev Each probe's terms, the wallet's binding and what its promoter earned.
    function _promoteProbes(GangLaunchpad3 p, address[] memory probes) internal view returns (bytes memory out) {
        if (probes.length % 2 != 0) revert WiringCheck("PAD3_PROMOTE_PROBES: pairs of token,wallet");
        if (probes.length != 0) {
            (bool ok, bytes memory ret) = address(p).staticcall(abi.encodeCall(Pad3Module.promoteOf, (probes[0])));
            if (!ok || ret.length != 64) revert WiringCheck("PAD3_PROMOTE_PROBES: this pad has no promoter share yet");
        }
        Pad3Module m = Pad3Module(payable(address(p)));
        for (uint256 i; i < probes.length; i += 2) {
            (address token, address wallet) = (probes[i], probes[i + 1]);
            (address promoter, uint40 boundAt, bool traded) = m.bindingOf(token, wallet);
            out = abi.encode(out, _promoteState(p, token), promoter, boundAt, traded, m.promoterFeeOf(token, promoter));
        }
    }

    /// @dev Tokens with a promoter share in the sample and no probes: their bindings and earnings go unchecked. Said out
    ///      loud, not refused (the first upgrades after the feature ships may have none worth probing).
    function _warnNoPromoteProbes(GangLaunchpad3 p) internal view {
        address[] memory probes = _promoteProbeList();
        if (probes.length != 0) {
            for (uint256 i; i < probes.length; i += 2) {
                (address promoter,,) = Pad3Module(payable(address(p))).bindingOf(probes[i], probes[i + 1]);
                if (promoter == address(0)) {
                    console.log(
                        "WARNING: PAD3_PROMOTE_PROBES names a wallet bound to nobody: it checks nothing", probes[i + 1]
                    );
                }
            }
            return;
        }
        uint256 n = p.tokenCount();
        uint256 k = n < SAMPLE ? n : SAMPLE;
        for (uint256 i; i < k; i++) {
            if (_promoteState(p, p.allTokens(n - 1 - i)).length != 0) {
                console.log("WARNING: tokens with a promoter share and no PAD3_PROMOTE_PROBES: bindings and earnings");
                console.log("are not compared. Set it from the PromoterBound logs before the Safe signs.");
                return;
            }
        }
    }

    function _raw(GangLaunchpad3 p, address t) internal view returns (bytes memory) {
        (, bytes memory cv) = address(p).staticcall(abi.encodeWithSignature("curves(address)", t));
        (, bytes memory sa) = address(p).staticcall(abi.encodeWithSignature("sales(address)", t));
        return abi.encode(t, cv, sa, p.kindOf(t), p.tokenVersionOf(t), p.creatorFeeOf(t), p.gradTargetOf(t));
    }

    /// @dev Each through a raw staticcall: a view that reverts for this kind of token records its revert data.
    /// @dev `skipEntry`: leave out the entry views (index 0 getTokenInfo, 5 tryBuy) — see `_snapshot`.
    function _derived(GangLaunchpad3 p, address t, bool skipEntry) internal view returns (bytes memory d) {
        bytes[] memory calls = _derivedCalls(t);
        for (uint256 i; i < calls.length; i++) {
            if (skipEntry && (i == 0 || i == 5)) continue;
            (bool ok, bytes memory ret) = address(p).staticcall(calls[i]);
            d = bytes.concat(d, abi.encode(ok, ret));
        }
    }

    /// @dev The named views `_derived` reads for `t` (index 3: graduationRemaining).
    function _derivedCalls(address t) internal pure returns (bytes[] memory calls) {
        calls = new bytes[](11);
        bytes[11] memory c = [
            abi.encodeCall(GangLaunchpad3.getTokenInfo, (t)),
            abi.encodeCall(GangLaunchpad3.status, (t)),
            abi.encodeCall(Pad3Module.gradAmtOf, (t)),
            abi.encodeCall(Pad3Module.graduationRemaining, (t)),
            abi.encodeCall(Pad3Module.taxConfigOf, (t)),
            abi.encodeCall(GangLaunchpad3.tryBuy, (t, address(0), 0, 0.01 ether)),
            abi.encodeCall(GangLaunchpad3.trySell, (t, 1 ether)),
            abi.encodeCall(Pad3Module.exitFeeBpsOf, (t)),
            abi.encodeCall(GangLaunchpad3.holdBpsOf, (t)),
            abi.encodeCall(Pad3Module.previewMint, (t, address(0), 1)),
            abi.encodeCall(GangLaunchpad3.walletRoom, (t, address(0)))
        ];
        for (uint256 i; i < 11; i++) {
            calls[i] = c[i];
        }
    }
}
