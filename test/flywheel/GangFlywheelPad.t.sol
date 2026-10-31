// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GangMintToken} from "../../src/flywheel/GangMintToken.sol";
import {FlywheelTaxHandler} from "../../src/flywheel/FlywheelTaxHandler.sol";
import {IFlywheelPad} from "../../src/flywheel/interfaces/IFlywheelPad.sol";
import {FlywheelFixture} from "./FlywheelFixture.sol";
import {Vm} from "forge-std/Vm.sol";
import {TwapMockPair} from "../mocks/TwapMockPair.sol";

contract GangFlywheelPadTest is FlywheelFixture {
    uint256 constant PRICE = 20 ether / 10_000; // 0.002 BNB per share

    function setUp() public {
        _deploy();
    }

    // ------------------------------------------------------------ create
    function test_createMintsTheDevSharesAndWiresEverything() public {
        address t = _create(_agentMint(), 5);
        IFlywheelPad.Sale memory s = _sale(t);
        assertEq(s.creator, dev);
        assertEq(s.basePrice, PRICE);
        assertEq(s.sold, 5);
        assertEq(IERC20(t).balanceOf(dev), 5 * TPS);
        assertEq(IERC20(t).totalSupply(), 5 * TPS);
        assertEq(GangMintToken(t).maxSupply(), 2 * SHARES * TPS * 100);
        assertEq(GangMintToken(t).sellTaxBps(), 200);
        assertEq(pad.kindOf(t), 3);
        assertEq(pad.baselineOf(t, dev), 5 * TPS);
        assertEq(vault.shares(t, dev), 5 * TPS);
        (address q, address r) = handler.routeOf(t);
        assertEq(q, address(wbnb));
        assertEq(r, dev);
        // mint fee 1% to the platform, principal (dev cut included) held by the pad
        assertEq(wbnb.balanceOf(address(pad)), 5 * PRICE);
    }

    function test_createRefusesBadConfigs() public {
        IFlywheelPad.FlyConfig memory c = _agentMint();
        c.devCutBps = 1_000;
        (bool okCut,) = pad.checkConfig(c, 1);
        assertTrue(okCut);
        c.devCutBps = 1_001; // audit A-F2: the ceiling is 10%
        vm.prank(dev);
        vm.expectRevert(abi.encodeWithSelector(IFlywheelPad.BadConfig.selector, "devCutBps must be 0-1000"));
        pad.create(["a", "b", "c", "d"], address(0), address(0), c, 1);
        c = _agentMint();
        c.baseQuota = 101;
        (bool ok, string memory why) = pad.checkConfig(c, 1);
        assertFalse(ok);
        assertEq(why, "baseQuota must be 5-100");
        c = _agentMint();
        (ok,) = pad.checkConfig(c, 11); // > maxPerTx / quota
        assertFalse(ok);
    }

    // ------------------------------------------------------------ V2 config bounds
    function _why(IFlywheelPad.FlyConfig memory c) internal view returns (string memory why) {
        bool ok;
        (ok, why) = pad.checkConfig(c, 1);
        assertEq(ok, bytes(why).length == 0);
    }

    function test_checkConfigQuotaCeilingWithPostMint() public {
        IFlywheelPad.FlyConfig memory c = _agentMint();
        c.baseQuota = 10;
        assertEq(_why(c), "");
        c.baseQuota = 11;
        assertEq(_why(c), "baseQuota must be 5-10 with postMint");
        vm.prank(dev);
        vm.expectRevert(abi.encodeWithSelector(IFlywheelPad.BadConfig.selector, "baseQuota must be 5-10 with postMint"));
        pad.create(["a", "b", "c", "d"], address(0), address(0), c, 1);
        // without post-launch minting the V1 range stays
        c.postMint = false;
        assertEq(_why(c), "");
        address t = _create(c, 1);
        assertEq(_sale(t).baseQuota, 11);
        c.baseQuota = 100;
        assertEq(_why(c), "");
        c.baseQuota = 101;
        assertEq(_why(c), "baseQuota must be 5-100");
        c.baseQuota = 4;
        assertEq(_why(c), "baseQuota must be 5-100");
        c.postMint = true;
        assertEq(_why(c), "baseQuota must be 5-100");
    }

    function test_checkConfigGuardAndWindow() public {
        IFlywheelPad.FlyConfig memory c = _agentMint();
        uint16[4] memory okGuards = [uint16(0), 1_500, 2_000, 3_000];
        for (uint256 i; i < 4; i++) {
            c.guardBps = okGuards[i];
            assertEq(_why(c), "");
        }
        uint16[6] memory badGuards = [uint16(1), 1_000, 1_499, 2_500, 3_001, 5_000];
        for (uint256 i; i < 6; i++) {
            c.guardBps = badGuards[i];
            assertEq(_why(c), "guardBps must be 0, 1500, 2000 or 3000");
        }
        c.guardBps = 0;
        c.twapWindow = 900;
        assertEq(_why(c), "");
        uint32[6] memory badWindows = [uint32(0), 600, 899, 901, 1_200, 3_600];
        for (uint256 i; i < 6; i++) {
            c.twapWindow = badWindows[i];
            assertEq(_why(c), "twapWindow must be 900 or 1800");
        }
        // checked whether or not the sale mints after launch
        c.postMint = false;
        assertEq(_why(c), "twapWindow must be 900 or 1800");
        c.twapWindow = 1_800;
        c.guardBps = 1_000;
        assertEq(_why(c), "guardBps must be 0, 1500, 2000 or 3000");
        vm.prank(dev);
        vm.expectRevert(
            abi.encodeWithSelector(IFlywheelPad.BadConfig.selector, "guardBps must be 0, 1500, 2000 or 3000")
        );
        pad.create(["a", "b", "c", "d"], address(0), address(0), c, 1);
    }

    function test_createStoresThePostRulesAndEmitsThem() public {
        IFlywheelPad.FlyConfig memory c = _agentMint();
        c.guardBps = 2_000;
        c.twapWindow = 900;
        vm.recordLogs();
        address t = _create(c, 1);
        (uint16 g, uint32 w) = pad.postRulesOf(t);
        assertEq(g, 2_000);
        assertEq(w, 900);
        // the Sale getter is unchanged (28 fields)
        assertEq(_sale(t).baseQuota, 10);
        bytes32 sig = keccak256(
            "Created(address,address,string,string,string,address,uint256,(uint256,uint16,uint8,uint8,uint16,uint16,uint16,uint16,uint16,uint16,uint32,uint32,uint8,bool,uint8,uint16,uint32,uint16,uint16,uint16,uint32))"
        );
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] != sig) continue;
            found = true;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), t);
            (,,,,, IFlywheelPad.FlyConfig memory e) =
                abi.decode(logs[i].data, (string, string, string, address, uint256, IFlywheelPad.FlyConfig));
            assertEq(e.guardBps, 2_000);
            assertEq(e.twapWindow, 900);
            assertEq(e.baseQuota, 10);
        }
        assertTrue(found, "no Created event with the V2 config");
    }

    function test_createNeedsAnAgentId() public {
        address plain = _plain();
        vm.prank(plain);
        vm.expectRevert(IFlywheelPad.NotAgent.selector);
        pad.create(["a", "b", "c", "d"], address(0), address(0), _agentMint(), 1);
    }

    // ------------------------------------------------------------ quota and invites
    function test_quotaIsSharedAndCapped() public {
        address t = _create(_agentMint(), 1);
        address a = _newAgent();
        vm.startPrank(a);
        pad.mint(t, 7, 1, address(0));
        pad.mint(t, 10, 1, address(0)); // only 3 left
        assertEq(_sale(t).sold, 11);
        assertEq(pad.quotaLeft(t, a), 0);
        vm.expectRevert(IFlywheelPad.ZeroAmount.selector);
        pad.mint(t, 1, 1, address(0));
        vm.stopPrank();
    }

    function test_inviteAddsQuotaOnlyOnTheInviteesFirstMint() public {
        address t = _create(_agentMint(), 1);
        address a = _newAgent();
        address b = _newAgent();
        vm.prank(a);
        pad.mint(t, 1, 1, address(0));
        vm.prank(b);
        pad.mint(t, 1, 1, a); // a invited b
        assertEq(pad.quotaLeft(t, a), 9 + 1);
        vm.prank(b);
        pad.mint(t, 1, 1, dev); // not b's first mint: no bonus for dev
        assertEq(pad.quotaLeft(t, dev), 9);
    }

    function test_inviteNeedsAReferrerThatMintedAndIsNotSelf() public {
        address t = _create(_agentMint(), 1);
        address a = _newAgent();
        address never = _newAgent();
        vm.prank(a);
        pad.mint(t, 1, 1, never); // never has not minted
        assertEq(pad.quotaLeft(t, never), 10);
        address c = _newAgent();
        vm.prank(c);
        pad.mint(t, 1, 1, c); // self
        assertEq(pad.quotaLeft(t, c), 9);
    }

    // ------------------------------------------------------------ sell-back
    function test_withdrawRefundsPrincipalLessExitFeeAndRestoresQuota() public {
        address t = _create(_agentMint(), 1);
        address a = _newAgent();
        vm.startPrank(a);
        pad.mint(t, 10, 1, address(0));
        uint256 before = wbnb.balanceOf(a);
        uint256 payout = pad.withdraw(t, 4, 0);
        vm.stopPrank();
        assertEq(payout, 4 * PRICE - (4 * PRICE) / 100);
        assertEq(wbnb.balanceOf(a) - before, payout);
        assertEq(IERC20(t).balanceOf(a), 6 * TPS);
        assertEq(IERC20(t).balanceOf(address(pad)), 4 * TPS); // held for the next mints
        assertEq(pad.quotaLeft(t, a), 4);
        assertEq(vault.shares(t, a), 6 * TPS);
        // the next mint takes the held tokens first: supply does not grow
        uint256 supply = IERC20(t).totalSupply();
        address b = _newAgent();
        vm.prank(b);
        pad.mint(t, 3, 1, address(0));
        assertEq(IERC20(t).totalSupply(), supply);
    }

    function test_noSellBackOnceFilled() public {
        IFlywheelPad.FlyConfig memory c = _wide();
        c.launchDelay = 120;
        address t = _create(c, 1);
        _fill(t);
        vm.prank(dev);
        vm.expectRevert(IFlywheelPad.NotMinting.selector);
        pad.withdraw(t, 1, 0);
    }

    // ------------------------------------------------------------ launch
    function test_launchSeedsThePoolAtTheMintPriceAndPaysTheDev() public {
        address t = _create(_wide(), 1);
        _fill(t);
        uint256 devBefore = wbnb.balanceOf(dev);
        vm.expectRevert(IFlywheelPad.TooEarly.selector);
        pad.launch(t);
        vm.warp(vm.getBlockTimestamp() + 60);
        pad.launch(t);
        IFlywheelPad.Sale memory s = _sale(t);
        assertTrue(s.launched);
        (uint256 rT, uint256 rQ) = _res(t);
        uint256 cut = ((SHARES - 1) * PRICE) / 10; // 10% of everyone's shares but the creator's own one
        assertEq(rQ, 20 ether - cut);
        assertEq(rT, SHARES * TPS - ((SHARES - 1) * TPS) / 10);
        assertEq((rQ * 1e18) / rT, (PRICE * 1e18) / TPS); // open price = mint price
        assertEq(wbnb.balanceOf(dev) - devBefore, cut);
        assertEq(wbnb.balanceOf(address(pad)), 0); // no escrow left behind
        (uint64 until,,) = handler.protectionOf(t);
        assertEq(until, vm.getBlockTimestamp() + 600);
    }

    function test_zeroDelayLaunchesInTheFillingMint() public {
        IFlywheelPad.FlyConfig memory c = _wide();
        c.launchDelay = 0;
        address t = _create(c, 1);
        _fill(t);
        assertTrue(_sale(t).launched);
    }

    function test_openEarlyOnlyByCreatorAfter30Percent() public {
        IFlywheelPad.FlyConfig memory c = _wide();
        c.launchDelay = 0;
        address t = _create(c, 1);
        for (uint256 i; i < 25; i++) {
            address w = _newAgent();
            vm.prank(w);
            pad.mint(t, 10, 1, address(0));
        }
        vm.prank(dev);
        vm.expectRevert(IFlywheelPad.TooEarly.selector);
        pad.openEarly(t); // 251 < 3,000
        for (uint256 i; i < 300; i++) {
            address w = _newAgent();
            vm.prank(w);
            pad.mint(t, 10, 1, address(0));
        }
        address other = _newAgent();
        vm.prank(other);
        vm.expectRevert(IFlywheelPad.OnlyCreator.selector);
        pad.openEarly(t);
        vm.prank(dev);
        pad.openEarly(t);
        IFlywheelPad.Sale memory s = _sale(t);
        assertTrue(s.launched);
        (uint256 rT, uint256 rQ) = _res(t);
        assertEq((rQ * 1e18) / rT, (PRICE * 1e18) / TPS);
        assertEq(rQ, uint256(s.sold) * PRICE - ((uint256(s.sold) - 1) * PRICE) / 10);
    }

    // ------------------------------------------------------------ post-launch mint
    function _launched() internal returns (address t) {
        t = _launchedWith(_wide());
    }

    function _launchedWith(IFlywheelPad.FlyConfig memory c) internal returns (address t) {
        t = _create(c, 1);
        _fillAndLaunch(t);
        vm.warp(vm.getBlockTimestamp() + 600); // past the launch protection
        vm.roll(vm.getBlockNumber() + 1);
    }

    function test_postMintPaysTierPriceGetsTokensAtSpotAndFillsThePool() public {
        address t = _launched();
        address a = _newAgent();
        uint256 spot = _price(t);
        (uint256 rT0, uint256 rQ0) = _res(t);
        uint256 devBefore = wbnb.balanceOf(dev);
        uint256 balBefore = wbnb.balanceOf(a);
        vm.prank(a);
        (uint256 out, uint256 spent) = pad.mintPost(t, 10, 0, type(uint256).max, address(0));
        // shares 10,001..10,010: tier ×1.10
        uint256 paid = (10 * PRICE * 110) / 100;
        assertEq(spent, paid + paid / 100);
        assertEq(balBefore - wbnb.balanceOf(a), spent);
        assertApproxEqRel(out, (paid * 1e18) / spot, 1e12);
        assertEq(IERC20(t).balanceOf(a), out);
        assertEq(wbnb.balanceOf(dev) - devBefore, paid / 10);
        (uint256 rT1, uint256 rQ1) = _res(t);
        assertApproxEqAbs(rQ1 - rQ0, paid - paid / 10, 2); // the rest went into the pool
        assertGt(_price(t), spot); // the 30% buy pushed it
        assertLe(_price(t), (spot * 10_081) / 10_000);
        assertGt(rT1, rT0 - out); // liquidity added
        assertEq(pad.baselineOf(t, a), out);
        assertEq(vault.shares(t, a), out);
        assertEq(pad.quotaLeft(t, a), 0); // quota 10 (V2 ceiling with post-launch minting)
    }

    function test_postMintPushNeverExceedsPointEightPercentPerBlock() public {
        address t = _launched();
        uint256 start = _price(t);
        for (uint256 i; i < 15; i++) {
            address w = _newAgent();
            vm.prank(w);
            pad.mintPost(t, 10, 0, type(uint256).max, address(0));
        }
        assertLe(_price(t), (start * 10_081) / 10_000);
        vm.roll(vm.getBlockNumber() + 1);
        address w2 = _newAgent();
        vm.prank(w2);
        pad.mintPost(t, 10, 0, type(uint256).max, address(0));
        assertGt(_price(t), (start * 10_081) / 10_000); // a new block, a new budget
    }

    /// @dev A holder with a large bag dumps it in one go (about −40% against the average).
    function _dumpedWith(IFlywheelPad.FlyConfig memory c) internal returns (address t) {
        t = _launchedWith(c);
        address whale = _newAgent();
        _poolBuy(t, whale, 5 ether);
        vm.warp(vm.getBlockTimestamp() + 3600); // the whale's buy is now part of the average
        vm.roll(vm.getBlockNumber() + 1);
        uint256 w = IERC20(t).balanceOf(whale);
        _poolSell(t, whale, w);
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 3);
    }

    /// @dev V2 (was test_postMintRefusedAfterADump, V1's fixed 10% refusal): a sale with the guard on refuses.
    function test_postMintRefusedAfterADumpWhenGuarded() public {
        IFlywheelPad.FlyConfig memory c = _wide();
        c.guardBps = 3_000;
        address t = _dumpedWith(c);
        address a = _newAgent();
        vm.prank(a);
        vm.expectRevert(IFlywheelPad.PriceBelowAverage.selector);
        pad.mintPost(t, 10, 0, type(uint256).max, address(0));
    }

    /// @dev V2: with the guard off, the mint in the next block goes through at the pool's price.
    function test_postMintAfterADumpUnguardedPaysThePool() public {
        address t = _dumpedWith(_wide());
        (uint256 spot,,, uint256 avg) = pad.prices(t);
        assertLt(spot * 10, avg * 7); // more than 30% under the average
        address a = _newAgent();
        vm.prank(a);
        (uint256 out, uint256 spent) = pad.mintPost(t, 10, 0, type(uint256).max, address(0));
        uint256 paid = spent - spent / 101;
        assertEq(out, (paid << 112) / spot);
    }

    function test_sameBlockDumpDoesNotMakeAMintCheaper() public {
        address t = _launched();
        uint256 blockStart = _price(t);
        _poolSell(t, dev, IERC20(t).balanceOf(dev) / 2); // price drops within the block
        assertLt(_price(t), blockStart);
        address a = _newAgent();
        vm.prank(a);
        (uint256 out,) = pad.mintPost(t, 10, 0, type(uint256).max, address(0));
        uint256 paid = (10 * PRICE * 110) / 100;
        assertApproxEqRel(out, (paid * 1e18) / blockStart, 1e12); // priced at the block's start
    }

    /// @dev A pool crashed to ~0.65 BNB of quote: 2% of it is ~0.013 BNB, and 5 shares at ×1.1 cost 0.011 BNB, so one
    ///      wallet's second mint of 5 (quota 10) is over its pace (since A-M1 a steep linear tier no longer starts
    ///      post-launch shares at its cap, so the crash, not the tier, brings the pace into reach).
    function test_paceCapsOneWalletPerHalfHour() public {
        address t = _launched();
        address seller = _newAgent();
        (uint256 rT, uint256 rQ) = _res(t);
        deal(t, seller, rT * 40);
        for (uint256 i; i < 300 && rQ > 0.7 ether; i++) {
            _poolSell(t, seller, rT / 20);
            (rT, rQ) = _res(t);
        }
        assertLe(rQ, 0.7 ether);
        assertGt(rQ, 0.6 ether);
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 3);
        address a = _newAgent();
        vm.startPrank(a);
        pad.mintPost(t, 5, 0, type(uint256).max, address(0));
        vm.roll(vm.getBlockNumber() + 1);
        vm.expectRevert(IFlywheelPad.PaceExceeded.selector);
        pad.mintPost(t, 5, 0, type(uint256).max, address(0));
        // sliding, not fixed: a moment later the allowance has hardly come back (no burst at a window's edge)
        vm.warp(vm.getBlockTimestamp() + 2);
        vm.expectRevert(IFlywheelPad.PaceExceeded.selector);
        pad.mintPost(t, 5, 0, type(uint256).max, address(0));
        vm.warp(vm.getBlockTimestamp() + 30 minutes);
        pad.mintPost(t, 5, 0, type(uint256).max, address(0));
        vm.stopPrank();
    }

    function test_postMintOffRefuses() public {
        IFlywheelPad.FlyConfig memory c = _wide();
        c.postMint = false;
        address t = _create(c, 1);
        _fillAndLaunch(t);
        assertEq(GangMintToken(t).maxSupply(), 2 * SHARES * TPS);
        vm.prank(dev);
        vm.expectRevert(IFlywheelPad.PostMintOff.selector);
        pad.mintPost(t, 1, 0, type(uint256).max, address(0));
    }

    function test_mintingAgainRequalifiesAWalletThatWasOut() public {
        address t = _launched();
        uint256 bal = IERC20(t).balanceOf(dev);
        _poolSell(t, dev, (bal * 6) / 10); // below the 60% line
        assertTrue(handler.isOut(t, dev));
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(dev);
        (uint256 out,) = pad.mintPost(t, 5, 0, type(uint256).max, address(0));
        assertFalse(handler.isOut(t, dev));
        assertEq(pad.baselineOf(t, dev), out);
        assertEq(vault.shares(t, dev), out);
    }

    function test_bnbPaymentsRefundTheChange() public {
        address t = _create(_wide(), 1);
        address a = _newAgent();
        uint256 eth = a.balance;
        vm.prank(a);
        uint256 spent = pad.mintWithBnb{value: 1 ether}(t, 5, 1, address(0));
        assertEq(spent, 5 * PRICE + (5 * PRICE) / 100);
        assertEq(eth - a.balance, spent);
        _fillAndLaunch(t);
        vm.warp(vm.getBlockTimestamp() + 600);
        eth = a.balance;
        vm.prank(a);
        (, spent) = pad.mintPostWithBnb{value: 1 ether}(t, 5, 0, address(0)); // the rest of quota 10
        assertEq(eth - a.balance, spent);
    }

    function test_mintThenSellRightAwayLoses() public {
        address t = _launched();
        address a = _newAgent();
        vm.prank(a);
        (uint256 out, uint256 spent) = pad.mintPost(t, 10, 0, type(uint256).max, address(0));
        uint256 got = _poolSell(t, a, out);
        assertLt(got, spent);
    }

    function test_launchProtectionAppliesToPoolBuysNotToMints() public {
        address t = _create(_wide(), 1);
        _fillAndLaunch(t);
        address plain = _plain();
        (uint256 rT, uint256 rQ) = _res(t);
        uint256 out = _amountOut(0.01 ether, rQ, rT);
        TwapMockPair p = TwapMockPair(_sale(t).pair);
        wbnb.mintUnlimited(address(p), 0.01 ether);
        bool t0 = p.token0() == t;
        vm.expectRevert(FlywheelTaxHandler.ProtectionNotAgent.selector);
        p.swap(t0 ? out : 0, t0 ? 0 : out, plain, "");
        address a = _newAgent();
        vm.prank(a);
        pad.mintPost(t, 10, 0, type(uint256).max, address(0)); // an Agent minting during protection: fine
    }

    function test_agentMintPresetFillsWithAThousandWallets() public {
        address t = _create(_agentMint(), 1);
        _fillAndLaunch(t);
        assertTrue(_sale(t).launched);
        assertEq(_sale(t).sold, SHARES);
    }

    // ------------------------------------------------------------ the creator's own mints (internal audit B-M1)
    function test_creatorMintThenSellRightAwayLoses() public {
        address t = _launched();
        uint256 q0 = wbnb.balanceOf(dev);
        uint256 got;
        // the creator's whole quota left: 9 of 10 (V1: 99 of 100 in 9 mints)
        vm.prank(dev);
        (got,) = pad.mintPost(t, 9, 0, type(uint256).max, address(0));
        vm.roll(vm.getBlockNumber() + 1);
        _poolSell(t, dev, got);
        assertLt(wbnb.balanceOf(dev), q0, "creator mint-then-sell paid");
    }

    function test_creatorMintCarriesNoCutOthersDo() public {
        address t = _launched();
        (uint256 rT0, uint256 rQ0) = _res(t);
        rT0;
        vm.prank(dev);
        (, uint256 spent) = pad.mintPost(t, 10, 0, type(uint256).max, address(0));
        (, uint256 rQ1) = _res(t);
        uint256 paid = spent - spent / 101; // spent = paid × 1.01
        assertApproxEqAbs(rQ1 - rQ0, paid, 2); // all of it into the pool
        address a = _newAgent();
        uint256 devBefore = wbnb.balanceOf(dev);
        vm.prank(a);
        (, uint256 spentA) = pad.mintPost(t, 10, 0, type(uint256).max, address(0));
        uint256 paidA = spentA - spentA / 101;
        assertApproxEqAbs(wbnb.balanceOf(dev) - devBefore, paidA / 10, 2);
    }

    function test_creatorPreLaunchSharesCarryNoCut() public {
        IFlywheelPad.FlyConfig memory c = _wide();
        address t = _create(c, 5);
        vm.startPrank(dev);
        pad.mint(t, 5, 1, address(0)); // the creator holds 10 shares, its quota (V1: 100, quota 100)
        pad.withdraw(t, 4, 0); // sells 4 back: 6 left
        vm.stopPrank();
        assertEq(_sale(t).creatorShares, 6);
        uint256 devBefore = wbnb.balanceOf(dev);
        _fillAndLaunch(t);
        assertEq(wbnb.balanceOf(dev) - devBefore, ((SHARES - 6) * PRICE) / 10);
    }
}
