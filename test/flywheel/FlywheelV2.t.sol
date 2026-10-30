// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IFlywheelPad} from "../../src/flywheel/interfaces/IFlywheelPad.sol";
import {FlywheelPostLogic} from "../../src/flywheel/FlywheelPostLogic.sol";
import {GangMintToken} from "../../src/flywheel/GangMintToken.sol";
import {FlywheelFixture} from "./FlywheelFixture.sol";
import {TwapMockPair} from "../mocks/TwapMockPair.sol";

/// @notice V2 post-launch rules (price = max(spot, blockStart); refused more than 10% above the pool; the dev's TWAP
///         guard, 0 / 15 / 20 / 30% over 900 or 1,800 s) as permanent regressions, ported from the scratch evaluation
///         that chose them ("V6"). Scenario harness: one launch per test function, every scenario from a snapshot.
///
///         Accounting (bag-neutral): the whale already holds its inventory (dealt, so the pool keeps its launch size)
///         and the buy-back restores it. held = change in WBNB of whale + IDs + (minted tokens + bag overshoot) at the
///         lower of the start and end spot, less their exit cost (sell tax + DEX fee). sold = change in WBNB after every
///         ID (and the overshoot) is sold in the pool right away.
abstract contract FlywheelV2Base is FlywheelFixture {
    uint256 internal constant BPS = 10_000;
    /// @dev GangFlywheelPad's storage slot of `postRulesOf` (checked by `_setRules`).
    uint256 internal constant POST_RULES_SLOT = 16;

    struct Sc {
        uint256 attack; // 1 same block, 2 next block, 22 dump N / observe N+1 / mint N+2, 3 hold, 4 backrun
        uint256 depthBps; // dump depth below the pre-attack spot
        uint256 k; // Agent IDs minting
        bool up; // uptrend before the attack
        uint256 holdMin; // attack 3
        bool dip; // attack 3: a dip buyer restores half the drop, half-life 5 min
        uint256 riseBps; // attack 4: an outside buy lifts the price this much
        uint256 mode; // attack 4: 0 dump in the buy's block, 1 dump in the next block, 2 = 1 + an observe gap block
    }

    address internal t;
    address internal whale;
    address internal crowd;
    address[] internal ids;
    IFlywheelPad.FlyConfig internal cfg;

    // per-run state
    uint256 internal p0;
    uint256 internal rq0;
    int256 internal wq0;
    uint256 internal bag;
    uint256 internal mints;
    uint256 internal mintPaid;

    function setUp() public virtual {
        _deploy();
    }

    /// @dev A launched J-preset sale (quota `baseQuota` + 1 per invite) past its protection, a whale, a crowd and
    ///      `nIds` Agent IDs. Gas metering stays off for the rest of the test: a thousand-wallet fill and dozens of
    ///      scenarios do not fit one test's gas limit (nothing on these paths depends on the gas left).
    function _prep(uint16 baseQuota, uint256 nIds) internal {
        vm.pauseGasMetering();
        cfg = _agentMint();
        cfg.baseQuota = baseQuota;
        t = _create(cfg, 1);
        _fillAndLaunch(t);
        vm.warp(vm.getBlockTimestamp() + cfg.window);
        vm.roll(vm.getBlockNumber() + 1);
        whale = _newAgent();
        crowd = _plain();
        for (uint256 i; i < nIds; i++) {
            ids.push(_newAgent());
        }
    }

    /// @dev Test-only: switch a launched sale's post rules in place, so one pool path is checked under every guard and
    ///      window (a real sale's rules are fixed at create).
    function _setRules(uint256 g, uint256 w) internal {
        bytes32 slot = keccak256(abi.encode(t, POST_RULES_SLOT));
        vm.store(address(pad), slot, bytes32((w << 16) | g));
        (uint16 g2, uint32 w2) = pad.postRulesOf(t);
        require(g2 == g && w2 == w, "postRulesOf slot moved");
    }

    function _next(uint256 blocks, uint256 secs) internal {
        vm.roll(vm.getBlockNumber() + blocks);
        vm.warp(vm.getBlockTimestamp() + secs);
    }

    // ------------------------------------------------------------ pool helpers
    function _buyPaid(address who, uint256 quoteIn) internal {
        TwapMockPair p = TwapMockPair(_sale(t).pair);
        (uint256 rT, uint256 rQ) = _res(t);
        uint256 out = _amountOut(quoteIn, rQ, rT);
        vm.prank(who);
        wbnb.transfer(address(p), quoteIn);
        bool t0 = p.token0() == t;
        p.swap(t0 ? out : 0, t0 ? 0 : out, who, "");
    }

    /// @dev Quote needed to take `gross` tokens out of the pair.
    function _quoteFor(uint256 gross) internal view returns (uint256) {
        (uint256 rT, uint256 rQ) = _res(t);
        require(gross < rT, "too big");
        return (rQ * gross * 10_000) / ((rT - gross) * 9975) + 1;
    }

    /// @dev A bag the whale already holds, enough for a dump of `depthBps` (margin 30%, taxes included).
    function _inventory(uint256 depthBps) internal {
        (uint256 rT,) = _res(t);
        uint256 inv = Math.sqrt((1e36 * 10_000) / (10_000 - depthBps)); // 1e18 / sqrt(1-d)
        uint256 c = ((inv - 1e18) * 130) / 98;
        deal(t, whale, IERC20(t).balanceOf(whale) + (c * rT) / 1e18);
    }

    /// @dev Sell from `who` until the spot is at or below `target` (1e18 price scale).
    function _dumpTo(address who, uint256 target) internal {
        (uint256 rT, uint256 rQ) = _res(t);
        if (_price(t) <= target) return;
        uint256 rT2 = Math.sqrt((rQ * rT / target) * 1e18);
        uint256 gross = rT2 > rT ? ((rT2 - rT) * 10_000 * 85) / (uint256(10_000 - cfg.sellTaxBps) * 100) : 0;
        uint256 bal = IERC20(t).balanceOf(who);
        if (gross > bal) gross = bal;
        if (gross > 0) _poolSell(t, who, gross);
        for (uint256 i; i < 600 && _price(t) > target; i++) {
            (rT,) = _res(t);
            uint256 x = rT / 1_000;
            bal = IERC20(t).balanceOf(who);
            if (x > bal) x = bal;
            if (x == 0) break;
            _poolSell(t, who, x);
        }
    }

    /// @dev A third party buys until the spot reaches `target` (free money).
    function _liftTo(address who, uint256 target) internal {
        (uint256 rT, uint256 rQ) = _res(t);
        if (_price(t) >= target) return;
        uint256 rQ2 = Math.sqrt((rQ * rT / 1e18) * target);
        if (rQ2 <= rQ) return;
        _poolBuy(t, who, ((rQ2 - rQ) * 10_000) / 9975);
    }

    function _buyBack(address who, uint256 want) internal {
        for (uint256 i; i < 30; i++) {
            uint256 bal = IERC20(t).balanceOf(who);
            if (bal >= want) return;
            uint256 gross = ((want - bal) * 10_000) / 9_900 + 1;
            _buyPaid(who, _quoteFor(gross));
        }
    }

    function _quoteAll() internal view returns (int256 q) {
        q = int256(wbnb.balanceOf(whale));
        for (uint256 i; i < ids.length; i++) {
            q += int256(wbnb.balanceOf(ids[i]));
        }
    }

    // ------------------------------------------------------------ minting
    /// @dev The first `k` IDs mint their whole quota (each invited by the previous one), then their invite bonus.
    function _mintAll(uint256 k) internal {
        for (uint256 i; i < k; i++) {
            address w = ids[i];
            address ref = i == 0 ? address(0) : ids[i - 1];
            vm.startPrank(w);
            for (uint256 j; j < 20 && pad.quotaLeft(t, w) > 0; j++) {
                try pad.mintPost(t, 10, 0, type(uint256).max, ref) returns (uint256, uint256 spent) {
                    mints++;
                    mintPaid += spent;
                } catch {
                    break;
                }
            }
            vm.stopPrank();
        }
        for (uint256 i; i < k; i++) {
            address w = ids[i];
            uint256 left = pad.quotaLeft(t, w);
            if (left == 0) continue;
            vm.prank(w);
            try pad.mintPost(t, left, 0, type(uint256).max, address(0)) returns (uint256, uint256 spent) {
                mints++;
                mintPaid += spent;
            } catch {}
        }
    }

    // ------------------------------------------------------------ one scenario
    /// @dev Everything before the mints. Returns the whale's bag before the dump.
    function _stage(Sc memory sc) internal returns (uint256 bagNow) {
        uint256 d = sc.attack == 4 ? (sc.riseBps * 10_000) / (10_000 + sc.riseBps) : sc.depthBps;
        _inventory(d);
        _next(4_800, 1 hours);
        handler.observe(t);
        if (sc.up) {
            for (uint256 i; i < 20; i++) {
                _next(240, 3 minutes);
                (, uint256 rQ) = _res(t);
                _poolBuy(t, crowd, (rQ * 100) / 10_000);
                handler.observe(t);
            }
        }
        _next(240, 3 minutes);
        handler.observe(t);

        p0 = _price(t);
        (, rq0) = _res(t);
        wq0 = _quoteAll();
        bag = IERC20(t).balanceOf(whale);
        bagNow = bag;

        if (sc.attack == 4) {
            _next(1, 1); // block A
            uint256 pb = _price(t);
            _liftTo(_plain(), (pb * (10_000 + sc.riseBps)) / 10_000);
            if (sc.mode != 0) _next(1, 1);
            _dumpTo(whale, pb);
            if (sc.mode == 2) {
                _next(1, 1);
                handler.observe(t);
            }
            _next(1, 1);
        } else {
            _next(1, 1); // block N
            _dumpTo(whale, (p0 * (10_000 - sc.depthBps)) / 10_000);
            uint256 pDump = _price(t);
            if (sc.attack == 2) {
                _next(1, 1);
            } else if (sc.attack == 22) {
                _next(1, 1);
                handler.observe(t);
                _next(1, 1);
            } else if (sc.attack == 3) {
                uint256 f = 1e6;
                for (uint256 m; m < sc.holdMin; m++) {
                    _next(80, 60);
                    if (sc.dip) {
                        f = (f * 870_551) / 1e6;
                        _liftTo(crowd, pDump + ((p0 - pDump) * (1e6 - f)) / 2e6);
                    }
                }
                _next(1, 1);
            }
            // attack 1: the mints follow in block N
        }
    }

    function _finish(Sc memory sc, uint256 bagNow) internal returns (int256 held, int256 liq) {
        _mintAll(sc.k);
        _buyBack(whale, bagNow);
        uint256 p1 = _price(t);
        uint256 tok = IERC20(t).balanceOf(whale) - bag;
        for (uint256 i; i < sc.k; i++) {
            tok += IERC20(t).balanceOf(ids[i]);
        }
        uint256 pl = p1 < p0 ? p1 : p0;
        held = (_quoteAll() - wq0) + int256((((tok * pl) / 1e18) * (10_000 - uint256(cfg.sellTaxBps) - 25)) / 10_000);
        for (uint256 i; i < sc.k; i++) {
            uint256 b = IERC20(t).balanceOf(ids[i]);
            if (b > 1e15) _poolSell(t, ids[i], b);
        }
        uint256 extra = IERC20(t).balanceOf(whale) - bag;
        if (extra > 1e15) _poolSell(t, whale, extra);
        liq = _quoteAll() - wq0;
    }

    /// @dev One scenario from a snapshot (state restored after). `g`, `w`: the post rules the mints meet.
    function _one(Sc memory sc, uint256 g, uint256 w) internal returns (int256 held, int256 liq, uint256 n) {
        uint256 snap = vm.snapshotState();
        mints = 0;
        mintPaid = 0;
        _setRules(0, 30 minutes);
        uint256 bagNow = _stage(sc);
        _setRules(g, w);
        (held, liq) = _finish(sc, bagNow);
        n = mints;
        emit log_named_string("scenario", _label(sc));
        emit log_named_int("  held (wei)", held);
        emit log_named_int("  sold (wei)", liq);
        emit log_named_uint("  mints", n);
        emit log_named_decimal_uint("  paid (WBNB)", mintPaid, 18);
        vm.revertToState(snap);
    }

    function _label(Sc memory sc) internal pure returns (string memory) {
        return string.concat(
            "attack ",
            vm.toString(sc.attack),
            sc.up ? " up" : " flat",
            " depth ",
            vm.toString(sc.depthBps),
            " k ",
            vm.toString(sc.k),
            " hold ",
            vm.toString(sc.holdMin),
            sc.dip ? " dip" : "",
            " rise ",
            vm.toString(sc.riseBps),
            " mode ",
            vm.toString(sc.mode)
        );
    }
}

