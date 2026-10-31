// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {GangToken} from "../../src/gang/GangToken.sol";
import {PlatformFeeBucket} from "../../src/launchpad-v2/PlatformFeeBucket.sol";
import {SharedDividendVault} from "../../src/common/SharedDividendVault.sol";
import {PadMergeGuardsTest} from "./PadMergeGuards.t.sol";

/// @notice Regression tests from the independent review of the 打新 side and same-quote isolation on the merged pad:
///         per quote, the pad holds exactly live sale principal + owedFee + live curve realQuote + dust, with V3 curves
///         and 打新 sales on the same two quotes interleaved (owedFee included), a random interleaving fuzz, and every
///         cross-kind entry / view / reclaim refused or empty.
contract FairMixedIsolationTest is PadMergeGuardsTest {
    address[] internal cs; // curves
    address[] internal ss; // sales
    mapping(address => uint256) internal dustOf;

    function _sum(address q) internal view returns (uint256 owed) {
        owed = v3.owedFee(q);
        for (uint256 i; i < cs.length; i++) {
            (, address cq, uint128 realQuote,,,, bool graduated,,,,,) = v3.curves(cs[i]);
            if (cq == q && !graduated) owed += realQuote;
            if (cq == q) owed += v3.creatorFeeOf(cs[i]); // kept for the creator, live or graduated
        }
        for (uint256 i; i < ss.length; i++) {
            (,,,, address sq, uint16 sold, bool launched,,,, uint128 price,,,) = v3.sales(ss[i]);
            if (sq == q && !launched) owed += uint256(sold) * price;
        }
    }

    /// exact: dust must not move (打新 ops, flush); otherwise dust may only grow (curve rounding)
    function _chk(address q, bool exact, string memory step) internal {
        uint256 bal = IERC20(q).balanceOf(address(v3));
        uint256 s = _sum(q);
        assertGe(bal, s, step);
        uint256 d = bal - s;
        if (exact) assertEq(d, dustOf[q], string.concat(step, ": dust moved on an exact op"));
        else assertGe(d, dustOf[q], string.concat(step, ": dust shrank"));
        dustOf[q] = d;
    }

    function _chkAll(bool exact, string memory step) internal {
        _chk(address(wbnb), exact, step);
        _chk(address(quoteTok), exact, step);
    }

    function _cfgQ() internal pure returns (IGangLaunchpad.MintConfig memory) {
        return
            IGangLaunchpad.MintConfig({raiseBnb: 5 ether, capBps: 50, holdBps: 6000, mintFeeBps: 300, exitFeeBps: 100});
    }

    function _gradAny(address token) internal {
        for (uint256 i; i < 300 && !_v3Graduated(token); i++) {
            address w = address(uint160(0xE2000 + i));
            _agent(w);
            vm.prank(w);
            v3.buy(token, 1 ether, 0);
        }
        assertTrue(_v3Graduated(token), "graduated");
    }

    function test_review_mixedIsolation_withOwedFeeAndTwoQuotes() public {
        // WBNB: a1 taxed+dividend curve, a2 plain curve, b1 / b2 sales; quoteTok: a3 curve, b3 sale
        address a1 = _v3Token(5000);
        vm.prank(agent);
        address a2 = v3.create("Plain", "PLN", "", "", address(0), address(0), _plain());
        vm.prank(agent);
        address a3 = v3.create("Q", "Q", "", "", address(quoteTok), address(0), _plain());
        address b1 = _fairSale();
        vm.prank(agent);
        address b2 = fair.create("Fair2", "F2", "", "", address(0), address(0), _cfg(), 7);
        vm.prank(agent);
        address b3 = fair.create("Fair3", "F3", "", "", address(quoteTok), address(0), _cfgQ(), 3);
        cs.push(a1);
        cs.push(a2);
        cs.push(a3);
        ss.push(b1);
        ss.push(b2);
        ss.push(b3);
        _chkAll(true, "after creates");

        for (uint256 i; i < 8; i++) {
            address w = address(uint160(0xD1000 + i));
            _agent(w);
            vm.startPrank(w);
            v3.buy(a1, 0.37 ether + i, 0);
            _chkAll(false, "buy a1");
            v3.mint(b1, 33, 1);
            _chkAll(true, "mint b1");
            v3.buy(a3, 0.9 ether + 7 * i, 0);
            _chkAll(false, "buy a3");
            v3.mint(b3, 17 + i, 1);
            _chkAll(true, "mint b3");
            v3.buy(a2, 0.21 ether, 0);
            v3.mint(b2, 50, 1);
            _chkAll(false, "buy a2 / mint b2");
            uint256 bal = IERC20(a1).balanceOf(w);
            IERC20(a1).approve(address(v3), bal);
            v3.sell(a1, bal / 2 + 1, 0);
            _chkAll(false, "sell a1");
            v3.withdraw(b1, 11, 0);
            _chkAll(true, "withdraw b1");
            uint256 bq = IERC20(a3).balanceOf(w);
            IERC20(a3).approve(address(v3), bq);
            v3.sell(a3, bq / 3, 0);
            _chkAll(false, "sell a3");
            v3.withdraw(b3, 5, 0);
            _chkAll(true, "withdraw b3");
            vm.stopPrank();
        }

        // bucket refuses the pad: curve trades and mints stop, withdraws go on and book owedFee
        address bucket = address(v3.platformBucket());
        vm.mockCallRevert(bucket, abi.encodeWithSelector(PlatformFeeBucket.notifyAccrual.selector), "refused");
        address w0 = address(uint160(0xD1000));
        vm.startPrank(w0);
        vm.expectRevert();
        v3.buy(a1, 0.1 ether, 0);
        vm.expectRevert();
        v3.mint(b2, 1, 1);
        uint256 owedBefore = v3.owedFee(address(wbnb));
        (uint256 p1, uint256 f1) = v3.previewWithdraw(b1, w0, 7);
        assertGt(f1, 0);
        uint256 got = v3.withdraw(b1, 7, p1);
        assertEq(got, p1);
        assertEq(v3.owedFee(address(wbnb)) - owedBefore, f1, "exit fee booked as owed");
        _chkAll(true, "withdraw b1 while bucket refuses");
        (, uint256 f3) = v3.previewWithdraw(b3, w0, 4);
        v3.withdraw(b3, 4, 0);
        assertEq(v3.owedFee(address(quoteTok)), f3, "owed per quote");
        _chkAll(true, "withdraw b3 while bucket refuses");
        vm.expectRevert();
        v3.flushFees(address(wbnb));
        vm.stopPrank();
        vm.clearMockedCalls();

        // flush moves exactly owedFee of that quote, nothing else
        uint256 balW = wbnb.balanceOf(address(v3));
        uint256 owedW = v3.owedFee(address(wbnb));
        v3.flushFees(address(wbnb));
        assertEq(balW - wbnb.balanceOf(address(v3)), owedW, "flush = owedFee");
        assertEq(v3.owedFee(address(wbnb)), 0);
        assertGt(v3.owedFee(address(quoteTok)), 0, "other quote untouched");
        _chkAll(true, "flush wbnb");
        vm.expectRevert(IGangLaunchpad.ZeroAmount.selector);
        v3.flushFees(address(wbnb));

        // stale: exit fee 0, exact
        vm.warp(block.timestamp + 7 days);
        assertEq(v3.exitFeeBpsOf(b2), 0);
        vm.prank(w0);
        (uint256 pz, uint256 fz) = (0, 0);
        (pz, fz) = v3.previewWithdraw(b2, w0, 10);
        assertEq(fz, 0);
        vm.prank(w0);
        assertEq(v3.withdraw(b2, 10, pz), pz);
        _chkAll(true, "stale withdraw b2");

        // launch b1: exactly 10,000 × price leaves; curves and other sales untouched
        (,,,,,,,,,, uint128 price1,,,) = v3.sales(b1);
        uint256 before = wbnb.balanceOf(address(v3));
        uint256 dustBefore = dustOf[address(wbnb)];
        _launchFresh(b1);
        // during _launch: mints add price×n each, then 10,000×price leaves; dust must stay the same
        _chkAll(true, "launch b1");
        assertEq(dustOf[address(wbnb)], dustBefore);
        before;
        price1;

        // graduate a1 (WBNB) and a3 (quoteTok)
        _gradAny(a1);
        _chkAll(false, "graduate a1");
        _gradAny(a3);
        _chkAll(false, "graduate a3");

        // the rest can still exit in full
        for (uint256 i; i < 8; i++) {
            address w = address(uint160(0xD1000 + i));
            uint256 sh = v3.positions(b2, w);
            if (sh > 0) {
                vm.prank(w);
                v3.withdraw(b2, sh, 0);
            }
            sh = v3.positions(b3, w);
            if (sh > 0) {
                vm.prank(w);
                v3.withdraw(b3, sh, 0);
            }
            uint256 bal = IERC20(a2).balanceOf(w);
            if (bal > 0) {
                vm.startPrank(w);
                IERC20(a2).approve(address(v3), bal);
                v3.sell(a2, bal, 0);
                vm.stopPrank();
            }
            _chkAll(false, "exit all");
        }
        _launchFresh(b3);
        _chkAll(true, "launch b3");
        v3.flushFees(address(quoteTok));
        _chkAll(true, "flush quoteTok");
        emit log_named_uint("final WBNB dust", dustOf[address(wbnb)]);
        emit log_named_uint("final quoteTok dust", dustOf[address(quoteTok)]);
        assertLt(dustOf[address(wbnb)], 1e6);
        assertLt(dustOf[address(quoteTok)], 1e6);
    }

    uint256 internal fresh = 0xF9000;

    function _launchFresh(address token) internal {
        for (uint256 i; i < 300 && v3.status(token) != IGangLaunchpad.Status.Launched; i++) {
            address m = address(uint160(fresh++));
            _agent(m);
            vm.prank(m);
            v3.mint(token, 100, 1);
            if (v3.status(token) != IGangLaunchpad.Status.Launched) _chkAll(true, "launch mint");
        }
        assertEq(uint8(v3.status(token)), uint8(IGangLaunchpad.Status.Launched), "launched");
    }

    // ---------------------------------------------------------------- kind mixing
    function test_review_kindMixing() public {
        address a1 = _v3Token(5000);
        vm.prank(agent);
        address a0 = v3.create("Plain", "PLN", "", "", address(0), address(0), _plain());
        address b1 = _fairSale();
        assertEq(v3.kindOf(a1), 1);
        assertEq(v3.kindOf(a0), 1);
        assertEq(v3.kindOf(b1), 2);

        vm.startPrank(agent);
        vm.expectRevert(IGangLaunchpad.UnknownToken.selector);
        v3.mint(a1, 1, 1);
        vm.expectRevert(IGangLaunchpad.UnknownToken.selector);
        v3.withdraw(a1, 1, 0);
        vm.expectRevert(IGangLaunchpad.UnknownToken.selector);
        v3.buy(b1, 1 ether, 0);
        vm.expectRevert(IGangLaunchpad.UnknownToken.selector);
        v3.sell(b1, 1, 0);
        vm.stopPrank();
        vm.startPrank(address(router), agent);
        vm.expectRevert(IGangLaunchpad.UnknownToken.selector);
        v3.mintFor(agent, a1, 1, 1);
        vm.expectRevert(IGangLaunchpad.UnknownToken.selector);
        v3.buyFor(agent, b1, 1 ether, 0);
        vm.stopPrank();

        // fair views on a V3 token
        assertEq(uint8(v3.status(a1)), 0);
        (uint256 acc, uint256 cost, uint256 fee) = v3.previewMint(a1, agent, 5);
        assertEq(acc + cost + fee, 0);
        (uint256 p, uint256 f) = v3.previewWithdraw(a1, agent, 1);
        assertEq(p + f, 0);
        assertEq(v3.baselineOf(a1, agent), 0);
        assertEq(v3.holdBpsOf(a1), 0);
        // V3 views on a fair token
        assertEq(v3.graduationRemaining(b1), 0);
        assertEq(v3.gradAmtOf(b1), 0);
        (uint16 bt, uint16 st, uint16 db, address rcp) = v3.taxConfigOf(b1);
        emit log_named_uint("taxConfigOf(fair).buy", bt);
        emit log_named_uint("taxConfigOf(fair).sell", st);
        emit log_named_uint("taxConfigOf(fair).div", db);
        emit log_named_address("taxConfigOf(fair).recipient", rcp);

        // reclaim: only the pad, only 打新, only while locked
        vm.prank(agent);
        v3.buy(a1, 0.2 ether, 0);
        vm.expectRevert(GangToken.OnlyLaunchpad.selector);
        vm.prank(agent);
        GangToken(b1).reclaim(agent, 1);
        vm.prank(address(v3));
        vm.expectRevert(GangToken.NotReclaimable.selector);
        GangToken(a1).reclaim(agent, 1);
        vm.prank(address(v3));
        vm.expectRevert(GangToken.NotReclaimable.selector);
        GangToken(a0).reclaim(agent, 1);
        // V3 graduated: transfers + pool transfers never consult the pad's fair views
        _graduate(a1);
        address w = address(uint160(0xE1000));
        uint256 bal = IERC20(a1).balanceOf(w);
        (,,,,,,,,,, address pair,) = v3.curves(a1);
        vm.expectCall(address(v3), abi.encodeWithSelector(v3.baselineOf.selector), 0);
        vm.expectCall(address(v3), abi.encodeWithSelector(v3.holdBpsOf.selector), 0);
        vm.startPrank(w);
        IERC20(a1).transfer(agent2, bal / 4);
        IERC20(a1).transfer(pair, bal / 4);
        vm.stopPrank();
        _launch(b1);
        vm.prank(address(v3));
        vm.expectRevert(GangToken.NotLocked.selector);
        GangToken(b1).reclaim(agent, 1);
        vm.prank(agent);
        vm.expectRevert(IGangLaunchpad.NotMinting.selector);
        v3.withdraw(b1, 1, 0);
        vm.prank(agent);
        vm.expectRevert(IGangLaunchpad.NotMinting.selector);
        v3.mint(b1, 1, 1);
    }

    // ---------------------------------------------------------------- random interleaving
    function _try(address who, bytes memory data) internal returns (bool ok) {
        vm.prank(who);
        (ok,) = address(v3).call(data);
    }

    function testFuzz_review_randomMixed(uint256 seed) public {
        _body(seed);
    }

    function _body(uint256 seed) internal returns (uint256 done) {
        address a1 = _v3Token(5000);
        vm.prank(agent);
        address a2 = v3.create("Plain", "PLN", "", "", address(0), address(0), _plain());
        address b1 = _fairSale();
        // b2's rules span the launch ranges (2026-10-27): cap 0.25%–1%, hold line 60%–90%
        IGangLaunchpad.MintConfig memory cfg2 = _cfgQ();
        cfg2.capBps = uint16(25 + (seed >> 200) % 76);
        cfg2.holdBps = uint16(6_000 + (seed >> 216) % 3_001);
        vm.prank(agent);
        address b2 = fair.create("Fair2", "F2", "", "", address(0), address(0), cfg2, 2);
        cs.push(a1);
        cs.push(a2);
        ss.push(b1);
        ss.push(b2);
        address bucket = address(v3.platformBucket());
        address[5] memory ws;
        for (uint256 i; i < 5; i++) {
            ws[i] = address(uint160(0xC0000 + i));
            _agent(ws[i]);
            vm.startPrank(ws[i]);
            IERC20(a1).approve(address(v3), type(uint256).max);
            IERC20(a2).approve(address(v3), type(uint256).max);
            vm.stopPrank();
        }
        bool refusing;
        for (uint256 step; step < 60; step++) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            address w = ws[r % 5];
            uint256 op = (r >> 8) % 11;
            if (op > 8) op = 8;
            address c = ((r >> 16) & 1) == 0 ? a1 : a2;
            address s = ((r >> 17) & 1) == 0 ? b1 : b2;
            uint256 amt = (r >> 24) % 3 ether + 1;
            bool exact = true;
            if (op == 0) {
                _try(w, abi.encodeWithSignature("buy(address,uint256,uint256)", c, amt, 0));
                exact = false;
            } else if (op == 1) {
                uint256 bal = IERC20(c).balanceOf(w);
                if (bal > 0) {
                    _try(
                        w,
                        abi.encodeWithSignature(
                            "sell(address,uint256,uint256)", c, (bal * ((r >> 40) % 100 + 1)) / 100, 0
                        )
                    );
                }
                exact = false;
            } else if (op == 2 || op == 3) {
                _try(w, abi.encodeWithSignature("mint(address,uint256,uint256)", s, (r >> 40) % 240 + 1, 0));
            } else if (op == 4) {
                uint256 sh = v3.positions(s, w);
                if (sh > 0) {
                    _try(w, abi.encodeWithSignature("withdraw(address,uint256,uint256)", s, (r >> 40) % sh + 1, 0));
                }
            } else if (op == 5) {
                if (!refusing && (r >> 40) % 3 != 0) continue;
                if (refusing) vm.clearMockedCalls();
                else vm.mockCallRevert(bucket, abi.encodeWithSelector(PlatformFeeBucket.notifyAccrual.selector), "x");
                refusing = !refusing;
            } else if (op == 6) {
                _try(w, abi.encodeWithSignature("flushFees(address)", address(wbnb)));
            } else if (op == 7) {
                vm.warp(block.timestamp + (r >> 40) % 9 days);
            } else {
                // push a sale toward launch with fresh minters
                for (uint256 k; k < 25; k++) {
                    address m = address(uint160(fresh++));
                    _agent(m);
                    _try(m, abi.encodeWithSignature("mint(address,uint256,uint256)", s, 100, 0));
                    _try(m, abi.encodeWithSignature("buy(address,uint256,uint256)", c, 0.4 ether, 0));
                }
                exact = false;
            }
            _chk(address(wbnb), exact, "random step");
        }
        vm.clearMockedCalls();
        if (v3.status(b1) == IGangLaunchpad.Status.Launched) done |= 1;
        if (v3.status(b2) == IGangLaunchpad.Status.Launched) done |= 2;
        if (_v3Graduated(a1)) done |= 4;
        if (_v3Graduated(a2)) done |= 8;
        emit log_named_uint("launched/graduated mask", done);
        // everybody out (sales still minting) and every curve seller out: pad keeps exactly owedFee + dust
        for (uint256 i; i < 5; i++) {
            for (uint256 j; j < 2; j++) {
                address s = j == 0 ? b1 : b2;
                uint256 sh = v3.positions(s, ws[i]);
                if (sh > 0 && v3.status(s) == IGangLaunchpad.Status.Minting) {
                    assertTrue(
                        _try(ws[i], abi.encodeWithSignature("withdraw(address,uint256,uint256)", s, sh, 0)), "exit"
                    );
                }
                address c = j == 0 ? a1 : a2;
                uint256 bal = IERC20(c).balanceOf(ws[i]);
                (,,,,,, bool g,,,,,) = v3.curves(c);
                if (bal > 0 && !g) {
                    assertTrue(
                        _try(ws[i], abi.encodeWithSignature("sell(address,uint256,uint256)", c, bal, 0)), "sell out"
                    );
                }
            }
            _chk(address(wbnb), false, "exit");
        }
    }
}
