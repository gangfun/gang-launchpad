// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {GangRouterDeployLib as R} from "../../script/GangRouterDeployLib.sol";
import {Pad3LiveUpgrade} from "./Pad3LiveUpgrade.sol";
import {Pad3Impl} from "../../script/Pad3Impl.sol";
import {GangLaunchpad3} from "../../src/gang/GangLaunchpad3.sol";
import {GangMainnetRefs as M} from "../../config/GangDeployRefs.sol";
import {IGangPad} from "../../src/gang/interfaces/IGangPad.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {GangHandlerAdmin} from "../../src/gang/GangHandlerAdmin.sol";
import {GangTaxHandler} from "../../src/gang/GangTaxHandler.sol";
import {GangBond} from "../../src/gang/GangBond.sol";
import {GangBuybackSplitter} from "../../src/gang/GangBuybackSplitter.sol";
import {GangBuybackSplitterFactory} from "../../src/gang/GangBuybackSplitterFactory.sol";
import {GangSplitModule} from "../../src/gang/GangSplitModule.sol";
import {GangSplitModuleFactory} from "../../src/gang/GangSplitModuleFactory.sol";
import {GangLiquiditySplitter} from "../../src/gang/GangLiquiditySplitter.sol";
import {GangLiquiditySplitterFactory} from "../../src/gang/GangLiquiditySplitterFactory.sol";
import {GangComboSplitter} from "../../src/gang/GangComboSplitter.sol";
import {GangComboSplitterFactory} from "../../src/gang/GangComboSplitterFactory.sol";
import {GangModulePadScript} from "../../script/GangModulePadScript.sol";
import {DeployGangLaunchpad3} from "../../script/DeployGangLaunchpad3.s.sol";
import {DeployGangBond} from "../../script/DeployGangBond.s.sol";
import {DeployGangBuybackSplitterFactory} from "../../script/DeployGangBuybackSplitterFactory.s.sol";
import {DeployGangSplitModuleFactory} from "../../script/DeployGangSplitModuleFactory.s.sol";
import {DeployGangLiquiditySplitterFactory} from "../../script/DeployGangLiquiditySplitterFactory.s.sol";
import {DeployGangComboSplitterFactory} from "../../script/DeployGangComboSplitterFactory.s.sol";

interface IPad3ForkHandler {
    function maxChunk(address token) external view returns (uint256);
    function process(address token, uint256 amount, uint256 minQuoteOut) external returns (uint256);
    function keeper() external view returns (address);
}

