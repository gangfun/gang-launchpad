// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFlywheelPad} from "../../src/flywheel/interfaces/IFlywheelPad.sol";
import {FlywheelFixture} from "./FlywheelFixture.sol";
import {SharedMigrator} from "../../src/common/SharedMigrator.sol";
import {MockSPCXB} from "../../src/launchpad-v2/mocks/MockSPCXB.sol";

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

/// @notice Fixes from the internal audit (A-L1, C-L1).
contract FlywheelAuditFixesTest is FlywheelFixture {
    function setUp() public {
        _deploy();
    }

    /// @dev A-L1: a quote so cheap that the raise could overflow the pair's uint112 reserves is refused at create.
    function test_raiseTooLargeInTheQuoteIsRefused() public {
        MockSPCXB cheap = new MockSPCXB();
        vm.prank(owner);
        quoteRegistry.setQuote(address(cheap), true, 1e40); // "15 BNB" = 1e40 units
        cheap.mintUnlimited(dev, 1e50);
        vm.prank(dev);
        cheap.approve(address(pad), type(uint256).max);
        vm.prank(dev);
        vm.expectRevert(abi.encodeWithSelector(IFlywheelPad.BadConfig.selector, "raise too large in this quote"));
        pad.create(["a", "b", "c", "d"], address(cheap), address(0), _wide(), 1);
    }

    /// @dev A-L1: a filled sale that can't launch does not trap the escrow: after the grace period minters sell back
    ///      (at the full price: the sale is stale by then).
    function test_filledSaleThatCannotLaunchReopensSellBacks() public {
        address t = _create(_wide(), 1);
        _fill(t);
        vm.mockCallRevert(address(migrator), abi.encodeWithSelector(SharedMigrator.migrate.selector), "stuck");
        vm.warp(vm.getBlockTimestamp() + 60);
        vm.expectRevert();
        pad.launch(t);
        vm.prank(dev);
        vm.expectRevert(IFlywheelPad.NotMinting.selector);
        pad.withdraw(t, 1, 0);
        vm.warp(vm.getBlockTimestamp() + 7 days);
        (uint256 quoted,) = pad.previewWithdraw(t, dev, 1);
        vm.prank(dev);
        uint256 payout = pad.withdraw(t, 1, 0);
        assertEq(payout, quoted);
        assertEq(payout, _sale(t).basePrice); // no exit fee
    }

    /// @dev C-L1: the keeper's chunk, first in a block, does not move the block-start price the mints use.
    function test_keeperChunkFirstInBlockKeepsTheBlockStartPrice() public {
        address t = _create(_wide(), 1);
        _fillAndLaunch(t);
        vm.warp(vm.getBlockTimestamp() + 600);
        address b = _newAgent();
        _poolBuy(t, b, 2 ether);
        vm.roll(vm.getBlockNumber() + 1);
        (uint256 before,,,) = pad.prices(t);
        uint256 chunk = handler.maxChunk(t);
        assertGt(chunk, 0);
        vm.prank(keeper);
        handler.process(t, chunk, 1);
        (uint256 spotNow, uint256 blockStart,,) = pad.prices(t);
        assertLt(spotNow, before);
        assertEq(blockStart, before);
    }

    /// @dev R2-1 L-2: an ungated sale takes no dev cut (quotas can't bound a creator using fresh wallets).
    function test_ungatedSaleTakesNoDevCut() public {
        vm.prank(owner);
        pad.setAgentGate(false, address(0));
        IFlywheelPad.FlyConfig memory c = _wide();
        vm.prank(dev);
        vm.expectRevert(abi.encodeWithSelector(IFlywheelPad.BadConfig.selector, "devCutBps must be 0 when ungated"));
        pad.create(["a", "b", "c", "d"], address(0), address(0), c, 1);
        c.devCutBps = 0;
        vm.prank(dev);
        pad.create(["a", "b", "c", "d"], address(0), address(0), c, 1);
    }

    /// @dev R2-1 L-1: after the grace period, a filled sale sold back below the early-open floor only refunds.
    function test_afterGraceASaleBelowTheFloorCannotLaunch() public {
        address t = _create(_wide(), 1);
        _fill(t);
        vm.mockCallRevert(address(migrator), abi.encodeWithSelector(SharedMigrator.migrate.selector), "stuck");
        vm.warp(vm.getBlockTimestamp() + 60 + 7 days);
        // minters leave until 2,999 shares remain
        uint256 n = _sale(t).sold - 2_999;
        for (uint256 i; n > 0 && i < 200; i++) {
            address w = address(uint160(uint256(keccak256(abi.encode("fly-agent", i + 1))))); // fixture's agents
            (uint32 held,,,,,,) = pad.accounts(t, w);
            if (held == 0) continue;
            uint256 k = held < n ? held : n;
            vm.prank(w);
            pad.withdraw(t, k, 0);
            n -= k;
        }
        assertEq(_sale(t).sold, 2_999);
        vm.clearMockedCalls();
        vm.expectRevert(IFlywheelPad.TooFewShares.selector);
        pad.launch(t);
        // back above the floor (a sell-back can't be undone, but nothing stops refunds either way)
        assertEq(_sale(t).launched, false);
    }

    function test_afterGraceASaleAboveTheFloorStillLaunches() public {
        address t = _create(_wide(), 1);
        _fill(t);
        vm.mockCallRevert(address(migrator), abi.encodeWithSelector(SharedMigrator.migrate.selector), "stuck");
        vm.warp(vm.getBlockTimestamp() + 60 + 7 days);
        vm.prank(dev);
        pad.withdraw(t, 1, 0);
        vm.clearMockedCalls();
        pad.launch(t);
        assertTrue(_sale(t).launched);
        _assertPadEmpty(t);
    }

    function _assertPadEmpty(address) internal view {
        assertEq(wbnb.balanceOf(address(pad)), pad.owedFee(address(wbnb)));
    }

    /// @dev R2-1 Info: previews say no for a wallet without an Agent ID.
    function test_previewsRespectTheGate() public {
        address t = _create(_wide(), 1);
        address plain = _plain();
        (uint256 acc,,) = pad.previewMint(t, plain, 10);
        assertEq(acc, 0);
        _fillAndLaunch(t);
        vm.warp(vm.getBlockTimestamp() + 600);
        (,,,, bool ok) = pad.previewMintPost(t, plain, 10);
        assertFalse(ok);
    }
}
