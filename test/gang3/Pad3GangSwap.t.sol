// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GangFixture} from "../utils/GangFixture.sol";
import {GangLaunchpad} from "../../src/gang/GangLaunchpad.sol";
import {UpgradeGangLaunchpad3} from "../../script/UpgradeGangLaunchpad3.s.sol";
import {Pad3VanitySalt} from "../../script/Pad3VanitySalt.sol";
import {DeployGang} from "../../script/DeployGang.s.sol";
import {GangLaunchpad3} from "../../src/gang/GangLaunchpad3.sol";
import {Pad3Module} from "../../src/gang/Pad3Module.sol";
import {Pad3GangSwapStore} from "../../src/gang/Pad3GangSwapStore.sol";
import {Pad3VanityDeployer} from "../../src/gang/Pad3VanityDeployer.sol";
import {GangBond} from "../../src/gang/GangBond.sol";
import {IGangBond} from "../../src/gang/interfaces/IGangBond.sol";
import {GangPadRegistry} from "../../src/gang/GangPadRegistry.sol";
import {Vm} from "forge-std/Vm.sol";
import {GangGateway} from "../../src/router/GangGateway.sol";
import {GangRouter} from "../../src/router/GangRouter.sol";
import {GangGatewayDeployLib as G} from "../../script/GangGatewayDeployLib.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {IGangLaunchpad3} from "../../src/gang/interfaces/IGangLaunchpad3.sol";
import {IGangSwapPad} from "../../src/gang/interfaces/IGangSwapPad.sol";
import {IGangPromote} from "../../src/gang/interfaces/IGangPromote.sol";
import {IGangAgentWindow} from "../../src/gang/interfaces/IGangAgentWindow.sol";

/// @dev The GangSwap core as this suite sees it (the core lives in gangswap/, another compiler project: deployed here
///      from its artifacts, never imported).
interface IGSMigrator {
    function addLaunchpad(address launchpad) external;
    function launchpads(address pad) external view returns (bool);
    function padOf(address pair) external view returns (address);
    function quote() external view returns (address);
}

contract GangSwapUpgradeHarness is UpgradeGangLaunchpad3 {
    function snap(GangLaunchpad3 p, Stack memory s) external view returns (Snapshot memory) {
        return _snapshot(p, s, true, new bool[](0));
    }

    function compare(Snapshot memory a, Snapshot memory b) external pure {
        _compare(a, b);
    }

    function state(GangLaunchpad3 p) external view returns (bytes memory) {
        return _gangSwapState(p);
    }

    function check(GangLaunchpad3 p) external view {
        _checkGangSwap(p);
    }

    function window(GangLaunchpad3 p) external view returns (bool served, bytes memory st) {
        return _agentWindowState(p);
    }

    function checkWindow(GangLaunchpad3 p, bool servedBefore, bytes memory before) external view {
        _checkAgentWindow(p, servedBefore, before);
    }
}

interface IGSFactory {
    function getPair(address a, address b) external view returns (address);
    function allPairsLength() external view returns (uint256);
}

interface IGSPair {
    function getReserves() external view returns (uint112, uint112, uint32);
    function quoteIs0() external view returns (bool);
    function virtualReserve() external view returns (uint256);
    function realQuoteReserve() external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
}

