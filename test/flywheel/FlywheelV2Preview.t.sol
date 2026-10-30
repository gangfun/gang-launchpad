// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFlywheelPad} from "../../src/flywheel/interfaces/IFlywheelPad.sol";
import {FlywheelV2Base} from "./FlywheelV2.t.sol";

/// @notice From audit V2 / B: previews vs trades on random pool paths for every guard and window, prices() vs an
///         independent ledger, Created's cfg order, checkConfig's V2 bounds. (The exact supply-cap check, B-1, is in
///         FlywheelV2AuditFixesTest.)
contract FlywheelV2PreviewTest is FlywheelV2Base {
    uint256[4] internal G = [uint256(0), 1_500, 2_000, 3_000];

    uint256 nOk;
    uint256 nBelow;
    uint256 nAbove;
    uint256 nPace;

    function _rand(uint256 seed, uint256 i) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, i)));
    }

    /// Random pool paths (dumps, lifts, quiet stretches, keeper pokes, same-block dumps) then one mint: the preview's
    /// `ok`, tokensOut and cost equal the trade's outcome exactly, for every guard and window.
    function testFuzz_previewMintPostMatchesTrade(uint256 seed) public {
        _prep(10, 4);
        (uint256 rT,) = _res(t);
        deal(t, whale, rT * 2);
        for (uint256 round; round < 12; round++) {
            uint256 snap = vm.snapshotState();
            uint256 r = _rand(seed, round);
            _setRules(G[r % 4], (r >> 8) % 2 == 0 ? 900 : 1800);
            uint256 steps = 1 + (r >> 16) % 10;
            for (uint256 s; s < steps; s++) {
                uint256 x = _rand(r, s);
                _next(1 + x % 200, 1 + (x >> 8) % 600);
                uint256 op = (x >> 20) % 4;
                if (op == 0) _dumpTo(whale, (_price(t) * (10_000 - (x >> 32) % 6_000)) / 10_000);
                else if (op == 1) _liftTo(crowd, (_price(t) * (10_000 + (x >> 32) % 5_000)) / 10_000);
                else if (op == 2) handler.observe(t);
            }
            _next(1, 1 + (r >> 40) % 30);
            // sometimes a dump in the mint's block (abovePool / blockStart pricing)
            if ((r >> 48) % 3 == 0) _dumpTo(whale, (_price(t) * (10_000 - (r >> 56) % 2_500)) / 10_000);
            address m = ids[(r >> 64) % ids.length];
            uint256 n = 1 + (r >> 72) % 12;
            _check(m, n);
            // a second mint in the same block by another ID (pace / blockStart already set by the first)
            _check(ids[((r >> 64) + 1) % ids.length], 1 + (r >> 80) % 12);
            uint256[4] memory c = [nOk, nBelow, nAbove, nPace];
            vm.revertToState(snap);
            (nOk, nBelow, nAbove, nPace) = (c[0], c[1], c[2], c[3]);
        }
        emit log_named_uint("ok", nOk);
        emit log_named_uint("belowAverage", nBelow);
        emit log_named_uint("abovePool", nAbove);
        emit log_named_uint("pace", nPace);
    }

    function _check(address m, uint256 n) internal {
        (uint256 acc, uint256 paid, uint256 fee, uint256 out, bool ok) = pad.previewMintPost(t, m, n);
        uint256 b0 = IERC20(t).balanceOf(m);
        uint256 q0 = wbnb.balanceOf(m);
        vm.prank(m);
        try pad.mintPost(t, n, 0, type(uint256).max, address(0)) returns (uint256 o, uint256 sp) {
            assertTrue(ok, "preview said no, trade went through");
            assertEq(o, out, "tokensOut");
            assertEq(sp, paid + fee, "spent");
            assertEq(IERC20(t).balanceOf(m) - b0, out, "delivered");
            assertEq(q0 - wbnb.balanceOf(m), paid + fee, "pulled");
            assertGt(acc, 0);
            nOk++;
        } catch (bytes memory e) {
            assertFalse(ok, "preview ok, trade reverted");
            bytes4 sel = bytes4(e);
            if (sel == IFlywheelPad.PriceBelowAverage.selector) nBelow++;
            else if (sel == IFlywheelPad.PriceAbovePool.selector) nAbove++;
            else if (sel == IFlywheelPad.PaceExceeded.selector) nPace++;
        }
    }

    /// prices(): spot / blockStart / high from the pair and handler; average over the sale's window from a ledger.
    function test_pricesMatchesLedgerForBothWindows() public {
        _prep(10, 0);
        _next(1, 1);
        // T1: lift; then keeper pokes every 5 min for 40 min at a constant price
        _liftTo(crowd, (_price(t) * 12_000) / 10_000);
        (uint256 rT, uint256 rQ) = _res(t);
        uint256 p1 = (rQ << 112) / rT;
        for (uint256 i; i < 8; i++) {
            _next(100, 300);
            handler.observe(t);
        }
        // T2: dump in the same block as the last poke; then pokes every 5 min for 20 min
        deal(t, whale, rT);
        _dumpTo(whale, (_price(t) * 7_000) / 10_000);
        (rT, rQ) = _res(t);
        uint256 p2 = (rQ << 112) / rT;
        for (uint256 i; i < 4; i++) {
            _next(100, 300);
            handler.observe(t);
        }
        _next(1, 1); // one second past the last obs, new block
        uint256 nowP2Secs = 1201;
        _setRules(2_000, 900);
        (uint256 spot, uint256 bs, uint256 high, uint256 avg900) = pad.prices(t);
        assertEq(spot, p2);
        assertEq(bs, spot, "untouched block: blockStart == spot");
        (uint32 kt, uint224 kh) = handler.peakOf(t);
        assertEq(high, handler.decayedHigh(kh, block.timestamp - kt));
        // 900 s: newest obs <= now-900 is T2+300 → (p2 * 901) / 901
        assertApproxEqRel(avg900, p2, 1e12, "900s average");
        _setRules(2_000, 1800);
        (,,, uint256 avg1800) = pad.prices(t);
        // 1800 s: newest obs <= now-1800 is T2-600 → (p1*600 + p2*1201) / 1801
        uint256 exp = (p1 * 600 + p2 * nowP2Secs) / 1801;
        assertApproxEqRel(avg1800, exp, 1e12, "1800s average");
        // guard off: the TWAP is not read by pricing, but prices() still reports it
        _setRules(0, 1800);
        (,,, uint256 avgOff) = pad.prices(t);
        assertEq(avgOff, avg1800);
    }

    /// Created carries cfg with guardBps and twapWindow last; create's selector is the V2 tuple.
    function test_createdEventCfgOrder() public {
        IFlywheelPad.FlyConfig memory c = _agentMint();
        c.guardBps = 3_000;
        c.twapWindow = 900;
        vm.recordLogs();
        address tok = _create(c, 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256(
            "Created(address,address,string,string,string,address,uint256,(uint256,uint16,uint8,uint8,uint16,uint16,uint16,uint16,uint16,uint16,uint32,uint32,uint8,bool,uint8,uint16,uint32,uint16,uint16,uint16,uint32))"
        );
        bool found;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(pad) || logs[i].topics[0] != topic) continue;
            (,,,, uint256 price, IFlywheelPad.FlyConfig memory got) =
                abi.decode(logs[i].data, (string, string, string, address, uint256, IFlywheelPad.FlyConfig));
            assertEq(got.guardBps, 3_000);
            assertEq(got.twapWindow, 900);
            assertEq(got.supplyCapMul, c.supplyCapMul);
            assertEq(price, pad.sales(tok).basePrice);
            found = true;
        }
        assertTrue(found, "Created with the V2 topic");
        (uint16 g, uint32 w) = pad.postRulesOf(tok);
        assertEq(g, 3_000);
        assertEq(w, 900);
    }

    /// checkConfig: the new fields and the quota cap.
    function test_checkConfigBounds() public view {
        IFlywheelPad.FlyConfig memory c = _agentMint();
        c.baseQuota = 11;
        (bool ok, string memory why) = pad.checkConfig(c, 1);
        assertFalse(ok);
        assertEq(why, "baseQuota must be 5-10 with postMint");
        c.postMint = false;
        (ok,) = pad.checkConfig(c, 1);
        assertTrue(ok, "11 fine without postMint");
        c.baseQuota = 10;
        c.postMint = true;
        c.guardBps = 1_000;
        (ok, why) = pad.checkConfig(c, 1);
        assertFalse(ok);
        c.guardBps = 0;
        c.twapWindow = 0;
        (ok, why) = pad.checkConfig(c, 1);
        assertFalse(ok);
        assertEq(why, "twapWindow must be 900 or 1800");
        c.twapWindow = 1800;
        c.inviteBonus = 2;
        (ok, why) = pad.checkConfig(c, 1);
        assertFalse(ok);
        assertEq(why, "inviteBonus must be 0-1 with postMint");
    }
}
