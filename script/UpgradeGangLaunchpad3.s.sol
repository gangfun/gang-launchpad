// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {GangMainnetRefs as M} from "../config/GangDeployRefs.sol";
import {GangLaunchpad3} from "../src/gang/GangLaunchpad3.sol";
import {GangRouterDeployLib as R} from "./GangRouterDeployLib.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pad3GradStore} from "../src/gang/Pad3GradStore.sol";
import {Pad3Module} from "../src/gang/Pad3Module.sol";
import {IGangGradReward, IGangGradRewardBase} from "../src/gang/interfaces/IGangGradReward.sol";
import {FlywheelTaxHandler} from "../src/flywheel/FlywheelTaxHandler.sol";
import {MintTokenDeployer} from "../src/flywheel/MintTokenDeployer.sol";
import {SharedDividendVault} from "../src/common/SharedDividendVault.sol";
import {SharedPlatformFeeBucket} from "../src/common/SharedPlatformFeeBucket.sol";
import {Pad3FlyVaultCore} from "../src/gang/Pad3FlyVaultCore.sol";
import {Pad3FlyModule} from "../src/gang/Pad3FlyModule.sol";
import {Pad3Impl} from "./Pad3Impl.sol";
import {DeployGangLaunchpad3} from "./DeployGangLaunchpad3.s.sol";
import {Pad3VanityDeployer} from "../src/gang/Pad3VanityDeployer.sol";
import {GangBaseVault} from "../src/gang/GangBaseVault.sol";
import {IGangSwapPad} from "../src/gang/interfaces/IGangSwapPad.sol";
import {Pad3GangSwapStore} from "../src/gang/Pad3GangSwapStore.sol";
import {IGangAgentWindow} from "../src/gang/interfaces/IGangAgentWindow.sol";
import {GangPadRegistry} from "../src/gang/GangPadRegistry.sol";
import {GangPadRegistryDeployLib as D} from "./GangPadRegistryDeployLib.sol";

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
///      Optional PAD3_ABCD_DEPLOYER (DeployPad3Vanity): validate its code and legacy references, then enable it after
///      the upgrade in the same Safe batch. The pad owner must also own that batch. Do not set it again once enabled.
///      Optional PAD3_BASE_VAULT_IMPL (DeployGangBaseVault; docs/SPEC-BASE-VAULT-V2-2026-11-12.md §8): its code must be
///      this build's GangBaseVault for this proxy, byte for byte; `setBaseVaultImpl` runs after the upgrade (and after
///      any abcd activation) in the same batch, after the settings comparison. The pad owner must own that batch too.
///      PAD3_BASE_PROBES (optional, token,token,…: from `BaseCreated` logs; the pad can't list them): each one's base
///      vault and base amount are compared across the upgrade.
///      GangSwap (docs/SPEC-GANGSWAP-2026-11-22.md): the upgrade neither opens nor closes createGangSwap
///      (`setGangSwapMigrator` is a batch of its own, spec §13). Its migrator and EVERY GangSwap token (found by walking
///      the pad's tokens, not the sample) are compared: own migrator, record, named views, agent window, wallet cap.
///      The new implementation must serve GangSwap.
///      Graduation rewards (docs/SPEC-GRAD-REWARD-2026-11-17.md): the deps and EVERY token with a reward (found by its raw
///      state word, so a moved namespace shows) are compared: stored words, `gradReward`, `gradEntries`, each listed
///      buyer's `gradClaimable`. After the upgrade createGangSwapWithGradReward must refuse an empty config and, with a
///      valid one, a wrong GangSwap version, directly and through createWithAgentWindow and (abcd on) createWithSalt: that
///      shows the entry is dispatched and listed there, not that a create works end to end (the tests' part).
///      Optional PAD3_GRAD_REWARD=true (docs/SPEC-GRAD-REWARD-2026-11-17.md §13): `setGradReward(true, admin, factory)`
///      runs last in the same batch, once (refused when already set), with PAD3_GRAD_HANDLER_ADMIN (required: this
///      build's GangHandlerAdmin owning the pad's handler, owned by OWNER) and PAD3_GRAD_COUNTDOWN_FACTORY (must be 0:
///      the carry opens with script/SetGradRewardCountdown.s.sol, run without --libraries). The pad owner must own it.
///      Optional PAD3_REGISTRY_UPGRADE=true (docs/SPEC-AGENT-WINDOW-2026-11-20.md §5.6, audit C M-1): GangPadRegistry
///      (GANG_PAD_REGISTRY) moves to this build's code in the same batch, last: PAD_REGISTRY_IMPL (or deployed here)
///      must be this build's GangPadRegistry, locked; its ProxyAdmin must be owned by the pad's upgrader. The
///      simulation upgrades it after the pad, then runs GangPadRegistryDeployLib.check (impl code, locked, ProxyAdmin,
///      owner, no pending owner, the same pads in order) and compares, for the newest SAMPLE tokens of each registered
///      pad, `padOf` and the fresh-wallet quotes `previewBuy` / `previewSell` with what they were before both upgrades.
contract UpgradeGangLaunchpad3 is DeployGangLaunchpad3 {
    uint256 internal constant SAMPLE = 25;
    /// @dev A fixed address with no code and no Agent ID, for `_registryState`'s gated quotes (keccak256 of a label).
    address internal constant REGISTRY_PROBE_WALLET =
        address(uint160(uint256(keccak256("gang.registry.probe.wallet"))));

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
    /// @dev Optional one-way activation, after the upgrade in the same batch. Existing dependencies stay fixed.
    address internal _abcd;
    /// @dev Optional base vault implementation set after the upgrade in the same batch.
    address internal _baseImpl;
    /// @dev Optional 冲毕业奖励 opening after the upgrade in the same batch (PAD3_GRAD_REWARD).
    bool internal _grad;
    address internal _gradAdmin;
    address internal _gradFactory;
    /// @dev Optional GangPadRegistry upgrade, last in the same batch (PAD3_REGISTRY_UPGRADE): proxy, its new
    ///      implementation and its ProxyAdmin.
    address internal _reg;
    address internal _regImpl;
    address internal _regAdmin;

    struct Snapshot {
        bytes32 settings;
        bytes32[] tokens;
        /// @dev whether the vault state was read (the current implementation serves the vault mode)
        bool vault;
        /// @dev per sampled token: a gated 打新 sale the CURRENT implementation doesn't trade through the entry (status
        ///      3); its entry views (getTokenInfo, tryBuy) change on purpose with the upgrade to the 打新 entry
        bool[] newFairEntry;
        /// @dev GangSwap: the pad's migrator and every GangSwap token (`_gangSwapState`)
        bytes32 gangSwap;
        /// @dev graduation rewards: the deps and every token with one (`_gradState`)
        bytes32 grad;
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
        _abcd = _envAddr("PAD3_ABCD_DEPLOYER", address(0));
        if (_abcd != address(0)) _checkVanity(s.pad, upgrader);
        _baseImpl = _envAddr("PAD3_BASE_VAULT_IMPL", address(0));
        if (_baseImpl != address(0)) _checkBaseImpl(s.pad, upgrader);
        _grad = vm.envOr("PAD3_GRAD_REWARD", false);
        if (_grad) _checkGrad(s, c, upgrader);
        bool deployed = _resolveFly(GangLaunchpad3(payable(current)), impl, s, c, pk, upgrader);
        if (vm.envOr("PAD3_REGISTRY_UPGRADE", false) && _resolveRegistry(x.padRegistry, upgrader, pk)) deployed = true;
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
            _enableVanity(proxy);
            _setBaseImpl(proxy);
            _setGrad(proxy);
            _upgradeRegistry();
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
        if (_abcd != address(0)) console.log("(enable abcd addresses after the upgrade in the same batch)");
        if (_baseImpl != address(0)) console.log("(set the base vault implementation last, in the same batch)");
        if (_grad) console.log("(open the graduation reward last, in the same batch)");
        if (_regImpl != address(0)) console.log("(then move GangPadRegistry to this build, last, in the same batch)");
        _warnNotUpgradeAlone(prepTo.length);
        _emitBatch(_batchJson(c.mainnet, upgrader, prepTo, prepCall, admin, call, proxy));
    }

    /// @dev The batch `run` prints. Virtual: a test keeps exactly what was printed.
    function _emitBatch(string memory json) internal virtual {
        console.log(json);
    }

    /// @dev Anything in the batch besides the one upgradeAndCall, said out loud: the optional steps are one-time, and an
    ///      env variable left over from an earlier rollout must not slip into a batch by itself.
    function _warnNotUpgradeAlone(uint256 preps) internal view {
        uint256 extra = preps + (_abcd != address(0) ? 1 : 0) + (_baseImpl != address(0) ? 1 : 0) + (_grad ? 1 : 0)
            + (_regImpl != address(0) ? 1 : 0);
        if (extra == 0) return;
        console.log("WARNING: the batch is NOT the upgrade alone; transactions besides upgradeAndCall:", extra);
        console.log("Unset PAD3_ABCD_DEPLOYER, PAD3_BASE_VAULT_IMPL, PAD3_GRAD_REWARD and PAD3_REGISTRY_UPGRADE unless");
        console.log("this rollout means them (docs/SPEC-GANGSWAP-GRAD-REWARD-2026-11-25.md sec. 7).");
    }

    /// @dev The upgrade in the simulation, as the owner sends it (the 铸币飞轮 listings first); checked; rolled back.
    function _simulate(Stack memory s, Cfg memory c, Ctx memory x, Up memory u) internal {
        GangLaunchpad3 p = GangLaunchpad3(payable(s.pad));
        Snapshot memory before = _snapshot(p, s, _servesVaultMode(s.pad), new bool[](0));
        _warnNoPromoteProbes(p);
        _warnNoBaseProbes(p);
        (bool windowBefore, bytes memory windowState) = _agentWindowState(p);
        (address[] memory regPads, bytes memory regQuotes) = _registryState();
        uint256 snap = vm.snapshotState();
        _sendPrep(u.prepTo, u.prepCall, u.upgrader, true);
        vm.prank(u.upgrader);
        ProxyAdmin(u.admin).upgradeAndCall(ITransparentUpgradeableProxy(s.pad), u.impl, u.init);
        if (R.implementationOf(s.pad) != u.impl) revert WiringCheck("upgrade: implementation slot");
        (uint64 v1, bool initializing) = R.initState(s.pad);
        if (v1 != u.wantVersion || initializing) revert WiringCheck("upgrade: initialized version");
        _compare(before, _snapshot(p, s, before.vault, before.newFairEntry));
        _checkNewFairEntry(p, before.newFairEntry);
        _checkAgentWindow(p, windowBefore, windowState);
        _checkGangSwap(p);
        _checkGangSwapGradCreate(p);
        // final audit (deploy) L-5: the proxy, implementation, libraries and wiring of 3.0 itself, not the deploy-time
        // pins (TWAP, keeper, gate…) the Safe may have changed since: drift is what the snapshot above compares
        _checkPad3(s, c, x);
        _checkLibs(s, c);
        _checkOriginTrader(s);
        if (_abcd != address(0)) vm.prank(u.upgrader);
        _enableVanity(s.pad);
        if (_baseImpl != address(0)) vm.prank(u.upgrader);
        _setBaseImpl(s.pad);
        if (_grad) vm.prank(u.upgrader);
        _setGrad(s.pad);
        if (_regImpl != address(0)) {
            vm.prank(u.upgrader);
            _upgradeRegistry();
            D.check(D.Registry(_reg, _regImpl, _regAdmin), GangPadRegistry(_reg).owner(), regPads);
            (, bytes memory regAfter) = _registryState();
            if (keccak256(regAfter) != keccak256(regQuotes)) revert WiringCheck("registry: a quote or padOf changed");
        }
        vm.revertToState(snap);
        console.log("simulated: upgrade + read-back ok; tokens compared", before.tokens.length);
    }

    function _compare(Snapshot memory before, Snapshot memory afterUp) internal pure {
        if (afterUp.settings != before.settings) revert WiringCheck("upgrade: settings changed");
        if (afterUp.gangSwap != before.gangSwap) revert WiringCheck("upgrade: GangSwap state changed");
        if (afterUp.grad != before.grad) revert WiringCheck("upgrade: graduation reward state changed");
        for (uint256 i; i < before.tokens.length; i++) {
            if (afterUp.tokens[i] != before.tokens[i]) revert WiringCheck("upgrade: a token's record changed");
        }
    }

    /// @dev Whether `p` serves the agent window (SPEC-AGENT-WINDOW-2026-11-20; its views answer from Pad3GradModule)
    ///      and, if so, each of the newest SAMPLE tokens' window and wallet cap. Raw staticcalls: before the first
    ///      upgrade to it the selectors don't exist (the pad reverts), which reads as "not served".
    function _agentWindowState(GangLaunchpad3 p) internal view returns (bool served, bytes memory st) {
        (bool ok, bytes memory ret) =
            address(p).staticcall(abi.encodeCall(IGangAgentWindow.MAX_AGENT_WINDOW_MINUTES, ()));
        if (!ok || ret.length != 32) return (false, "");
        served = true;
        IGangAgentWindow w = IGangAgentWindow(address(p));
        uint256 n = p.tokenCount();
        uint256 k = n < SAMPLE ? n : SAMPLE;
        for (uint256 i; i < k; i++) {
            address t = p.allTokens(n - 1 - i);
            st = abi.encode(st, t, w.agentOpenAt(t), _isCurve(p, t) && w.walletCapOn(t));
        }
    }

    /// @dev After the upgrade the pad serves the agent window with its bounds. On the first upgrade to it, each of the
    ///      newest SAMPLE tokens (all created before it) is still agent only (`openAt` 0) with its wallet cap as the
    ///      pad's switch says; on a later upgrade, their windows and caps are the ones read before it (`before`), so a
    ///      token that has a window doesn't fail the check. That the pad links this build's CurveLogic3 is
    ///      `_checkLibs` / `_checkImplCode`'s, not this check's.
    function _checkAgentWindow(GangLaunchpad3 p, bool servedBefore, bytes memory before) internal view {
        IGangAgentWindow w = IGangAgentWindow(address(p));
        if (w.MIN_AGENT_WINDOW_MINUTES() != 1 || w.MAX_AGENT_WINDOW_MINUTES() != 1440) {
            revert WiringCheck("upgrade: agent window bounds");
        }
        if (servedBefore) {
            (, bytes memory afterUp) = _agentWindowState(p);
            if (keccak256(afterUp) != keccak256(before)) revert WiringCheck("upgrade: a token's agent window changed");
            return;
        }
        uint256 n = p.tokenCount();
        uint256 k = n < SAMPLE ? n : SAMPLE;
        for (uint256 i; i < k; i++) {
            address t = p.allTokens(n - 1 - i);
            if (w.agentOpenAt(t) != 0 || w.agentWindowOpen(t)) revert WiringCheck("upgrade: an old token opened");
            if (_isCurve(p, t) && w.walletCapOn(t) != p.walletCapEnabled()) {
                revert WiringCheck("upgrade: an old token's wallet cap changed");
            }
        }
    }

    /// @dev PAD3_REGISTRY_UPGRADE: the registry's new implementation (PAD_REGISTRY_IMPL, or deployed now: returns true),
    ///      checked to be this build's GangPadRegistry and locked, and the registry's ProxyAdmin owned by `upgrader`
    ///      (one Safe signs the whole batch). Refused when the registry already runs this build.
    function _resolveRegistry(address reg, address upgrader, uint256 pk) internal returns (bool deployed) {
        if (reg == address(0)) revert WiringCheck("GANG_PAD_REGISTRY");
        D.Registry memory r = D.load(reg);
        if (R.sameCode(r.impl, type(GangPadRegistry).runtimeCode)) {
            revert WiringCheck("registry already runs this build: omit PAD3_REGISTRY_UPGRADE");
        }
        if (ProxyAdmin(r.proxyAdmin).owner() != upgrader) revert WiringCheck("registry ProxyAdmin owner");
        address impl = _envAddr("PAD_REGISTRY_IMPL", address(0));
        if (impl == address(0)) {
            vm.startBroadcast(pk);
            impl = address(new GangPadRegistry());
            vm.stopBroadcast();
            deployed = true;
            console.log("new GangPadRegistry implementation (deployed now; pass it as PAD_REGISTRY_IMPL)", impl);
        } else {
            console.log("new GangPadRegistry implementation (PAD_REGISTRY_IMPL)", impl);
        }
        if (!R.sameCode(impl, type(GangPadRegistry).runtimeCode)) revert WiringCheck("PAD_REGISTRY_IMPL code");
        (uint64 v,) = R.initState(impl);
        if (v != type(uint64).max || GangPadRegistry(impl).owner() != address(0)) {
            revert WiringCheck("PAD_REGISTRY_IMPL not locked");
        }
        (_reg, _regImpl, _regAdmin) = (reg, impl, r.proxyAdmin);
    }

    /// @dev Sent by the caller (pranked as the upgrader in the simulation, broadcast on testnet); nothing when not asked.
    function _upgradeRegistry() internal {
        if (_regImpl == address(0)) return;
        ProxyAdmin(_regAdmin).upgradeAndCall(ITransparentUpgradeableProxy(_reg), _regImpl, "");
    }

    /// @dev The registry's pads and, for the newest SAMPLE tokens of each, `padOf` and the quotes of a 0.01 quote-unit
    ///      buy and a 1-token sell, for a fresh wallet (address 0: no gate check) and for REGISTRY_PROBE_WALLET, a fixed
    ///      address without an Agent ID (it goes through the new gate path, `canTradeCurve` / `isAgent`). Nothing
    ///      opens or closes between the two reads (same block, only the upgrades in between), so its quotes must stay
    ///      as they were: 0 for a token not open, the open curve's quote for one that is. Empty when no registry
    ///      upgrade is asked (audit re-review L-1).
    function _registryState() internal view returns (address[] memory pads, bytes memory st) {
        if (_regImpl == address(0)) return (pads, st);
        GangPadRegistry g = GangPadRegistry(_reg);
        pads = g.pads();
        for (uint256 i; i < pads.length; i++) {
            (bool ok, bytes memory ret) = pads[i].staticcall(abi.encodeWithSignature("tokenCount()"));
            if (!ok || ret.length != 32) continue;
            uint256 n = abi.decode(ret, (uint256));
            uint256 k = n < SAMPLE ? n : SAMPLE;
            for (uint256 j; j < k; j++) {
                (ok, ret) = pads[i].staticcall(abi.encodeWithSignature("allTokens(uint256)", n - 1 - j));
                if (!ok || ret.length != 32) continue;
                address t = abi.decode(ret, (address));
                (uint256 out,,,) = g.previewBuy(t, address(0), 0.01 ether);
                (uint256 back,) = g.previewSell(t, address(0), 1 ether);
                (uint256 outP,,,) = g.previewBuy(t, REGISTRY_PROBE_WALLET, 0.01 ether);
                (uint256 backP,) = g.previewSell(t, REGISTRY_PROBE_WALLET, 1 ether);
                st = abi.encode(st, t, g.padOf(t), out, back, outP, backP);
            }
        }
    }

    function _checkVanity(address proxy, address upgrader) internal {
        if (Ownable(proxy).owner() != upgrader) revert WiringCheck("abcd: pad owner must own the upgrade batch");
        if (_vanityState(GangLaunchpad3(payable(proxy))) != address(0)) {
            revert WiringCheck("abcd already enabled: omit PAD3_ABCD_DEPLOYER");
        }
        GangLaunchpad3 p = GangLaunchpad3(payable(proxy));
        (, Pad3Impl.FlyDeps memory f) = Pad3Impl.flyDepsOf(p);
        // Simulation only, before any broadcast: every immutable occurrence must match these trusted dependencies.
        // Getter values alone cannot establish what the other runtime references actually use.
        address ref = address(new Pad3VanityDeployer(proxy, p.tokenDeployer(), f.flyTokenDeployer));
        if (!R.sameCode(_abcd, ref.code)) revert WiringCheck("abcd deployer code");
    }

    function _enableVanity(address proxy) internal {
        if (_abcd == address(0)) return;
        Pad3Module p = Pad3Module(payable(proxy));
        p.enableVanity(_abcd);
        if (p.vanityDeployer() != _abcd) revert WiringCheck("abcd activation");
    }

    /// @dev PAD3_BASE_VAULT_IMPL: the pad owner sends the batch, it is not set yet, and its code is this build's
    ///      GangBaseVault for `proxy` (the pad is an immutable, so a reference deployed here has the same bytes).
    function _checkBaseImpl(address proxy, address upgrader) internal {
        if (Ownable(proxy).owner() != upgrader) revert WiringCheck("base vault: pad owner must own the upgrade batch");
        if (_baseState(GangLaunchpad3(payable(proxy))) == _baseImpl) {
            revert WiringCheck("base vault implementation already set: omit PAD3_BASE_VAULT_IMPL");
        }
        address ref = address(new GangBaseVault(proxy));
        if (!R.sameCode(_baseImpl, ref.code)) revert WiringCheck("base vault implementation code");
    }

    function _setBaseImpl(address proxy) internal {
        if (_baseImpl == address(0)) return;
        Pad3Module p = Pad3Module(payable(proxy));
        p.setBaseVaultImpl(_baseImpl);
        if (p.baseVaultImpl() != _baseImpl) revert WiringCheck("base vault implementation");
    }

    /// @dev PAD3_GRAD_REWARD: a one-time opening, never over settings the Safe made since (a factory set, an emergency
    ///      close: read from storage, as the current implementation may not serve the view); the pad owner sends the
    ///      batch; the admin is this build's GangHandlerAdmin owning the pad's handler, owned by OWNER, nothing pending;
    ///      no countdown factory yet (this build has none to compare code with: the carry opens in a later batch).
    function _checkGrad(Stack memory s, Cfg memory c, address upgrader) internal {
        if (Ownable(s.pad).owner() != upgrader) {
            revert WiringCheck("grad reward: pad owner must own the upgrade batch");
        }
        if (vm.load(s.pad, Pad3GradStore.SLOT) != 0 || vm.load(s.pad, bytes32(uint256(Pad3GradStore.SLOT) + 1)) != 0) {
            revert WiringCheck("grad reward already set: omit PAD3_GRAD_REWARD");
        }
        _gradAdmin = _envAddr("PAD3_GRAD_HANDLER_ADMIN", address(0));
        _gradFactory = _envAddr("PAD3_GRAD_COUNTDOWN_FACTORY", address(0));
        if (!_isOwnersAdmin(_gradAdmin, s.handler, c.owner)) revert WiringCheck("PAD3_GRAD_HANDLER_ADMIN");
        if (Ownable(s.handler).owner() != _gradAdmin || Ownable2Step(s.handler).pendingOwner() != address(0)) {
            revert WiringCheck("PAD3_GRAD_HANDLER_ADMIN: not the handler's owner (or a handover pending)");
        }
        // the factory's exact code check needs a build without --libraries, which this script can't do: the carry opens
        // with script/SetGradRewardCountdown.s.sol once the reward is open
        if (_gradFactory != address(0)) {
            revert WiringCheck("PAD3_GRAD_COUNTDOWN_FACTORY: leave 0, open the carry with SetGradRewardCountdown");
        }
    }

    function _setGrad(address proxy) internal {
        if (!_grad) return;
        Pad3Module(payable(proxy)).setGradReward(true, _gradAdmin, _gradFactory);
        (bool open, address a, address f) = IGangGradReward(proxy).gradRewardDeps();
        if (!open || a != _gradAdmin || f != _gradFactory) revert WiringCheck("grad reward opening");
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
        bytes memory call,
        address proxy
    ) internal view returns (string memory j) {
        j = _head(mainnet, upgrader, "gang: upgrade GangLaunchpad 3.0");
        for (uint256 i; i < to.length; i++) {
            j = string.concat(j, _tx(to[i], data[i], i != 0));
        }
        j = string.concat(j, _tx(admin, call, to.length != 0));
        if (_abcd != address(0)) {
            j = string.concat(j, _tx(proxy, abi.encodeCall(Pad3Module.enableVanity, (_abcd)), true));
        }
        if (_baseImpl != address(0)) {
            j = string.concat(j, _tx(proxy, abi.encodeCall(Pad3Module.setBaseVaultImpl, (_baseImpl)), true));
        }
        if (_grad) {
            j = string.concat(
                j, _tx(proxy, abi.encodeCall(Pad3Module.setGradReward, (true, _gradAdmin, _gradFactory)), true)
            );
        }
        if (_regImpl != address(0)) {
            j = string.concat(
                j,
                _tx(
                    _regAdmin,
                    abi.encodeCall(
                        ProxyAdmin.upgradeAndCall, (ITransparentUpgradeableProxy(_reg), _regImpl, bytes(""))
                    ),
                    true
                )
            );
        }
        j = string.concat(j, "]}");
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
        snap.gangSwap = keccak256(_gangSwapState(p));
        snap.grad = keccak256(_gradState(p));
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
                listed,
                _vanityState(p),
                _baseState(p),
                _baseProbes(p, _baseProbeList())
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
                    _promoteState(p, t),
                    _baseState(p, t)
                )
            );
        }
    }

    function _vanityState(GangLaunchpad3 p) internal view returns (address) {
        try Pad3Module(payable(address(p))).vanityDeployer() returns (address d) {
            return d;
        } catch {
            return address(0);
        }
    }

    /// @dev The base vault implementation (0 before the first upgrade with the opening base).
    function _baseState(GangLaunchpad3 p) internal view returns (address) {
        try Pad3Module(payable(address(p))).baseVaultImpl() returns (address a) {
            return a;
        } catch {
            return address(0);
        }
    }

    /// @dev A token with an opening base: its vault and base amount. Empty for any other token and before the first
    ///      upgrade with the opening base, so tokens without one hash the same across that upgrade.
    function _baseState(GangLaunchpad3 p, address t) internal view returns (bytes memory) {
        (bool ok, bytes memory ret) = address(p).staticcall(abi.encodeCall(Pad3Module.baseVaultOf, (t)));
        if (!ok || ret.length != 32 || abi.decode(ret, (address)) == address(0)) return "";
        return abi.encode(ret, Pad3Module(payable(address(p))).baseOf(t));
    }

    /// @dev PAD3_BASE_PROBES: token,token,… (from `BaseCreated` logs: tokens beyond the sample).
    function _baseProbeList() internal view virtual returns (address[] memory) {
        return vm.envOr("PAD3_BASE_PROBES", ",", new address[](0));
    }

    /// @dev Each probe's base vault and amount; a probe without a base is refused (it would check nothing).
    function _baseProbes(GangLaunchpad3 p, address[] memory probes) internal view returns (bytes memory out) {
        for (uint256 i; i < probes.length; i++) {
            bytes memory st = _baseState(p, probes[i]);
            if (st.length == 0) revert WiringCheck("PAD3_BASE_PROBES: a token without an opening base");
            out = abi.encode(out, probes[i], st);
        }
    }

    /// @dev The opening base is open and PAD3_BASE_PROBES is empty: tokens with a base outside the newest 25 go
    ///      unchecked. Said out loud (as `_warnNoPromoteProbes`), not refused: the pad can't list them.
    function _warnNoBaseProbes(GangLaunchpad3 p) internal view {
        if (_baseState(p) == address(0) || _baseProbeList().length != 0) return;
        console.log("WARNING: the opening base is open and PAD3_BASE_PROBES is empty: tokens with a base outside the");
        console.log("newest 25 are not compared. Set it from the BaseCreated logs before the Safe signs.");
    }

    /// @dev A token that trades on a curve with a wallet cap: kind 1, or a GangSwap curve token (kind 4).
    function _isCurve(GangLaunchpad3 p, address t) internal view returns (bool) {
        uint8 kind = p.kindOf(t);
        return kind == 1 || kind == Pad3GangSwapStore.KIND;
    }

    /// @dev The GangSwap migrator new tokens get and whether `p` serves GangSwap at all (not before the first upgrade
    ///      with it: reads as closed).
    function _gangSwapOpen(GangLaunchpad3 p) internal view returns (bool served, address migrator) {
        (bool ok, bytes memory ret) = address(p).staticcall(abi.encodeCall(IGangSwapPad.gangSwapMigrator, ()));
        if (ok && ret.length == 32) return (true, abi.decode(ret, (address)));
    }

    /// @dev The migrator `t` graduates through (0: not a GangSwap token).
    function _gangSwapOf(GangLaunchpad3 p, address t) internal view returns (address) {
        (bool ok, bytes memory ret) = address(p).staticcall(abi.encodeCall(IGangSwapPad.gangSwapMigratorOf, (t)));
        return ok && ret.length == 32 ? abi.decode(ret, (address)) : address(0);
    }

    /// @dev The pad's GangSwap migrator and, for EVERY token that is kind 4 or has a GangSwap migrator (a walk of
    ///      `allTokens`; a token that stops being either drops out, and that shows), its migrator, record, named views,
    ///      agent window and wallet cap. No token before the first upgrade with GangSwap, so that upgrade compares equal.
    ///      Storage and views: which migrator graduation itself calls is `_checkImplCode`'s.
    function _gangSwapState(GangLaunchpad3 p) internal view returns (bytes memory st) {
        (bool served, address migrator) = _gangSwapOpen(p);
        if (!served) return abi.encode(migrator, bytes32(0));
        uint256 n = p.tokenCount();
        bytes32 h;
        for (uint256 i; i < n; i++) {
            // each token's data is dropped once hashed (`h` is on the stack): memory stays flat over the walk
            uint256 free;
            assembly ("memory-safe") {
                free := mload(0x40)
            }
            h = _gangSwapTokenHash(p, p.allTokens(i), h);
            assembly ("memory-safe") {
                mstore(0x40, free)
            }
        }
        st = abi.encode(migrator, h);
    }

    /// @dev `h` with `t` folded in; `h` as it is when `t` is no GangSwap token.
    function _gangSwapTokenHash(GangLaunchpad3 p, address t, bytes32 h) internal view returns (bytes32) {
        address own = _gangSwapOf(p, t);
        if (own == address(0) && p.kindOf(t) != Pad3GangSwapStore.KIND) return h;
        (, bytes memory openAt) = address(p).staticcall(abi.encodeCall(IGangAgentWindow.agentOpenAt, (t)));
        (, bytes memory capOn) = address(p).staticcall(abi.encodeCall(IGangAgentWindow.walletCapOn, (t)));
        return keccak256(abi.encode(h, t, own, _raw(p, t), _derived(p, t, false), openAt, capOn));
    }

    /// @dev After the upgrade the pad serves GangSwap (an implementation without it would read as closed, so an already
    ///      closed pad would compare as unchanged), and a token is kind 4 exactly when it has a GangSwap migrator (a kind-4
    ///      token without one would graduate into a Pancake V2 pair).
    function _checkGangSwap(GangLaunchpad3 p) internal view {
        (bool served,) = _gangSwapOpen(p);
        (bool ok, bytes memory ret) =
            address(p).staticcall(abi.encodeCall(IGangSwapPad.gangSwapMigratorOf, (address(p))));
        if (!served || !ok || ret.length != 32) revert WiringCheck("upgrade: GangSwap not served");
        uint256 n = p.tokenCount();
        for (uint256 i; i < n; i++) {
            address t = p.allTokens(i);
            if ((p.kindOf(t) == Pad3GangSwapStore.KIND) != (_gangSwapOf(p, t) != address(0))) {
                revert WiringCheck("upgrade: a GangSwap token without its migrator");
            }
        }
    }

    /// @dev The graduation reward's deps and, for EVERY token whose stored reward state is not NONE (read raw at
    ///      Pad3GradStore's slot, the same before and after whatever the implementation does), `_gradTokenHash`. A pad
    ///      that does not serve the reward yet has no such token.
    function _gradState(GangLaunchpad3 p) internal view returns (bytes memory) {
        (, bytes memory deps) = address(p).staticcall(abi.encodeCall(IGangGradReward.gradRewardDeps, ()));
        uint256 n = p.tokenCount();
        bytes32 h;
        for (uint256 i; i < n; i++) {
            // memory stays flat over the walk (`_gangSwapState`)
            uint256 free;
            assembly ("memory-safe") {
                free := mload(0x40)
            }
            address t = p.allTokens(i);
            uint256 slot = uint256(keccak256(abi.encode(t, uint256(Pad3GradStore.SLOT) + 2)));
            if (uint8(uint256(vm.load(address(p), bytes32(slot)))) != Pad3GradStore.NONE) {
                h = _gradTokenHash(p, t, slot, h);
            }
            assembly ("memory-safe") {
                mstore(0x40, free)
            }
        }
        return abi.encode(deps, h);
    }

    /// @dev `h` with `t`'s reward folded in: its five stored words, its view, its list and what each listed buyer may claim.
    function _gradTokenHash(GangLaunchpad3 p, address t, uint256 slot, bytes32 h) internal view returns (bytes32) {
        IGangGradReward g = IGangGradReward(address(p));
        bytes32[5] memory w;
        for (uint256 i; i < 5; i++) {
            w[i] = vm.load(address(p), bytes32(slot + i));
        }
        h = keccak256(abi.encode(h, t, w, p.kindOf(t), g.gradReward(t)));
        (address[] memory buyers, uint64[] memory seqs, uint96[] memory spent, bool[] memory valid) = g.gradEntries(t);
        h = keccak256(abi.encode(h, buyers, seqs, spent, valid));
        for (uint256 i; i < buyers.length; i++) {
            h = keccak256(abi.encode(h, g.gradClaimable(t, buyers[i])));
        }
        return h;
    }

    /// @dev What this shows: after the upgrade the pad dispatches createGangSwapWithGradReward, and both wrappers' lists let
    ///      it through (a wrapper that does not list it, or a pad without it, answers something else). Two calls, each
    ///      refused before anything is created: an empty config (`_checkGradConfig`), and, the reward open, a valid config
    ///      naming a version that is not the pad's current one, which must get past the config check into the GangSwap
    ///      one. What it does not show: a create that succeeds (token, seed pull, stored reward); the Foundry and fork
    ///      tests do, on the code `_checkImplCode` compares byte for byte.
    function _checkGangSwapGradCreate(GangLaunchpad3 p) internal {
        (bool open,,) = IGangGradReward(address(p)).gradRewardDeps();
        IGangGradRewardBase.GradConfig memory cfg;
        _probeGradCreate(
            p,
            cfg,
            abi.encodeWithSelector(
                open ? IGangGradRewardBase.BadGradConfig.selector : IGangGradRewardBase.GradNotOpen.selector
            )
        );
        if (!open) return;
        (cfg.seed, cfg.minBuy, cfg.entries, cfg.refundAfter) = (1, 1, 1, 30 days);
        (, address migrator) = _gangSwapOpen(p);
        _probeGradCreate(
            p,
            cfg,
            migrator == address(0)
                ? abi.encodeWithSelector(IGangSwapPad.GangSwapNotOpen.selector)
                : abi.encodeWithSelector(IGangSwapPad.GangSwapVersionChanged.selector, migrator)
        );
    }

    /// @dev The create with `cfg` and a version no pad has (the pad itself), refused with exactly `want` each way in.
    function _probeGradCreate(GangLaunchpad3 p, IGangGradRewardBase.GradConfig memory cfg, bytes memory want) private {
        bytes memory data = abi.encodeCall(
            IGangSwapPad.createGangSwapWithGradReward, ("", "", "", "", uint256(6 ether), address(p), cfg)
        );
        _refusedWith(p, data, want);
        _refusedWith(p, abi.encodeCall(IGangAgentWindow.createWithAgentWindow, (uint16(1), data)), want);
        if (_vanityState(p) != address(0)) {
            _refusedWith(p, abi.encodeCall(Pad3Module.createWithSalt, (bytes32(0), data)), want);
        }
    }

    function _refusedWith(GangLaunchpad3 p, bytes memory data, bytes memory want) private {
        (bool ok, bytes memory ret) = address(p).call(data);
        if (ok || keccak256(ret) != keccak256(want)) {
            revert WiringCheck("upgrade: createGangSwapWithGradReward not wired");
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
