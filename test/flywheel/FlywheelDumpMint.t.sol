// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFlywheelPad} from "../../src/flywheel/interfaces/IFlywheelPad.sol";
import {FlywheelFixture} from "./FlywheelFixture.sol";
import {TwapMockPair} from "../mocks/TwapMockPair.sol";

/// @notice Review R2-2 M-1, kept as a regression: dump just under the 10% TWAP gate in block N, mint with several
///         Agent IDs in block N+1 (where the dumped price is the block's start), buy the dump back in N+1. Before the
///         fix five Agent IDs made ~0.26% of the pool; with mints priced no lower than 1% under the TWAP, every size
///         loses. Wealth = WBNB plus tokens at the end price; the inventory's purchase is not counted (generous).
contract FlywheelDumpMintOneBlockTest is FlywheelFixture {
    address[] internal ws;
    /// @dev mints that went through (the attack must reach them: below the floor, within the global budget)
    uint256 internal minted;

    function setUp() public {
        _deploy();
    }

    function _buyPaid(address t, address who, uint256 quoteIn) internal {
        TwapMockPair p = TwapMockPair(_sale(t).pair);
        (uint256 rT, uint256 rQ) = _res(t);
        uint256 out = _amountOut(quoteIn, rQ, rT);
        vm.prank(who);
        wbnb.transfer(address(p), quoteIn);
        bool t0 = p.token0() == t;
        p.swap(t0 ? out : 0, t0 ? 0 : out, who, "");
    }

    function _wealth(address t, uint256 px) internal view returns (int256 q, int256 v) {
        for (uint256 i; i < ws.length; i++) {
            q += int256(wbnb.balanceOf(ws[i]));
            v += int256((IERC20(t).balanceOf(ws[i]) * px) / 1e18);
        }
    }

    function _run(uint256 nWallets, uint256 mintsEach) internal returns (int256 pnl) {
        return _runC(_wide(), nWallets, mintsEach);
    }

    function _runC(IFlywheelPad.FlyConfig memory c, uint256 nWallets, uint256 mintsEach) internal returns (int256 pnl) {
        address t = _create(c, 1);
        _fillAndLaunch(t);
        vm.warp(vm.getBlockTimestamp() + c.window);
        vm.roll(vm.getBlockNumber() + 1);

        address whale = _newAgent();
        ws.push(whale);
        _poolBuy(t, whale, 1 ether); // inventory (paid by the fixture, not counted)
        for (uint256 i; i < nWallets; i++) ws.push(_newAgent());
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.roll(vm.getBlockNumber() + 1);
        handler.observe(t);

        uint256 p0 = _price(t);
        (int256 q0, int256 v0) = _wealth(t, p0);
        uint256 bag = IERC20(t).balanceOf(whale);

        // block N: dump to ~-9.6%
        (uint256 rT,) = _res(t);
        uint256 x = (rT * 512) / 10_000 * 100 / 98;
        if (x > bag) x = bag;
        _poolSell(t, whale, x);
        (uint256 spot,,, uint256 avg) = pad.prices(t);
        assertLt(spot, (avg * 9_100) / 10_000); // the dump passed 9% but stays above the 10% gate

        // block N+1, same second (BSC: several blocks per timestamp)
        vm.roll(vm.getBlockNumber() + 1);
        for (uint256 i = 1; i <= nWallets; i++) {
            vm.startPrank(ws[i]);
            for (uint256 k; k < mintsEach; k++) {
                try pad.mintPost(t, 10, 0, type(uint256).max, address(0)) {
                    minted++;
                } catch {}
            }
            vm.stopPrank();
        }
        // buy the dump back, same block
        for (uint256 i; i < 2_000 && IERC20(t).balanceOf(whale) < bag; i++) _buyPaid(t, whale, 0.005 ether);

        uint256 p1 = _price(t);
        (int256 q1, int256 v1) = _wealth(t, p1);
        pnl = (q1 + v1) - (q0 + v0);
    }

    function test_twentyWalletsWideQuota() public {
        assertLt(_run(20, 8), 0);
        assertGt(minted, 0, "the attack never got to mint");
    }

    function test_oneWallet() public {
        assertLt(_run(1, 8), 0);
        assertGt(minted, 0, "the attack never got to mint");
    }

    function test_fiveWallets() public {
        assertLt(_run(5, 8), 0, "five Agent IDs: one-block dump-mint pays");
        assertGt(minted, 0, "the attack never got to mint");
    }

    function test_jPreset20Wallets() public {
        assertLt(_runC(_agentMint(), 20, 1), 0);
        assertGt(minted, 0, "the attack never got to mint");
    }

    function test_jPreset40Wallets() public {
        assertLt(_runC(_agentMint(), 40, 1), 0);
        assertGt(minted, 0, "the attack never got to mint");
    }

    function test_tenWallets() public {
        assertLt(_run(10, 8), 0);
        assertGt(minted, 0, "the attack never got to mint");
    }
}

