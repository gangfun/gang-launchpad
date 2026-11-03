// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console} from "forge-std/Script.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {GangMainnetRefs as M} from "../config/GangDeployRefs.sol";
import {GangLaunchpad3} from "../src/gang/GangLaunchpad3.sol";
import {GangRouterDeployLib as R} from "./GangRouterDeployLib.sol";
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
///            - the whole phase-2 read-back of DeployGangLaunchpad3 passes on the upgraded proxy;
///            then it is rolled back. Testnet with the deploy wallet owning the ProxyAdmin: sent. Otherwise: printed as
///         a Safe batch. Run test/gang3/GangLaunchpad3Layout.t.sol against the new implementation too: it pins every
///         slot and struct member; this script checks real data only.
/// @dev Env: as DeployGangLaunchpad3 phase 2 (DEPLOYER_PRIVATE_KEY, GANG_PAD = 1.0, GANG_PAD3, GANG_ROUTER3, OWNER,
///      KEEPER, GANG_GATEWAY, GANG_PAD_REGISTRY, CALLERS), plus PAD3_IMPL (optional), PAD3_INIT_CALL (optional
///      calldata: the new implementation's reinitializer). A later version replaces `_newImpl` with its own contract. Mainnet broadcast needs
///      GANG_MAINNET_OK=true (only PAD3_IMPL's deployment is broadcast there; the upgrade is the Safe's).
contract UpgradeGangLaunchpad3 is DeployGangLaunchpad3 {
    uint256 internal constant SAMPLE = 25;

    struct Snapshot {
        bytes32 settings;
        bytes32[] tokens;
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
        GangLaunchpad3 p = GangLaunchpad3(payable(proxy));
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
        if (impl == address(0)) {
            vm.startBroadcast(pk);
            impl = _newImpl(GangLaunchpad3(payable(current)));
            vm.stopBroadcast();
            console.log("new implementation (deployed now; pass it as PAD3_IMPL on any re-run)", impl);
        } else {
            console.log("new implementation (PAD3_IMPL)", impl);
        }
        _checkImpl(current, impl);
        uint64 wantVersion = _wantVersion(impl, v0, init);

        // the upgrade in the simulation, as the owner sends it; checked; rolled back
        Snapshot memory before = _snapshot(p, s);
        uint256 snap = vm.snapshotState();
        vm.prank(upgrader);
        ProxyAdmin(admin).upgradeAndCall(ITransparentUpgradeableProxy(proxy), impl, init);
        if (R.implementationOf(proxy) != impl) revert WiringCheck("upgrade: implementation slot");
        (uint64 v1, bool initializing) = R.initState(proxy);
        if (v1 != wantVersion || initializing) revert WiringCheck("upgrade: initialized version");
        Snapshot memory afterUp = _snapshot(p, s);
        if (afterUp.settings != before.settings) revert WiringCheck("upgrade: settings changed");
        for (uint256 i; i < before.tokens.length; i++) {
            if (afterUp.tokens[i] != before.tokens[i]) revert WiringCheck("upgrade: a token's record changed");
        }
        _check2(s, c, x);
        vm.revertToState(snap);
        console.log("simulated: upgrade + read-back ok; tokens compared", before.tokens.length);

        bytes memory call = abi.encodeCall(ProxyAdmin.upgradeAndCall, (ITransparentUpgradeableProxy(proxy), impl, init));
        if (!c.mainnet && upgrader == me) {
            vm.startBroadcast(pk);
            ProxyAdmin(admin).upgradeAndCall(ITransparentUpgradeableProxy(proxy), impl, init);
            vm.stopBroadcast();
            console.log("upgraded (testnet, the deploy wallet owns the ProxyAdmin)");
            return s;
        }
        console.log("\n=== Safe batch: upgrade GangLaunchpad 3.0 (ProxyAdmin.upgradeAndCall, effective at once) ===");
        console.log(
            string.concat(_head(c.mainnet, upgrader, "gang: upgrade GangLaunchpad 3.0"), _tx(admin, call, false), "]}")
        );
    }

    /// @dev Review 3: the version the new implementation leaves the proxy at (`initVersion`) decides whether a set-up
    ///      call is due: a new reinitializer must run inside the upgrade, and a set-up call needs one.
    function _wantVersion(address impl, uint64 current, bytes memory init) internal view returns (uint64 want) {
        want = GangLaunchpad3(payable(impl)).initVersion();
        if (want < current) revert WiringCheck("PAD3_IMPL initVersion below the proxy's");
        if (want > current && init.length == 0) revert WiringCheck("PAD3_INIT_CALL missing: reinitializer left open");
        if (want == current && init.length != 0) revert WiringCheck("PAD3_INIT_CALL without a new reinitializer");
    }

    /// @dev This build's GangLaunchpad3 with the current implementation's seven dependencies (read from its code, never
    ///      typed in). A later version deploys its own contract here.
    function _newImpl(GangLaunchpad3 cur) internal virtual returns (address) {
        return address(
            new GangLaunchpad3(
                address(cur.quoteRegistry()),
                address(cur.dividendVault()),
                address(cur.platformBucket()),
                cur.taxHandler(),
                cur.tokenDeployer(),
                cur.wbnb(),
                address(cur.padRegistry())
            )
        );
    }

    function _checkImpl(address current, address impl) internal view {
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
    }

    /// @dev The settings every token trades under, and for the newest SAMPLE tokens both their raw records (as their
    ///      getters return them) and what the named views derive from them (a member read from another place changes
    ///      a derived value even when the raw bytes do not).
    function _snapshot(GangLaunchpad3 p, Stack memory s) internal view returns (Snapshot memory snap) {
        address[] memory callers = _callers();
        bool[] memory listed = new bool[](callers.length);
        for (uint256 i; i < callers.length; i++) {
            listed[i] = p.isCaller(callers[i]);
        }
        snap.settings = keccak256(
            abi.encode(
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
        for (uint256 i; i < k; i++) {
            address t = p.allTokens(n - 1 - i);
            snap.tokens[i] = keccak256(abi.encode(_raw(p, t), _derived(p, t)));
        }
    }

    function _raw(GangLaunchpad3 p, address t) internal view returns (bytes memory) {
        (, bytes memory cv) = address(p).staticcall(abi.encodeWithSignature("curves(address)", t));
        (, bytes memory sa) = address(p).staticcall(abi.encodeWithSignature("sales(address)", t));
        return abi.encode(t, cv, sa, p.kindOf(t), p.tokenVersionOf(t), p.creatorFeeOf(t), p.gradTargetOf(t));
    }

    /// @dev Each through a raw staticcall: a view that reverts for this kind of token records its revert data.
    function _derived(GangLaunchpad3 p, address t) internal view returns (bytes memory d) {
        bytes[] memory calls = _derivedCalls(t);
        for (uint256 i; i < calls.length; i++) {
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
            abi.encodeCall(GangLaunchpad3.gradAmtOf, (t)),
            abi.encodeCall(GangLaunchpad3.graduationRemaining, (t)),
            abi.encodeCall(GangLaunchpad3.taxConfigOf, (t)),
            abi.encodeCall(GangLaunchpad3.tryBuy, (t, address(0), 0, 0.01 ether)),
            abi.encodeCall(GangLaunchpad3.trySell, (t, 1 ether)),
            abi.encodeCall(GangLaunchpad3.exitFeeBpsOf, (t)),
            abi.encodeCall(GangLaunchpad3.holdBpsOf, (t)),
            abi.encodeCall(GangLaunchpad3.previewMint, (t, address(0), 1)),
            abi.encodeCall(GangLaunchpad3.walletRoom, (t, address(0)))
        ];
        for (uint256 i; i < 11; i++) {
            calls[i] = c[i];
        }
    }
}