/// @notice Same-block dump-then-mint: the block's start prices the mints, and past 10% they are refused outright.
contract FlywheelV2SameBlockTest is FlywheelV2Base {
    function test_sameBlockDumpThenMintLosesAtEveryDepth() public {
        _prep(10, 60);
        uint256[5] memory depths = [uint256(500), 1_000, 2_000, 3_000, 5_000];
        for (uint256 i; i < 5; i++) {
            Sc memory sc;
            sc.attack = 1;
            sc.depthBps = depths[i];
            sc.k = 60;
            (int256 held, int256 liq, uint256 n) = _one(sc, 0, 30 minutes);
            assertLe(held, 0, "same-block dump-then-mint paid (held)");
            assertLe(liq, 0, "same-block dump-then-mint paid (sold)");
            if (depths[i] > 1_000) assertEq(n, 0, "a mint more than 10% above the pool went through");
        }
    }

    function test_sameBlockDumpIsPricedAtTheBlockStartOrRefused() public {
        _prep(10, 1);
        _inventory(5_000);
        _next(1, 3);
        uint256 snap = vm.snapshotState();
        // −5%: priced at the block's start, above the pool
        (, uint256 blockStart0,,) = pad.prices(t);
        _dumpTo(whale, (_price(t) * 9_500) / 10_000);
        (uint256 spot, uint256 blockStart,,) = pad.prices(t);
        assertEq(blockStart, blockStart0);
        assertLt(spot, blockStart);
        (, uint256 paid,, uint256 out, bool ok) = pad.previewMintPost(t, ids[0], 10);
        assertTrue(ok);
        assertEq(out, (paid << 112) / blockStart);
        vm.prank(ids[0]);
        (uint256 got,) = pad.mintPost(t, 10, 0, type(uint256).max, address(0));
        assertEq(got, out);
        vm.revertToState(snap);
        // −15%: refused (the block's start is more than 10% above the pool)
        _dumpTo(whale, (_price(t) * 8_500) / 10_000);
        (,,,, ok) = pad.previewMintPost(t, ids[0], 10);
        assertFalse(ok);
        vm.prank(ids[0]);
        vm.expectRevert(IFlywheelPad.PriceAbovePool.selector);
        pad.mintPost(t, 10, 0, type(uint256).max, address(0));
        // the next block: priced at the pool
        _next(1, 0);
        (spot,,,) = pad.prices(t);
        (, paid,, out, ok) = pad.previewMintPost(t, ids[0], 10);
        assertTrue(ok);
        assertEq(out, (paid << 112) / spot);
    }
}