/// @notice Re-review R5 M-1, kept as a regression: an outside buyer lifts the price in block A; the attacker dumps it
///         back as the first trade of A+1 (so the buy's price never becomes a recent high, which needs two block
///         starts), mints with many Agent IDs in A+2 and buys its bag back. Before pricing mints at 99% of the previous
///         block's start too, 60 IDs made ~6.7% of the pool (held value). Both the conservative P&L (tokens at the
///         lower of start and end price, minted tokens less exit costs) and the P&L after selling everything must lose.
contract FlywheelBackrunDumpTest is FlywheelFixture {
    address[] internal ws;
    uint256 internal minted;

    function setUp() public {
        _deploy();
    }

    function _buyPaid(address t, address who, uint256 quoteIn) internal {
        TwapMockPair p = TwapMockPair(_sale(t).pair);
        (uint256 rT, uint256 rQ) = _res(t);
        uint256 out = _amountOut(quoteIn, rQ, rT);
        vm.prank(who);
        wbnb.transfer(address(p), quoteIn);
        bool t0 = p.token0() == t;
        p.swap(t0 ? out : 0, t0 ? 0 : out, who, "");
    }

    function _quote() internal view returns (int256 q) {
        for (uint256 i; i < ws.length; i++) q += int256(wbnb.balanceOf(ws[i]));
    }

    function _run(uint256 nWallets, uint256 buyBpsOfPool) internal returns (int256 cons, int256 liq) {
        address t = _create(_wide(), 1);
        _fillAndLaunch(t);
        vm.warp(vm.getBlockTimestamp() + 600);
        vm.roll(vm.getBlockNumber() + 1);
        address whale = _newAgent();
        ws.push(whale);
        _poolBuy(t, whale, 2 ether); // inventory (paid by the fixture, not counted)
        for (uint256 i; i < nWallets; i++) ws.push(_newAgent());
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.roll(vm.getBlockNumber() + 1);
        handler.observe(t);

        // block A: an outside buy of `buyBpsOfPool` of the pool's quote
        uint256 before = _price(t);
        (, uint256 rQ) = _res(t);
        _poolBuy(t, _plain(), (rQ * buyBpsOfPool) / 10_000);
        uint256 p0 = _price(t);
        int256 q0 = _quote();
        uint256 bag = IERC20(t).balanceOf(whale);
        // block A+1: the attacker's dump is its first trade, back to the pre-buy price
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 1);
        for (uint256 i; i < 400 && _price(t) > before; i++) {
            (uint256 rT,) = _res(t);
            uint256 x = rT / 400;
            if (x > IERC20(t).balanceOf(whale)) x = IERC20(t).balanceOf(whale);
            if (x == 0) break;
            _poolSell(t, whale, x);
        }
        // block A+2: many Agent IDs mint
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 1);
        for (uint256 i = 1; i <= nWallets; i++) {
            vm.prank(ws[i]);
            try pad.mintPost(t, 10, 0, type(uint256).max, address(0)) {
                minted++;
            } catch {}
        }
        for (uint256 i; i < 4_000 && IERC20(t).balanceOf(whale) < bag; i++) _buyPaid(t, whale, 0.02 ether);
        uint256 p1 = _price(t);
        uint256 pl = p1 < p0 ? p1 : p0;
        int256 mintedValue;
        for (uint256 i = 1; i < ws.length; i++) mintedValue += int256((IERC20(t).balanceOf(ws[i]) * pl) / 1e18);
        int256 overshoot = int256(((IERC20(t).balanceOf(whale) - bag) * pl) / 1e18);
        cons = (_quote() - q0) + overshoot + mintedValue - (mintedValue * 225) / 10_000;
        for (uint256 i = 1; i < ws.length; i++) {
            uint256 b = IERC20(t).balanceOf(ws[i]);
            if (b != 0) _poolSell(t, ws[i], b);
        }
        liq = (_quote() - q0) + overshoot;
    }

    /// @dev A big buy (+21%): the previous block's start lifts the floor more than 10% above the pool, so the mints are
    ///      refused (PriceAbovePool) and the attacker is left with its round trip.
    function test_bigBuy_sixtyWallets_mintsRefused() public {
        (int256 cons, int256 liq) = _run(60, 1_000);
        assertEq(minted, 0);
        assertLt(cons, 0);
        assertLt(liq, 0);
    }

    /// @dev A smaller buy (+8%, under the 10% cap): the mints go through at 99% of the previous block's start, and lose.
    function test_smallBuy_tenWallets() public {
        (int256 cons, int256 liq) = _run(10, 400);
        assertGt(minted, 0, "the attack never got to mint");
        assertLt(cons, 0, "backrun dump-then-mint paid (held)");
        assertLt(liq, 0, "backrun dump-then-mint paid (sold)");
    }

    function test_smallBuy_sixtyWallets() public {
        (int256 cons, int256 liq) = _run(60, 400);
        assertGt(minted, 0, "the attack never got to mint");
        assertLt(cons, 0, "backrun dump-then-mint paid (held)");
        assertLt(liq, 0, "backrun dump-then-mint paid (sold)");
    }
}

