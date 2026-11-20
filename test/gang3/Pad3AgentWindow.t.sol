// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Vm} from "forge-std/Vm.sol";
import {GangLaunchpad} from "../../src/gang/GangLaunchpad.sol";
import {GangLaunchpad3} from "../../src/gang/GangLaunchpad3.sol";
import {Pad3Module} from "../../src/gang/Pad3Module.sol";
import {Pad3AgentWindowStore} from "../../src/gang/Pad3AgentWindowStore.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {IGangAgentWindow} from "../../src/gang/interfaces/IGangAgentWindow.sol";
import {IGangGradReward, IGangGradRewardBase} from "../../src/gang/interfaces/IGangGradReward.sol";
import {GangFixture} from "../utils/GangFixture.sol";
import {UpgradeGangLaunchpad3} from "../../script/UpgradeGangLaunchpad3.s.sol";

/// @dev The upgrade script's agent window checks, exposed.
contract AgentWindowCheckHarness is UpgradeGangLaunchpad3 {
    function state(GangLaunchpad3 p) external view returns (bool served, bytes memory st) {
        return _agentWindowState(p);
    }

    function check(GangLaunchpad3 p, bool servedBefore, bytes memory before) external view {
        _checkAgentWindow(p, servedBefore, before);
    }
}

contract AWMockModuleAdmin {
    mapping(address => address) public moduleOf;
}

/// @dev A contract trader (no Agent ID): buys and sells on the curve for itself.
contract AWContractTrader {
    function buy(GangLaunchpad pad, IERC20 quote, address token, uint256 amount) external returns (uint256 out) {
        quote.approve(address(pad), amount);
        out = pad.buy(token, amount, 0);
    }

    function sell(GangLaunchpad pad, address token, uint256 amount) external returns (uint256 out) {
        IERC20(token).approve(address(pad), amount);
        out = pad.sell(token, amount, 0);
    }
}

/// @dev Many contract buyers in one tx: the atomic sweep the spec accepts (SPEC-AGENT-WINDOW §3).
contract AWSweeper {
    function sweep(GangLaunchpad pad, IERC20 quote, address token, uint256 n, uint256 each) external {
        for (uint256 i; i < n; i++) {
            AWContractTrader c = new AWContractTrader();
            quote.transfer(address(c), each);
            c.buy(pad, quote, token, each);
        }
    }
}