/// @notice Honest minters after a real crash, under every guard and window: refused in the crash's own block, priced
///         at the pool from the next block on (never above it), and let through exactly when the guard allows.
contract FlywheelV2HonestTest is FlywheelV2Base {
    uint256[4] internal GUARDS = [uint256(0), 1_500, 2_000, 3_000];
    uint256[2] internal WINDOWS = [uint256(15 minutes), 30 minutes];

    function _crashThenMint(uint256 crashBps, uint256 gapBlocks) internal returns (bool ok, uint256 spot) {
        address seller = _newAgent();
        (uint256 rT,) = _res(t);
        deal(t, seller, rT);
        _next(1, 1);
        uint256 pre = _price(t);
        _dumpTo(seller, (pre * (10_000 - crashBps)) / 10_000);
        if (gapBlocks != 0) _next(gapBlocks, (gapBlocks * 3) / 4 + 1);
        address w = ids[0];
        (spot,,,) = pad.prices(t);
        (, uint256 paid,, uint256 previewOut, bool pok) = pad.previewMintPost(t, w, 10);
        vm.prank(w);
        try pad.mintPost(t, 10, 0, type(uint256).max, address(0)) returns (uint256 out, uint256) {
            ok = true;
            assertTrue(pok, "preview said no");
            assertEq(out, previewOut, "preview tokensOut");
            assertEq(out, (paid << 112) / spot, "not priced at the pool");
        } catch {
            assertFalse(pok, "preview said ok but the mint reverted");
        }
    }

    function _honest(uint256 crashBps) internal {
        _prep(10, 1);
        uint256[4] memory gaps = [uint256(0), 1, 2, 21];
        uint256 snap = vm.snapshotState();
        for (uint256 wi; wi < 2; wi++) {
            for (uint256 gi; gi < 4; gi++) {
                for (uint256 x; x < 4; x++) {
                    _setRules(GUARDS[gi], WINDOWS[wi]);
                    (bool ok,) = _crashThenMint(crashBps, gaps[x]);
                    if (x == 0) assertFalse(ok, "same-block mint after a crash went through");
                    // a few seconds on the TWAP has barely moved: the guard lets it through iff the crash is within it
                    else if (crashBps != GUARDS[gi]) assertEq(ok, GUARDS[gi] == 0 || crashBps < GUARDS[gi], "guard");
                    vm.revertToState(snap);
                }
            }
        }
    }

    function test_honestMinterAfterA20PercentCrash() public {
        _honest(2_000);
    }

    function test_honestMinterAfterA30PercentCrash() public {
        _honest(3_000);
    }

    function test_honestMinterAfterA50PercentCrash() public {
        _honest(5_000);
    }
}

