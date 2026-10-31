// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {DeployGang} from "../../script/DeployGang.s.sol";
import {DeployGangBond} from "../../script/DeployGangBond.s.sol";
import {DeployGangBuybackSplitterFactory} from "../../script/DeployGangBuybackSplitterFactory.s.sol";
import {DeployGangComboSplitterFactory} from "../../script/DeployGangComboSplitterFactory.s.sol";
import {DeployGangSplitModuleFactory} from "../../script/DeployGangSplitModuleFactory.s.sol";
import {GangModulePadScript} from "../../script/GangModulePadScript.sol";
import {GangMainnetRefs as M} from "../../config/GangDeployRefs.sol";
import {SharedPlatformFeeBucket} from "../../src/common/SharedPlatformFeeBucket.sol";
import {GangPadRegistry} from "../../src/gang/GangPadRegistry.sol";
import {GangHandlerAdmin} from "../../src/gang/GangHandlerAdmin.sol";
import {GangBond} from "../../src/gang/GangBond.sol";
import {GangComboSplitter} from "../../src/gang/GangComboSplitter.sol";
import {GangComboSplitterFactory} from "../../src/gang/GangComboSplitterFactory.sol";
import {IGangPad} from "../../src/gang/interfaces/IGangPad.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {DeployGangLaunchpad2Harness} from "./GangLaunchpad2DeployFork.t.sol";