interface IPad3ForkPair {
    function token0() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

/// @notice The module set of GangLaunchpad 3.0 on a BSC mainnet fork, deployed by the five module scripts with
///         GANG_PAD3 and wired by the two Safe batches they print (as 2.0's were): batch 1 — the 3.0 handler handed
///         to the new GangHandlerAdmin, the buy-back factory allowed, the two partner recipients of 2.0 listed;
///         batch 2 — the Split / LP / Combo factories allowed. Then each module works on a 3.0 token: an Agent
///         clones one from each factory, creates a 3.0 tax token naming it and binds it; a bond is posted; the combo
///         token graduates into a real Pancake pair, pool sells pay the tax, the keeper processes it and the combo
///         module burns, adds LP and pays. Also: the scripts never bind to 1.0 or 2.0 through GANG_PAD3. Agent IDs
///         are mocked. No broadcast. Run it alone (the scripts read process-wide env vars).
///         Two modes. Deploy (the rehearsal before the launch): fork at a block before Safe batch 1, e.g.
///         PAD3_FORK_BLOCK=131436000, run WITH --libraries (below). Live (the default once 3.0's handler is held by an
///         admin, i.e. now): the mainnet set (or the addresses given in HANDLER_ADMIN / SPLITTER_FACTORY /
///         SPLIT_FACTORY / LP_FACTORY / COMBO_FACTORY / GANG_BOND) is only checked, nothing is left for the Safe, and
///         new clones of the live factories run; run it WITHOUT --libraries (the factories' code check compares whole
///         runtime code, metadata included, and --libraries changes it). Before a 3.0 upgrade (spec §6): live mode at
///         the new build's commit with PAD3_FORK_IMPL = the deployed new implementation (the Safe's upgrade runs first),
///         or, before it's deployed, PAD3_FORK_THIS_BUILD=true: this build's implementation, made in the fork.
/// @dev Needs BSC_RPC_URL (without it the test is skipped). Deploy mode also needs the live PoolCheck linked (the 3.0
///      phase-2 read-back pins it): --libraries src/launchpad-v2/PoolCheck.sol:PoolCheck:0xd2B159820749f178503E4faBCB18A7Ae4492bDb3
contract Pad3ModulesForkTest is Test {
    address constant PAD3 = 0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29;
    address constant ROUTER3 = 0xec9717E5C68b9F18fA76D3961C9Cd7e67b5E61e7;
    address constant PAD_1 = 0x15CFD2dc8278Fb87a1783ef42111618E20874365;
    address constant PAD_2 = 0x770331a9accdb53ACb4a45B6c5B7D151fADCe557;
    address constant GANG = 0x0c6302401aa5325C2E36F170f52C00B1d220B405;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    // the mainnet module set of 3.0 (deployed 2026-11-03)
    address constant LIVE_ADMIN = 0xC833CEC2B283759003945C0Bf8C048aB1949Af76;
    address constant LIVE_BUYBACK = 0xc1282e7Fd3DFa5e00e74E9EbF8c54fFfB5763194;
    address constant LIVE_SPLIT = 0x904D4498a9257E4d7638afEbB95A1162cB2171f2;
    address constant LIVE_LP = 0x98C506F0F4762F9d1Ec96C27499CE8B7e5981752;
    address constant LIVE_COMBO = 0x20188054dE31De844df205712768852BdeD3eA39;
    address constant LIVE_BOND = 0x830b38F695Ca1bCbdD313CD5AA5943e2125Be9D6;
    address constant VAULT_PAD = 0xE90851A90C6278E3d6e4C24320101f8B13D90A11;
    address constant ADMIN_2 = 0x2e994cdF2c8aC41c6aF26874e4F989773aD8Bd18;
    address constant PARTNER_1 = 0xC7f501D25Ea088aeFCa8B4b3ebD936aAe12bF4A4;
    address constant PARTNER_2 = 0x13B362286dC1d43250DA9F9FDC979f6aBe883EF0;

    address dev = makeAddr("pad3-mod-dev");
    address kol = makeAddr("pad3-mod-kol");

    function test_fork_pad3Modules_deployWireAndRun() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 forkBlock = vm.envOr("PAD3_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);
        uint256 pk = uint256(keccak256("GangLaunchpad 3.0 modules fork test: throwaway, never funded"));
        vm.deal(vm.addr(pk), 1 ether);
        vm.mockCall(M.AGENT_ID_REGISTRY, abi.encodeWithSelector(IERC721.balanceOf.selector), abi.encode(uint256(1)));
        address handler = IGangPad(PAD3).taxHandler();
        // after Safe batch 1 (block 131438345) the live set holds 3.0's handler: check that set by default
        bool live = vm.envOr("PAD3_FORK_LIVE", Ownable(handler).owner() != M.OWNER_SAFE);
        _env(pk, live);
        address impl = vm.envOr("PAD3_FORK_IMPL", address(0));
        if (bytes(Pad3LiveUpgrade.batchFile()).length != 0) {
            // the upgrade as the Safe signs it, with the listings the read-back expects
            Pad3LiveUpgrade.executeBatchFile(Pad3LiveUpgrade.batchFile(), M.OWNER_SAFE);
        } else {
            // not deployed yet: this build's implementation, made here over the live dependencies
            if (impl == address(0) && vm.envOr("PAD3_FORK_THIS_BUILD", false)) {
                GangLaunchpad3 cur = GangLaunchpad3(payable(PAD3));
                Pad3Impl.Deps memory d = Pad3Impl.depsOf(cur);
                (, Pad3Impl.FlyDeps memory f) = Pad3Impl.flyDepsOf(cur);
                impl = Pad3Impl.implWith(d, Pad3Impl.module(d, f));
            }
            if (impl != address(0)) {
                vm.prank(M.OWNER_SAFE);
                ProxyAdmin(R.adminOf(PAD3)).upgradeAndCall(ITransparentUpgradeableProxy(PAD3), impl, "");
                assertEq(R.implementationOf(PAD3), impl);
            }
        }

        if (!live) _guards();

        // 1. GangHandlerAdmin + buy-back factory; Safe batch 1 (takeover, allow, the two partners)
        DeployGangBuybackSplitterFactory bs = new DeployGangBuybackSplitterFactory();
        (GangHandlerAdmin admin, GangBuybackSplitterFactory buyback) = bs.run();
        assertEq(admin.owner(), M.OWNER_SAFE);
        bytes[] memory b1 = bs.pendingBatch(address(admin), address(buyback));
        if (live) {
            assertEq(b1.length, 0, "live: nothing left for the Safe");
        } else {
            assertEq(Ownable(handler).owner(), M.OWNER_SAFE, "the script sends nothing on mainnet");
            assertEq(b1.length, 3, "takeover (2) + allow");
            _execAsSafe(b1);
            vm.startPrank(M.OWNER_SAFE);
            admin.exec(abi.encodeCall(GangTaxHandler.list, (PARTNER_1, "partner 1")));
            admin.exec(abi.encodeCall(GangTaxHandler.list, (PARTNER_2, "partner 2")));
            vm.stopPrank();
        }
        assertEq(Ownable(handler).owner(), address(admin));
        assertTrue(GangTaxHandler(handler).isListed(PARTNER_1) && GangTaxHandler(handler).isListed(PARTNER_2));
        assertEq(bs.pendingBatch(address(admin), address(buyback)).length, 0);
        // 3.0's phase-2 read-back with admin3 holding the handler: self-check ok, only the cut-over left. Not in
        // the live mode: it runs without --libraries (the live factories' code check compares whole runtime code,
        // metadata included, and --libraries changes it), and the upgrade script reads phase 2 back itself.
        if (!live) {
            _env3();
            new DeployGangLaunchpad3().run();
        }

        // 2. Split / LP / Combo over the admin; Safe batch 2 (three setFactory)
        vm.setEnv("HANDLER_ADMIN", vm.toString(address(admin)));
        DeployGangSplitModuleFactory ss = new DeployGangSplitModuleFactory();
        DeployGangLiquiditySplitterFactory ls = new DeployGangLiquiditySplitterFactory();
        DeployGangComboSplitterFactory cs = new DeployGangComboSplitterFactory();
        GangSplitModuleFactory split = ss.run();
        GangLiquiditySplitterFactory lp = ls.run();
        GangComboSplitterFactory combo = cs.run();
        uint256 pending = ss.pendingBatch(address(admin), address(split)).length
            + ls.pendingBatch(address(admin), address(lp)).length
            + cs.pendingBatch(address(admin), address(combo)).length;
        assertEq(pending, live ? 0 : 3, "batch 2: three setFactory");
        _execAsSafe(ss.pendingBatch(address(admin), address(split)));
        _execAsSafe(ls.pendingBatch(address(admin), address(lp)));
        _execAsSafe(cs.pendingBatch(address(admin), address(combo)));
        assertTrue(
            admin.isFactory(address(buyback)) && admin.isFactory(address(split)) && admin.isFactory(address(lp))
                && admin.isFactory(address(combo))
        );
        if (!live) assertEq(admin.factories().length, 4);
        vm.setEnv("COMBO_FACTORY", vm.toString(address(combo)));
        cs.run(); // re-run with the deployed factory: checks pass, nothing left
        assertEq(cs.pendingBatch(address(admin), address(combo)).length, 0);

        // 3. GangBond
        GangBond bond = new DeployGangBond().run();
        assertEq(bond.pad(), PAD3);
        assertEq(buyback.pad(), PAD3);
        assertEq(split.pad(), PAD3);
        assertEq(lp.pad(), PAD3);
        assertEq(combo.pad(), PAD3);

        _useModules(buyback, split, lp, combo, bond, admin);
    }

    /// @dev Each module on a 3.0 token: cloned, named as the tax recipient, bound; a bond; the combo token's life.
    function _useModules(
        GangBuybackSplitterFactory buyback,
        GangSplitModuleFactory split,
        GangLiquiditySplitterFactory lp,
        GangComboSplitterFactory combo,
        GangBond bond,
        GangHandlerAdmin admin
    ) internal {
        vm.startPrank(dev, dev);
        GangBuybackSplitter mb = GangBuybackSplitter(buyback.create(5_000, keccak256("b"), dev));
        address[] memory p = new address[](2);
        (p[0], p[1]) = (dev, kol);
        uint16[] memory sh = new uint16[](2);
        (sh[0], sh[1]) = (7_000, 3_000);
        GangSplitModule ms = GangSplitModule(split.create(p, sh, keccak256("s")));
        GangLiquiditySplitter ml = GangLiquiditySplitter(lp.create(5_000, keccak256("l"), dev));
        GangComboSplitter mc = GangComboSplitter(combo.create(3_000, 3_000, p, sh, keccak256("c")));
        vm.stopPrank();
        assertEq(admin.moduleOf(address(mb)), address(buyback));
        assertEq(admin.moduleOf(address(mc)), address(combo));
        address tb = _createBound(address(mb), "B");
        _createBound(address(ms), "S");
        _createBound(address(ml), "L");
        address tc = _createBound(address(mc), "C");
        assertEq(mb.token(), tb);
        assertEq(mc.token(), tc);

        // a bond on a 3.0 token; the combo token's full life on 3.0
        _bond(bond, tb);
        this.runCombo(tc, mc);
    }

    // ---------------------------------------------------------------- pieces
    /// @dev GANG_PAD3 binds to 3.0 only; GANG_PAD2 never to 3.0; both set is refused.
    function _guards() internal {
        DeployGangBond s = new DeployGangBond();
        vm.setEnv("GANG_PAD3", vm.toString(PAD_1));
        vm.expectRevert(
            abi.encodeWithSelector(GangModulePadScript.ModulePad.selector, "GANG_PAD3 is not GangLaunchpad 3.0")
        );
        s.run();
        vm.setEnv("GANG_PAD3", vm.toString(PAD_2));
        vm.expectRevert(
            abi.encodeWithSelector(GangModulePadScript.ModulePad.selector, "GANG_PAD3 is not GangLaunchpad 3.0")
        );
        s.run();
        vm.setEnv("GANG_PAD3", vm.toString(PAD3));
        vm.setEnv("GANG_PAD2", vm.toString(PAD_2));
        vm.expectRevert(
            abi.encodeWithSelector(GangModulePadScript.ModulePad.selector, "set GANG_PAD3 or GANG_PAD2, not both")
        );
        s.run();
        vm.setEnv("GANG_PAD3", vm.toString(address(0)));
        vm.setEnv("GANG_PAD2", vm.toString(PAD3));
        vm.expectRevert(
            abi.encodeWithSelector(GangModulePadScript.ModulePad.selector, "GANG_PAD2 is not GangLaunchpad 2.0")
        );
        s.run();
        vm.setEnv("GANG_PAD2", vm.toString(VAULT_PAD));
        vm.expectRevert(
            abi.encodeWithSelector(GangModulePadScript.ModulePad.selector, "GANG_PAD2 is not GangLaunchpad 2.0")
        );
        s.run();
        vm.setEnv("GANG_PAD2", vm.toString(address(0)));
        vm.setEnv("GANG_PAD3", vm.toString(PAD3));
        // a leftover 2.0 admin in the shell: the factory scripts refuse it for 3.0's handler
        vm.setEnv("HANDLER_ADMIN", vm.toString(ADMIN_2));
        DeployGangSplitModuleFactory ss = new DeployGangSplitModuleFactory();
        vm.expectRevert(GangSplitModuleFactory.WrongHandler.selector); // the factory is refused at deployment
        ss.run();
        vm.stopBroadcast(); // the reverted deployment left the script's broadcast open
        vm.setEnv("HANDLER_ADMIN", vm.toString(address(0)));
    }

    function _createBound(address module, string memory sym) internal returns (address t) {
        vm.prank(dev, dev);
        t = IGangPad(PAD3)
            .create(
                sym,
                sym,
                "",
                "",
                M.WBNB,
                address(0),
                IGangLaunchpad.TaxConfig({buyTaxBps: 300, sellTaxBps: 300, dividendBps: 4000, recipient: module})
            );
        GangComboSplitter(module).bind(t); // same selector on all four
    }

    /// @dev The combo token graduates on 3.0, pool sells pay the tax, the keeper processes it, the module works.
    function runCombo(address t, GangComboSplitter m) external {
        bool graduated;
        address pair;
        for (uint256 i; i < 400 && !graduated; i++) {
            address b = address(uint160(0xD0000 + i));
            deal(M.WBNB, b, 2 ether);
            vm.startPrank(b, b);
            IERC20(M.WBNB).approve(PAD3, type(uint256).max);
            try IGangPad(PAD3).buy(t, 2 ether, 0) {} catch {}
            vm.stopPrank();
            (,,,,,, graduated,,,, pair,) = IGangPad(PAD3).curves(t);
        }
        assertTrue(graduated, "graduated on 3.0");
        for (uint256 i; i < 6; i++) {
            address seller = address(uint160(0xD0000 + i));
            _poolSell(t, pair, seller, IERC20(t).balanceOf(seller) / 20);
            vm.warp(vm.getBlockTimestamp() + 60);
            vm.roll(vm.getBlockNumber() + 2);
        }
        IPad3ForkHandler h = IPad3ForkHandler(IGangPad(PAD3).taxHandler());
        uint256 chunk = h.maxChunk(t);
        assertGt(IERC20(t).balanceOf(address(h)), 0, "pool sells taxed into the handler");
        vm.warp(vm.getBlockTimestamp() + 60);
        vm.roll(vm.getBlockNumber() + 2);
        vm.prank(h.keeper());
        h.process(t, chunk, 1);
        assertGt(IERC20(M.WBNB).balanceOf(address(m)), 0, "the handler paid the combo module");
        deal(M.WBNB, address(m), IERC20(M.WBNB).balanceOf(address(m)) + 0.5 ether);
        uint256 kol0 = IERC20(M.WBNB).balanceOf(kol);
        uint256 dead0 = IERC20(t).balanceOf(DEAD);
        uint256 burns;
        uint256 adds;
        for (uint256 i; i < 30; i++) {
            (bool due, uint256 minOut) = m.previewWork();
            if (due) {
                uint256 b0 = m.buybackLeft();
                uint256 l0 = m.lpLeft();
                m.work(minOut);
                if (m.buybackLeft() < b0) burns++;
                if (m.lpLeft() < l0) adds++;
            }
            vm.warp(vm.getBlockTimestamp() + 4 minutes);
            vm.roll(vm.getBlockNumber() + 1);
        }
        assertGt(burns, 0, "bought back");
        assertGt(adds, 0, "liquidity added");
        assertGt(IERC20(t).balanceOf(DEAD), dead0, "burned");
        assertGt(IERC20(M.WBNB).balanceOf(kol) + _owed(m, 1), kol0, "the KOL is paid");
    }

    function _owed(GangComboSplitter m, uint256 i) internal returns (uint256 got) {
        uint256 b0 = IERC20(M.WBNB).balanceOf(kol);
        try m.release(M.WBNB, i, type(uint256).max) {} catch {}
        got = IERC20(M.WBNB).balanceOf(kol) - b0;
    }

    function _bond(GangBond bond, address t) internal {
        vm.deal(dev, 2 ether);
        vm.prank(dev, dev);
        (bool ok,) = PAD3.call{value: 0.1 ether}(
            abi.encodeWithSignature("buyTokenAMAP(address,address,uint256,uint256)", t, dev, 0.1 ether, 0)
        );
        assertTrue(ok, "dev buys its token through the entry");
        uint256 hold = IERC20(t).balanceOf(dev);
        vm.prank(dev, dev);
        bond.post{value: 0.5 ether}(t, 0.5 ether, hold, 30 days);
        assertEq(bond.bondOf(t).creator, dev);
        assertEq(bond.bondOf(t).amount, 0.5 ether);
        assertEq(bond.bondOf(t).holdAmount, hold);
        assertFalse(bond.isViolated(t));
    }

    function _poolSell(address t, address pair, address seller, uint256 amount) internal {
        vm.startPrank(seller, seller);
        IERC20(t).transfer(pair, amount);
        IPad3ForkPair pr = IPad3ForkPair(pair);
        (uint112 r0, uint112 r1,) = pr.getReserves();
        bool t0 = pr.token0() == t;
        (uint256 rIn, uint256 rOut) = t0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 got = IERC20(t).balanceOf(pair) - rIn;
        uint256 out = (got * 9975 * rOut) / (rIn * 10_000 + got * 9975);
        if (t0) pr.swap(0, out, seller, "");
        else pr.swap(out, 0, seller, "");
        vm.stopPrank();
    }

    function _execAsSafe(bytes[] memory calls) internal {
        for (uint256 i; i < calls.length; i++) {
            (address to, bytes memory data) = this.cut(calls[i]);
            vm.prank(M.OWNER_SAFE);
            (bool ok, bytes memory ret) = to.call(data);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
    }

    /// @dev A printed batch call (to ‖ data) split.
    function cut(bytes calldata c) external pure returns (address, bytes memory) {
        return (address(bytes20(c[:20])), c[20:]);
    }

    function _envDefault(string memory name, address value) internal {
        if (vm.envOr(name, address(0)) == address(0)) vm.setEnv(name, vm.toString(value));
    }

    /// @dev DeployGangLaunchpad3 phase 2 on the live 3.0 (read-only; CUTOVER=false: nothing printed for batch 5).
    function _env3() internal {
        vm.setEnv("OWNER", vm.toString(M.OWNER_SAFE));
        vm.setEnv("KEEPER", vm.toString(M.KEEPER));
        vm.setEnv("GANG_GATEWAY", vm.toString(M.GANG_GATEWAY));
        vm.setEnv("GANG_PAD_REGISTRY", vm.toString(M.PAD_REGISTRY));
        vm.setEnv("GANG_ROUTER3", vm.toString(ROUTER3));
        vm.setEnv("PAD3_NEW", "false");
        // the three aggregator routers Safe batch 4 listed on 3.0 (isCaller); update when that list changes
        vm.setEnv(
            "CALLERS",
            "0x1de460f363AF910f51726DEf188F9004276Bf4bc,0xDB97fC3329Ed1939012D56ECeaef00Be1C0CdFF5,0x3508DcA95a64C9378Cb07eF6F40553A50905372a"
        );
        vm.setEnv("CALLER_CODEHASHES", "");
        vm.setEnv("CALLERS_PROXY_OK", "true");
        vm.setEnv("PAD3_LOG_SCAN", "false");
        vm.setEnv("CUTOVER", "false");
        vm.setEnv("ROUTER_TIMELOCK_DELAY", "172800");
        vm.setEnv("MAINNET_OWNER_IS_DEPLOYER", "false");
        vm.setEnv("KEEPER_OVERRIDE_OK", "false");
        vm.setEnv("FEE_VAULT", vm.toString(address(0)));
        vm.setEnv("BURNER", vm.toString(address(0)));
        vm.setEnv("RECIPIENT", vm.toString(address(0)));
        vm.setEnv("TWAP_WINDOW", vm.toString(uint256(IGangPad(PAD_1).twapWindow())));
    }

    /// @dev `live`: the module set's addresses come from the shell (checked by the scripts; default: the mainnet set,
    ///      docs/MAINNET-GANG-LAUNCHPAD-3-MODULES-2026-11-03.md), else all deployed here.
    function _env(uint256 pk, bool live) internal {
        if (live) {
            _envDefault("HANDLER_ADMIN", LIVE_ADMIN);
            _envDefault("SPLITTER_FACTORY", LIVE_BUYBACK);
            _envDefault("SPLIT_FACTORY", LIVE_SPLIT);
            _envDefault("LP_FACTORY", LIVE_LP);
            _envDefault("COMBO_FACTORY", LIVE_COMBO);
            _envDefault("GANG_BOND", LIVE_BOND);
        }
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(pk));
        vm.setEnv("GANG_PAD3", vm.toString(PAD3));
        vm.setEnv("GANG_PAD2", vm.toString(address(0)));
        vm.setEnv("GANG_PAD", vm.toString(PAD_1));
        if (!live) {
            vm.setEnv("HANDLER_ADMIN", vm.toString(address(0)));
            vm.setEnv("SPLITTER_FACTORY", vm.toString(address(0)));
            vm.setEnv("SPLIT_FACTORY", vm.toString(address(0)));
            vm.setEnv("LP_FACTORY", vm.toString(address(0)));
            vm.setEnv("COMBO_FACTORY", vm.toString(address(0)));
            vm.setEnv("GANG_BOND", vm.toString(address(0)));
        }
        vm.setEnv("ADMIN_OWNER", vm.toString(address(0)));
        vm.setEnv("GANG_QUOTE", vm.toString(GANG));
    }
}