/// @notice The guard: refused exactly when spot × 10,000 < TWAP × (10,000 − guardBps), and the refusal lifts as the
///         TWAP over the sale's window catches up with a crash (the shorter window sooner), for both windows.
contract FlywheelV2GuardTest is FlywheelV2Base {
    uint256[3] internal GUARDS = [uint256(1_500), 2_000, 3_000];
    uint256[2] internal WINDOWS = [uint256(15 minutes), 30 minutes];

    function _refuses(uint256 g) internal view returns (bool) {
        (uint256 spot,,, uint256 avg) = pad.prices(t);
        return spot * BPS < avg * (BPS - g);
    }

    function test_guardRefusesAtItsThresholdForBothWindows() public {
        _prep(10, 1);
        _inventory(5_000);
        // a fresh observation ring: keeper pokes every 5 minutes
        for (uint256 i; i < 8; i++) {
            _next(100, 5 minutes);
            handler.observe(t);
        }
        _next(1, 1);
        uint256 snap = vm.snapshotState();
        for (uint256 wi; wi < 2; wi++) {
            for (uint256 gi; gi < 3; gi++) {
                uint256 g = GUARDS[gi];
                _setRules(g, WINDOWS[wi]);
                (,,, uint256 avg) = pad.prices(t);
                uint256 line = (avg * (BPS - g)) / BPS; // UQ112x112
                // block N: dump to just under the line; block N+1, same second (the TWAP does not move): refused
                _dumpTo(whale, (((line * 9_990) / BPS) * 1e18) >> 112);
                _next(1, 0);
                assertTrue(_refuses(g), "not under the line");
                (,,,, bool ok) = pad.previewMintPost(t, ids[0], 1);
                assertFalse(ok);
                vm.prank(ids[0]);
                vm.expectRevert(IFlywheelPad.PriceBelowAverage.selector);
                pad.mintPost(t, 1, 0, type(uint256).max, address(0));
                // a buyer lifts it just over the line (block N+1); block N+2, same second: allowed
                _liftTo(crowd, (((line * 10_010) / BPS) * 1e18) >> 112);
                _next(1, 0);
                assertFalse(_refuses(g), "not over the line");
                (,,,, ok) = pad.previewMintPost(t, ids[0], 1);
                assertTrue(ok);
                vm.prank(ids[0]);
                pad.mintPost(t, 1, 0, type(uint256).max, address(0));
                vm.revertToState(snap);
            }
        }
    }

    /// @dev A 40% crash nobody buys back, the keeper poking every minute: every guard refuses right after, then lifts
    ///      as the TWAP comes down, within the window plus the 5-minute observation step; the 15-minute window first.
    function test_guardLiftsAsTheTwapCatchesUp() public {
        _prep(10, 1);
        for (uint256 i; i < 8; i++) {
            _next(100, 5 minutes);
            handler.observe(t);
        }
        address seller = _newAgent();
        (uint256 rT,) = _res(t);
        deal(t, seller, rT);
        _next(1, 1);
        _dumpTo(seller, (_price(t) * 6_000) / 10_000);
        uint256[6] memory firstOk; // minutes after the crash, guard i × window j at 2i + j
        for (uint256 m = 1; m <= 40; m++) {
            _next(20, 60);
            handler.observe(t);
            for (uint256 i; i < 3; i++) {
                for (uint256 j; j < 2; j++) {
                    _setRules(GUARDS[i], WINDOWS[j]);
                    bool refused = _refuses(GUARDS[i]);
                    (,,,, bool ok) = pad.previewMintPost(t, ids[0], 1);
                    assertEq(ok, !refused, "preview disagrees with the guard");
                    if (m == 1) assertTrue(refused, "a 40% crash passed the guard");
                    if (ok && firstOk[2 * i + j] == 0) {
                        firstOk[2 * i + j] = m;
                        uint256 snap = vm.snapshotState();
                        vm.prank(ids[0]);
                        pad.mintPost(t, 1, 0, type(uint256).max, address(0));
                        vm.revertToState(snap);
                    }
                }
            }
        }
        for (uint256 i; i < 3; i++) {
            emit log_named_uint(
                string.concat("guard ", vm.toString(GUARDS[i]), " w900: lifts after min"), firstOk[2 * i]
            );
            emit log_named_uint(
                string.concat("guard ", vm.toString(GUARDS[i]), " w1800: lifts after min"), firstOk[2 * i + 1]
            );
            for (uint256 j; j < 2; j++) {
                uint256 m = firstOk[2 * i + j];
                assertGt(m, 0, "never lifted");
                assertLe(m, WINDOWS[j] / 60 + 5, "lifted later than the window and one observation step");
            }
            assertLt(firstOk[2 * i], firstOk[2 * i + 1], "the 15-minute window did not lift first");
            if (i > 0) assertLe(firstOk[2 * i], firstOk[2 * i - 2], "a wider guard lifted later");
        }
    }
}

