// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
// The dev-funded graduation reward on GangSwap curve tokens (docs/SPEC-GANGSWAP-GRAD-REWARD-2026-11-25.md).

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Vm} from "forge-std/Vm.sol";
import {Pad3GangSwapTest, IGSPair, IGSFactory, IGSMigrator, GangSwapUpgradeHarness} from "./Pad3GangSwap.t.sol";
import {MockModuleAdmin} from "./Pad3GradReward.t.sol";
import {GangLaunchpad3} from "../../src/gang/GangLaunchpad3.sol";
import {Pad3GradStore} from "../../src/gang/Pad3GradStore.sol";
import {Pad3GangSwapStore} from "../../src/gang/Pad3GangSwapStore.sol";
import {Pad3Module} from "../../src/gang/Pad3Module.sol";
import {Pad3VanityDeployer} from "../../src/gang/Pad3VanityDeployer.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {IGangLaunchpad3} from "../../src/gang/interfaces/IGangLaunchpad3.sol";
import {IGangSwapPad} from "../../src/gang/interfaces/IGangSwapPad.sol";
import {IGangPromote} from "../../src/gang/interfaces/IGangPromote.sol";
import {IGangAgentWindow} from "../../src/gang/interfaces/IGangAgentWindow.sol";
import {IGangGradReward, IGangGradRewardBase} from "../../src/gang/interfaces/IGangGradReward.sol";
import {UpgradeGangLaunchpad3} from "../../script/UpgradeGangLaunchpad3.s.sol";
import {Pad3VanitySalt} from "../../script/Pad3VanitySalt.sol";
import {DeployGang} from "../../script/DeployGang.s.sol";

interface IGSBoostG {
    function step(address) external returns (uint256, uint256);
    function boosts(address) external view returns (address, uint64, bool, uint128, uint128);
}

contract GradUpgradeHarness is GangSwapUpgradeHarness {
    function gradState(GangLaunchpad3 p) external view returns (bytes memory) {
        return _gradState(p);
    }

    function checkGradCreate(GangLaunchpad3 p) external {
        _checkGangSwapGradCreate(p);
    }
}

/// @dev Etched over WBNB: `transferFrom` runs `call` on the pad (bubbling its revert) and moves nothing.
contract HookedWbnb {
    address internal target;
    bytes internal data;

    function set(address target_, bytes calldata data_) external {
        (target, data) = (target_, data_);
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }

    function transferFrom(address, address, uint256) external returns (bool) {
        if (target == address(0)) return true;
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 32), mload(ret))
            }
        }
        return true;
    }
}

