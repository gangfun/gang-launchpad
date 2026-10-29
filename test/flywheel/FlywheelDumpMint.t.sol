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
                try pad.mintPost(t, 10, 0, address(0)) {
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