/// @notice Mint, then sell right away, never pays: every guard and window, after a crash or not, with earlier mints in
///         the block.
contract FlywheelV2MintThenSellTest is FlywheelV2Base {
    uint256[4] internal GUARDS = [uint256(0), 1_500, 2_000, 3_000];

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_mintThenSellNeverPays(
        uint8 shares,
        uint16 buyBps,
        uint16 sellTax,
        uint16 devCut,
        uint8 pre,
        uint8 gi,
        bool w15,
        uint16 crash,
        uint8 gap
    ) public {
        IFlywheelPad.FlyConfig memory c = _wide();
        c.buyBps = uint16(bound(buyBps, 0, 5_000));
        c.sellTaxBps = uint16(bound(sellTax, 100, 200));
        c.devCutBps = uint16(bound(devCut, 0, 1_000));
        c.guardBps = uint16(GUARDS[bound(gi, 0, 3)]);
        c.twapWindow = w15 ? 900 : 1_800;
        cfg = c;
        t = _create(c, 1);
        _fillAndLaunch(t);
        _next(1, c.window);
        uint256 crashBps = bound(crash, 0, 5_000);
        if (crashBps != 0) {
            address seller = _newAgent();
            (uint256 rT,) = _res(t);
            deal(t, seller, rT);
            _next(1, 1);
            _dumpTo(seller, (_price(t) * (10_000 - crashBps)) / 10_000);
            _next(bound(gap, 1, 3), 1);
        }
        for (uint256 i; i < bound(pre, 0, 5); i++) {
            address w = _newAgent();
            vm.prank(w);
            try pad.mintPost(t, 10, 0, type(uint256).max, address(0)) {} catch {}
        }
        address a = _newAgent();
        uint256 n = bound(shares, 1, 10);
        uint256 q0 = wbnb.balanceOf(a);
        vm.prank(a);
        try pad.mintPost(t, n, 0, type(uint256).max, address(0)) returns (uint256 out, uint256) {
            _poolSell(t, a, out);
            assertLt(wbnb.balanceOf(a), q0, "mint-then-sell paid");
        } catch {}
    }
}