/// @notice The 2026-10-31 full audit's deployment findings, on a BSC mainnet fork (BSC_RPC_URL; skipped without it):
///         - L-1: a pad the deploy key didn't make, or no longer owns, never reaches Safe batch 1;
///         - L-2: the buy-back script refuses a handler whose hand-over is half done, and an admin owner that isn't
///           the Safe;
///         - L-3: the module scripts bind only to 2.0 on mainnet (GANG_PAD2), never to a leftover GANG_PAD = 1.0;
///         - info-1: phase 2 still checks out (and prints batch 3) once a GangHandlerAdmin of the Safe holds the
///           handler;
///         - info-5: a pending bucket keeper change stops phase 1;
///         - the combo factory (main's combo-v1): its script binds only to 2.0 as well, deploys over the Safe's admin2,
///           and a combined recipient works on a 2.0 token at a picked 6 BNB target.
/// @dev Sets process-wide env: run alone (`--match-path`), not with the other fork suites.
contract GangLaunchpad2DeployGuardsForkTest is Test {
    address constant PAD_1 = 0x15CFD2dc8278Fb87a1783ef42111618E20874365;
    address constant GATEWAY = 0x9dD16b73f624bdd8a210CBB2602FdF70f1B450B8;
    address constant SAFE = 0x2866369F7acEFC9760bdE7779362fae5cD68B41E;
    address constant GANG = 0x0c6302401aa5325C2E36F170f52C00B1d220B405;

    DeployGangLaunchpad2Harness d;
    uint256 pk;
    address me;

    function _setUp() internal returns (bool) {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return false;
        vm.createSelectFork(rpc);
        pk = uint256(keccak256("deploy guards throwaway"));
        me = vm.addr(pk);
        vm.deal(me, 10 ether);
        _resetEnv();
        d = new DeployGangLaunchpad2Harness();
        return true;
    }

    function _resetEnv() internal {
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(pk));
        vm.setEnv("GANG_PAD", vm.toString(PAD_1));
        vm.setEnv("OWNER", vm.toString(SAFE));
        vm.setEnv("KEEPER", vm.toString(M.KEEPER));
        vm.setEnv("GANG_GATEWAY", vm.toString(GATEWAY));
        vm.setEnv("GANG_PAD_REGISTRY", vm.toString(M.PAD_REGISTRY));
        vm.setEnv("GANG_PAD2", vm.toString(address(0)));
        vm.setEnv("GANG_ROUTER2", vm.toString(address(0)));
        vm.setEnv("ROUTER_TIMELOCK_DELAY", "172800");
        vm.setEnv("MAINNET_OWNER_IS_DEPLOYER", "false");
        vm.setEnv("KEEPER_OVERRIDE_OK", "false");
        vm.setEnv("FEE_VAULT", vm.toString(address(0)));
        vm.setEnv("BURNER", vm.toString(address(0)));
        vm.setEnv("RECIPIENT", vm.toString(address(0)));
        vm.setEnv("TWAP_WINDOW", vm.toString(uint256(IGangPad(PAD_1).twapWindow())));
        vm.setEnv("HANDLER_ADMIN", vm.toString(address(0)));
        vm.setEnv("SPLITTER_FACTORY", vm.toString(address(0)));
        vm.setEnv("ADMIN_OWNER", vm.toString(address(0)));
        vm.setEnv("GANG_BOND", vm.toString(address(0)));
        vm.setEnv("COMBO_FACTORY", vm.toString(address(0)));
        vm.setEnv("GANG_QUOTE", vm.toString(GANG));
    }

    function _exec(string memory json) internal {
        for (uint256 i;; i++) {
            string memory k = string.concat(".transactions[", vm.toString(i), "]");
            if (!vm.keyExistsJson(json, k)) break;
            vm.prank(SAFE);
            (bool ok, bytes memory ret) = vm.parseJsonAddress(json, string.concat(k, ".to"))
                .call(vm.parseJsonBytes(json, string.concat(k, ".data")));
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
    }

    function _phase2Env(DeployGang.Stack memory s) internal {
        vm.setEnv("GANG_PAD2", vm.toString(s.pad));
        vm.setEnv("GANG_ROUTER2", vm.toString(s.router));
    }

    /// @dev phase 1 → batch 1 → phase 2 → batch 2: 2.0 open, the Safe owning pad and handler.
    function _fullDeploy() internal returns (DeployGang.Stack memory s) {
        s = d.run();
        _exec(d.wiringJson(s, PAD_1, SAFE));
        _phase2Env(s);
        d.run();
        _exec(d.acceptJson(s, SAFE));
    }

    /// @dev One test: the cases set process-wide env, so they run in sequence (each on a fresh copy of the fork state
    ///      and env) instead of as parallel tests.
    function test_fork_deployGuards() public {
        if (!_setUp()) return;
        uint256 snap = vm.snapshotState();
        _foreignPad_refusedBeforeBatch1();
        vm.revertToState(snap);
        _resetEnv();
        _lookalikeOwnedByMe_refusedBeforeBatch1();
        vm.revertToState(snap);
        _resetEnv();
        _ownPadHandoverStarted_refusedBeforeBatch1();
        vm.revertToState(snap);
        _resetEnv();
        _adminHoldsHandler_phase2StillChecksOut();
        vm.revertToState(snap);
        _resetEnv();
        _pendingBucketKeeper_refused();
        vm.revertToState(snap);
        _resetEnv();
        _buyback_refusesUnsettledHandlerAndForeignAdminOwner();
        vm.revertToState(snap);
        _resetEnv();
        _moduleScripts_bindOnlyTo20();
        vm.revertToState(snap);
        _resetEnv();
        _combo_on20();
        vm.revertToState(snap);
        _resetEnv();
        _adminHandoverPending_refused();
    }

    // ---------------------------------------------------------------- L-1
    function _foreignPad_refusedBeforeBatch1() internal {
        uint256 other = uint256(keccak256("deploy guards someone else"));
        vm.deal(vm.addr(other), 10 ether);
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(other));
        DeployGang.Stack memory f = d.run(); // someone else's phase 1, same code
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(pk));
        _phase2Env(f);
        vm.expectRevert(abi.encodeWithSelector(DeployGang.WiringCheck.selector, "2.0 not the deployer's own"));
        d.run();
        assertFalse(GangPadRegistry(M.PAD_REGISTRY).isPad(f.pad), "nothing listed");
    }

    /// @dev A look-alike handed to us: same code, now owned by our key, but deployed by another: refused.
    function _lookalikeOwnedByMe_refusedBeforeBatch1() internal {
        uint256 other = uint256(keccak256("deploy guards look-alike"));
        vm.deal(vm.addr(other), 10 ether);
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(other));
        DeployGang.Stack memory f = d.run();
        vm.startPrank(vm.addr(other));
        Ownable2Step(f.pad).transferOwnership(me);
        Ownable2Step(f.handler).transferOwnership(me);
        vm.stopPrank();
        vm.startPrank(me);
        Ownable2Step(f.pad).acceptOwnership();
        Ownable2Step(f.handler).acceptOwnership();
        vm.stopPrank();
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(pk));
        _phase2Env(f);
        vm.expectRevert(abi.encodeWithSelector(DeployGang.WiringCheck.selector, "2.0 not deployed by this deployer"));
        d.run();
    }

    /// @dev Our own pad, but its hand-over already started before batch 1: refused too.
    function _ownPadHandoverStarted_refusedBeforeBatch1() internal {
        DeployGang.Stack memory s = d.run();
        vm.prank(me);
        Ownable2Step(s.pad).transferOwnership(address(0xBEEF));
        _phase2Env(s);
        vm.expectRevert(abi.encodeWithSelector(DeployGang.WiringCheck.selector, "2.0 not the deployer's own"));
        d.run();
    }

    // ---------------------------------------------------------------- info-1
    function _adminHoldsHandler_phase2StillChecksOut() internal {
        DeployGang.Stack memory s = _fullDeploy();
        GangHandlerAdmin admin = new GangHandlerAdmin(SAFE, s.handler);
        vm.prank(SAFE);
        Ownable2Step(s.handler).transferOwnership(address(admin));
        vm.prank(SAFE);
        admin.exec(abi.encodeWithSignature("acceptOwnership()"));
        d.run(); // self-check ok, batch 3 printed
        // an admin the Safe doesn't own is still refused
        GangHandlerAdmin foreign = new GangHandlerAdmin(address(0xBEEF), s.handler);
        vm.prank(SAFE);
        admin.exec(abi.encodeWithSignature("transferOwnership(address)", address(foreign)));
        vm.prank(address(0xBEEF));
        foreign.exec(abi.encodeWithSignature("acceptOwnership()"));
        vm.expectRevert(abi.encodeWithSelector(DeployGang.WiringCheck.selector, "owner / pendingOwner"));
        d.run();
    }

    /// @dev The Safe's admin starts handing the handler on: no longer settled, refused (the hand-over step of phase 2
    ///      stops it before the self-check). Last case: the refused run leaves its broadcast open.
    function _adminHandoverPending_refused() internal {
        DeployGang.Stack memory s = _fullDeploy();
        GangHandlerAdmin admin = new GangHandlerAdmin(SAFE, s.handler);
        vm.prank(SAFE);
        Ownable2Step(s.handler).transferOwnership(address(admin));
        vm.prank(SAFE);
        admin.exec(abi.encodeWithSignature("acceptOwnership()"));
        vm.prank(SAFE);
        admin.exec(abi.encodeWithSignature("transferOwnership(address)", address(0xCAFE)));
        vm.expectRevert(abi.encodeWithSelector(DeployGang.PendingOwnerMismatch.selector, s.handler));
        d.run();
    }

    // ---------------------------------------------------------------- info-5
    function _pendingBucketKeeper_refused() internal {
        SharedPlatformFeeBucket b = SharedPlatformFeeBucket(IGangPad(PAD_1).platformBucket());
        vm.prank(SAFE);
        b.proposeKeeper(address(0xBEEF));
        vm.expectRevert(abi.encodeWithSelector(DeployGang.WiringCheck.selector, "bucket keeper change pending"));
        d.run();
    }

    // ---------------------------------------------------------------- L-2
    function _buyback_refusesUnsettledHandlerAndForeignAdminOwner() internal {
        DeployGang.Stack memory s = d.run();
        _exec(d.wiringJson(s, PAD_1, SAFE));
        _phase2Env(s);
        d.run(); // hand-over started: the deployer still owns pad and handler
        DeployGangBuybackSplitterFactory b = new DeployGangBuybackSplitterFactory();
        vm.expectRevert(abi.encodeWithSelector(GangModulePadScript.ModulePad.selector, "pad not owned by the Safe"));
        b.run();

        _exec(d.acceptJson(s, SAFE)); // the Safe owns both now
        vm.prank(SAFE);
        Ownable2Step(s.handler).transferOwnership(address(0xBEEF)); // a hand-over half done
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployGangBuybackSplitterFactory.WiringCheck.selector, "handler not settled with the Safe"
            )
        );
        b.run();
        vm.prank(SAFE);
        Ownable2Step(s.handler).transferOwnership(SAFE); // pending back to the owner itself: nothing pending to anyone else
        vm.prank(SAFE);
        Ownable2Step(s.handler).acceptOwnership();

        vm.setEnv("ADMIN_OWNER", vm.toString(me));
        vm.expectRevert(
            abi.encodeWithSelector(
                DeployGangBuybackSplitterFactory.WiringCheck.selector, "ADMIN_OWNER must be the Safe on mainnet"
            )
        );
        b.run();

        vm.setEnv("ADMIN_OWNER", vm.toString(address(0)));
        (GangHandlerAdmin admin,) = b.run(); // settled: admin owned by the Safe, batch printed for the Safe
        assertEq(admin.owner(), SAFE);
        assertEq(Ownable(s.handler).owner(), SAFE, "the script sends nothing on mainnet");
    }

    // ---------------------------------------------------------------- L-3
    function _moduleScripts_bindOnlyTo20() internal {
        DeployGangBond bondScript = new DeployGangBond();
        DeployGangSplitModuleFactory split = new DeployGangSplitModuleFactory();

        // the 2.0 deploy shell: GANG_PAD = 1.0, GANG_PAD2 unset → nothing is bound to 1.0
        vm.setEnv("GANG_PAD2", vm.toString(address(0)));
        vm.expectRevert(
            abi.encodeWithSelector(GangModulePadScript.ModulePad.selector, "GANG_PAD2 is not GangLaunchpad 2.0")
        );
        bondScript.run();
        vm.setEnv("GANG_PAD2", vm.toString(PAD_1));
        vm.expectRevert(
            abi.encodeWithSelector(GangModulePadScript.ModulePad.selector, "GANG_PAD2 is not GangLaunchpad 2.0")
        );
        bondScript.run();
        vm.expectRevert(
            abi.encodeWithSelector(GangModulePadScript.ModulePad.selector, "GANG_PAD2 is not GangLaunchpad 2.0")
        );
        split.run();

        // a 2.0 the Safe doesn't own / that isn't registered
        vm.setEnv("GANG_PAD2", vm.toString(address(0)));
        DeployGang.Stack memory s = d.run(); // phase 1 only: not registered yet
        vm.setEnv("GANG_PAD2", vm.toString(s.pad));
        vm.expectRevert(abi.encodeWithSelector(GangModulePadScript.ModulePad.selector, "pad not in the registry"));
        bondScript.run();

        _exec(d.wiringJson(s, PAD_1, SAFE));
        _phase2Env(s);
        d.run();
        _exec(d.acceptJson(s, SAFE));
        GangBond bond = bondScript.run();
        assertEq(bond.pad(), s.pad, "bound to 2.0");
    }

    // ---------------------------------------------------------------- combo-v1 on 2.0
    /// @dev Runbook step 6 with the combo factory: refused on 1.0; on 2.0, the buy-back script's Safe-owned admin2
    ///      takes the handler, the combo script deploys over it and prints the Safe's setFactory; then a dev clones
    ///      a combined recipient (30% buy-back, 30% liquidity, the rest 70 / 30 to itself and a KOL) for a 6 BNB
    ///      token, which graduates at 6 BNB; pool sells pay the tax and the keeper's loop burns, adds LP and pays.
    function _combo_on20() internal {
        DeployGangComboSplitterFactory combo = new DeployGangComboSplitterFactory();
        vm.setEnv("GANG_PAD2", vm.toString(PAD_1));
        vm.setEnv("HANDLER_ADMIN", vm.toString(address(0xBEEF)));
        vm.expectRevert(
            abi.encodeWithSelector(GangModulePadScript.ModulePad.selector, "GANG_PAD2 is not GangLaunchpad 2.0")
        );
        combo.run();

        vm.setEnv("GANG_PAD2", vm.toString(address(0)));
        vm.setEnv("HANDLER_ADMIN", vm.toString(address(0)));
        DeployGang.Stack memory s = _fullDeploy();
        (GangHandlerAdmin admin,) = new DeployGangBuybackSplitterFactory().run();
        vm.prank(SAFE);
        Ownable2Step(s.handler).transferOwnership(address(admin));
        vm.prank(SAFE);
        admin.exec(abi.encodeWithSignature("acceptOwnership()"));

        vm.setEnv("HANDLER_ADMIN", vm.toString(address(admin)));
        GangComboSplitterFactory f = combo.run();
        assertEq(f.pad(), s.pad, "bound to 2.0");
        assertEq(f.admin(), address(admin));
        bytes[] memory batch = combo.pendingBatch(address(admin), address(f));
        assertEq(batch.length, 1, "one Safe call: setFactory");
        vm.prank(SAFE);
        admin.setFactory(address(f), true);
        assertEq(combo.pendingBatch(address(admin), address(f)).length, 0);
        vm.setEnv("COMBO_FACTORY", vm.toString(address(f)));
        combo.run(); // re-check of the deployed factory: nothing left

        vm.mockCall(M.AGENT_ID_REGISTRY, abi.encodeWithSelector(IERC721.balanceOf.selector), abi.encode(uint256(1)));
        IGangPad p = IGangPad(s.pad);
        address dev = makeAddr("combo2-dev");
        address kol = makeAddr("combo2-kol");
        address[] memory payees = new address[](2);
        (payees[0], payees[1]) = (dev, kol);
        uint16[] memory shares = new uint16[](2);
        (shares[0], shares[1]) = (7_000, 3_000);
        vm.prank(dev, dev);
        GangComboSplitter m = GangComboSplitter(f.create(3_000, 3_000, payees, shares, keccak256("combo2")));
        vm.prank(dev, dev);
        address t = p.createWithGradTarget(
            "Combo two",
            "CMB2",
            "",
            "",
            M.WBNB,
            address(0),
            IGangLaunchpad.TaxConfig({buyTaxBps: 300, sellTaxBps: 300, dividendBps: 4000, recipient: address(m)}),
            6 ether
        );
        m.bind(t);
        assertEq(p.gradAmtOf(t), 6 ether);

        // the wallet cap off so one buyer graduates it (fewer fresh accounts for the fork to fetch)
        vm.prank(SAFE);
        p.setWalletCapEnabled(false);
        address b = makeAddr("combo2-buyer");
        deal(M.WBNB, b, 8 ether);
        vm.prank(b, b);
        IERC20(M.WBNB).approve(s.pad, type(uint256).max);
        bool graduated;
        address pair;
        for (uint256 i; i < 20 && !graduated; i++) {
            vm.prank(b, b);
            p.buy(t, 0.5 ether, 0);
            (,,,,,, graduated,,,, pair,) = p.curves(t);
        }
        assertTrue(graduated && pair != address(0), "graduated");
        assertApproxEqAbs(IERC20(M.WBNB).balanceOf(pair), 6 ether, 1, "at its 6 BNB target");

        for (uint256 i; i < 6; i++) {
            _poolSell(t, pair, b, IERC20(t).balanceOf(b) / 4);
            vm.warp(block.timestamp + 60);
            vm.roll(block.number + 2);
        }
        IComboHandler2 h = IComboHandler2(s.handler);
        uint256 mc = h.maxChunk(t);
        vm.warp(block.timestamp + 60);
        vm.roll(block.number + 2);
        vm.prank(h.keeper());
        if (mc != 0) h.process(t, mc, 1);
        assertGt(IERC20(M.WBNB).balanceOf(address(m)), 0, "the pool tax reached the combined recipient");
        deal(M.WBNB, address(m), IERC20(M.WBNB).balanceOf(address(m)) + 0.5 ether); // a backlog worth both parts

        uint256 kol0 = IERC20(M.WBNB).balanceOf(kol);
        uint256 dead0 = IERC20(t).balanceOf(DEAD);
        uint256 deadLp0 = IERC20(pair).balanceOf(DEAD);
        for (uint256 i; i < 30; i++) {
            (bool due, uint256 minOut) = m.previewWork();
            if (due) m.work(minOut);
            vm.warp(block.timestamp + 4 minutes);
            vm.roll(block.number + 1);
        }
        assertGt(IERC20(t).balanceOf(DEAD), dead0, "bought back and burned");
        assertGt(IERC20(pair).balanceOf(DEAD), deadLp0, "Pancake LP added to 0xdead");
        assertGt(IERC20(M.WBNB).balanceOf(kol), kol0, "the KOL paid");
        assertEq(IERC20(t).balanceOf(address(m)), 0, "holds no token");
    }

    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    function _poolSell(address t, address pair, address who, uint256 amount) internal {
        if (amount == 0) return;
        bool tIs0 = IComboPair2(pair).token0() == t;
        vm.prank(who, who);
        IERC20(t).transfer(pair, amount);
        (uint112 r0, uint112 r1,) = IComboPair2(pair).getReserves();
        (uint256 rT, uint256 rQ) = tIs0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 inT = IERC20(t).balanceOf(pair) - rT;
        uint256 out = (inT * 9975 * rQ) / (rT * 10_000 + inT * 9975);
        vm.prank(who, who);
        if (tIs0) IComboPair2(pair).swap(0, out, who, "");
        else IComboPair2(pair).swap(out, 0, who, "");
    }
}

interface IComboPair2 {
    function token0() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IComboHandler2 {
    function maxChunk(address token) external view returns (uint256);
    function process(address token, uint256 amount, uint256 minQuoteOut) external returns (uint256);
    function keeper() external view returns (address);
}
