// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFlywheelPad} from "../../src/flywheel/interfaces/IFlywheelPad.sol";
import {FlywheelFixture} from "./FlywheelFixture.sol";
import {TwapMockPair} from "../mocks/TwapMockPair.sol";

/// @notice Re-review R3 M-1, kept as a regression under V2: in an uptrend, dump 4.5% below the recent high, hold, then
///         mint and buy back. Regressions: these dump-then-mint variants lose. Conservative P&L as in
///         FlywheelDumpMintUptrend; holds of 61 s and 3 minutes, which no dip buyer interrupts here (generous).
contract FlywheelDumpHoldTest is FlywheelFixture {
    address[] internal ws;

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

    /// @dev seconds the dumped price is held before minting
    uint256 internal holdFor;
    uint256 internal mintedCount;

    /// @param rampSteps 3-minute steps, each a third-party buy of `stepBps` of the quote reserve (0 = flat market)
    function _run(
        IFlywheelPad.FlyConfig memory c,
        uint256 rampSteps,
        uint256 stepBps,
        uint256 nWallets,
        uint256 mintsEach
    ) internal returns (int256 pnl, int256 pnlConservative) {
        address t = _create(c, 1);
        _fillAndLaunch(t);
        vm.warp(vm.getBlockTimestamp() + c.window);
        vm.roll(vm.getBlockNumber() + 1);

        address whale = _newAgent();
        ws.push(whale);
        _poolBuy(t, whale, 2 ether); // inventory (not counted, as in FlywheelDumpMint)
        for (uint256 i; i < nWallets; i++) {
            ws.push(_newAgent());
        }
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.roll(vm.getBlockNumber() + 1);
        handler.observe(t);

        // organic uptrend by third parties
        address crowd = _plain();
        for (uint256 i; i < rampSteps; i++) {
            vm.warp(vm.getBlockTimestamp() + 3 minutes);
            vm.roll(vm.getBlockNumber() + 1);
            (, uint256 rQ) = _res(t);
            _poolBuy(t, crowd, (rQ * stepBps) / 10_000);
            handler.observe(t);
        }
        vm.warp(vm.getBlockTimestamp() + 3 minutes);
        vm.roll(vm.getBlockNumber() + 1);
        handler.observe(t);

        uint256 p0 = _price(t);
        (,, uint256 high0,) = pad.prices(t);
        (int256 q0, int256 v0) = _wealth(t, p0);
        uint256 bag = IERC20(t).balanceOf(whale);
        uint256 tok0 = _tokens(t);

        // block N: sell in chunks until spot is 4.5% under the recent high (just inside the 5% gap)
        uint256 target = (high0 * 9_550) / 10_000;
        for (uint256 i; i < 400; i++) {
            (uint256 s,,,) = pad.prices(t);
            if (s <= target) break;
            (uint256 rT,) = _res(t);
            uint256 x = rT / 400;
            if (x > IERC20(t).balanceOf(whale)) x = IERC20(t).balanceOf(whale);
            if (x == 0) break;
            _poolSell(t, whale, x);
        }
        // hold (nobody buys the dip), then mint
        vm.warp(vm.getBlockTimestamp() + holdFor);
        vm.roll(vm.getBlockNumber() + 1);
        uint256 minted;
        uint256 wq0 = wbnb.balanceOf(whale);
        (int256 mq0,) = _wealth(t, 0);
        mq0 -= int256(wq0);
        for (uint256 i = 1; i <= nWallets; i++) {
            vm.startPrank(ws[i]);
            for (uint256 k; k < mintsEach; k++) {
                try pad.mintPost(t, 10, 0, type(uint256).max, address(0)) {
                    minted++;
                    mintedCount++;
                } catch {
                    break;
                }
            }
            vm.stopPrank();
        }
        mq0;
        for (uint256 i; i < 4_000 && IERC20(t).balanceOf(whale) < bag; i++) {
            _buyPaid(t, whale, 0.02 ether);
        }

        uint256 p1 = _price(t);
        (int256 q1, int256 v1) = _wealth(t, p1);
        pnl = (q1 + v1) - (q0 + v0);
        // conservative: tokens valued at the lower of the two prices, minted tokens' exit costs (sell tax + DEX fee)
        uint256 pl = p1 < p0 ? p1 : p0;
        int256 mintedValue = 0;
        for (uint256 i = 1; i < ws.length; i++) {
            mintedValue += int256((IERC20(t).balanceOf(ws[i]) * pl) / 1e18);
        }
        int256 dTok = int256((_tokens(t) * pl) / 1e18) - int256((tok0 * pl) / 1e18);
        pnlConservative = (q1 - q0) + dTok - (mintedValue * int256(uint256(c.sellTaxBps) + 25)) / 10_000;
        emit log_named_int("pnl (wei)", pnl);
        emit log_named_int("pnl conservative (wei)", pnlConservative);
        emit log_named_uint("pool quote (wei)", _rq(t));
    }

    function _tokens(address t) internal view returns (uint256 n) {
        for (uint256 i; i < ws.length; i++) {
            n += IERC20(t).balanceOf(ws[i]);
        }
    }

    function _rq(address t) internal view returns (uint256 rQ) {
        (, rQ) = _res(t);
    }

    function test_hot_wide20x8_hold61s() public {
        holdFor = 61;
        (, int256 b) = _run(_wide(), 20, 200, 20, 8);
        assertLt(b, 0, "held dump-then-mint paid");
        assertGt(mintedCount, 0, "the attack never got to mint");
    }

    function test_hot_wide20x8_hold3min() public {
        holdFor = 180;
        (, int256 b) = _run(_wide(), 20, 200, 20, 8);
        assertLt(b, 0, "held dump-then-mint paid");
        assertGt(mintedCount, 0, "the attack never got to mint");
    }

    function test_up_wide20x8_hold61s() public {
        holdFor = 61;
        (, int256 b) = _run(_wide(), 20, 100, 20, 8);
        assertLt(b, 0, "held dump-then-mint paid");
        assertGt(mintedCount, 0, "the attack never got to mint");
    }
}
