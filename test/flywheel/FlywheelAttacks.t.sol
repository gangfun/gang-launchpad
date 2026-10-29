// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFlywheelPad} from "../../src/flywheel/interfaces/IFlywheelPad.sol";
import {FlywheelFixture} from "./FlywheelFixture.sol";

/// @notice The economic attacks of the spec (§9) on the real contracts: mint-then-sell (A), dump-then-mint (B) and
///         sandwiching an honest mint (E), plus the pad's quote never drifting from what it owes.
contract FlywheelAttacksTest is FlywheelFixture {
    uint256 constant PRICE = 20 ether / 10_000;

    function setUp() public {
        _deploy();
    }

    function _launchedWith(IFlywheelPad.FlyConfig memory c) internal returns (address t) {
        t = _create(c, 1);
        _fillAndLaunch(t);
        vm.warp(vm.getBlockTimestamp() + c.window);
        vm.roll(vm.getBlockNumber() + 1);
    }

    /// @dev The pad holds exactly: escrow of sales not launched (sold × price), exit fees owed, dev cuts owed.
    function _assertSolvent(address t) internal view {
        IFlywheelPad.Sale memory s = _sale(t);
        uint256 escrow = s.launched ? 0 : uint256(s.sold) * s.basePrice;
        assertEq(wbnb.balanceOf(address(pad)), escrow + pad.owedFee(address(wbnb)) + pad.owedDev(t), "pad quote");
    }

    // ------------------------------------------------------------ A: mint, then sell right away
    function testFuzz_mintThenSellNeverPays(uint8 shares, uint16 buyBps, uint16 sellTax, uint16 devCut, uint8 pre)
        public
    {
        IFlywheelPad.FlyConfig memory c = _wide();
        c.buyBps = uint16(bound(buyBps, 0, 5_000));
        c.sellTaxBps = uint16(bound(sellTax, 100, 200));
        c.devCutBps = uint16(bound(devCut, 0, 1_500));
        address t = _launchedWith(c);
        // some earlier minting in the same block (the push budget partly used)
        for (uint256 i; i < bound(pre, 0, 5); i++) {
            address w = _newAgent();
            vm.prank(w);
            pad.mintPost(t, 10, 0, address(0));
        }
        address a = _newAgent();
        uint256 n = bound(shares, 1, 10);
        uint256 q0 = wbnb.balanceOf(a);
        vm.prank(a);
        (uint256 out,) = pad.mintPost(t, n, 0, address(0));
        _poolSell(t, a, out);
        assertLt(wbnb.balanceOf(a), q0, "mint-then-sell paid");
        _assertSolvent(t);
    }

    /// @dev A wallet with a bigger quota (invites) minting in many mints over many blocks, then selling all.
    function test_manyMintsThenSellNeverPays() public {
        IFlywheelPad.FlyConfig memory c = _wide();
        c.buyBps = 5_000;
        c.sellTaxBps = 100;
        c.devCutBps = 0;
        address t = _launchedWith(c);
        address a = _newAgent();
        uint256 q0 = wbnb.balanceOf(a);
        uint256 got;
        vm.startPrank(a);
        for (uint256 i; i < 9; i++) {
            (uint256 out,) = pad.mintPost(t, 10, 0, address(0));
            got += out;
            vm.roll(vm.getBlockNumber() + 1);
            vm.warp(vm.getBlockTimestamp() + 1);
        }
        vm.stopPrank();
        _poolSell(t, a, got);
        assertLt(wbnb.balanceOf(a), q0);
    }

    // ------------------------------------------------------------ B: dump, then mint cheap
    function test_dumpThenMintNextBlockIsRefused() public {
        address t = _launchedWith(_wide());
        address whale = _newAgent();
        _poolBuy(t, whale, 6 ether);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.roll(vm.getBlockNumber() + 1);
        _poolSell(t, whale, IERC20(t).balanceOf(whale)); // −25% or so
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 3);
        vm.prank(whale);
        vm.expectRevert(IFlywheelPad.PriceBelowAverage.selector);
        pad.mintPost(t, 10, 0, address(0));
    }

    /// @dev The patient version: dump, wait until the TWAP has caught up (no dip buyer at all for half an hour),
    ///      mint the whole quota at the low price, buy the dumped tokens back. One Agent ID loses money.
    function test_dumpWaitMintBuyBackLosesForOneWallet() public {
        IFlywheelPad.FlyConfig memory c = _wide();
        c.buyBps = 0;
        c.devCutBps = 0;
        c.sellTaxBps = 200;
        address t = _launchedWith(c);
        address w = _newAgent();
        _poolBuy(t, w, 3 ether);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.roll(vm.getBlockNumber() + 1);
        handler.observe(t);
        uint256 q0 = wbnb.balanceOf(w);
        uint256 bag = IERC20(t).balanceOf(w);
        _poolSell(t, w, bag);
        // nobody trades for 31 minutes; observations keep coming from pokes
        for (uint256 i; i < 7; i++) {
            vm.warp(vm.getBlockTimestamp() + 5 minutes);
            vm.roll(vm.getBlockNumber() + 1);
            handler.observe(t);
        }
        vm.warp(vm.getBlockTimestamp() + 1 minutes);
        vm.roll(vm.getBlockNumber() + 1);
        vm.startPrank(w);
        for (uint256 i; i < 10; i++) pad.mintPost(t, 10, 0, address(0)); // the whole quota, 10 per mint
        vm.stopPrank();
        // buy back to the starting bag
        uint256 have = IERC20(t).balanceOf(w);
        uint256 spentBack;
        for (uint256 i; i < 1_000 && have < bag; i++) {
            spentBack += 0.01 ether;
            _poolBuy(t, w, 0.01 ether);
            have = IERC20(t).balanceOf(w);
        }
        assertGe(have, bag, "bag not restored");
        // quote won, plus the overshoot of the last buy-back step at the end price
        int256 pnl = int256(wbnb.balanceOf(w)) - int256(q0) - int256(spentBack) + int256(((have - bag) * _price(t)) / 1e18);
        assertLt(pnl, 0, "dump-wait-mint paid");
        _assertSolvent(t);
    }

    // ------------------------------------------------------------ E: sandwich an honest mint
    function test_sandwichingAnHonestMintLoses() public {
        IFlywheelPad.FlyConfig memory c = _wide();
        c.buyBps = 5_000;
        address t = _launchedWith(c);
        address mev = _newAgent();
        address victim = _newAgent();
        // the victim quotes now and allows 2% slippage
        uint256 expected = ((10 * PRICE * 110) / 100) * 1e18 / _price(t);
        uint256 minOut = (expected * 98) / 100;
        uint256 spent = 0.3 ether; // the fixture's pool buy is paid into the pair directly
        _poolBuy(t, mev, spent); // front-run: ~+3%
        vm.prank(victim);
        try pad.mintPost(t, 10, minOut, address(0)) {} catch {}
        uint256 got = _poolSell(t, mev, IERC20(t).balanceOf(mev));
        assertLt(got, spent, "sandwich paid");
    }

    // ------------------------------------------------------------ escrow accounting through a whole life
    function test_padQuoteMatchesWhatItOwesThroughoutASale() public {
        address t = _create(_wide(), 1);
        _assertSolvent(t);
        address a = _newAgent();
        vm.prank(a);
        pad.mint(t, 10, 1, address(0));
        _assertSolvent(t);
        vm.prank(a);
        pad.withdraw(t, 4, 0);
        _assertSolvent(t);
        _fillAndLaunch(t);
        _assertSolvent(t);
        vm.warp(vm.getBlockTimestamp() + 600);
        vm.prank(a);
        pad.mintPost(t, 10, 0, address(0));
        _assertSolvent(t);
    }
}