/// @notice The J preset (quota 10 + 1 per invite, 10% dev cut, 30% buy, 2% sell tax, 20 BNB) with ten Agent IDs against
///         the dump-then-mint families: next block (2), dump / observe / mint over three blocks (22), dump and hold (3,
///         with or without a dip buyer), back-running an outside buy (4). The guard is off here (the most permissive
///         rules). Every scenario loses, held and sold.
contract FlywheelV2JPresetTenIdsTest is FlywheelV2Base {
    function _scenarios() internal pure returns (Sc[] memory s) {
        s = new Sc[](18);
        uint256 n;
        uint256[3] memory depths = [uint256(1_000), 3_000, 5_000];
        for (uint256 i; i < 3; i++) {
            s[n].attack = 2;
            s[n++].depthBps = depths[i];
        }
        s[n].attack = 2;
        s[n].up = true;
        s[n++].depthBps = 5_000;
        s[n].attack = 22;
        s[n++].depthBps = 5_000;
        uint256[2] memory holds = [uint256(5), 15];
        for (uint256 i; i < 2; i++) {
            for (uint256 x; x < 2; x++) {
                s[n].attack = 3;
                s[n].depthBps = 5_000;
                s[n].holdMin = holds[i];
                s[n++].dip = x == 1;
            }
        }
        uint256[3] memory rises = [uint256(400), 1_000, 2_000];
        for (uint256 i; i < 3; i++) {
            for (uint256 m; m < 3; m++) {
                s[n].attack = 4;
                s[n].riseBps = rises[i];
                s[n++].mode = m;
            }
        }
    }

    function test_jPreset_tenIdsLoseEverywhere() public {
        _prep(10, 10);
        Sc[] memory s = _scenarios();
        for (uint256 i; i < s.length; i++) {
            s[i].k = 10;
            (int256 held, int256 liq, uint256 n) = _one(s[i], 0, 30 minutes);
            assertGt(n, 0, "the attack never got to mint");
            assertLt(held, 0, string.concat("10 IDs paid (held): ", _label(s[i])));
            assertLt(liq, 0, string.concat("10 IDs paid (sold): ", _label(s[i])));
        }
    }
}

