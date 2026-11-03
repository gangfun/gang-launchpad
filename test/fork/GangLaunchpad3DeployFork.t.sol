// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {DeployGang} from "../../script/DeployGang.s.sol";
import {DeployGangLaunchpad3} from "../../script/DeployGangLaunchpad3.s.sol";
import {UpgradeGangLaunchpad3} from "../../script/UpgradeGangLaunchpad3.s.sol";
import {GangRouterDeployLib as R} from "../../script/GangRouterDeployLib.sol";
import {GangMainnetRefs as M} from "../../config/GangDeployRefs.sol";
import {TokenDeployer} from "../../src/common/TokenDeployer.sol";
import {GangPadRegistry} from "../../src/gang/GangPadRegistry.sol";
import {GangLaunchpad3} from "../../src/gang/GangLaunchpad3.sol";
import {IGangPad} from "../../src/gang/interfaces/IGangPad.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {IGangGateway} from "../../src/router/interfaces/IGangGateway.sol";
import {GangFlywheelPad} from "../../src/flywheel/GangFlywheelPad.sol";
import {IFlywheelPad} from "../../src/flywheel/interfaces/IFlywheelPad.sol";
import {GatewayAdapter} from "../router/GangGateway.t.sol";
import {MultiHopRouter} from "../gang3/Pad3SellTo.t.sol";
import {GangLaunchpad3V2Mock} from "../mocks/GangLaunchpad3V2Mock.sol";
import {IGangVaultPad} from "../../src/gang/interfaces/IGangVaultPad.sol";

/// @dev A partner vault stand-in (the vault pad lists contracts only).
contract VaultStub {}

