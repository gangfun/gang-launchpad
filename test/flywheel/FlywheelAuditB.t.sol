// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {FlywheelFixture} from "./FlywheelFixture.sol";
import {FlywheelTaxHandler} from "../../src/flywheel/FlywheelTaxHandler.sol";
import {GangFlywheelPad} from "../../src/flywheel/GangFlywheelPad.sol";
import {IFlywheelPad} from "../../src/flywheel/interfaces/IFlywheelPad.sol";
import {TwapMockPair} from "../mocks/TwapMockPair.sol";

interface IOnPaid {
    function onPaid() external;
}

/// @dev An 18-decimal quote with a receive hook (ERC777-style tokensReceived, or any creator-made token): calls
///      `onPaid` on `hooked` whenever it receives.
contract HookQuote is ERC20("Hook", "HOOK") {
    address public hooked;

    function setHooked(address h) external {
        hooked = h;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (to == hooked && hooked != address(0) && from != address(0)) IOnPaid(to).onPaid();
    }
}

/// @dev The creator: a contract wallet holding an Agent ID. When its dev cut arrives (inside `launch`), it buys from
///      the fresh pair for `sniper`, a wallet with no Agent ID, far above the protection cap.
contract EvilCreator is IOnPaid {
    GangFlywheelPad pad;
    HookQuote quote;
    address public token;
    address sniper;
    uint256 public bought;

    constructor(GangFlywheelPad p, HookQuote q, address s) {
        (pad, quote, sniper) = (p, q, s);
    }

    function create(IFlywheelPad.FlyConfig memory c) external returns (address t) {
        quote.approve(address(pad), type(uint256).max);
        string[4] memory text = ["Fly", "FLY", "l", "m"];
        t = pad.create(text, address(quote), address(0), c, 1);
        token = t;
    }

    function onPaid() external {
        if (bought != 0 || token == address(0)) return;
        IFlywheelPad.Sale memory s = pad.sales(token);
        if (!s.launched || s.pair == address(0)) return;
        TwapMockPair p = TwapMockPair(s.pair);
        (uint112 r0, uint112 r1,) = p.getReserves();
        bool t0 = p.token0() == token;
        (uint256 rT, uint256 rQ) = t0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 qIn = rQ / 5; // 20% of the pool's quote
        uint256 out = (qIn * 9975 * rT) / (rQ * 10_000 + qIn * 9975);
        quote.mint(address(p), qIn);
        bought = out;
        p.swap(t0 ? out : 0, t0 ? 0 : out, sniper, "");
    }
}

/// @notice Pre-mainnet audit (2026-10-30), B-L1 and B-I1 fixed.
contract FlywheelAuditBFixesTest is FlywheelFixture {
    function setUp() public {
        _deploy();
    }

    /// B-L1: the protection and the oracle are on before the dev cut goes out. A quote calling the creator back now
    ///       meets the protection: its snipe for a wallet with no Agent ID is refused, the cut is owed instead, and the
    ///       oracle starts at the mint price.
    function test_B_L1_cutAfterProtection() public {
        HookQuote hq = new HookQuote();
        vm.prank(owner);
        quoteRegistry.setQuote(address(hq), true, 15 ether);
        address sniper = makeAddr("sniper-no-agent-id");
        EvilCreator evil = new EvilCreator(pad, hq, sniper);
        agents.mint(address(evil), 999_999);
        hq.mint(address(evil), 10 ether);

        IFlywheelPad.FlyConfig memory c = _wide();
        c.launchDelay = 60;
        address t = evil.create(c);
        for (uint256 i; pad.sales(t).filledAt == 0; i++) {
            address w = _newAgent();
            hq.mint(w, 100 ether);
            vm.startPrank(w);
            hq.approve(address(pad), type(uint256).max);
            while (pad.quotaLeft(t, w) > 0 && pad.sales(t).filledAt == 0) pad.mint(t, 10, 1, address(0));
            vm.stopPrank();
        }
        hq.setHooked(address(evil));
        vm.warp(vm.getBlockTimestamp() + 60);
        pad.launch(t);

        assertEq(IERC20(t).balanceOf(sniper), 0, "the snipe met the protection");
        assertEq(evil.bought(), 0);
        assertGt(pad.owedDev(t), 0, "the refused callback left the cut owed");
        (,, uint224 launchPrice,) = handler.oracleOf(t);
        uint256 mintPriceX112 = (uint256(pad.sales(t).basePrice) << 112) / TPS;
        assertApproxEqRel(launchPrice, mintPriceX112, 0.001e18, "the oracle starts at the mint price");
    }

    /// @dev A filled sale on a steep linear tier, 90 post-launch shares in: the next 10 still cost ×1, but 10 more
    ///      landing first cross the step at share 10,101 (×1.1).
    function _launchedTiers() internal returns (address t) {
        IFlywheelPad.FlyConfig memory c = _wide();
        c.tierMode = 2;
        c.stepBps = 1_000;
        c.stepShares = 100;
        c.maxMulX100 = 1_000;
        t = _create(c, 1);
        _fillAndLaunch(t);
        vm.warp(vm.getBlockTimestamp() + 700);
        while (pad.sales(t).totalShares < 10_090) {
            vm.roll(vm.getBlockNumber() + 1);
            vm.warp(vm.getBlockTimestamp() + 3);
            address w = _newAgent();
            vm.prank(w);
            pad.mintPost(t, 10, 0, type(uint256).max, address(0));
        }
        assertEq(pad.sales(t).totalShares, 10_090);
        assertEq(pad.sharePrice(t, 10), pad.sales(t).basePrice, "shares 10,091..10,100: x1");
        assertEq(pad.sharePrice(t, 20), (uint256(pad.sales(t).basePrice) * 110) / 100, "past 10,100: x1.1");
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 3);
    }

    /// B-I1: `maxSpent` bounds the bill. A mint landing first crosses a tier step: the quoted spend now refuses it.
    function test_B_I1_maxSpentRefusesAStepCrossedFirst() public {
        address t = _launchedTiers();
        address victim = _newAgent();
        (, uint256 paid, uint256 fee, uint256 out, bool ok) = pad.previewMintPost(t, victim, 10);
        assertTrue(ok);
        address other = _newAgent();
        vm.prank(other);
        pad.mintPost(t, 10, 0, type(uint256).max, address(0));
        vm.prank(victim);
        vm.expectRevert(IFlywheelPad.Slippage.selector);
        pad.mintPost(t, 10, out, paid + fee, address(0));
    }

    function test_B_I1_maxSpentAtThePreviewPasses() public {
        address t = _launchedTiers();
        address victim = _newAgent();
        (, uint256 paid, uint256 fee, uint256 out, bool ok) = pad.previewMintPost(t, victim, 10);
        assertTrue(ok);
        vm.prank(victim);
        (uint256 got, uint256 spent) = pad.mintPost(t, 10, out, paid + fee, address(0));
        assertEq(got, out);
        assertEq(spent, paid + fee);
    }
}