contract Pad3GangSwapGradTest is Pad3GangSwapTest {
    uint256 internal constant BPS = 10_000;
    uint128 internal constant SEED = 1 ether;
    uint96 internal constant MIN_BUY = 0.1 ether;
    uint32 internal constant REFUND_AFTER = 90 days;

    IGangGradReward internal gr;
    MockModuleAdmin internal admin;

    /// @dev Both switches open, the 1% cap off (exact amounts per buy).
    function _openBoth() internal {
        _open();
        gr = IGangGradReward(address(pad));
        admin = new MockModuleAdmin();
        vm.startPrank(owner);
        m.setGradReward(true, address(admin), makeAddr("countdownFactory"));
        pad.setWalletCapEnabled(false);
        vm.stopPrank();
    }

    function _cfg(uint8 entries) internal pure returns (IGangGradRewardBase.GradConfig memory) {
        return IGangGradRewardBase.GradConfig({
            seed: SEED,
            minBuy: MIN_BUY,
            entries: entries,
            lastBps: 3_000,
            carryBps: 0,
            refundAfter: REFUND_AFTER,
            promoteBps: 0,
            promoteWindow: 0
        });
    }

    function _data(uint256 gradBnb, address mig, IGangGradRewardBase.GradConfig memory c)
        internal
        pure
        returns (bytes memory)
    {
        return
            abi.encodeCall(IGangSwapPad.createGangSwapWithGradReward, ("Swap", "GSW", "logo", "meta", gradBnb, mig, c));
    }

    function _createR(IGangGradRewardBase.GradConfig memory c) internal returns (address t) {
        vm.prank(creator);
        t = m.createGangSwapWithGradReward("Swap", "GSW", "logo", "meta", 9 ether, address(gsMigrator), c);
    }

    function _createR(uint8 entries) internal returns (address) {
        return _createR(_cfg(entries));
    }

    function _refused(IGangGradRewardBase.GradConfig memory c, bytes4 why) internal {
        vm.prank(creator);
        vm.expectRevert(why);
        m.createGangSwapWithGradReward("Swap", "GSW", "logo", "meta", 9 ether, address(gsMigrator), c);
    }

    function _buyAs(address t, address who, uint256 amount) internal {
        vm.prank(who, who);
        pad.buy(t, amount, 0);
    }

    function _sellAll(address t, address who) internal {
        uint256 bal = IERC20(t).balanceOf(who);
        vm.startPrank(who, who);
        IERC20(t).approve(address(pad), bal);
        pad.sell(t, bal, 0);
        vm.stopPrank();
    }

    function _claimAs(address t, address who) internal returns (uint256 got) {
        uint256 before = wbnb.balanceOf(who);
        vm.prank(who);
        gr.claimGradReward(t);
        got = wbnb.balanceOf(who) - before;
    }

    function _wbnb(address a) internal view returns (uint256) {
        return wbnb.balanceOf(a);
    }

    // ---------------------------------------------------------------- create
    function test_gr_create_recordsAndPullsSeed() public {
        _openBoth();
        address plain = _createGS(creator, 9 ether);
        uint256 dev = _wbnb(creator);
        uint256 held = _wbnb(address(pad));
        address t = _createR(7);
        assertEq(dev - _wbnb(creator), SEED);
        assertEq(_wbnb(address(pad)) - held, SEED);
        // everything else is `createGangSwap`'s
        assertEq(p.kindOf(t), KIND_GS);
        assertEq(m.gangSwapMigratorOf(t), address(gsMigrator));
        assertEq(p.gradTargetOf(t), 9 ether);
        assertEq(p.logoURIOf(t), "logo");
        assertEq(p.tokenVersionOf(t), p.tokenVersionOf(plain));
        (bool ok1, bytes memory a) = address(pad).staticcall(abi.encodeWithSignature("curves(address)", t));
        (bool ok2, bytes memory b) = address(pad).staticcall(abi.encodeWithSignature("curves(address)", plain));
        assertTrue(ok1 && ok2);
        assertEq(a, b, "the same curve record: the seed is in no curve number");
        (uint16 shareBps,) = m.promoteOf(t);
        assertEq(shareBps, 0);

        IGangGradRewardBase.GradView memory v = gr.gradReward(t);
        assertEq(v.state, Pad3GradStore.ACTIVE);
        assertEq(v.pot, SEED);
        assertEq(v.minBuy, MIN_BUY);
        assertEq(v.entries, 7);
        assertEq(v.lastBps, 3_000);
        assertEq(v.carryBps, 0);
        assertEq(v.refundAfter, REFUND_AFTER);
        assertEq(v.createdAt, vm.getBlockTimestamp());
        assertEq(v.countdown, address(0));
        assertEq(gr.gradReward(plain).state, 0);
    }

    /// @dev `createGangSwap`'s logs, one for one, then the seed's Transfer and GradRewardSet: nothing else, in that order.
    function test_gr_create_events() public {
        _openBoth();
        vm.recordLogs();
        _createGS(creator, 9 ether);
        Vm.Log[] memory a = vm.getRecordedLogs();
        address t = _createR(10);
        Vm.Log[] memory b = vm.getRecordedLogs();
        uint256 n = b.length;
        uint256 gsAt;
        uint256 matched;
        for (uint256 i; i < n; i++) {
            if (matched < a.length && b[i].emitter != address(wbnb) && b[i].topics[0] == a[matched].topics[0]) {
                if (b[i].topics[0] == IGangSwapPad.GangSwapCreated.selector) gsAt = i;
                matched++;
            }
        }
        assertEq(matched, a.length, "every log of createGangSwap, in order");
        assertEq(b[n - 1].topics[0], IGangGradRewardBase.GradRewardSet.selector, "last");
        assertEq(b[n - 1].topics[1], bytes32(uint256(uint160(t))));
        assertEq(
            b[n - 1].data,
            abi.encode(
                uint256(SEED), uint256(MIN_BUY), uint8(10), uint16(3_000), uint16(0), uint32(REFUND_AFTER), address(0)
            )
        );
        assertEq(gsAt, a.length - 1, "then only the pull and GradRewardSet");
        for (uint256 i = gsAt + 1; i < n - 1; i++) {
            assertEq(b[i].emitter, address(wbnb));
        }
    }

    function test_gr_create_badConfig() public {
        _openBoth();
        bytes4 bad = IGangGradRewardBase.BadGradConfig.selector;
        IGangGradRewardBase.GradConfig memory c = _cfg(10);
        c.seed = 0;
        _refused(c, bad);
        c = _cfg(10);
        c.minBuy = 0;
        _refused(c, bad);
        _refused(_cfg(0), bad);
        _refused(_cfg(21), bad);
        c = _cfg(10);
        c.lastBps = 5_001;
        _refused(c, bad);
        c = _cfg(10);
        c.refundAfter = 30 days - 1;
        _refused(c, bad);
        c.refundAfter = 180 days + 1;
        _refused(c, bad);
        // no carry, no promoter share, whatever the values
        uint16[3] memory carries = [uint16(1), 5_000, 5_001];
        for (uint256 i; i < 3; i++) {
            c = _cfg(10);
            c.carryBps = carries[i];
            _refused(c, bad);
        }
        c = _cfg(10);
        c.promoteBps = 1;
        _refused(c, bad);
        c.promoteWindow = 30 days;
        _refused(c, bad); // valid terms on a kind-1 token
        c.promoteBps = 0;
        _refused(c, bad);
        // bounds are allowed
        c = _cfg(20);
        c.seed = 1;
        c.minBuy = 1;
        c.lastBps = 5_000;
        c.refundAfter = 180 days;
        _createR(c);
        c = _cfg(1);
        c.lastBps = 0;
        c.refundAfter = 30 days;
        _createR(c);
    }

    function test_gr_create_switches() public {
        // both closed, then each alone
        _refused(_cfg(10), IGangGradRewardBase.GradNotOpen.selector);
        _open();
        _refused(_cfg(10), IGangGradRewardBase.GradNotOpen.selector);
        _openBoth();
        vm.prank(owner);
        m.setGangSwapMigrator(address(0));
        _refused(_cfg(10), IGangSwapPad.GangSwapNotOpen.selector);
        // 0 is no wildcard while closed or open
        vm.prank(creator);
        vm.expectRevert(IGangSwapPad.GangSwapNotOpen.selector);
        m.createGangSwapWithGradReward("S", "S", "", "", 9 ether, address(0), _cfg(10));
        _open();
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IGangSwapPad.GangSwapVersionChanged.selector, address(gsMigrator)));
        m.createGangSwapWithGradReward("S", "S", "", "", 9 ether, address(0), _cfg(10));
        // createGangSwap without a reward needs only its own switch; and back
        vm.prank(owner);
        m.setGradReward(false, address(admin), address(0));
        _createGS(creator, 9 ether);
        _refused(_cfg(10), IGangGradRewardBase.GradNotOpen.selector);
    }

    function test_gr_create_otherChecks() public {
        _openBoth();
        vm.startPrank(creator);
        vm.expectRevert(IGangLaunchpad.BadGradTarget.selector);
        m.createGangSwapWithGradReward("S", "S", "", "", 10 ether, address(gsMigrator), _cfg(10));
        (bool ok,) = address(m).call{value: 1}(_data(9 ether, address(gsMigrator), _cfg(10)));
        assertFalse(ok, "not payable");
        vm.stopPrank();
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(IGangLaunchpad.NotAgent.selector);
        m.createGangSwapWithGradReward("S", "S", "", "", 9 ether, address(gsMigrator), _cfg(10));
    }

    /// @dev A pull that fails (balance, allowance, short) reverts the whole create: no token, no reward, nothing moved.
    function test_gr_create_failedPullRevertsAll() public {
        _openBoth();
        uint256 n = p.tokenCount();
        uint256 held = _wbnb(address(pad));
        uint256 dev = _wbnb(creator);
        IGangGradRewardBase.GradConfig memory c = _cfg(10);
        c.seed = uint128(dev + 1);
        vm.prank(creator);
        vm.expectRevert();
        m.createGangSwapWithGradReward("S", "S", "", "", 9 ether, address(gsMigrator), c);
        c.seed = type(uint128).max;
        vm.prank(creator);
        vm.expectRevert();
        m.createGangSwapWithGradReward("S", "S", "", "", 9 ether, address(gsMigrator), c);
        vm.startPrank(creator);
        wbnb.approve(address(pad), SEED - 1);
        vm.expectRevert();
        m.createGangSwapWithGradReward("S", "S", "", "", 9 ether, address(gsMigrator), _cfg(10));
        wbnb.approve(address(pad), SEED);
        vm.stopPrank();
        // returns true, moves nothing
        vm.mockCall(address(wbnb), abi.encodeWithSelector(IERC20.transferFrom.selector), abi.encode(true));
        _refused(_cfg(10), IGangLaunchpad.FeeOnTransferQuote.selector);
        vm.clearMockedCalls();
        assertEq(p.tokenCount(), n);
        assertEq(_wbnb(address(pad)), held);
        assertEq(_wbnb(creator), dev);
        // an agent window around it is not left pending either
        vm.prank(creator);
        vm.expectRevert();
        IGangAgentWindow(address(pad)).createWithAgentWindow(30, _data(9 ether, address(0xdead), _cfg(10)));
        address t = _createR(10); // exactly the allowance
        assertEq(IGangAgentWindow(address(pad)).agentOpenAt(t), 0);
        assertEq(wbnb.allowance(creator, address(pad)), 0);
    }

    /// @dev Were the quote to call back during the pull (WBNB does not), the pad's guard stops every state-changing entry.
    function test_gr_create_pullCannotReenter() public {
        _openBoth();
        address t = _createR(10);
        bytes[] memory calls = new bytes[](6);
        calls[0] = _data(9 ether, address(gsMigrator), _cfg(10));
        calls[1] = abi.encodeCall(IGangSwapPad.createGangSwap, ("S", "S", "", "", 9 ether, address(gsMigrator)));
        calls[2] = abi.encodeCall(IGangGradReward.claimGradReward, (t));
        calls[3] = abi.encodeCall(IGangGradReward.gradRefund, (t));
        calls[4] = abi.encodeCall(IGangGradReward.settleGradReward, (t));
        calls[5] = abi.encodeWithSignature("buy(address,uint256,uint256)", t, 1 ether, 0);
        vm.etch(address(wbnb), address(new HookedWbnb()).code);
        for (uint256 i; i < calls.length; i++) {
            HookedWbnb(address(wbnb)).set(address(pad), calls[i]);
            _refused(_cfg(10), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        }
    }

    function _salt(Pad3VanityDeployer f, address who) internal view returns (bytes32 salt) {
        bytes32 hash = f.tokenInitCodeHash("Swap", "GSW", "meta", address(0), 0, 0, false);
        (salt,) = Pad3VanitySalt.find(address(f), who, hash);
    }

    function _vanity() internal returns (Pad3VanityDeployer f) {
        f = new Pad3VanityDeployer(address(pad), address(tokenDeployer), address(flyDeployer));
        vm.prank(owner);
        m.enableVanity(address(f));
    }

    function test_gr_createWithSalt() public {
        _openBoth();
        bytes32 salt = _salt(_vanity(), creator);
        bytes memory data = _data(9 ether, address(gsMigrator), _cfg(10));
        vm.startPrank(creator);
        vm.expectRevert();
        m.createWithSalt{value: 1 ether}(salt, data);
        vm.expectRevert(abi.encodeWithSelector(IGangSwapPad.GangSwapVersionChanged.selector, address(gsMigrator)));
        m.createWithSalt(salt, _data(9 ether, address(0xdead), _cfg(10)));
        vm.expectRevert(IGangGradRewardBase.BadGradConfig.selector);
        m.createWithSalt(salt, _data(9 ether, address(gsMigrator), _cfg(0)));
        // not outside it once vanity is on
        vm.expectRevert(Pad3Module.VanityContextRequired.selector);
        m.createGangSwapWithGradReward("Swap", "GSW", "logo", "meta", 9 ether, address(gsMigrator), _cfg(10));
        uint256 dev = _wbnb(creator);
        address t = m.createWithSalt(salt, data);
        vm.stopPrank();
        assertEq(uint16(uint160(t)), 0xabcd);
        assertEq(p.kindOf(t), KIND_GS);
        assertEq(gr.gradReward(t).pot, SEED);
        assertEq(dev - _wbnb(creator), SEED, "pulled from the creator, not the pad");
    }

    /// @dev Window + salt + reward, nested; the reward counts buys as a kind-1 window token's: Agents only, before and
    ///      after the window, though anyone trades after it.
    function test_gr_windowSaltReward() public {
        _openBoth();
        vm.prank(owner);
        pad.setWalletCapEnabled(true);
        bytes32 salt = _salt(_vanity(), creator);
        bytes memory inner =
            abi.encodeCall(Pad3Module.createWithSalt, (salt, _data(9 ether, address(gsMigrator), _cfg(10))));
        vm.prank(creator);
        address t = IGangAgentWindow(address(pad)).createWithAgentWindow(30, inner);
        assertEq(uint16(uint160(t)), 0xabcd);
        assertEq(IGangAgentWindow(address(pad)).agentOpenAt(t), vm.getBlockTimestamp() + 30 minutes);
        assertEq(gr.gradReward(t).pot, SEED);

        address human = makeAddr("human");
        wbnb.mintUnlimited(human, 100 ether);
        vm.prank(human);
        wbnb.approve(address(pad), type(uint256).max);
        vm.prank(human, human);
        vm.expectRevert(IGangLaunchpad.NotAgent.selector);
        pad.buy(t, 0.5 ether, 0);
        address a = _newAgent();
        _buyAs(t, a, 1 ether); // cut by the 1% cap, below minBuy: not counted
        assertEq(gr.gradReward(t).seq, 0);
        assertEq(IERC20(t).balanceOf(a), 10_000_000 ether);

        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        _buyAs(t, human, 2 ether); // open: trades, not counted
        assertEq(gr.gradReward(t).seq, 0);
        _buyAs(t, a, 1 ether);
        assertEq(gr.gradReward(t).seq, 1);
        _buyAs(t, human, 20 ether); // graduates it, still not counted
        assertTrue(_graduated(t));
        assertEq(gr.gradReward(t).seq, 1);
        assertEq(gr.gradClaimable(t, human), 0);
        assertEq(_claimAs(t, a), SEED);
    }

    function test_gr_createWithAgentWindow() public {
        _openBoth();
        vm.prank(creator);
        address t =
            IGangAgentWindow(address(pad)).createWithAgentWindow(5, _data(6 ether, address(gsMigrator), _cfg(10)));
        assertEq(p.kindOf(t), KIND_GS);
        assertEq(gr.gradReward(t).state, 1);
        assertEq(IGangAgentWindow(address(pad)).agentOpenAt(t), vm.getBlockTimestamp() + 5 minutes);
        vm.prank(creator);
        vm.expectRevert(IGangGradRewardBase.BadGradConfig.selector);
        IGangAgentWindow(address(pad)).createWithAgentWindow(5, _data(6 ether, address(gsMigrator), _cfg(21)));
    }

    // ---------------------------------------------------------------- curve trades and quotes
    /// @dev Every curve entry and quote on a reward GangSwap token as on a plain kind-1 token, to the wei.
    function test_gr_curveTrades_matchKind1() public {
        _openBoth();
        address a = _createR(10);
        address b = _createCurve(creator);
        vm.startPrank(owner);
        pad.setWalletCapEnabled(true);
        padRegistry3.addPad(address(pad));
        vm.stopPrank();
        address w = _newAgent();
        for (uint256 i; i < 2; i++) {
            (uint256 o1, uint256 c1, uint256 f1, uint256 r1) =
                padRegistry3.previewBuy(a, i == 0 ? w : address(0), 1 ether);
            (uint256 o2, uint256 c2, uint256 f2, uint256 r2) =
                padRegistry3.previewBuy(b, i == 0 ? w : address(0), 1 ether);
            assertGt(o1, 0);
            assertEq(abi.encode(o1, c1, f1, r1), abi.encode(o2, c2, f2, r2));
        }
        (address rp, uint8 kind) = padRegistry3.lookup(a);
        assertEq(rp, address(pad));
        assertEq(kind, KIND_GS);
        _sameTrades(w, a, b);
    }

    /// @dev Every way to buy and sell on the curve feeds the list.
    function test_gr_entries_allPaths() public {
        _openBoth();
        address t = _createR(10);
        address a = _newAgent();
        address b = _newAgent();
        address c = _newAgent();
        _buyAs(t, a, 0.5 ether);
        vm.prank(b, b);
        p.buyTokenAMAP{value: 0.5 ether}(t, b, 0.5 ether, 0);
        vm.prank(c, c);
        router.v3BuyBNB{value: 0.5 ether}(t, 0, vm.getBlockTimestamp());
        vm.prank(c, c);
        vm.expectRevert(IGangLaunchpad3.NotCurveToken.selector);
        IGangPromote(address(pad)).buyWithPromoter{value: 0.5 ether}(t, 0.5 ether, 0, address(0));
        (address[] memory buyers,,, bool[] memory valid) = gr.gradEntries(t);
        assertEq(buyers.length, 3);
        assertEq(buyers[0], c);
        assertEq(buyers[1], b);
        assertEq(buyers[2], a);
        uint256 amt = IERC20(t).balanceOf(b) / 4;
        vm.startPrank(b, b);
        IERC20(t).approve(address(pad), amt);
        p.sellToken(0, t, b, amt, 0, 0, address(0));
        vm.stopPrank();
        (,,, valid) = gr.gradEntries(t);
        assertTrue(valid[0] && !valid[1] && valid[2]);
    }

    function test_gr_gateOffNotCounted() public {
        _openBoth();
        address t = _createR(10);
        _buyAs(t, _newAgent(), 1 ether);
        vm.prank(owner);
        pad.setAgentGate(false, address(agents));
        _buyAs(t, _newAgent(), 1 ether);
        assertEq(gr.gradReward(t).seq, 1);
        vm.prank(owner);
        pad.setAgentGate(true, address(agents));
        _buyAs(t, _newAgent(), 1 ether);
        assertEq(gr.gradReward(t).seq, 2);
    }

    // ---------------------------------------------------------------- graduation, claims, sweep
    function _pairNumbers(address t) internal view returns (bytes memory) {
        IGSPair x = IGSPair(_curvePair(t));
        (uint112 r0, uint112 r1,) = x.getReserves();
        (uint256 rq, uint256 rt) = x.quoteIs0() ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        return abi.encode(rq, rt, x.virtualReserve(), x.realQuoteReserve(), x.totalSupply(), x.balanceOf(DEAD));
    }

    /// @dev A reward token and a plain GangSwap token bought by the same wallets with the same amounts graduate into
    ///      the same pool and buy-back; the pad keeps exactly the pot (and the creators' fees); then everyone claims,
    ///      the buy-back runs to its end without touching the pot, and the sweep pays the dust to the creator.
    function test_gr_graduate_poolBoostAndClaims() public {
        _openBoth();
        address t = _createR(3);
        address plain = _createGS(creator, 9 ether);
        address[4] memory w;
        for (uint256 i; i < 4; i++) {
            w[i] = _newAgent();
            uint256 amt = i == 3 ? 20 ether : 2 ether;
            _buyAs(t, w[i], amt);
            _buyAs(plain, w[i], amt);
        }
        assertTrue(_graduated(t) && _graduated(plain));
        assertEq(_pairNumbers(t), _pairNumbers(plain), "the same pool");
        IGSBoostG boost = IGSBoostG(gsBoost);
        (,,,, uint128 v1) = boost.boosts(t);
        (,,,, uint128 v2) = boost.boosts(plain);
        assertEq(v1, v2);
        assertEq(_wbnb(gsBoost), uint256(v1) + v2, "the buy-back holds its two V only");
        // a graduation cut leaves at most 1 wei of fee rounding on the pad (kind 1 too); it is no one's
        uint256 dust = _wbnb(address(pad)) - (SEED + p.creatorFeeOf(t) + p.creatorFeeOf(plain));
        assertLe(dust, 2);
        assertEq(p.creatorFeeOf(t), p.creatorFeeOf(plain));
        IGangGradRewardBase.GradView memory v = gr.gradReward(t);
        assertEq(v.state, 2);
        assertEq(v.pot, SEED);
        assertEq(v.seq, 4);
        assertEq(v.carryOwed, 0);

        // w0 fell off the list of 3; w3 (the graduating buy) gets 30%, the three split 70% by spend
        assertEq(gr.gradClaimable(t, w[0]), 0);
        (,, uint96[] memory spent,) = gr.gradEntries(t);
        uint256 vs = uint256(spent[0]) + spent[1] + spent[2];
        assertEq(_claimAs(t, w[3]), SEED * 3 / 10 + (uint256(SEED) * 7 / 10) * spent[0] / vs);
        // the buy-back, to its end, between two claims
        uint256 left = 1;
        while (left != 0) {
            vm.warp(vm.getBlockTimestamp() + 8);
            boost.step(t);
            (,,,, uint128 l) = boost.boosts(t);
            left = l;
        }
        assertEq(_wbnb(gsBoost), v2);
        uint256 paid = gr.gradReward(t).claimed;
        assertEq(_wbnb(address(pad)), SEED - paid + p.creatorFeeOf(t) + p.creatorFeeOf(plain) + dust);
        paid += _claimAs(t, w[1]) + _claimAs(t, w[2]);
        assertEq(gr.gradReward(t).claimed, paid);
        vm.prank(w[0]);
        vm.expectRevert(IGangGradRewardBase.NothingToClaim.selector);
        gr.claimGradReward(t);
        vm.prank(w[1]);
        vm.expectRevert(IGangGradRewardBase.AlreadyClaimed.selector);
        gr.claimGradReward(t);
        vm.expectRevert(IGangGradRewardBase.NoCarryOwed.selector);
        gr.retryCarry(t);
        vm.expectRevert(IGangGradRewardBase.SweepNotDue.selector);
        gr.sweepGradReward(t);
        vm.warp(vm.getBlockTimestamp() + 180 days);
        uint256 dev = _wbnb(creator);
        gr.sweepGradReward(t);
        assertEq(_wbnb(creator) - dev, SEED - paid);
        assertEq(gr.gradReward(t).state, 4);
        vm.expectRevert(IGangGradRewardBase.NotGradState.selector);
        gr.sweepGradReward(t);
        // the creators' curve fees are still all there
        vm.startPrank(creator);
        uint256 f1 = pad.claimCreatorFee(t, creator);
        uint256 f2 = pad.claimCreatorFee(plain, creator);
        vm.stopPrank();
        assertGt(f1 + f2, 0);
        assertEq(_wbnb(address(pad)), dust, "nothing left, nothing missing");
    }

    /// @dev No claim at all: the whole pool is the creator's again after the window.
    function test_gr_sweep_unclaimedWhole() public {
        _openBoth();
        address t = _createR(10);
        _buyAs(t, _newAgent(), 30 ether);
        vm.warp(vm.getBlockTimestamp() + 180 days);
        uint256 dev = _wbnb(creator);
        gr.sweepGradReward(t);
        assertEq(_wbnb(creator) - dev, SEED);
        assertEq(gr.gradReward(t).carryOwed, 0);
    }

    /// @dev The creator's own last buys are as good as anyone's (spec: it can win its own money back).
    function test_gr_creatorCanWinIt() public {
        _openBoth();
        address t = _createR(10);
        _buyAs(t, creator, 30 ether);
        assertEq(_claimAs(t, creator), SEED);
    }

    /// @dev Everyone sold everything back: every entry is out, the curve pays in full from its own money, and a
    ///      graduation with the gate off pays the pool back to the creator.
    function test_gr_allSoldBack() public {
        _openBoth();
        address t = _createR(10);
        address[3] memory w;
        for (uint256 i; i < 3; i++) {
            w[i] = _newAgent();
            _buyAs(t, w[i], 2 ether);
        }
        for (uint256 i; i < 3; i++) {
            _sellAll(t, w[i]);
        }
        assertEq(_curveSold(t), 0);
        (,,, bool[] memory valid) = gr.gradEntries(t);
        assertFalse(valid[0] || valid[1] || valid[2]);
        assertEq(_wbnb(address(pad)), SEED + _curveRealQuote(t) + p.creatorFeeOf(t));
        vm.prank(owner);
        pad.setAgentGate(false, address(agents));
        _buyAs(t, _newAgent(), 30 ether);
        assertTrue(_graduated(t));
        uint256 dev = _wbnb(creator);
        gr.settleGradReward(t);
        assertEq(_wbnb(creator) - dev, SEED);
        assertEq(gr.gradReward(t).state, 4);
        assertLe(_wbnb(address(pad)) - p.creatorFeeOf(t), 1); // the graduation cut's rounding
    }

    /// @dev The graduating buy through the GangSwap migrator: without a reward, with a list of 20 whose last (empty) slot
    ///      it writes (the dearest), and with a full one. Run with `--isolate` for the cost of a transaction on its own.
    function test_gr_gasOfGraduatingBuy() public {
        _openBoth();
        address t = _createR(20);
        address full = _createR(20);
        address plain = _createGS(creator, 9 ether);
        for (uint256 i; i < 20; i++) {
            address w = _newAgent();
            if (i < 19) _buyAs(t, w, 0.4 ether);
            else _buyAs(t, w, 0.05 ether); // under minBuy: the 20th slot stays empty
            _buyAs(full, w, 0.4 ether);
            _buyAs(plain, w, 0.4 ether);
        }
        uint256 gPlain = _gasOfLast(plain);
        uint256 gWorst = _gasOfLast(t);
        uint256 gFull = _gasOfLast(full);
        assertEq(gr.gradReward(t).seq, 20);
        assertEq(gr.gradReward(full).seq, 21);
        emit log_named_uint("graduating buy gas, no reward", gPlain);
        emit log_named_uint("graduating buy gas, reward, the 20th slot fresh", gWorst);
        emit log_named_uint("graduating buy gas, reward, full list", gFull);
        assertLt(gWorst, 2_700_000);
        (address[] memory buyers,,,) = gr.gradEntries(t);
        vm.prank(buyers[0]);
        uint256 g = gasleft();
        gr.claimGradReward(t);
        emit log_named_uint("first claim gas (settles 20)", g - gasleft());
    }

    function _gasOfLast(address t) internal returns (uint256 g) {
        address e = _newAgent();
        vm.prank(e, e);
        g = gasleft();
        pad.buy(t, 10 ether, 0);
        g -= gasleft();
        assertTrue(_graduated(t));
    }

    // ---------------------------------------------------------------- refund
    function test_gr_refund_requestCancelLapseRefund() public {
        _openBoth();
        address t = _createR(10);
        vm.startPrank(creator);
        vm.expectRevert(IGangGradRewardBase.RefundNotDue.selector);
        gr.requestGradRefund(t);
        vm.warp(vm.getBlockTimestamp() + REFUND_AFTER);
        gr.requestGradRefund(t);
        gr.cancelGradRefund(t);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.expectRevert(IGangGradRewardBase.RefundNotDue.selector);
        gr.gradRefund(t);
        gr.requestGradRefund(t);
        vm.warp(vm.getBlockTimestamp() + 10 days); // lapsed
        vm.expectRevert(IGangGradRewardBase.RefundNotDue.selector);
        gr.gradRefund(t);
        gr.requestGradRefund(t);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.stopPrank();
        vm.prank(_newAgent());
        vm.expectRevert(IGangLaunchpad.NotCreator.selector);
        gr.gradRefund(t);
        // the curve holds money of its own: not part of the refund
        _buyAs(t, _newAgent(), 3 ether);
        uint256 dev = _wbnb(creator);
        vm.prank(creator);
        assertEq(gr.gradRefund(t), SEED);
        assertEq(_wbnb(creator) - dev, SEED);
        assertEq(_wbnb(address(pad)), _curveRealQuote(t) + p.creatorFeeOf(t));
        // it still graduates into GangSwap, and pays nothing
        address e = _newAgent();
        _buyAs(t, e, 30 ether);
        (uint8 s,,,,) = _info(t);
        assertEq(s, STATUS_GANGSWAP);
        assertEq(gr.gradReward(t).state, 3);
        vm.prank(e);
        vm.expectRevert(IGangGradRewardBase.NotGradState.selector);
        gr.claimGradReward(t);
        vm.prank(creator);
        vm.expectRevert(IGangGradRewardBase.NotGradState.selector);
        gr.gradRefund(t);
        assertLe(_wbnb(address(pad)) - p.creatorFeeOf(t), 1); // the graduation cut's rounding
    }

    function test_gr_refund_graduationDuringNoticePays() public {
        _openBoth();
        address t = _createR(10);
        vm.warp(vm.getBlockTimestamp() + REFUND_AFTER);
        vm.prank(creator);
        gr.requestGradRefund(t);
        vm.warp(vm.getBlockTimestamp() + 7 days); // ready to take
        address e = _newAgent();
        _buyAs(t, e, 30 ether);
        assertEq(gr.gradReward(t).refundAt, 0);
        vm.prank(creator);
        vm.expectRevert(IGangGradRewardBase.NotGradState.selector);
        gr.gradRefund(t);
        assertEq(_claimAs(t, e), SEED);
    }

    function test_gr_refund_afterAllSoldBack() public {
        _openBoth();
        address t = _createR(10);
        address a = _newAgent();
        _buyAs(t, a, 5 ether);
        _sellAll(t, a);
        vm.warp(vm.getBlockTimestamp() + REFUND_AFTER);
        vm.prank(creator);
        gr.requestGradRefund(t);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(creator);
        assertEq(gr.gradRefund(t), SEED);
        assertEq(_wbnb(address(pad)), _curveRealQuote(t) + p.creatorFeeOf(t));
    }

    // ---------------------------------------------------------------- versions and switches after the create
    function test_gr_versionAndSwitchesAfterCreate() public {
        _openBoth();
        address t1 = _createR(10);
        (IGSMigrator v2,,, IGSFactory factory2) = _deployGangSwap(true);
        vm.prank(owner);
        m.setGangSwapMigrator(address(v2));
        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IGangSwapPad.GangSwapVersionChanged.selector, address(v2)));
        m.createGangSwapWithGradReward("S", "S", "", "", 9 ether, address(gsMigrator), _cfg(10));
        vm.prank(creator);
        address t2 = m.createGangSwapWithGradReward("S", "S", "", "", 9 ether, address(v2), _cfg(10));
        assertEq(m.gangSwapMigratorOf(t2), address(v2));
        // both switches closed: both still graduate through their own version and pay
        vm.startPrank(owner);
        m.setGangSwapMigrator(address(0));
        m.setGradReward(false, address(admin), address(0));
        vm.stopPrank();
        address e = _newAgent();
        _buyAs(t1, e, 30 ether);
        _buyAs(t2, e, 30 ether);
        assertEq(gsFactory.getPair(t1, address(wbnb)), _curvePair(t1));
        assertEq(factory2.getPair(t2, address(wbnb)), _curvePair(t2));
        assertEq(_claimAs(t1, e), SEED);
        assertEq(_claimAs(t2, e), SEED);
    }

    // ---------------------------------------------------------------- the pad's money
    /// @dev Reward GangSwap tokens, a plain one, a kind-1 one and a kind-1 reward one traded at random: the pad holds every
    ///      curve's quote, every creator's fee and every pool not paid out.
    function testFuzz_gr_solvency(uint256 seed) public {
        _openBoth();
        address[5] memory ts;
        ts[0] = _createR(3);
        ts[1] = _createR(20);
        ts[2] = _createGS(creator, 6 ether);
        ts[3] = _createCurve(creator);
        vm.prank(creator);
        ts[4] = m.createWithGradReward(
            "G", "G", "", "", address(wbnb), address(0), _tax(0, 0, 0, address(0)), 9 ether, _cfg(5)
        );
        address[4] memory w;
        for (uint256 i; i < 4; i++) {
            w[i] = _newAgent();
        }
        for (uint256 i; i < 24; i++) {
            seed = uint256(keccak256(abi.encode(seed)));
            address t = ts[seed % 5];
            address who = w[(seed >> 8) % 4];
            if (!_graduated(t)) {
                if ((seed >> 16) % 3 == 0 && IERC20(t).balanceOf(who) != 0) _sellAll(t, who);
                else _buyAs(t, who, 0.05 ether + (seed >> 32) % 4 ether);
            } else if (gr.gradClaimable(t, who) != 0) {
                _claimAs(t, who);
            }
            uint256 owed;
            for (uint256 j; j < 5; j++) {
                IGangGradRewardBase.GradView memory v = gr.gradReward(ts[j]);
                owed += _curveRealQuote(ts[j]) + p.creatorFeeOf(ts[j]) + v.pot - v.claimed;
            }
            // never short; at most 1 wei of fee rounding over per cut buy
            assertGe(_wbnb(address(pad)), owed);
            assertLe(_wbnb(address(pad)) - owed, 5);
        }
    }

    // ---------------------------------------------------------------- storage: no new slot anywhere
    /// @dev The create writes the two namespaces' existing members and nothing new: one migrator word (GangSwap), and the
    ///      reward's first two words, as a kind-1 reward create.
    function test_gr_storageWrites() public {
        _openBoth();
        vm.record();
        address plain = _createGS(creator, 9 ether);
        (, bytes32[] memory a) = vm.accesses(address(pad));
        vm.record();
        address t = _createR(10);
        (, bytes32[] memory b) = vm.accesses(address(pad));
        assertEq(
            address(
                uint160(uint256(vm.load(address(pad), keccak256(abi.encode(t, uint256(Pad3GangSwapStore.SLOT) + 1)))))
            ),
            address(gsMigrator)
        );
        uint256 base = uint256(keccak256(abi.encode(t, uint256(Pad3GradStore.SLOT) + 2)));
        uint256 rewardWrites;
        for (uint256 i; i < b.length; i++) {
            uint256 s = uint256(b[i]);
            if (s >= base && s < base + 5) {
                rewardWrites++;
                assertLe(s, base + 2, "words 0-2 only");
            }
        }
        assertGt(rewardWrites, 0);
        assertEq(b.length, a.length + rewardWrites, "createGangSwap's writes plus the reward's words");
        assertEq(
            uint256(
                vm.load(address(pad), bytes32(uint256(keccak256(abi.encode(plain, uint256(Pad3GradStore.SLOT) + 2)))))
            ),
            0
        );
    }

    // ---------------------------------------------------------------- the upgrade script
    function test_gr_upgradeScript_seesEveryReward() public {
        GradUpgradeHarness h = new GradUpgradeHarness();
        DeployGang.Stack memory st;
        _openBoth();
        address t = _createR(3);
        vm.prank(creator);
        address k1 = m.createWithGradReward(
            "G", "G", "", "", address(wbnb), address(0), _tax(0, 0, 0, address(0)), 9 ether, _cfg(5)
        );
        address a = _newAgent();
        _buyAs(t, a, 1 ether);
        _buyAs(k1, a, 1 ether);
        for (uint256 i; i < 25; i++) {
            _createCurve(creator); // both outside the newest 25
        }
        UpgradeGangLaunchpad3.Snapshot memory s = h.snap(p, st);
        bytes32 full = s.grad;
        assertEq(keccak256(h.gradState(p)), full);
        h.compare(s, h.snap(p, st));
        // every stored word, the list, the sold mark, the deps
        address[2] memory ts = [t, k1];
        for (uint256 j; j < 2; j++) {
            uint256 base = uint256(keccak256(abi.encode(ts[j], uint256(Pad3GradStore.SLOT) + 2)));
            for (uint256 i; i < 5; i++) {
                _flip(h, bytes32(base + i), full);
            }
            _flip(h, keccak256(abi.encode(ts[j], uint256(Pad3GradStore.SLOT) + 3)), full); // ringOf[0]
            _flip(h, keccak256(abi.encode(a, keccak256(abi.encode(ts[j], uint256(Pad3GradStore.SLOT) + 4)))), full);
            // a reward that reads as gone
            bytes32 was = vm.load(address(pad), bytes32(base));
            vm.store(address(pad), bytes32(base), 0);
            assertTrue(keccak256(h.gradState(p)) != full);
            vm.store(address(pad), bytes32(base), was);
        }
        _flip(h, Pad3GradStore.SLOT, full);
        _flip(h, bytes32(uint256(Pad3GradStore.SLOT) + 1), full);
        // a view that reads otherwise over the same storage
        bytes[] memory calls = new bytes[](3);
        calls[0] = abi.encodeCall(IGangGradReward.gradReward, (t));
        calls[1] = abi.encodeCall(IGangGradReward.gradEntries, (t));
        calls[2] = abi.encodeCall(IGangGradReward.gradClaimable, (t, a));
        bytes[3] memory rets = [bytes(""), bytes(""), abi.encode(uint256(7))];
        // k1's list differs from t's once another buyer is on it
        _buyAs(k1, _newAgent(), 1 ether);
        (, rets[0]) = address(pad).staticcall(abi.encodeCall(IGangGradReward.gradReward, (k1)));
        (, rets[1]) = address(pad).staticcall(abi.encodeCall(IGangGradReward.gradEntries, (k1)));
        full = keccak256(h.gradState(p));
        for (uint256 i; i < 3; i++) {
            vm.mockCall(address(pad), calls[i], rets[i]);
            assertTrue(keccak256(h.gradState(p)) != full, "a view");
            vm.clearMockedCalls();
        }
        assertEq(keccak256(h.gradState(p)), full);
        // the comparison refuses a difference; a graduated and claimed one compares
        UpgradeGangLaunchpad3.Snapshot memory x = h.snap(p, st);
        s = h.snap(p, st);
        x.grad = bytes32(uint256(1));
        vm.expectRevert(_wiring("upgrade: graduation reward state changed"));
        h.compare(s, x);
        _buyAs(t, a, 30 ether);
        _claimAs(t, a);
        h.compare(h.snap(p, st), h.snap(p, st));
        assertTrue(keccak256(h.gradState(p)) != full);
    }

    function _flip(GradUpgradeHarness h, bytes32 slot, bytes32 full) internal {
        bytes32 was = vm.load(address(pad), slot);
        // above state and entries (word 0's low bytes), inside every other member
        vm.store(address(pad), slot, was ^ bytes32(uint256(1) << 40));
        assertTrue(keccak256(h.gradState(p)) != full, "a stored word");
        vm.store(address(pad), slot, was);
        assertEq(keccak256(h.gradState(p)), full);
    }

    function test_gr_upgradeScript_createWired() public {
        GradUpgradeHarness h = new GradUpgradeHarness();
        h.checkGradCreate(p); // reward closed, abcd off
        _openBoth();
        uint256 n = p.tokenCount();
        h.checkGradCreate(p);
        vm.prank(owner);
        m.setGangSwapMigrator(address(0));
        h.checkGradCreate(p); // GangSwap closed
        _open();
        _vanity();
        h.checkGradCreate(p);
        assertEq(p.tokenCount(), n);

        // each probe, each way in, answered otherwise: refused (the other ways answer as they should)
        bytes[2] memory wants = [
            abi.encodeWithSelector(IGangGradRewardBase.BadGradConfig.selector),
            abi.encodeWithSelector(IGangSwapPad.GangSwapVersionChanged.selector, address(gsMigrator))
        ];
        for (uint256 k; k < 2; k++) {
            IGangGradRewardBase.GradConfig memory c;
            if (k == 1) (c.seed, c.minBuy, c.entries, c.refundAfter) = (1, 1, 1, 30 days);
            bytes memory data = _probe(c);
            bytes[3] memory calls = [
                data,
                abi.encodeCall(IGangAgentWindow.createWithAgentWindow, (uint16(1), data)),
                abi.encodeCall(Pad3Module.createWithSalt, (bytes32(0), data))
            ];
            for (uint256 i; i < 3; i++) {
                for (uint256 j; j < 3; j++) {
                    vm.mockCallRevert(
                        address(pad),
                        calls[j],
                        j == i ? abi.encodeWithSelector(Pad3Module.BadVanityCall.selector) : wants[k]
                    );
                }
                vm.expectRevert(_wiring("upgrade: createGangSwapWithGradReward not wired"));
                h.checkGradCreate(p);
                vm.clearMockedCalls();
            }
        }
        h.checkGradCreate(p);
    }

    function _probe(IGangGradRewardBase.GradConfig memory c) internal view returns (bytes memory) {
        return
            abi.encodeCall(
                IGangSwapPad.createGangSwapWithGradReward, ("", "", "", "", uint256(6 ether), address(pad), c)
            );
    }
}
