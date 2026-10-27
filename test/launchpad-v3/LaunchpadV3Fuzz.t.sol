// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LaunchpadV3} from "../../src/launchpad-v3/LaunchpadV3.sol";
import {LaunchpadV3Test} from "./LaunchpadV3.t.sol";

/// @notice Fuzzed curve accounting (from the 2026-10-26 internal audit; §19 no curve tax): every buy and sell of a taxed
///         token splits exactly into curve and the 1% fee — no tax, nothing to the recipient, the vault or the
///         handler; truncation at the wallet cap / graduation only charges what is spent. The cross-curve solvency invariants live in test/invariant/CoreInvariants.t.sol.
contract LaunchpadV3FuzzTest is LaunchpadV3Test {
    function _realQuote(address t) internal view returns (uint256 rq) {
        (,, uint128 r,,,,,,,,,) = pad.curves(t);
        rq = r;
    }

    function _pairOf(address t) internal view returns (address p) {
        (,,,,,,,,,, p,) = pad.curves(t);
    }

    /// @dev spent == net + 1% fee (+ ≤ 1 wei pad dust); bucket += exactly 1% of spent; no tax anywhere; out ≤ room.
    function testFuzz_buyAccounting(uint256 quoteIn, uint16 b, uint16 s, uint16 d, uint256 preIn) public {
        b = uint16(bound(b, 100, 500));
        s = uint16(bound(s, 100, 500));
        d = uint16(bound(d, 0, 10_000));
        quoteIn = bound(quoteIn, 1, 2 ether);
        preIn = bound(preIn, 0, 0.5 ether);
        address t = _create(_tax(b, s, d, treasury));
        if (preIn > 0) {
            vm.prank(agent2);
            pad.buy(t, preIn, 0);
        }
        address u = makeAddr("fuzzBuyer");
        _agent(u);

        uint256 uq = quoteTok.balanceOf(u);
        uint256 pq = quoteTok.balanceOf(address(pad));
        uint256 bk = bucket.accruedQuote(address(quoteTok));
        uint256 rq = _realQuote(t);
        uint256 room = pad.walletRoom(t, u);
        vm.prank(u);
        try pad.buy(t, quoteIn, 0) returns (uint256 out) {
            assertLe(out, room, "wallet room");
            uint256 spent = uq - quoteTok.balanceOf(u);
            uint256 net = _realQuote(t) - rq;
            uint256 padDelta = quoteTok.balanceOf(address(pad)) - pq;
            assertGe(padDelta, net, "pad keeps >= net");
            assertLe(padDelta - net, 1, "pad dust <= 1 wei");
            uint256 fee = (spent * 100) / BPS;
            assertEq(bucket.accruedQuote(address(quoteTok)) - bk, fee, "bucket = 1% only");
            assertEq(spent, padDelta + fee, "conservation: curve + 1% fee, no tax");
            assertEq(quoteTok.balanceOf(treasury), 0, "recipient: nothing on the curve");
            assertEq(quoteTok.balanceOf(address(divVault)), 0, "holders: nothing on the curve");
            assertEq(quoteTok.balanceOf(address(handler)), 0, "handler: nothing on the curve");
        } catch (bytes memory err) {
            bytes4 sel = bytes4(err);
            assertTrue(sel == LaunchpadV3.ZeroAmount.selector || sel == LaunchpadV3.WalletCapReached.selector, "revert");
        }
    }

    /// @dev Sell: the pad pays exactly the curve's quoteOut; the seller gets quoteOut − 1% (no sell tax on the curve).
    function testFuzz_sellAccounting(uint256 inQ, uint256 frac, uint16 b, uint16 s) public {
        b = uint16(bound(b, 100, 500));
        s = uint16(bound(s, 100, 500));
        inQ = bound(inQ, 1e9, 1 ether);
        frac = bound(frac, 1, 10_000);
        address t = _create(_tax(b, s, 3_000, treasury));
        vm.prank(agent);
        pad.buy(t, inQ, 0);
        vm.prank(agent2);
        pad.buy(t, 0.3 ether, 0);
        uint256 amt = (IERC20(t).balanceOf(agent) * frac) / 10_000;
        vm.assume(amt > 0);
        uint256 pq = quoteTok.balanceOf(address(pad));
        uint256 uq = quoteTok.balanceOf(agent);
        uint256 rq = _realQuote(t);
        vm.startPrank(agent);
        IERC20(t).approve(address(pad), amt);
        pad.sell(t, amt, 0);
        vm.stopPrank();
        uint256 quoteOut = rq - _realQuote(t);
        assertEq(pq - quoteTok.balanceOf(address(pad)), quoteOut, "pad pays exactly quoteOut");
        assertEq(quoteTok.balanceOf(agent) - uq, quoteOut - (quoteOut * 100) / BPS, "seller net: only the 1% fee");
        assertEq(quoteTok.balanceOf(treasury), 0, "recipient: nothing on the curve");
        assertEq(quoteTok.balanceOf(address(divVault)), 0, "holders: nothing on the curve");
    }

    /// @dev Graduation truncation (cap off): the graduating buy pays the 1% fee only on what it spends; the pair gets
    ///      the locked graduation amount (+ ≤ 1 wei); the pad keeps ≤ 1 wei.
    function testFuzz_gradTruncation(uint256 pre, uint256 quoteIn, uint16 b) public {
        b = uint16(bound(b, 100, 500));
        pre = bound(pre, 1 ether, 15.5 ether);
        quoteIn = bound(quoteIn, 1, 30 ether);
        vm.prank(owner);
        pad.setWalletCapEnabled(false);
        address t = _create(_tax(b, 300, 0, treasury));
        quoteTok.mintUnlimited(agent2, 100 ether);
        vm.prank(agent2);
        pad.buy(t, pre, 0);
        if (_graduated(t)) return;
        address u = makeAddr("gradBuyer");
        _agent(u);
        quoteTok.mintUnlimited(u, 100 ether);
        uint256 uq = quoteTok.balanceOf(u);
        vm.prank(u);
        pad.buy(t, quoteIn, 0);
        uint256 spent = uq - quoteTok.balanceOf(u);
        if (_graduated(t)) {
            uint256 toPair = quoteTok.balanceOf(_pairOf(t));
            assertGe(toPair, 15 ether, "pair got >= gradAmt");
            assertLe(toPair, 15 ether + 1, "pair got <= gradAmt + 1");
            assertLe(quoteTok.balanceOf(address(pad)), 1, "pad dust");
        } else {
            assertEq(spent, quoteIn, "no refund unless truncated");
        }
    }
}