/// @notice docs/SPEC-GANGSWAP-2026-11-22.md §4, §5, D2, D3, D11: the GangSwap curve token (kindOf 4) on GangLaunchpad
///         3.0, graduating through the real GangSwapMigrator (gangswap/ artifacts: run `forge build --root gangswap`).
contract Pad3GangSwapTest is GangFixture {
    uint8 internal constant KIND_GS = 4;
    uint8 internal constant STATUS_CURVE = 1;
    uint8 internal constant STATUS_POOL = 2;
    uint8 internal constant STATUS_GANGSWAP = 4;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    Pad3Module internal m;
    GangLaunchpad3 internal p;
    address internal creator;

    IGSMigrator internal gsMigrator;
    address internal gsBoost;
    address internal gsFees;
    IGSFactory internal gsFactory;

    function _newPad() internal override returns (GangLaunchpad) {
        return _newPad3();
    }

    function setUp() public {
        _deployGang(makeAddr("keeper"));
        m = Pad3Module(payable(address(pad)));
        p = GangLaunchpad3(payable(address(pad)));
        (gsMigrator, gsBoost, gsFees, gsFactory) = _deployGangSwap(true);
        creator = _newAgent();
    }

    /// @dev gangswap/test/GangSwap.t.sol `_deploy`: migrator, boost, fees, factory at predicted addresses (they point at
    ///      each other; `addLaunchpad` checks it).
    function _deployGangSwap(bool listPad)
        internal
        returns (IGSMigrator mig, address boost, address fees, IGSFactory factory)
    {
        uint256 n = vm.getNonce(address(this));
        address mAddr = vm.computeCreateAddress(address(this), n);
        address bAddr = vm.computeCreateAddress(address(this), n + 1);
        address fAddr = vm.computeCreateAddress(address(this), n + 2);
        address facAddr = vm.computeCreateAddress(address(this), n + 3);
        mig = IGSMigrator(
            deployCode(
                "gangswap/out/GangSwapMigrator.sol/GangSwapMigrator.json",
                abi.encode(address(this), facAddr, bAddr, address(wbnb))
            )
        );
        boost = deployCode("gangswap/out/GangSwapBoost.sol/GangSwapBoost.json", abi.encode(mAddr, address(wbnb)));
        fees = deployCode(
            "gangswap/out/GangSwapFees.sol/GangSwapFees.json",
            abi.encode(facAddr, mAddr, address(bucket), address(wbnb))
        );
        factory = IGSFactory(deployCode("gangswap/out/GangSwapPair.sol/GangSwapFactory.json", abi.encode(mAddr, fAddr)));
        assertEq(address(mig), mAddr);
        assertEq(boost, bAddr);
        assertEq(fees, fAddr);
        assertEq(address(factory), facAddr);
        if (listPad) mig.addLaunchpad(address(pad));
        vm.prank(owner);
        bucket.setOperator(fees, true);
    }

    function _open() internal {
        vm.prank(owner);
        m.setGangSwapMigrator(address(gsMigrator));
    }

    function _createGS(address who, uint256 gradBnb) internal returns (address t) {
        address gs = m.gangSwapMigrator();
        vm.prank(who);
        t = m.createGangSwap("Swap", "GSW", "logo", "meta", gradBnb, gs);
    }

    function _createCurve(address who) internal returns (address t) {
        vm.prank(who);
        t = pad.createWithGradTarget(
            "Curve", "CRV", "logo", "meta", address(wbnb), address(0), _tax(0, 0, 0, address(0)), 9 ether
        );
    }

    function _info(address t) internal view returns (uint8 s, address q, address pr, uint256 fee, uint256 left) {
        return p.getTokenInfo(t);
    }

    // ---------------------------------------------------------------- storage and admin
    function test_namespace() public pure {
        assertEq(
            Pad3GangSwapStore.SLOT,
            keccak256(abi.encode(uint256(keccak256("gang.pad3.gangswap")) - 1)) & ~bytes32(uint256(0xff))
        );
        assertEq(Pad3GangSwapStore.KIND, KIND_GS);
    }

    /// @dev migrator at SLOT, tokenMigrator at SLOT+1.
    function test_layoutPinned() public {
        _open();
        address t = _createGS(creator, 9 ether);
        bytes32 s = Pad3GangSwapStore.SLOT;
        assertEq(address(uint160(uint256(vm.load(address(pad), s)))), address(gsMigrator));
        assertEq(
            address(uint160(uint256(vm.load(address(pad), keccak256(abi.encode(t, uint256(s) + 1)))))),
            address(gsMigrator)
        );
        assertEq(m.gangSwapMigratorOf(t), address(gsMigrator));
        address c = _createCurve(creator);
        assertEq(uint256(vm.load(address(pad), keccak256(abi.encode(c, uint256(s) + 1)))), 0);
    }

    function test_setGangSwapMigrator_checks() public {
        assertEq(m.gangSwapMigrator(), address(0));
        // closed until set
        vm.prank(creator);
        vm.expectRevert(IGangSwapPad.GangSwapNotOpen.selector);
        m.createGangSwap("Swap", "GSW", "logo", "meta", 9 ether, address(gsMigrator));

        vm.prank(creator);
        vm.expectRevert();
        m.setGangSwapMigrator(address(gsMigrator));

        (IGSMigrator unlisted,,,) = _deployGangSwap(false);
        vm.startPrank(owner);
        vm.expectRevert(IGangSwapPad.WrongGangSwapMigrator.selector);
        m.setGangSwapMigrator(address(unlisted)); // does not list this pad
        vm.expectRevert(IGangSwapPad.WrongGangSwapMigrator.selector);
        m.setGangSwapMigrator(address(migrator)); // the Pancake SharedMigrator lists the pad but is not GangSwap's
        vm.expectRevert(IGangSwapPad.WrongGangSwapMigrator.selector);
        m.setGangSwapMigrator(makeAddr("eoa"));
        // answers launchpads(pad) and quote() but its factory / boost / fees are not its own (review 4 #1)
        address stray = address(new StrayMigrator(address(wbnb), false));
        vm.expectRevert(IGangSwapPad.WrongGangSwapMigrator.selector);
        m.setGangSwapMigrator(stray);
        // everything right but the quote
        stray = address(new StrayMigrator(makeAddr("otherQuote"), true));
        vm.expectRevert(IGangSwapPad.WrongGangSwapMigrator.selector);
        m.setGangSwapMigrator(stray);

        vm.expectEmit(address(pad));
        emit IGangSwapPad.GangSwapMigratorSet(address(gsMigrator));
        m.setGangSwapMigrator(address(gsMigrator));
        assertEq(m.gangSwapMigrator(), address(gsMigrator));

        vm.stopPrank();
        // Config.migrator untouched
        assertEq(address(p.migrator()), address(migrator));
    }

    /// @dev A new version serves new tokens only: one created before keeps its migrator, before and after graduation.
    function test_newVersion_onlyNewTokens() public {
        _open();
        address t1 = _createGS(creator, 6 ether);
        (IGSMigrator v2,,, IGSFactory factory2) = _deployGangSwap(true);
        vm.prank(creator);
        vm.expectRevert();
        m.setGangSwapMigrator(address(v2));
        vm.prank(owner);
        m.setGangSwapMigrator(address(v2));
        vm.expectEmit(false, true, false, false, address(pad));
        emit IGangSwapPad.GangSwapCreated(address(0), address(v2));
        address t2 = _createGS(creator, 6 ether);
        assertEq(m.gangSwapMigrator(), address(v2));
        assertEq(m.gangSwapMigratorOf(t1), address(gsMigrator));
        assertEq(m.gangSwapMigratorOf(t2), address(v2));
        // the version a creator saw is the one it gets, or nothing
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IGangSwapPad.GangSwapVersionChanged.selector, address(v2)));
        m.createGangSwap("Swap", "GSW", "logo", "meta", 9 ether, address(gsMigrator));
        // 0 is no wildcard
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IGangSwapPad.GangSwapVersionChanged.selector, address(v2)));
        m.createGangSwap("Swap", "GSW", "logo", "meta", 9 ether, address(0));
        // v1's token graduates through v1 while v2 is the current version
        _graduate(t1);
        (,, address p1,,) = _info(t1);
        assertEq(gsFactory.getPair(t1, address(wbnb)), p1);

        // closed: no new token, the old ones still trade and graduate through their own version
        vm.prank(owner);
        m.setGangSwapMigrator(address(0));
        vm.prank(creator);
        vm.expectRevert(IGangSwapPad.GangSwapNotOpen.selector);
        m.createGangSwap("Swap", "GSW", "logo", "meta", 9 ether, address(gsMigrator));
        _graduate(t2);
        (uint8 s1,,,,) = _info(t1);
        (uint8 s2,, address p2,,) = _info(t2);
        assertEq(s1, 4);
        assertEq(s2, 4);
        assertEq(gsFactory.getPair(t1, address(wbnb)), p1);
        assertEq(factory2.getPair(t2, address(wbnb)), p2);
        assertEq(factory2.getPair(t1, address(wbnb)), address(0));
        assertEq(gsMigrator.padOf(p1), address(pad));
        assertEq(v2.padOf(p2), address(pad));
        assertEq(m.gangSwapMigratorOf(t1), address(gsMigrator));
        // a kind-1 token has none
        assertEq(m.gangSwapMigratorOf(_createCurve(creator)), address(0));
    }

    // ---------------------------------------------------------------- create
    function _lastGangSwapCreated(address t) internal returns (bool found) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics.length == 3 && logs[i].topics[0] == IGangSwapPad.GangSwapCreated.selector) {
                found = found || address(uint160(uint256(logs[i].topics[1]))) == t;
            }
        }
    }

    function test_create() public {
        _open();
        vm.recordLogs();
        uint256 n = p.tokenCount();
        address t = _createGS(creator, 12 ether);
        assertEq(p.kindOf(t), KIND_GS);
        assertEq(p.gradTargetOf(t), 12 ether);
        assertEq(p.tokenVersionOf(t), p.TOKEN_VERSION());
        assertEq(p.logoURIOf(t), "logo");
        assertEq(p.tokenCount(), n + 1);
        assertEq(p.allTokens(n), t);
        assertTrue(_lastGangSwapCreated(t), "GangSwapCreated(token) emitted (review 4 #4)");
        (
            address c,
            address q,
            uint128 rq,
            uint128 sold,
            uint128 gradAmt,
            uint128 vq,
            bool grad,
            uint16 bt,
            uint16 st,
            uint16 dv,
            address pr,
            address ref
        ) = p.curves(t);
        assertEq(c, creator);
        assertEq(q, address(wbnb));
        assertEq(uint256(rq) + sold, 0);
        assertEq(gradAmt, 12 ether);
        assertEq(vq, 4 ether);
        assertFalse(grad);
        assertEq(uint256(bt) + st + dv, 0);
        assertEq(pr, address(0));
        assertEq(ref, address(0));
        assertEq(IERC20(t).totalSupply(), TOTAL_SUPPLY);
        assertEq(IERC20(t).balanceOf(address(pad)), TOTAL_SUPPLY);

        (uint8 s, address eq, address ep, uint256 fee, uint256 left) = _info(t);
        assertEq(s, STATUS_CURVE);
        assertEq(eq, address(0));
        assertEq(ep, address(0));
        assertEq(fee, 100);
        assertEq(left, 12 ether);
        // not a module token
        assertEq(m.vaultOf(t), address(0));
        assertEq(m.baseVaultOf(t), address(0));
    }

    function test_create_checks() public {
        _open();
        vm.prank(creator);
        vm.expectRevert(IGangLaunchpad.BadGradTarget.selector);
        m.createGangSwap("Swap", "GSW", "logo", "meta", 10 ether, address(gsMigrator));
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(IGangLaunchpad.NotAgent.selector);
        m.createGangSwap("Swap", "GSW", "logo", "meta", 9 ether, address(gsMigrator));
    }

    /// @dev The same create as a kind-1 untaxed WBNB token: same curve record and events but the kind and the migrator.
    function test_create_matchesKind1Record() public {
        _open();
        address a = _createGS(creator, 9 ether);
        address b = _createCurve(creator);
        (address c1, address q1,,, uint128 g1, uint128 v1,,,,,,) = p.curves(a);
        (address c2, address q2,,, uint128 g2, uint128 v2,,,,,,) = p.curves(b);
        assertEq(c1, c2);
        assertEq(q1, q2);
        assertEq(g1, g2);
        assertEq(v1, v2);
        assertEq(p.kindOf(b), KIND_CURVE);
    }

    function test_createWithSalt() public {
        _open();
        Pad3VanityDeployer f = new Pad3VanityDeployer(address(pad), address(tokenDeployer), address(flyDeployer));
        vm.prank(owner);
        m.enableVanity(address(f));
        bytes32 hash = f.tokenInitCodeHash("Swap", "GSW", "meta", address(0), 0, 0, false);
        (bytes32 salt,) = Pad3VanitySalt.find(address(f), creator, hash);
        bytes memory data =
            abi.encodeCall(IGangSwapPad.createGangSwap, ("Swap", "GSW", "logo", "meta", 9 ether, address(gsMigrator)));
        // a value with this non-payable entry reverts the whole call
        vm.prank(creator);
        vm.expectRevert();
        m.createWithSalt{value: 1 ether}(salt, data);
        // a stale version comes back as is
        bytes memory stale =
            abi.encodeCall(IGangSwapPad.createGangSwap, ("Swap", "GSW", "logo", "meta", 9 ether, address(0xdead)));
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IGangSwapPad.GangSwapVersionChanged.selector, address(gsMigrator)));
        m.createWithSalt(salt, stale);
        vm.prank(creator);
        address t = m.createWithSalt(salt, data);
        assertEq(uint16(uint160(t)), 0xabcd);
        assertEq(p.kindOf(t), KIND_GS);
        // not outside createWithSalt once vanity is on
        vm.prank(creator);
        vm.expectRevert(Pad3Module.VanityContextRequired.selector);
        m.createGangSwap("Swap", "GSW", "logo", "meta", 9 ether, address(gsMigrator));
    }

    function test_createWithAgentWindow() public {
        _open();
        bytes memory data =
            abi.encodeCall(IGangSwapPad.createGangSwap, ("Swap", "GSW", "logo", "meta", 9 ether, address(gsMigrator)));
        // a stale version comes back as is
        bytes memory stale =
            abi.encodeCall(IGangSwapPad.createGangSwap, ("Swap", "GSW", "logo", "meta", 9 ether, address(0xdead)));
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IGangSwapPad.GangSwapVersionChanged.selector, address(gsMigrator)));
        IGangAgentWindow(address(pad)).createWithAgentWindow(30, stale);
        vm.prank(creator);
        address t = IGangAgentWindow(address(pad)).createWithAgentWindow(30, data);
        assertEq(p.kindOf(t), KIND_GS);
        assertEq(IGangAgentWindow(address(pad)).agentOpenAt(t), block.timestamp + 30 minutes);
    }

    // ---------------------------------------------------------------- the upgrade script
    function _tokenSlot(address t) internal pure returns (bytes32) {
        return keccak256(abi.encode(t, uint256(Pad3GangSwapStore.SLOT) + 1));
    }

    function _wiring(string memory what) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(DeployGang.WiringCheck.selector, what);
    }

    function test_upgradeScript_compare() public {
        GangSwapUpgradeHarness h = new GangSwapUpgradeHarness();
        DeployGang.Stack memory s;
        _createCurve(creator);
        UpgradeGangLaunchpad3.Snapshot memory a = h.snap(p, s);
        UpgradeGangLaunchpad3.Snapshot memory b = h.snap(p, s);
        h.compare(a, b);
        b.settings = bytes32(uint256(1));
        vm.expectRevert(_wiring("upgrade: settings changed"));
        h.compare(a, b);
        b = h.snap(p, s);
        b.gangSwap = bytes32(uint256(1));
        vm.expectRevert(_wiring("upgrade: GangSwap state changed"));
        h.compare(a, b);
        b = h.snap(p, s);
        b.tokens[0] = bytes32(uint256(1));
        vm.expectRevert(_wiring("upgrade: a token's record changed"));
        h.compare(a, b);
    }

    /// @dev Any change of the pad's migrator or of a GangSwap token is seen, also outside the newest 25 tokens; a change
    ///      of another token is not GangSwap's.
    function test_upgradeScript_seesEveryGangSwapToken() public {
        GangSwapUpgradeHarness h = new GangSwapUpgradeHarness();
        DeployGang.Stack memory s;
        address plain = _createCurve(creator);
        assertEq(h.state(p), abi.encode(address(0), bytes32(0)), "closed, no token");
        h.check(p);
        _open();
        address t = _createGS(creator, 6 ether);
        (IGSMigrator v2,,,) = _deployGangSwap(true);
        vm.prank(owner);
        m.setGangSwapMigrator(address(v2));
        address t2 = _createGS(creator, 6 ether);
        for (uint256 i; i < 25; i++) {
            _createCurve(creator);
        }
        UpgradeGangLaunchpad3.Snapshot memory a = h.snap(p, s);
        bytes32 full = a.gangSwap;
        assertEq(keccak256(h.state(p)), full);
        h.compare(a, h.snap(p, s));
        h.check(p);

        bytes32[3] memory slots = [Pad3GangSwapStore.SLOT, _tokenSlot(t), _tokenSlot(t2)];
        for (uint256 i; i < 3; i++) {
            bytes32 was = vm.load(address(pad), slots[i]);
            vm.store(address(pad), slots[i], bytes32(uint256(0xdead)));
            assertTrue(keccak256(h.state(p)) != full);
            vm.store(address(pad), slots[i], 0);
            assertTrue(keccak256(h.state(p)) != full);
            // lost by a token: refused on its own too; by the pad: just closed
            if (i != 0) vm.expectRevert(_wiring("upgrade: a GangSwap token without its migrator"));
            h.check(p);
            vm.store(address(pad), slots[i], was);
        }
        // a migrator on a token that is not GangSwap's
        vm.store(address(pad), _tokenSlot(plain), bytes32(uint256(1)));
        assertTrue(keccak256(h.state(p)) != full);
        vm.expectRevert(_wiring("upgrade: a GangSwap token without its migrator"));
        h.check(p);
        vm.store(address(pad), _tokenSlot(plain), 0);

        // each compared view
        bytes[] memory calls = new bytes[](5);
        calls[0] = abi.encodeWithSignature("kindOf(address)", t);
        calls[1] = abi.encodeWithSignature("curves(address)", t);
        calls[2] = abi.encodeCall(GangLaunchpad3.getTokenInfo, (t));
        calls[3] = abi.encodeCall(IGangAgentWindow.agentOpenAt, (t));
        calls[4] = abi.encodeCall(IGangAgentWindow.walletCapOn, (t));
        for (uint256 i; i < calls.length; i++) {
            vm.mockCall(address(pad), calls[i], abi.encode(uint256(7)));
            assertTrue(keccak256(h.state(p)) != full, "a view");
            vm.clearMockedCalls();
        }
        assertEq(keccak256(h.state(p)), full);

        // closed, and graduated: compares and passes the check
        vm.prank(owner);
        m.setGangSwapMigrator(address(0));
        _graduate(t);
        h.check(p);
        h.compare(h.snap(p, s), h.snap(p, s));
        assertTrue(keccak256(h.state(p)) != full);
    }

    function test_upgradeScript_notServedRefused() public {
        GangSwapUpgradeHarness h = new GangSwapUpgradeHarness();
        _createCurve(creator);
        bytes memory closed = h.state(p);
        vm.mockCallRevert(address(pad), abi.encodeCall(IGangSwapPad.gangSwapMigrator, ()), "");
        assertEq(h.state(p), closed, "reads as closed: the first upgrade compares equal");
        vm.expectRevert(_wiring("upgrade: GangSwap not served"));
        h.check(p);
        vm.clearMockedCalls();
        vm.mockCallRevert(address(pad), abi.encodeCall(IGangSwapPad.gangSwapMigratorOf, (address(pad))), "");
        vm.expectRevert(_wiring("upgrade: GangSwap not served"));
        h.check(p);
        vm.clearMockedCalls();
        h.check(p);
    }

    /// @dev A GangSwap token's wallet cap is part of the agent-window checks, as a kind-1 token's.
    function test_upgradeScript_walletCapOfKind4() public {
        GangSwapUpgradeHarness h = new GangSwapUpgradeHarness();
        _open();
        address t = _createGS(creator, 6 ether);
        (, bytes memory st) = h.window(p);
        h.checkWindow(p, false, "");
        vm.mockCall(address(pad), abi.encodeCall(IGangAgentWindow.walletCapOn, (t)), abi.encode(false));
        (, bytes memory st2) = h.window(p);
        assertTrue(keccak256(st2) != keccak256(st));
        vm.expectRevert(_wiring("upgrade: a token's agent window changed"));
        h.checkWindow(p, true, st);
        vm.expectRevert(_wiring("upgrade: an old token's wallet cap changed"));
        h.checkWindow(p, false, "");
    }

    // ---------------------------------------------------------------- curve trades
    /// @dev Every curve entry on a kind-4 token does what it does on a kind-1 token with the same curve, to the wei.
    function test_curveTrades_matchKind1() public {
        _open();
        address a = _createGS(creator, 9 ether);
        address b = _createCurve(creator);
        address w = _newAgent();
        _sameTrades(w, a, b);
    }

    function _sameTrades(address w, address a, address b) internal {
        // quotes
        (, address qa, uint256 ea, uint256 ca, uint256 fa,,,) = p.tryBuy(a, w, 0, 0.05 ether);
        (, address qb, uint256 eb, uint256 cb, uint256 fb,,,) = p.tryBuy(b, w, 0, 0.05 ether);
        assertGt(ea, 0);
        assertEq(qa, qb);
        assertEq(ea, eb);
        assertEq(ca, cb);
        assertEq(fa, fb);
        // a fresh-wallet quote too
        (,, ea,,,,,) = p.tryBuy(a, address(0), 0, 0.05 ether);
        assertGt(ea, 0);

        // pad.buy
        vm.startPrank(w, w);
        uint256 outA = pad.buy(a, 0.01 ether, 0);
        uint256 outB = pad.buy(b, 0.01 ether, 0);
        assertEq(outA, outB);
        // aggregator entry: buyTokenAMAP with native BNB
        (uint256 aOut, uint256 aUsed) = p.buyTokenAMAP{value: 0.005 ether}(a, w, 0.005 ether, 0);
        (uint256 bOut, uint256 bUsed) = p.buyTokenAMAP{value: 0.005 ether}(b, w, 0.005 ether, 0);
        assertEq(aOut, bOut);
        assertEq(aUsed, bUsed);
        vm.stopPrank();

        // trySell
        (,, uint256 sa, uint256 sfa) = p.trySell(a, 100_000 ether);
        (,, uint256 sb, uint256 sfb) = p.trySell(b, 100_000 ether);
        assertGt(sa, 0);
        assertEq(sa, sb);
        assertEq(sfa, sfb);

        vm.startPrank(w, w);
        // pad.sell
        IERC20(a).approve(address(pad), type(uint256).max);
        IERC20(b).approve(address(pad), type(uint256).max);
        uint256 qOutA = pad.sell(a, 100_000 ether, 0);
        uint256 qOutB = pad.sell(b, 100_000 ether, 0);
        assertEq(qOutA, qOutB);
        // aggregator entry sell (four.meme sellToken with a router fee), the seller itself
        uint256 balA = w.balance;
        uint256 toA = p.sellToken(0, a, w, 100_000 ether, 0, 100, makeAddr("feeTo"));
        uint256 toB = p.sellToken(0, b, w, 100_000 ether, 0, 100, makeAddr("feeTo"));
        vm.stopPrank();
        assertEq(toA, toB);
        assertGt(toA, 0);
        assertEq(w.balance - balA, toA + toB);
        _sameCurve(a, b);
    }

    function _sameCurve(address a, address b) internal view {
        (,, uint128 r1, uint128 s1,,,,,,,,) = p.curves(a);
        (,, uint128 r2, uint128 s2,,,,,,,,) = p.curves(b);
        assertEq(r1, r2);
        assertEq(s1, s2);
        assertEq(p.creatorFeeOf(a), p.creatorFeeOf(b));
    }

    /// @dev GangRouter's curve buy (buyFor) works on kind 4 as on kind 1.
    function test_routerCurveBuy() public {
        _open();
        address t = _createGS(creator, 9 ether);
        address w = _newAgent();
        vm.prank(w, w);
        uint256 out = router.v3BuyBNB{value: 0.2 ether}(t, 0, block.timestamp);
        assertGt(out, 0);
        assertEq(IERC20(t).balanceOf(w), out);
    }

    // ---------------------------------------------------------------- graduation
    function test_graduate_intoGangSwap() public {
        _open();
        address t = _createGS(creator, 9 ether);
        vm.prank(creator, creator);
        uint256 held = pad.buy(t, 0.1 ether, 0);
        uint256 bucketBefore = wbnb.balanceOf(address(bucket));
        _graduate(t);
        (,,, uint128 sold, uint128 gradAmt,, bool grad,,,, address pairAddr,) = p.curves(t);
        assertTrue(grad);
        assertEq(pairAddr, gsFactory.getPair(t, address(wbnb)));
        assertEq(gsFactory.allPairsLength(), 1);
        assertEq(gsMigrator.padOf(pairAddr), address(pad));
        // nothing on the Pancake side
        assertEq(pairFactory.getPair(t, address(wbnb)), address(0));

        uint256 raise = gradAmt; // graduation buys exactly up to the target
        uint256 tokens = TOTAL_SUPPLY - sold;
        uint256 v = (raise * tokens) / TOTAL_SUPPLY;
        IGSPair pair = IGSPair(pairAddr);
        (uint112 r0, uint112 r1,) = pair.getReserves();
        (uint256 rq, uint256 rt) = pair.quoteIs0() ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        assertEq(rq, raise, "effective quote = raise");
        assertEq(rt, tokens, "tokens = supply - sold");
        assertEq(pair.virtualReserve(), v);
        assertEq(pair.realQuoteReserve(), raise - v);
        assertEq(wbnb.balanceOf(pairAddr), raise - v);
        assertEq(wbnb.balanceOf(gsBoost), v, "boost holds V");
        assertEq(pair.balanceOf(DEAD), pair.totalSupply() - 1000, "LP burned");
        // the pad keeps none of it; the platform fee went out as on any curve
        assertEq(IERC20(t).balanceOf(address(pad)), 0);
        assertGt(wbnb.balanceOf(address(bucket)), bucketBefore);

        (uint8 s, address q, address ep, uint256 fee, uint256 left) = _info(t);
        assertEq(s, STATUS_GANGSWAP);
        assertEq(q, address(0));
        assertEq(ep, pairAddr);
        assertEq(fee, 100);
        assertEq(left, 0);

        // unlocked, untaxed: no pair set on the token, plain transfers work
        assertFalse(_gangToken(t).locked());
        assertEq(_gangToken(t).pair(), address(0));
        address h = makeAddr("holder");
        vm.prank(creator);
        IERC20(t).transfer(h, held);
        assertEq(IERC20(t).balanceOf(h), held);
    }

    /// @dev After graduation every curve path of the pad is closed for it, as for a graduated kind-1 token.
    function test_graduated_curveClosed() public {
        _open();
        address t = _createGS(creator, 6 ether);
        _graduate(t);
        address w = _newAgent();
        (,, uint256 est,,,,,) = p.tryBuy(t, w, 0, 1 ether);
        assertEq(est, 0);
        (,, uint256 funds,) = p.trySell(t, 1 ether);
        assertEq(funds, 0);
        vm.startPrank(w, w);
        vm.expectRevert(IGangLaunchpad3.NotCurveToken.selector);
        p.buyTokenAMAP{value: 1 ether}(t, w, 1 ether, 0);
        vm.expectRevert(IGangLaunchpad.AlreadyGraduated.selector);
        pad.buy(t, 1 ether, 0);
        vm.stopPrank();
    }

    /// @dev Kind 1 is unchanged: it still graduates into the Pancake pair through Config.migrator (status 2), even with
    ///      the GangSwap migrator set and a GangSwap token graduated next to it.
    function test_kind1_stillGraduatesToPancake() public {
        _open();
        address gs = _createGS(creator, 9 ether);
        address c = _createCurve(creator);
        _graduate(gs);
        _graduate(c);
        address pancakePair = pairFactory.getPair(c, address(wbnb));
        assertTrue(pancakePair != address(0));
        assertEq(_curvePair(c), pancakePair);
        assertEq(gsFactory.getPair(c, address(wbnb)), address(0));
        assertEq(gsFactory.allPairsLength(), 1);
        (uint8 s,, address ep, uint256 fee,) = _info(c);
        assertEq(s, STATUS_POOL);
        assertEq(ep, pancakePair);
        assertEq(fee, 0);
        (uint256 rT, uint256 rQ) = _reserves(c, pancakePair);
        (,, uint128 rq, uint128 sold,,,,,,,,) = p.curves(c);
        assertEq(rq, 0);
        assertEq(rT, TOTAL_SUPPLY - sold);
        assertEq(rQ, 9 ether);
    }

    // ---------------------------------------------------------------- modules refuse kind 4
    function test_promoterBuy_refused() public {
        _open();
        address t = _createGS(creator, 9 ether);
        address w = _newAgent();
        vm.prank(w, w);
        vm.expectRevert(IGangLaunchpad3.NotCurveToken.selector);
        IGangPromote(address(pad)).buyWithPromoter{value: 0.1 ether}(t, 0.1 ether, 0, makeAddr("promoter"));
    }

    function test_bond_refused() public {
        _open();
        address t = _createGS(creator, 9 ether);
        vm.prank(creator, creator);
        pad.buy(t, 0.1 ether, 0);
        GangBond bond = new GangBond(address(pad), address(wbnb));
        vm.prank(creator);
        vm.expectRevert(IGangBond.UnknownToken.selector);
        bond.post{value: 0.1 ether}(t, 0.1 ether, 1 ether, 7 days);
    }

    /// @dev GangRouter's Pancake entries refuse a GangSwap token (review N3); its curve buy is open (above).
    function test_routerPool_refused() public {
        _open();
        address t = _createGS(creator, 9 ether);
        _graduate(t);
        address w = _newAgent();
        vm.startPrank(w, w);
        vm.expectRevert(GangRouter.GangSwapToken.selector);
        router.poolBuyBNB{value: 0.1 ether}(t, address(wbnb), 0, block.timestamp);
        vm.expectRevert(GangRouter.GangSwapToken.selector);
        router.poolBuy(t, address(wbnb), 0.1 ether, 0, block.timestamp);
        vm.expectRevert(GangRouter.GangSwapToken.selector);
        router.poolSell(t, address(wbnb), 1 ether, 0, block.timestamp);
        vm.expectRevert(GangRouter.GangSwapToken.selector);
        router.poolSellForBNB(t, address(wbnb), 1 ether, 0, block.timestamp);
        // a GangSwap token as the middle hop of someone else's route (review 4 #2)
        address other = makeAddr("other");
        vm.expectRevert(GangRouter.GangSwapToken.selector);
        router.poolBuyBNB{value: 0.1 ether}(other, t, 0, block.timestamp);
        vm.expectRevert(GangRouter.GangSwapToken.selector);
        router.poolSellForBNB(other, t, 1 ether, 0, block.timestamp);
        vm.expectRevert(GangRouter.GangSwapToken.selector);
        router.poolBuy(other, t, 1 ether, 0, block.timestamp);
        vm.expectRevert(GangRouter.GangSwapToken.selector);
        router.poolSell(other, t, 1 ether, 0, block.timestamp);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- GangPadRegistry / GangGateway
    function test_registryAndGateway() public {
        _open();
        vm.prank(owner);
        padRegistry3.addPad(address(pad));
        G.Gateway memory g = G.deploy(address(padRegistry3), address(wbnb), owner, 0);
        GangGateway gw = GangGateway(payable(g.proxy));
        vm.prank(owner);
        pad.setRouter(address(gw), true);

        address t = _createGS(creator, 9 ether);
        (address rp, uint8 kind) = padRegistry3.lookup(t);
        assertEq(rp, address(pad));
        assertEq(kind, KIND_GS);
        address w = _newAgent();
        (uint256 out,,,) = padRegistry3.previewBuy(t, w, 0.5 ether);
        (,, uint256 est,,,,,) = p.tryBuy(t, w, 0, 0.5 ether);
        assertGt(out, 0);
        assertEq(out, est);

        // GangGateway does not know kind 4: no info, no quote, no trade (it stays off the rollout)
        (uint8 s,,,,) = gw.getTokenInfo(t);
        assertEq(s, 0);
        (,, uint256 gwEst,,,,,) = gw.tryBuy(t, w, 0, 0.5 ether);
        assertEq(gwEst, 0);
        vm.prank(w, w);
        vm.expectRevert();
        gw.buyTokenAMAP{value: 0.5 ether}(t, w, 0.5 ether, 0);

        _graduate(t);
        (s,,,,) = gw.getTokenInfo(t);
        assertEq(s, 0);
        (out,,,) = padRegistry3.previewBuy(t, w, 0.5 ether);
        assertEq(out, 0);
        vm.prank(w, w);
        vm.expectRevert();
        gw.buyTokenAMAP{value: 0.1 ether}(t, w, 0.1 ether, 0);
    }
}

/// @dev Answers the two getters setGangSwapMigrator used to rely on, but is not wired to a GangSwap factory.
contract StrayMigrator {
    address public quote;
    bool public wired;

    constructor(address q, bool w) {
        (quote, wired) = (q, w);
    }

    function launchpads(address) external pure returns (bool) {
        return true;
    }
}