/// @dev The upgrade script of a build whose next version is GangLaunchpad3V2Mock (its `_newImpl`).
contract UpgradeToV2Mock is UpgradeGangLaunchpad3 {
    function _newImpl(GangLaunchpad3 cur) internal override returns (address) {
        return address(
            new GangLaunchpad3V2Mock(
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
}

/// @dev Exposes the script's Safe batch builders (the same code the script runs and prints).
contract DeployGangLaunchpad3Harness is DeployGangLaunchpad3 {
    /// @dev After the test's Safe upgrade to GangLaunchpad3V2Mock, the read-back compares against that build.
    bool internal v2;

    function setV2(bool on) external {
        v2 = on;
    }

    function _refImpl(GangLaunchpad3 cur) internal override returns (address) {
        if (!v2) return super._refImpl(cur);
        return address(
            new GangLaunchpad3V2Mock(
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

    function wiringJson(DeployGang.Stack memory s) external pure returns (string memory) {
        return _wiringJson(s, _ctxM(), true, M.OWNER_SAFE);
    }

    function acceptJson(DeployGang.Stack memory s) external pure returns (string memory) {
        return _acceptJson(s, true, M.OWNER_SAFE, true, true, true);
    }

    function forwardJson(DeployGang.Stack memory s) external returns (string memory) {
        return _forwardJson(s, _ctxM(), _cfgM());
    }

    function callersJson(DeployGang.Stack memory s) external returns (string memory) {
        return _callersJson(s, _cfgM());
    }

    function cutoverJson(DeployGang.Stack memory s) external returns (string memory) {
        return _cutover3Json(s, _ctxM(), _cfgM());
    }

    function _ctxM() internal pure returns (Ctx memory x) {
        x = Ctx({pad1: MAINNET_PAD_1, padRegistry: M.PAD_REGISTRY, gateway: MAINNET_GATEWAY});
    }

    function _cfgM() internal pure returns (Cfg memory c) {
        c.mainnet = true;
    }
}

/// @notice Runs the real DeployGangLaunchpad3 (both phases) on a BSC mainnet fork with a throwaway key and executes
///         every Safe batch exactly as encoded: listing (1), accept + open (2), forward (3: the older pads list 3.0),
///         callers (4), then — after the life below — cut-over (5). On the way: the phase-1 guard, the read-back
///         checks refusing a ProxyAdmin handed elsewhere and an implementation on another registry; a curve token of
///         3.0 traded through its own entry (native BNB in and out, an aggregator adapter, the router fee), through the
///         live GangGateway and the live registry; live curve tokens of 1.0 / 2.0 / the vault pad and a live 铸币飞轮 V2
///         sale traded through 3.0's entry (each fill = its quote, 3.0 left holding nothing of theirs); an upgrade by
///         the Safe through the ProxyAdmin (state kept, the token still trades, phase 2 still passes). Agent IDs are
///         mocked (balanceOf = 1 for everyone). No broadcast. One test: the script reads process-wide env vars. Run it
///         alone (`--match-path test/fork/GangLaunchpad3DeployFork.t.sol`).
/// @dev Needs BSC_RPC_URL (without it the test returns at once), and the live PoolCheck linked as on mainnet (the
///      read-back pins it): forge test --libraries src/launchpad-v2/PoolCheck.sol:PoolCheck:0xd2B159820749f178503E4faBCB18A7Ae4492bDb3
contract GangLaunchpad3DeployForkTest is Test {
    address constant PAD_1 = 0x15CFD2dc8278Fb87a1783ef42111618E20874365;
    address constant PAD_2 = 0x770331a9accdb53ACb4a45B6c5B7D151fADCe557;
    address constant VAULT_PAD = 0xE90851A90C6278E3d6e4C24320101f8B13D90A11;
    address constant SAFE = 0x2866369F7acEFC9760bdE7779362fae5cD68B41E;

    DeployGangLaunchpad3Harness d;
    GatewayAdapter adapter;
    MultiHopRouter hop;
    address user = makeAddr("pad3-fork-user");
    address feeTo = makeAddr("pad3-fork-feeTo");

    function test_fork_deploy3_mainnetPathThenLife() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        uint256 pk = uint256(keccak256("GangLaunchpad 3.0 deploy-script fork test: throwaway, never funded"));
        address me = vm.addr(pk);
        vm.deal(me, 10 ether);
        _env(pk);
        d = new DeployGangLaunchpad3Harness();
        vm.mockCall(M.AGENT_ID_REGISTRY, abi.encodeWithSelector(IERC721.balanceOf.selector), abi.encode(uint256(1)));
        vm.deal(user, 100 ether);

        // mainnet phase 1 needs PAD3_NEW=true
        vm.expectRevert(
            abi.encodeWithSelector(DeployGang.WiringCheck.selector, "phase 1 on mainnet needs PAD3_NEW=true")
        );
        d.run();
        vm.setEnv("PAD3_NEW", "true");

        // phase 1: impl + proxy (initialized, ProxyAdmin = the Safe), own wiring; shared listing left to the Safe
        DeployGang.Stack memory s = d.run();
        // phase 2 proves the deploy wallet sent nothing else in between (final audit M-3)
        vm.setEnv("GANG_PAD3_DEPLOYER_NONCE", vm.toString(vm.getNonce(me)));
        GangLaunchpad3 p = GangLaunchpad3(payable(s.pad));
        address admin = R.adminOf(s.pad);
        assertEq(ProxyAdmin(admin).owner(), SAFE, "upgrades: the Safe from the start");
        assertEq(Ownable(s.pad).owner(), me, "pad owner: the deployer until the hand-over");
        assertEq(address(p.padRegistry()), M.PAD_REGISTRY);
        assertEq(address(p.migrator()), address(0), "closed");
        assertTrue(p.routers(s.router) && p.routers(M.GANG_GATEWAY), "router + gateway listed");
        assertEq(p.twapWindow(), IGangPad(PAD_1).twapWindow());

        // batch 1 (9 listings), phase 2 (hand-over started), batch 2 (accept both, open)
        _exec(d.wiringJson(s), SAFE, 9);
        vm.setEnv("GANG_PAD3", vm.toString(s.pad));
        vm.setEnv("GANG_ROUTER3", vm.toString(s.router));
        d.run();
        assertEq(Ownable2Step(s.pad).pendingOwner(), SAFE);
        assertEq(Ownable2Step(s.handler).pendingOwner(), SAFE);
        _exec(d.acceptJson(s), SAFE, 3);
        assertEq(Ownable(s.pad).owner(), SAFE);
        assertEq(address(p.migrator()), IGangPad(PAD_1).migrator(), "open on the live migrator");
        assertTrue(GangPadRegistry(M.PAD_REGISTRY).isPad(s.pad), "in the registry");

        // read-back guards: a ProxyAdmin handed away, an implementation on another registry
        _guards(s, admin);

        // before batch 3 an older pad's token can be quoted but not traded through 3.0
        adapter = new GatewayAdapter(IGangGateway(s.pad), feeTo);
        hop = new MultiHopRouter(GangLaunchpad3(payable(s.pad)));
        address live1 = _liveCurve(p, PAD_1);
        if (live1 != address(0)) {
            vm.prank(user, user);
            vm.expectRevert(IGangLaunchpad.OnlyRouter.selector);
            adapter.buyBnb{value: 0.01 ether}(live1, 0);
        }

        // batch 3 (forward: 5 pads), batch 4 (callers: the adapter), phase 2 again: nothing left but the cut-over
        _exec(d.forwardJson(s), SAFE, 5);
        address[5] memory olds = [PAD_1, PAD_2, VAULT_PAD, M.FLYWHEEL_PAD_V1, M.FLYWHEEL_PAD_V2];
        for (uint256 i; i < 5; i++) {
            assertTrue(IGangPad(olds[i]).routers(s.pad), "older pad lists 3.0");
        }
        assertEq(bytes(d.forwardJson(s)).length, 0, "forward: nothing left");
        vm.setEnv("CALLERS", string.concat(vm.toString(address(adapter)), ",", vm.toString(address(hop))));
        vm.setEnv(
            "CALLER_CODEHASHES",
            string.concat(vm.toString(address(adapter).codehash), ",", vm.toString(address(hop).codehash))
        );
        _exec(d.callersJson(s), SAFE, 2);
        assertTrue(p.isCaller(address(adapter)));
        d.run();

        // 3.0's own token: created, then traded through its entry, the live gateway and the router
        address creator = makeAddr("pad3-creator");
        IGangLaunchpad.TaxConfig memory untaxed;
        vm.prank(creator);
        address t = p.create("Three", "THREE", "", "", M.WBNB, address(0), untaxed);
        assertEq(p.tokenVersionOf(t), 1, "rule version");
        assertEq(GangPadRegistry(M.PAD_REGISTRY).padOf(t), s.pad, "registry finds 3.0's token");
        _tradeThrough(p, t, s.pad, true);
        _gatewayBuy(t);

        // older pads' live curve tokens and a live 铸币飞轮 V2 sale, through 3.0
        uint256 forwarded;
        address[3] memory curvePads = [PAD_1, PAD_2, VAULT_PAD];
        for (uint256 i; i < 3; i++) {
            address lt = _liveCurve(p, curvePads[i]);
            // the vault pad (partners only) may have none: the Safe lists a vault and names its creator, who creates one
            if (lt == address(0) && curvePads[i] == VAULT_PAD) lt = _vaultToken(creator);
            if (lt == address(0)) {
                console.log("no live BNB curve token on", curvePads[i]);
                continue;
            }
            _tradeThrough(p, lt, curvePads[i], false);
            forwarded++;
        }
        assertEq(forwarded, 3, "1.0, 2.0 and the vault pad");
        _flyThrough(p, M.FLYWHEEL_PAD_V2);

        // the upgrade script's pre-checks (audit 3C M-1 / L-3), then an upgrade by the Safe through the ProxyAdmin:
        // state kept, trading goes on, phase 2 still passes
        _upgradeScript(p);
        _upgrade(s, p, admin, t);

        // batch 5 (cut-over): 2.0 (and 1.0, if it still creates) stop creating; 3.0 keeps creating
        string memory cut = d.cutoverJson(s);
        _exec(cut, SAFE, _count(cut));
        TokenDeployer td = TokenDeployer(s.tokenDeployer);
        assertFalse(td.launchpads(PAD_1) || td.launchpads(PAD_2), "1.0 / 2.0 stopped");
        assertTrue(td.launchpads(VAULT_PAD), "the vault pad keeps creating");
        vm.prank(creator);
        vm.expectRevert();
        IGangPad(PAD_2).create("Two", "TWO", "", "", M.WBNB, address(0), untaxed);
        vm.prank(creator);
        p.create("Three2", "THREE2", "", "", M.WBNB, address(0), untaxed);
        assertEq(bytes(d.cutoverJson(s)).length, 0, "cut-over: nothing left");
        d.run();
    }

    function _guards(DeployGang.Stack memory s, address admin) internal {
        uint256 snap = vm.snapshotState();
        vm.prank(SAFE);
        ProxyAdmin(admin).transferOwnership(address(0xBEEF));
        vm.expectRevert(abi.encodeWithSelector(DeployGang.WiringCheck.selector, "pad ProxyAdmin owner"));
        d.run();
        vm.revertToState(snap);

        GangLaunchpad3 p = GangLaunchpad3(payable(s.pad));
        address other = address(
            new GangLaunchpad3(
                address(p.quoteRegistry()),
                address(p.dividendVault()),
                address(p.platformBucket()),
                p.taxHandler(),
                p.tokenDeployer(),
                p.wbnb(),
                address(0xBEEF)
            )
        );
        vm.prank(SAFE);
        ProxyAdmin(admin).upgradeAndCall(ITransparentUpgradeableProxy(s.pad), other, "");
        vm.expectRevert(abi.encodeWithSelector(DeployGang.WiringCheck.selector, "pad.padRegistry"));
        d.run();
        vm.revertToState(snap);
    }

    /// @dev A buy through the adapter (BNB in, = tryBuy to the wei), then half sold back through it (BNB out, the 1%
    ///      router fee, = trySell). 3.0 ends holding none of `t` and, for an older pad's token, exactly the WBNB it
    ///      held before (its own reserves).
    function _tradeThrough(GangLaunchpad3 p, address t, address pad, bool local) internal {
        uint256 w0 = IERC20(M.WBNB).balanceOf(address(p));
        uint256 t0 = IERC20(t).balanceOf(address(p));
        (uint8 st, address q,,,) = p.getTokenInfo(t);
        assertEq(st, 1, "on its curve");
        assertEq(q, address(0), "BNB-quoted");
        (,, uint256 est, uint256 cost,,,, uint256 amountFunds) = p.tryBuy(t, user, 0, 0.01 ether);
        assertGt(est, 0, "quote");
        uint256 b0 = IERC20(t).balanceOf(user);
        vm.prank(user, user);
        (uint256 out, uint256 used) = adapter.buyBnb{value: 0.01 ether}(t, est);
        assertEq(out, est, "fill = quote");
        assertEq(used, cost);
        assertEq(amountFunds, cost);
        assertEq(IERC20(t).balanceOf(user) - b0, out);
        // a quarter through the pay-to sell (multi-hop): the proceeds land on the listed router, none on the user
        uint256 quarter = out / 4;
        {
            (,, uint256 qf,) = p.trySell(t, quarter);
            vm.prank(user);
            IERC20(t).approve(address(p), quarter);
            uint256 h0 = address(hop).balance;
            uint256 u0 = user.balance;
            vm.prank(user, user);
            assertEq(hop.gangHop(t, quarter, qf), qf, "pay-to sell = trySell");
            assertEq(address(hop).balance - h0, qf, "native BNB on the router");
            assertEq(user.balance, u0, "nothing to the seller directly");
        }
        uint256 half = out / 2;
        (,, uint256 funds,) = p.trySell(t, half);
        assertGt(funds, 0);
        vm.prank(user);
        IERC20(t).approve(address(p), half);
        uint256 bnb0 = user.balance;
        uint256 fee0 = feeTo.balance;
        vm.prank(user, user);
        uint256 got = adapter.sell(t, half, 0);
        assertEq(got, funds - funds / 100, "after the adapter's 1%");
        assertEq(user.balance - bnb0, got, "native BNB out");
        assertEq(feeTo.balance - fee0, funds / 100, "router fee");
        assertEq(address(p).balance, 0, "3.0 holds no BNB");
        if (local) {
            assertEq(IERC20(t).balanceOf(address(p)), t0 - out + half + quarter, "curve tokens out and back");
        } else {
            assertEq(IERC20(t).balanceOf(address(p)), 0, "3.0 holds none of the token");
            assertEq(IERC20(M.WBNB).balanceOf(address(p)), w0, "3.0's reserves untouched");
            assertEq(IERC20(M.WBNB).allowance(address(p), pad), 0, "no approval left");
        }
    }

    function _vaultToken(address creator) internal returns (address t) {
        address vault = address(new VaultStub());
        vm.startPrank(SAFE);
        IGangVaultPad(VAULT_PAD).setVault(vault, true);
        IGangVaultPad(VAULT_PAD).setVaultCreator(vault, creator);
        vm.stopPrank();
        IGangLaunchpad.TaxConfig memory untaxed;
        vm.prank(creator);
        t = IGangVaultPad(VAULT_PAD)
            .createWithVault("Vault", "VLT", "", "", M.WBNB, address(0), untaxed, 9 ether, vault);
    }

    /// @dev The live GangGateway finds 3.0's token through the live registry and buys it on 3.0 (listed router).
    function _gatewayBuy(address t) internal {
        IGangGateway gw = IGangGateway(M.GANG_GATEWAY);
        (uint8 st,,,,) = gw.getTokenInfo(t);
        assertEq(st, 1, "gateway: curve");
        (,, uint256 est,,,,,) = gw.tryBuy(t, user, 0, 0.01 ether);
        assertGt(est, 0, "gateway quote");
        vm.prank(user, user);
        (uint256 out,) = gw.buyTokenAMAP{value: 0.01 ether}(t, user, 0.01 ether, est);
        assertEq(out, est, "gateway fill = quote");
    }

    /// @dev A minting 铸币飞轮 sale bought and sold back (whole shares) through 3.0, as through the gateway.
    function _flyThrough(GangLaunchpad3 p, address pad) internal {
        GangFlywheelPad f = GangFlywheelPad(payable(pad));
        address t;
        for (uint256 i = f.tokenCount(); i > 0 && t == address(0); i--) {
            address c = f.allTokens(i - 1);
            IFlywheelPad.Sale memory sale = f.sales(c);
            if (sale.gate != address(0) && !sale.launched && sale.filledAt == 0 && sale.sold < 9_000) t = c;
        }
        if (t == address(0)) {
            console.log("no minting sale on", pad);
            return;
        }
        (,, uint256 est, uint256 cost,,,,) = p.tryBuy(t, user, 0, 1 ether);
        assertGt(est, 0, "fly quote");
        uint256 w0 = IERC20(M.WBNB).balanceOf(user);
        uint256 r0 = IERC20(M.WBNB).balanceOf(address(p));
        vm.prank(user, user);
        (uint256 out, uint256 used) = adapter.buyBnb{value: 1 ether}(t, est);
        assertEq(out, est, "fly fill = quote");
        assertEq(used, cost);
        assertEq(IERC20(M.WBNB).balanceOf(user) - w0, 1 ether - cost, "refund in WBNB");
        uint256 tps = f.TOKENS_PER_SHARE();
        uint256 amount = (out / tps) * tps;
        (,, uint256 funds,) = p.trySell(t, amount);
        vm.prank(user);
        IERC20(t).approve(address(p), amount);
        vm.prank(user, user);
        uint256 got = adapter.sell(t, amount, 0);
        assertEq(got, funds - funds / 100, "fly sell");
        assertEq(IERC20(M.WBNB).balanceOf(address(p)), r0, "3.0's reserves untouched");
        assertEq(IERC20(t).balanceOf(address(p)), 0);
    }

    /// @dev UpgradeGangLaunchpad3 on the live-like stack: a fresh build passes (simulated, printed for the Safe, not
    ///      sent); an implementation on another registry, and a new reinitializer without its set-up call, are
    ///      refused before anything is printed; with the set-up call it passes.
    function _upgradeScript(GangLaunchpad3 p) internal {
        UpgradeGangLaunchpad3 u = new UpgradeGangLaunchpad3();
        address cur = R.implementationOf(address(p));
        vm.setEnv("PAD3_IMPL", vm.toString(address(0)));
        vm.setEnv("PAD3_INIT_CALL", "0x");
        u.run();
        assertEq(R.implementationOf(address(p)), cur, "printed for the Safe, not sent");

        address wrong = address(
            new GangLaunchpad3(
                address(p.quoteRegistry()),
                address(p.dividendVault()),
                address(p.platformBucket()),
                p.taxHandler(),
                p.tokenDeployer(),
                p.wbnb(),
                address(0xBEEF)
            )
        );
        vm.setEnv("PAD3_IMPL", vm.toString(wrong));
        vm.expectRevert(abi.encodeWithSelector(DeployGang.WiringCheck.selector, "PAD3_IMPL dependencies differ"));
        u.run();

        address next = address(
            new GangLaunchpad3V2Mock(
                address(p.quoteRegistry()),
                address(p.dividendVault()),
                address(p.platformBucket()),
                p.taxHandler(),
                p.tokenDeployer(),
                p.wbnb(),
                address(p.padRegistry())
            )
        );
        vm.setEnv("PAD3_IMPL", vm.toString(next));
        // not this build's GangLaunchpad3 code (final audit M-1); then with the script of the build that ships it
        vm.expectRevert(abi.encodeWithSelector(DeployGang.WiringCheck.selector, "pad implementation code"));
        u.run();
        UpgradeToV2Mock u2 = new UpgradeToV2Mock();
        vm.expectRevert(
            abi.encodeWithSelector(DeployGang.WiringCheck.selector, "PAD3_INIT_CALL missing: reinitializer left open")
        );
        u2.run();
        vm.setEnv("PAD3_INIT_CALL", vm.toString(abi.encodeCall(GangLaunchpad3V2Mock.initializeV2, (7))));
        u2.run();
        assertEq(R.implementationOf(address(p)), cur, "still not sent");
        vm.setEnv("PAD3_IMPL", vm.toString(address(0)));
        vm.setEnv("PAD3_INIT_CALL", "0x");
    }

    function _upgrade(DeployGang.Stack memory s, GangLaunchpad3 p, address admin, address t) internal {
        (,, uint128 rq,, uint128 gradAmt,,,,,,,) = p.curves(t);
        uint256 count = p.tokenCount();
        address next = address(
            new GangLaunchpad3V2Mock(
                address(p.quoteRegistry()),
                address(p.dividendVault()),
                address(p.platformBucket()),
                p.taxHandler(),
                p.tokenDeployer(),
                p.wbnb(),
                address(p.padRegistry())
            )
        );
        vm.prank(SAFE);
        ProxyAdmin(admin)
            .upgradeAndCall(
                ITransparentUpgradeableProxy(s.pad), next, abi.encodeCall(GangLaunchpad3V2Mock.initializeV2, (7))
            );
        assertEq(R.implementationOf(s.pad), next);
        d.setV2(true);
        assertEq(GangLaunchpad3V2Mock(payable(s.pad)).v2Value(), 7);
        assertEq(Ownable(s.pad).owner(), SAFE);
        assertEq(p.tokenVersionOf(t), 1, "version kept");
        (,, uint128 rq2,, uint128 gradAmt2,,,,,,,) = p.curves(t);
        assertEq(rq2, rq, "curve kept");
        assertEq(gradAmt2, gradAmt, "graduation amount kept");
        assertEq(p.tokenCount(), count);
        assertTrue(
            p.routers(s.router) && p.isCaller(address(adapter)) && address(p.migrator()) != address(0), "settings kept"
        );
        _tradeThrough(p, t, s.pad, true);
        d.run();
    }

    /// @dev The newest BNB-quoted curve token of `pad` with at least 0.5 BNB of curve left (as 3.0's entry sees it).
    function _liveCurve(GangLaunchpad3 p, address pad) internal view returns (address) {
        IGangPad op = IGangPad(pad);
        uint256 n = op.tokenCount();
        for (uint256 i = n; i > 0 && n - i < 60; i--) {
            address t = op.allTokens(i - 1);
            (uint8 st, address q,,, uint256 left) = p.getTokenInfo(t);
            if (st == 1 && q == address(0) && left > 0.5 ether) return t;
        }
        return address(0);
    }

    function _exec(string memory json, address safe, uint256 count) internal {
        assertEq(vm.parseJsonString(json, ".chainId"), "56");
        assertEq(vm.parseJsonAddress(json, ".meta.createdFromSafeAddress"), safe);
        assertEq(_count(json), count, "batch size");
        for (uint256 i; i < count; i++) {
            string memory k = string.concat(".transactions[", vm.toString(i), "]");
            address to = vm.parseJsonAddress(json, string.concat(k, ".to"));
            bytes memory data = vm.parseJsonBytes(json, string.concat(k, ".data"));
            vm.prank(safe);
            (bool ok, bytes memory ret) = to.call(data);
            if (!ok) {
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
    }

    function _count(string memory json) internal view returns (uint256 n) {
        while (vm.keyExistsJson(json, string.concat(".transactions[", vm.toString(n), "]"))) {
            n++;
        }
    }

    function _env(uint256 pk) internal {
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(pk));
        vm.setEnv("GANG_PAD", vm.toString(PAD_1));
        vm.setEnv("OWNER", vm.toString(SAFE));
        vm.setEnv("KEEPER", vm.toString(M.KEEPER));
        vm.setEnv("GANG_GATEWAY", vm.toString(M.GANG_GATEWAY));
        vm.setEnv("GANG_PAD_REGISTRY", vm.toString(M.PAD_REGISTRY));
        vm.setEnv("GANG_PAD3", vm.toString(address(0)));
        vm.setEnv("GANG_ROUTER3", vm.toString(address(0)));
        vm.setEnv("PAD3_NEW", "false");
        vm.setEnv("CALLERS", "");
        vm.setEnv("CALLER_CODEHASHES", "");
        vm.setEnv("GANG_PAD3_DEPLOYER_NONCE", "0");
        vm.setEnv("PAD3_LOG_SCAN", "false");
        vm.setEnv("CUTOVER", "true");
        vm.setEnv("ROUTER_TIMELOCK_DELAY", "172800");
        vm.setEnv("MAINNET_OWNER_IS_DEPLOYER", "false");
        vm.setEnv("KEEPER_OVERRIDE_OK", "false");
        vm.setEnv("FEE_VAULT", vm.toString(address(0)));
        vm.setEnv("BURNER", vm.toString(address(0)));
        vm.setEnv("RECIPIENT", vm.toString(address(0)));
        vm.setEnv("TWAP_WINDOW", vm.toString(uint256(IGangPad(PAD_1).twapWindow())));
    }
}
