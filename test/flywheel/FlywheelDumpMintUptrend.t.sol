// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFlywheelPad} from "../../src/flywheel/interfaces/IFlywheelPad.sol";
import {FlywheelFixture} from "./FlywheelFixture.sol";
import {TwapMockPair} from "../mocks/TwapMockPair.sol";

/// @notice Re-review of R2-2 M-1, kept as a measurement under V2: with spot above the 30-minute TWAP (an uptrend),
///         "dump to ~0.98 TWAP in block N, mint in N+1, buy back". V1 priced those mints at the pre-dump level (the
///         recent high); V2 prices them at the pool. Regressions: these dump-then-mint variants lose. Conservative P&L:
///         tokens at the lower of the start and end price, minted tokens less their exit costs; the inventory's
///         purchase is not counted (generous to the attacker).
contract FlywheelDumpMintUptrendTest is FlywheelFixture {
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
        (,,, uint256 avg0) = pad.prices(t);
        (int256 q0, int256 v0) = _wealth(t, p0);
        uint256 bag = IERC20(t).balanceOf(whale);
        uint256 tok0 = _tokens(t);

        // block N: sell in chunks until spot <= 0.98 TWAP (never below the 10% gate)
        uint256 target = (avg0 * 9_800) / 10_000;
        for (uint256 i; i < 400; i++) {
            (uint256 s,,,) = pad.prices(t);
            if (s <= target) break;
            (uint256 rT,) = _res(t);
            uint256 x = rT / 400;
            if (x > IERC20(t).balanceOf(whale)) x = IERC20(t).balanceOf(whale);
            if (x == 0) break;
            _poolSell(t, whale, x);
        }
        (uint256 spot1,,, uint256 avg1) = pad.prices(t);
        require(spot1 * 10_000 >= avg1 * 9_000, "gate");

        // block N+1
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

    function test_flat_fiveWallets() public {
        (, int256 b) = _run(_wide(), 0, 0, 5, 8);
        assertLt(b, 0, "dump-then-mint paid");
    }

    function test_uptrend_oneWallet() public {
        (, int256 b) = _run(_wide(), 20, 100, 1, 8);
        assertLt(b, 0, "dump-then-mint paid");
    }

    function test_uptrend_fiveWallets() public {
        (, int256 b) = _run(_wide(), 20, 100, 5, 8);
        assertLt(b, 0, "dump-then-mint paid");
    }

    function test_uptrend_jPreset20() public {
        (, int256 b) = _run(_agentMint(), 20, 100, 20, 1);
        assertLt(b, 0, "dump-then-mint paid");
    }

    function test_hotUptrend_fiveWallets() public {
        (, int256 b) = _run(_wide(), 20, 200, 5, 8);
        assertLt(b, 0, "dump-then-mint paid");
    }

    function test_hotUptrend_jPreset20() public {
        (, int256 b) = _run(_agentMint(), 20, 200, 20, 1);
        assertLt(b, 0, "dump-then-mint paid");
    }

    /// @dev 20 IDs at the quota cap (10 shares each): loses.
    function test_uptrend_twentyWallets() public {
        (, int256 b) = _run(_wide(), 20, 100, 20, 8);
        assertLt(b, 0, "dump-then-mint paid");
    }

    function test_flat_twentyWallets() public {
        (, int256 b) = _run(_wide(), 0, 0, 20, 8);
        assertLt(b, 0, "dump-then-mint paid");
    }

    function test_mildUptrend_fiveWallets() public {
        (, int256 b) = _run(_wide(), 20, 40, 5, 8);
        assertLt(b, 0, "dump-then-mint paid");
    }
}
