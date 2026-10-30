// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFlywheelPad} from "../../src/flywheel/interfaces/IFlywheelPad.sol";
import {FlywheelFixture} from "./FlywheelFixture.sol";
import {TwapMockPair} from "../mocks/TwapMockPair.sol";

/// @notice Review R2-2 M-1, kept as a regression under V2: dump ~9.6% in block N, mint with a few Agent IDs in block
///         N+1, buy the dump back in N+1. Regressions: these dump-then-mint variants lose. Wealth = WBNB plus tokens
///         at the end price, no exit cost; the inventory's purchase is not counted (generous to the attacker).
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
        IFlywheelPad.FlyConfig memory c = _wide();
        address t = _create(c, 1);
        _fillAndLaunch(t);
        vm.warp(vm.getBlockTimestamp() + c.window);
        vm.roll(vm.getBlockNumber() + 1);

        address whale = _newAgent();
        ws.push(whale);
        _poolBuy(t, whale, 1 ether); // inventory (paid by the fixture, not counted)
        for (uint256 i; i < nWallets; i++) {
            ws.push(_newAgent());
        }
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
        for (uint256 i; i < 2_000 && IERC20(t).balanceOf(whale) < bag; i++) {
            _buyPaid(t, whale, 0.005 ether);
        }

        uint256 p1 = _price(t);
        (int256 q1, int256 v1) = _wealth(t, p1);
        pnl = (q1 + v1) - (q0 + v0);
        emit log_named_int("pnl (wei)", pnl);
        (, uint256 rQ) = _res(t);
        emit log_named_uint("pool quote (wei)", rQ);
    }

    function test_oneWallet() public {
        assertLt(_run(1, 8), 0);
        assertGt(minted, 0, "the attack never got to mint");
    }

    function test_fiveWallets() public {
        assertLt(_run(5, 8), 0, "five Agent IDs: one-block dump-mint pays");
        assertGt(minted, 0, "the attack never got to mint");
    }

    /// @dev 10 IDs × 10 shares (quota 10): 100 shares lose.
    function test_tenWallets() public {
        assertLt(_run(10, 8), 0, "ten Agent IDs: one-block dump-mint pays");
        assertEq(minted, 10);
    }
}

/// @notice Re-review R5 M-1, kept as a regression under V2: an outside buyer lifts the price in block A; the attacker
///         dumps it back as the first trade of A+1, mints with several Agent IDs in A+2 and buys its bag back.
///         Regressions: these dump-then-mint variants lose. Conservative P&L ("held": tokens at the lower of start and
///         end price, minted tokens less exit costs) and the P&L after selling everything ("sold").
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
        for (uint256 i; i < ws.length; i++) {
            q += int256(wbnb.balanceOf(ws[i]));
        }
    }

    function _run(uint256 nWallets, uint256 buyBpsOfPool) internal returns (int256 cons, int256 liq) {
        address t = _create(_wide(), 1);
        _fillAndLaunch(t);
        vm.warp(vm.getBlockTimestamp() + 600);
        vm.roll(vm.getBlockNumber() + 1);
        address whale = _newAgent();
        ws.push(whale);
        _poolBuy(t, whale, 2 ether); // inventory (paid by the fixture, not counted)
        for (uint256 i; i < nWallets; i++) {
            ws.push(_newAgent());
        }
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
        for (uint256 i; i < 4_000 && IERC20(t).balanceOf(whale) < bag; i++) {
            _buyPaid(t, whale, 0.02 ether);
        }
        uint256 p1 = _price(t);
        uint256 pl = p1 < p0 ? p1 : p0;
        int256 mintedValue;
        for (uint256 i = 1; i < ws.length; i++) {
            mintedValue += int256((IERC20(t).balanceOf(ws[i]) * pl) / 1e18);
        }
        int256 overshoot = int256(((IERC20(t).balanceOf(whale) - bag) * pl) / 1e18);
        cons = (_quote() - q0) + overshoot + mintedValue - (mintedValue * 225) / 10_000;
        for (uint256 i = 1; i < ws.length; i++) {
            uint256 b = IERC20(t).balanceOf(ws[i]);
            if (b != 0) _poolSell(t, ws[i], b);
        }
        liq = (_quote() - q0) + overshoot;
        emit log_named_int("held (wei)", cons);
        emit log_named_int("sold (wei)", liq);
        emit log_named_uint("minted", minted);
    }

    /// @dev A smaller buy (+8%, under the 10% cap): the mints go through, and lose.
    function test_smallBuy_tenWallets() public {
        (int256 cons, int256 liq) = _run(10, 400);
        assertGt(minted, 0, "the attack never got to mint");
        assertLt(cons, 0, "backrun dump-then-mint paid (held)");
        assertLt(liq, 0, "backrun dump-then-mint paid (sold)");
    }
}