/// @notice The agent window (docs/SPEC-AGENT-WINDOW-2026-11-20.md): registered before a curve create, written at it,
///         and from `openAt` on the gate lets every wallet trade and the 1% cap is off (not on a graduation reward).
contract Pad3AgentWindowTest is GangFixture {
    uint16 internal constant MINUTES = 60;

    event NextAgentWindowSet(address indexed creator, uint16 windowMinutes);
    event AgentWindowSet(address indexed token, uint40 openAt);

    GangLaunchpad3 internal pad3;
    Pad3Module internal pm;
    IGangAgentWindow internal aw;
    address internal creator;
    address internal agent;
    address internal human;

    function _newPad() internal override returns (GangLaunchpad) {
        return _newPad3();
    }

    function setUp() public {
        _deployGang(address(this));
        pad3 = GangLaunchpad3(payable(address(pad)));
        pm = Pad3Module(payable(address(pad)));
        aw = IGangAgentWindow(address(pad));
        creator = _newAgent();
        agent = _newAgent();
        human = _newHuman("human");
    }

    // ---------------------------------------------------------------- helpers
    /// @dev A wallet without an Agent ID, funded and approved like `_newAgent`.
    function _newHuman(string memory name) internal returns (address who) {
        who = makeAddr(name);
        vm.deal(who, 1_000 ether);
        wbnb.mintUnlimited(who, 1_000 ether);
        vm.prank(who);
        wbnb.approve(address(pad), type(uint256).max);
    }

    function _register(uint16 m) internal {
        vm.prank(creator);
        aw.setNextAgentWindow(m);
    }

    function _createOpen(uint16 m) internal returns (address t) {
        _register(m);
        t = _createV3(creator, address(wbnb), _tax(0, 0, 0, address(0)));
    }

    function _open(address t) internal {
        vm.warp(aw.agentOpenAt(t));
    }

    function _buy(address who, address t, uint256 amount) internal returns (uint256) {
        vm.prank(who, who);
        return pad.buy(t, amount, 0);
    }

    function _quote(address t, address who, uint256 funds) internal view returns (uint256 est) {
        (,, est,,,,,) = pad3.tryBuy(t, who, 0, funds);
    }

    /// @dev The pool a 9 BNB curve opens with (GradTarget.t.sol's check): the raise and 200M tokens.
    function _assertPool(address t) internal view {
        assertEq(_curveSold(t), pad.CURVE_SUPPLY());
        (uint256 rT, uint256 rQ) = _reserves(t, _curvePair(t));
        assertGe(rQ, 9 ether);
        assertLe(rQ, 9 ether + 1);
        assertApproxEqRel((rQ * pad.TOTAL_SUPPLY()) / rT, 45 ether, 0.02e18);
    }

    // ---------------------------------------------------------------- store
    function test_slot_isTheErc7201Slot() public pure {
        bytes32 expected =
            keccak256(abi.encode(uint256(keccak256("gang.pad3.agentwindow")) - 1)) & ~bytes32(uint256(0xff));
        assertEq(Pad3AgentWindowStore.SLOT, expected);
    }

    function test_constants() public view {
        assertEq(aw.MIN_AGENT_WINDOW_MINUTES(), 1);
        assertEq(aw.MAX_AGENT_WINDOW_MINUTES(), 1440);
    }

    // ---------------------------------------------------------------- register / consume
    function test_register_boundsAndClear() public {
        vm.startPrank(creator);
        vm.expectEmit(true, false, false, true, address(pad));
        emit NextAgentWindowSet(creator, 1);
        aw.setNextAgentWindow(1);
        assertEq(aw.nextAgentWindowOf(creator), 1);
        aw.setNextAgentWindow(1440);
        assertEq(aw.nextAgentWindowOf(creator), 1440);
        vm.expectRevert(IGangAgentWindow.BadAgentWindow.selector);
        aw.setNextAgentWindow(1441);
        vm.expectRevert(IGangAgentWindow.BadAgentWindow.selector);
        aw.setNextAgentWindow(type(uint16).max);
        aw.setNextAgentWindow(0);
        assertEq(aw.nextAgentWindowOf(creator), 0);
        vm.stopPrank();
    }

    function test_noRegistration_agentOnlyForGood() public {
        address t = _createV3(creator, address(wbnb), _tax(0, 0, 0, address(0)));
        assertEq(aw.agentOpenAt(t), 0);
        vm.warp(block.timestamp + 3650 days);
        assertFalse(aw.agentWindowOpen(t));
        vm.prank(human, human);
        vm.expectRevert(IGangLaunchpad.NotAgent.selector);
        pad.buy(t, 0.01 ether, 0);
    }

    function test_create_writesOpenAtAndClears() public {
        _register(MINUTES);
        vm.recordLogs();
        address t = _createV3(creator, address(wbnb), _tax(0, 0, 0, address(0)));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.Log memory last = logs[logs.length - 1];
        assertEq(last.topics[0], AgentWindowSet.selector);
        assertEq(last.topics[1], bytes32(uint256(uint160(t))));
        uint40 openAt = uint40(block.timestamp + uint256(MINUTES) * 60);
        assertEq(last.data, abi.encode(openAt));
        assertEq(aw.agentOpenAt(t), openAt);
        assertEq(aw.nextAgentWindowOf(creator), 0);
        // the next create takes none
        address t2 = _createV3(creator, address(wbnb), _tax(0, 0, 0, address(0)));
        assertEq(aw.agentOpenAt(t2), 0);
    }

    function test_create_everyCurveEntryConsumes() public {
        _register(5);
        vm.prank(creator);
        address a = pad3.createWithGradTarget(
            "A", "A", "l", "m", address(wbnb), address(0), _tax(0, 0, 0, address(0)), 6 ether
        );
        assertEq(aw.agentOpenAt(a), block.timestamp + 300);

        _register(7);
        vm.prank(creator);
        address b = pm.createWithPromote(
            "B", "B", "l", "m", address(wbnb), address(0), _tax(0, 0, 0, address(0)), 9 ether, 2_000, 30 days
        );
        assertEq(aw.agentOpenAt(b), block.timestamp + 420);
        assertEq(aw.nextAgentWindowOf(creator), 0);
    }

    function test_create_fairDoesNotConsume() public {
        _register(MINUTES);
        address f = _createFair(creator, address(wbnb), 1);
        assertEq(aw.agentOpenAt(f), 0);
        assertEq(aw.nextAgentWindowOf(creator), MINUTES);
    }

    function test_register_onlyOwnCreates() public {
        _register(MINUTES);
        address other = _newAgent();
        address t = _createV3(other, address(wbnb), _tax(0, 0, 0, address(0)));
        assertEq(aw.agentOpenAt(t), 0);
        assertEq(aw.nextAgentWindowOf(creator), MINUTES);
    }

    // ---------------------------------------------------------------- the gate
    function test_window_boundary() public {
        address t = _createOpen(MINUTES);
        uint40 openAt = aw.agentOpenAt(t);

        vm.warp(openAt - 1);
        assertFalse(aw.agentWindowOpen(t));
        assertFalse(aw.canTradeCurve(t, human));
        assertTrue(aw.canTradeCurve(t, agent));
        assertFalse(aw.canTradeCurve(t, address(0)));
        assertEq(_quote(t, human, 0.01 ether), 0);
        vm.prank(human, human);
        vm.expectRevert(IGangLaunchpad.NotAgent.selector);
        pad.buy(t, 0.01 ether, 0);
        assertGt(_buy(agent, t, 0.01 ether), 0);

        vm.warp(openAt);
        assertTrue(aw.agentWindowOpen(t));
        assertTrue(aw.canTradeCurve(t, human));
        assertTrue(aw.canTradeCurve(t, address(0)));
        uint256 est = _quote(t, human, 0.01 ether);
        uint256 out = _buy(human, t, 0.01 ether);
        assertEq(out, est);
        // and sells back
        vm.startPrank(human, human);
        IERC20(t).approve(address(pad), out);
        assertGt(pad.sell(t, out, 0), 0);
        vm.stopPrank();
        assertEq(IERC20(t).balanceOf(human), 0);
    }

    function test_open_everyEntry() public {
        address t = _createOpen(1);
        _open(t);
        // buyTokenAMAP (the aggregator-shaped entry, native BNB)
        vm.prank(human, human);
        (uint256 out,) = pad3.buyTokenAMAP{value: 0.01 ether}(t, human, 0.01 ether, 0);
        assertGt(out, 0);
        // sellToken, four.meme's shape (the pad pulls with the seller's allowance to the pad; BNB back)
        vm.startPrank(human, human);
        IERC20(t).approve(address(pad), out);
        pad3.sellToken(0, t, human, out, 0, 0, address(0));
        vm.stopPrank();
        assertEq(IERC20(t).balanceOf(human), 0);
        // the router entry (buyFor), the trader being the wallet that sent the tx
        vm.prank(owner);
        pad.setRouter(address(router), true);
        address r = address(router);
        wbnb.mintUnlimited(r, 1 ether);
        vm.prank(r);
        wbnb.approve(address(pad), type(uint256).max);
        vm.prank(r, human);
        assertGt(pad.buyFor(human, t, 0.01 ether, 0), 0);
    }

    function test_open_contractTraderBuysAndSells() public {
        address t = _createOpen(1);
        AWContractTrader c = new AWContractTrader();
        wbnb.mintUnlimited(address(c), 1 ether);
        vm.expectRevert(IGangLaunchpad.NotAgent.selector);
        c.buy(pad, IERC20(address(wbnb)), t, 0.01 ether);
        _open(t);
        uint256 out = c.buy(pad, IERC20(address(wbnb)), t, 0.01 ether);
        assertGt(out, 0);
        assertGt(c.sell(pad, t, out), 0);
    }

    function test_gateOff_everyoneTradesAnyToken() public {
        address t = _createV3(creator, address(wbnb), _tax(0, 0, 0, address(0)));
        vm.prank(owner);
        pad.setAgentGate(false, address(agents));
        assertTrue(aw.canTradeCurve(t, human));
        assertTrue(aw.canTradeCurve(t, address(0)));
        assertGt(_buy(human, t, 0.01 ether), 0);
    }

    function test_closed_everyEntryRefusesAHuman() public {
        address t = _createOpen(MINUTES);
        vm.startPrank(human, human);
        vm.expectRevert(IGangLaunchpad.NotAgent.selector);
        pad.sell(t, 1 ether, 0);
        vm.expectRevert(IGangLaunchpad.NotAgent.selector);
        pad3.buyTokenAMAP{value: 0.01 ether}(t, human, 0.01 ether, 0);
        vm.stopPrank();
        vm.prank(owner);
        pad.setRouter(address(router), true);
        address r = address(router);
        wbnb.mintUnlimited(r, 1 ether);
        vm.prank(r);
        wbnb.approve(address(pad), type(uint256).max);
        vm.prank(r, human);
        vm.expectRevert(IGangLaunchpad.NotAgent.selector);
        pad.buyFor(human, t, 0.01 ether, 0);
        vm.prank(r, human);
        vm.expectRevert(IGangLaunchpad.NotAgent.selector);
        pad.sellFor(human, t, 1 ether, 0);
        vm.startPrank(human, human);
        vm.expectRevert(IGangLaunchpad.NotAgent.selector);
        pad3.sellToken(0, t, human, 1 ether, 0, 0, address(0));
        vm.stopPrank();
        // the promoter entry, on a token with a promoter share
        _register(MINUTES);
        vm.prank(creator);
        address p = pm.createWithPromote(
            "B", "B", "l", "m", address(wbnb), address(0), _tax(0, 0, 0, address(0)), 9 ether, 2_000, 30 days
        );
        vm.prank(human, human);
        vm.expectRevert(IGangLaunchpad.NotAgent.selector);
        pm.buyWithPromoter{value: 0.01 ether}(p, 0.01 ether, 0, agent);
    }

    /// @dev A "fresh wallet" 0 is never sent to the Agent ID registry (a real ERC-721 reverts on balanceOf(0)).
    function test_zeroTrader_neverAskedForAnAgentId() public {
        vm.prank(owner);
        padRegistry3.addPad(address(pad));
        address t = _createOpen(MINUTES);
        vm.expectCall(address(agents), abi.encodeCall(IERC721.balanceOf, (address(0))), 0);
        assertGt(_quote(t, address(0), 0.01 ether), 0);
        assertFalse(aw.canTradeCurve(t, address(0)));
        (uint256 r,,,) = padRegistry3.previewBuy(t, address(0), 0.01 ether);
        assertGt(r, 0);
        _open(t);
        assertTrue(aw.canTradeCurve(t, address(0)));
        assertGt(_quote(t, address(0), 0.01 ether), 0);
    }

    function test_gradReward_humanGraduates_agentTakesThePool() public {
        address t = _gradToken();
        IGangGradReward gr = IGangGradReward(address(pad));
        _buy(agent, t, 0.02 ether);
        _open(t);
        // humans push it to graduation, each under the cap the reward keeps
        address last;
        for (uint256 i; i < 200 && !_graduated(t); i++) {
            last = _newHuman(string(abi.encode("h", i)));
            _buy(last, t, 1 ether);
        }
        assertTrue(_graduated(t));
        (address[] memory buyers,,,) = gr.gradEntries(t);
        assertEq(buyers.length, 1);
        assertEq(buyers[0], agent);
        // the one valid entry takes the whole payout (SPEC-GRAD-REWARD); no human has a share
        assertGt(gr.gradClaimable(t, agent), 0);
        assertEq(gr.gradClaimable(t, last), 0); // the human who graduated it has no share
        vm.prank(agent);
        assertGt(gr.claimGradReward(t), 0);
    }

    // ---------------------------------------------------------------- the 1% cap
    function test_cap_onInWindow_offWhenOpen() public {
        address t = _createOpen(MINUTES);
        uint256 cap = pad.MAX_PER_WALLET();
        assertTrue(aw.walletCapOn(t));
        assertEq(pad.walletRoom(t, agent), cap);
        assertEq(_buy(agent, t, 1 ether), cap);
        vm.prank(agent, agent);
        vm.expectRevert(IGangLaunchpad.WalletCapReached.selector);
        pad.buy(t, 0.01 ether, 0);

        _open(t);
        assertFalse(aw.walletCapOn(t));
        assertEq(pad.walletRoom(t, agent), type(uint256).max);
        // the same agent buys on, past 1%
        assertGt(_buy(agent, t, 0.5 ether), 0);
        assertGt(IERC20(t).balanceOf(agent), cap);
    }

    function test_cap_padSwitchOff_noCapAnywhere() public {
        address t = _createOpen(MINUTES);
        vm.prank(owner);
        pad.setWalletCapEnabled(false);
        assertFalse(aw.walletCapOn(t));
        assertEq(pad.walletRoom(t, agent), type(uint256).max);
    }

    function test_open_oneWalletBuysToGraduation() public {
        address t = _createOpen(1);
        _open(t);
        uint256 est = _quote(t, human, 20 ether);
        uint256 out = _buy(human, t, 20 ether);
        assertEq(out, est);
        assertEq(out, pad.CURVE_SUPPLY());
        assertTrue(_graduated(t));
        _assertPool(t);
    }

    function test_open_atomicContractSweepGraduates() public {
        address t = _createOpen(1);
        _open(t);
        AWSweeper s = new AWSweeper();
        wbnb.mintUnlimited(address(s), 20 ether);
        // 10 contracts of 1 BNB: the 10th graduates the 9 BNB curve (its cut refunded)
        s.sweep(pad, IERC20(address(wbnb)), t, 10, 1 ether);
        assertTrue(_graduated(t));
        _assertPool(t);
    }

    /// @dev The cap is one definition: the buy, the pad's quote, `walletRoom` and the registry agree to the wei,
    ///      before and after `openAt`, held or not.
    function test_cap_quotesMatchTheBuy() public {
        vm.prank(owner);
        padRegistry3.addPad(address(pad));
        address t = _createOpen(MINUTES);
        address[3] memory who = [agent, _newAgent(), human];
        uint256[3] memory amt = [uint256(0.3 ether), 2 ether, 0.05 ether];
        for (uint256 round; round < 2; round++) {
            if (round == 1) _open(t);
            for (uint256 i; i < 3; i++) {
                if (round == 0 && who[i] == human) continue;
                uint256 room =
                    aw.walletCapOn(t) ? pad.MAX_PER_WALLET() - IERC20(t).balanceOf(who[i]) : type(uint256).max;
                assertEq(pad.walletRoom(t, who[i]), room, "walletRoom");
                uint256 q = _quote(t, who[i], amt[i]);
                (uint256 r,,,) = padRegistry3.previewBuy(t, who[i], amt[i]);
                uint256 out = _buy(who[i], t, amt[i]);
                assertEq(out, q, "pad quote");
                assertEq(out, r, "registry quote");
            }
        }
    }

    // ---------------------------------------------------------------- registry
    function test_registry_gateFollowsTheWindow() public {
        vm.prank(owner);
        padRegistry3.addPad(address(pad));
        address t = _createOpen(MINUTES);
        (uint256 r,,,) = padRegistry3.previewBuy(t, human, 0.01 ether);
        assertEq(r, 0);
        (r,,,) = padRegistry3.previewBuy(t, address(0), 0.01 ether);
        assertGt(r, 0); // a fresh wallet: no gate check, as before
        _open(t);
        (r,,,) = padRegistry3.previewBuy(t, human, 0.01 ether);
        assertEq(r, _buy(human, t, 0.01 ether));
        (uint256 s,) = padRegistry3.previewSell(t, human, 1 ether);
        assertGt(s, 0);
    }

    // ---------------------------------------------------------------- the upgrade script's check
    function _wiring(string memory what) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("WiringCheck(string)", what);
    }

    /// @dev First upgrade to the agent window (the pad didn't serve it before): every sampled token must be agent only.
    function test_upgradeCheck_firstUpgrade() public {
        AgentWindowCheckHarness h = new AgentWindowCheckHarness();
        _createV3(creator, address(wbnb), _tax(0, 0, 0, address(0)));
        h.check(pad3, false, "");
        // a token with a window can't exist before the first upgrade: if one shows, the check refuses
        _createOpen(MINUTES);
        vm.expectRevert(_wiring("upgrade: an old token opened"));
        h.check(pad3, false, "");
    }

    /// @dev A later upgrade (the pad already serves it): tokens may have windows; they must be the same after it.
    function test_upgradeCheck_laterUpgrade() public {
        AgentWindowCheckHarness h = new AgentWindowCheckHarness();
        _createV3(creator, address(wbnb), _tax(0, 0, 0, address(0)));
        address t = _createOpen(MINUTES);
        (bool served, bytes memory st) = h.state(pad3);
        assertTrue(served);
        h.check(pad3, true, st);
        // still the same once the window has opened (the cap is off now, in the state read before as well as after)
        _open(t);
        (, st) = h.state(pad3);
        h.check(pad3, true, st);
        // a changed state (here: a different reading) is refused
        vm.expectRevert(_wiring("upgrade: a token's agent window changed"));
        h.check(pad3, true, abi.encode(st, uint256(1)));
    }

    // ---------------------------------------------------------------- graduation reward
    function _gradToken() internal returns (address t) {
        AWMockModuleAdmin admin = new AWMockModuleAdmin();
        vm.prank(owner);
        pm.setGradReward(true, address(admin), makeAddr("countdownFactory"));
        _register(MINUTES);
        vm.prank(creator);
        t = pm.createWithGradReward(
            "G",
            "G",
            "l",
            "m",
            address(wbnb),
            address(0),
            _tax(0, 0, 0, address(0)),
            9 ether,
            IGangGradRewardBase.GradConfig({
                seed: 1 ether,
                minBuy: 0.01 ether,
                entries: 10,
                lastBps: 3_000,
                carryBps: 0,
                refundAfter: 90 days,
                promoteBps: 0,
                promoteWindow: 0
            })
        );
        assertGt(aw.agentOpenAt(t), 0);
    }

    function test_gradReward_keepsTheCapWhenOpen() public {
        address t = _gradToken();
        _open(t);
        assertTrue(aw.walletCapOn(t));
        assertEq(pad.walletRoom(t, human), pad.MAX_PER_WALLET());
        assertEq(_buy(human, t, 1 ether), pad.MAX_PER_WALLET());
    }

    function test_gradReward_countsOnlyAgentsWhenOpen() public {
        address t = _gradToken();
        IGangGradReward gr = IGangGradReward(address(pad));
        _buy(agent, t, 0.02 ether);
        _open(t);
        _buy(human, t, 0.02 ether);
        AWContractTrader c = new AWContractTrader();
        wbnb.mintUnlimited(address(c), 1 ether);
        c.buy(pad, IERC20(address(wbnb)), t, 0.02 ether);
        address agent2 = _newAgent();
        _buy(agent2, t, 0.02 ether);
        (address[] memory buyers,,,) = gr.gradEntries(t);
        // newest first; the human's and the contract's buys are not on the list
        assertEq(buyers.length, 2);
        assertEq(buyers[0], agent2);
        assertEq(buyers[1], agent);
    }

    // ---------------------------------------------------------------- promoter share
    function test_promote_humanNotBoundWhenOpen() public {
        _register(1);
        vm.prank(creator);
        address t = pm.createWithPromote(
            "B", "B", "l", "m", address(wbnb), address(0), _tax(0, 0, 0, address(0)), 9 ether, 2_000, 30 days
        );
        address promoter = _newAgent();
        _open(t);
        assertFalse(pm.canBind(t, human, promoter));
        vm.prank(human, human);
        (uint256 out,) = pm.buyWithPromoter{value: 0.01 ether}(t, 0.01 ether, 0, promoter);
        assertGt(out, 0);
        (address p,,) = pm.bindingOf(t, human);
        assertEq(p, address(0));
        // an agent still binds
        assertTrue(pm.canBind(t, agent, promoter));
        vm.prank(agent, agent);
        pm.buyWithPromoter{value: 0.01 ether}(t, 0.01 ether, 0, promoter);
        (p,,) = pm.bindingOf(t, agent);
        assertEq(p, promoter);
    }
}