/// @dev FlywheelPostLogic.tierX100 on a stored sale (the pad's views and mintPost read the same function).
contract TierHarness {
    IFlywheelPad.Sale internal s;

    function set(uint8 mode, uint16 stepBps, uint32 stepShares, uint16 maxMulX100) external {
        s.tierMode = mode;
        s.stepBps = stepBps;
        s.stepShares = stepShares;
        s.maxMulX100 = maxMulX100;
    }

    function tier(uint256 n) external view returns (uint256) {
        return FlywheelPostLogic.tierX100(s, n);
    }

    function standard(uint256 n) external pure returns (uint256) {
        return FlywheelPostLogic.standardX100(n);
    }
}

/// @notice Audit V2 fixes: linear tiers count from launch (A-M1), invite bonus 0–1 with postMint (A-M1), postMint only
///         with the Agent ID gate (A-L1), and the exact supply-cap check in `previewMintPost` (B-1).
contract FlywheelV2AuditFixesTest is FlywheelV2Base {
    /// A-M1: share 10,001 is the first post-launch share, at ×1; steps count from it; the cap holds; the standard table
    /// is unchanged.
    function test_linearTierCountsFromLaunch() public {
        TierHarness h = new TierHarness();
        h.set(2, 1_000, 100, 1_000); // the steepest linear tier
        assertEq(h.tier(1), 100);
        assertEq(h.tier(10_000), 100);
        assertEq(h.tier(10_001), 100, "first post-launch share at x1 (was x10)");
        assertEq(h.tier(10_100), 100);
        assertEq(h.tier(10_101), 110);
        assertEq(h.tier(10_200), 110);
        assertEq(h.tier(10_201), 120);
        assertEq(h.tier(19_000), 990);
        assertEq(h.tier(19_001), 1_000);
        assertEq(h.tier(1_000_000), 1_000, "capped");
        h.set(2, 1_000, 100, 300);
        assertEq(h.tier(10_301), 130);
        assertEq(h.tier(12_001), 300, "capped at maxMulX100");
        h.set(2, 50, 1_000, 1_000);
        assertEq(h.tier(11_000), 100);
        assertEq(h.tier(12_001), 101); // two steps of 0.5%, to the cent
        h.set(2, 0, 100, 1_000);
        assertEq(h.tier(500_000), 100);
        h.set(1, 1_000, 100, 1_000); // standard: the linear fields are ignored
        uint256[9] memory ns = [uint256(1), 10_000, 10_001, 11_001, 20_001, 100_001, 1_000_001, 4_440_000, 9_000_000];
        uint256[9] memory want = [uint256(100), 100, 110, 120, 210, 370, 550, 807, 807];
        for (uint256 i; i < ns.length; i++) {
            assertEq(h.tier(ns[i]), want[i], "standard table");
            assertEq(h.standard(ns[i]), want[i]);
        }
        h.set(0, 1_000, 100, 1_000);
        assertEq(h.tier(50_000), 100, "flat");
    }

    /// A-M1: the pad's views and the mint agree with the new count on a launched steep sale.
    function test_linearTierViewsAndMintAgree() public {
        vm.pauseGasMetering();
        cfg = _wide();
        cfg.tierMode = 2;
        cfg.stepBps = 1_000;
        cfg.stepShares = 100;
        cfg.maxMulX100 = 1_000;
        t = _create(cfg, 1);
        _fillAndLaunch(t);
        _next(1, cfg.window);
        uint256 base = _sale(t).basePrice;
        assertEq(pad.sharePrice(t, 10), base, "first post-launch shares at x1");
        assertEq(pad.sharePrice(t, 101), (base * 110) / 100);
        address a = _newAgent();
        (uint256 acc, uint256 paid, uint256 fee, uint256 out, bool ok) = pad.previewMintPost(t, a, 10);
        assertTrue(ok);
        assertEq(acc, 10);
        assertEq(paid, 10 * base);
        vm.prank(a);
        (uint256 got, uint256 spent) = pad.mintPost(t, 10, out, paid + fee, address(0));
        assertEq(got, out);
        assertEq(spent, paid + fee);
    }

    /// A-M1: invite bonus 0–1 with postMint, 0–3 without.
    function test_inviteBonusWithPostMint() public {
        IFlywheelPad.FlyConfig memory c = _wide();
        c.inviteBonus = 1;
        (bool ok, string memory why) = pad.checkConfig(c, 1);
        assertTrue(ok, why);
        c.inviteBonus = 2;
        (ok, why) = pad.checkConfig(c, 1);
        assertFalse(ok);
        assertEq(why, "inviteBonus must be 0-1 with postMint");
        vm.prank(dev);
        vm.expectRevert(
            abi.encodeWithSelector(IFlywheelPad.BadConfig.selector, "inviteBonus must be 0-1 with postMint")
        );
        pad.create(["a", "b", "c", "d"], address(0), address(0), c, 1);
        c.postMint = false;
        c.inviteBonus = 3;
        (ok, why) = pad.checkConfig(c, 1);
        assertTrue(ok, why);
        c.inviteBonus = 4;
        (, why) = pad.checkConfig(c, 1);
        assertEq(why, "inviteBonus must be 0-3");
    }

    /// A-L1: a sale created while the gate is off cannot mint after launch; the snapshot is what counts, so turning
    /// the gate back on later does not matter (create checks it, not only the view).
    function test_postMintNeedsTheAgentGate() public {
        vm.prank(owner);
        pad.setAgentGate(false, address(0));
        IFlywheelPad.FlyConfig memory c = _wide();
        c.devCutBps = 0;
        (bool ok, string memory why) = pad.checkConfig(c, 1);
        assertFalse(ok);
        assertEq(why, "postMint needs the Agent ID gate");
        vm.prank(dev);
        vm.expectRevert(abi.encodeWithSelector(IFlywheelPad.BadConfig.selector, "postMint needs the Agent ID gate"));
        pad.create(["a", "b", "c", "d"], address(0), address(0), c, 1);
        // the dev-cut rule still reads first
        c.devCutBps = 100;
        (, why) = pad.checkConfig(c, 1);
        assertEq(why, "devCutBps must be 0 when ungated");
        // gate on: fine
        vm.prank(owner);
        pad.setAgentGate(true, address(agents));
        (ok, why) = pad.checkConfig(c, 1);
        assertTrue(ok, why);
    }

    /// B-1: the preview's supply-cap check is exact: room for exactly what the mint mints says yes and the mint goes
    /// through; one token less says no and the mint reverts. Across buy shares, the creator (no cut) and a dump in
    /// the block (priced at the block's start, the buy bounded).
    function test_previewCapCheckIsExact() public {
        vm.pauseGasMetering();
        uint16[3] memory buys = [uint16(0), 3_000, 5_000];
        for (uint256 i; i < 3; i++) {
            uint256 snap = vm.snapshotState();
            cfg = _wide();
            cfg.buyBps = buys[i];
            t = _create(cfg, 1);
            _fillAndLaunch(t);
            _next(1, cfg.window);
            address[2] memory who = [_newAgent(), dev];
            for (uint256 j; j < 2; j++) {
                for (uint256 d; d < 2; d++) {
                    uint256 s2 = vm.snapshotState();
                    if (d == 1) {
                        (uint256 rT,) = _res(t);
                        address seller = _newAgent();
                        deal(t, seller, rT);
                        _poolSell(t, seller, rT / 30); // about -6% in the mint's block
                    }
                    _capEdge(who[j]);
                    vm.revertToState(s2);
                }
            }
            vm.revertToState(snap);
        }
    }

    function _capEdge(address m) internal {
        GangMintToken tk = GangMintToken(t);
        (,,,, bool ok) = pad.previewMintPost(t, m, 10);
        assertTrue(ok);
        uint256 snap = vm.snapshotState();
        uint256 s0 = tk.totalSupply();
        vm.prank(m);
        pad.mintPost(t, 10, 0, type(uint256).max, address(0));
        uint256 minted = tk.totalSupply() - s0;
        vm.revertToState(snap);
        // exactly the room it needs
        vm.store(t, bytes32(uint256(2)), bytes32(tk.maxSupply() - minted));
        assertEq(tk.mintRoom(), minted);
        (,,,, ok) = pad.previewMintPost(t, m, 10);
        assertTrue(ok, "exact room: preview says no");
        uint256 s1 = vm.snapshotState();
        vm.prank(m);
        pad.mintPost(t, 10, 0, type(uint256).max, address(0));
        assertEq(tk.mintRoom(), 0);
        vm.revertToState(s1);
        // one token short
        vm.store(t, bytes32(uint256(2)), bytes32(tk.maxSupply() - minted + 1));
        (,,,, ok) = pad.previewMintPost(t, m, 10);
        assertFalse(ok, "short room: preview says yes");
        vm.prank(m);
        vm.expectRevert(GangMintToken.CapExceeded.selector);
        pad.mintPost(t, 10, 0, type(uint256).max, address(0));
        vm.revertToState(snap);
    }
}
