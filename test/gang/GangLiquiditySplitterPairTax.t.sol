// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {GangFixture} from "../utils/GangFixture.sol";
import {LpMockPair, LpMockPairFactory} from "../mocks/LpMockPair.sol";
import {GangLiquiditySplitter} from "../../src/gang/GangLiquiditySplitter.sol";
import {GangLiquiditySplitterFactory} from "../../src/gang/GangLiquiditySplitterFactory.sol";
import {GangHandlerAdmin} from "../../src/gang/GangHandlerAdmin.sol";

/// @dev An 18-decimal quote that charges 5% on transfers: only INTO addresses marked as AMM pairs (a common BSC
///      pattern), or on every transfer once `taxAll` is on. Mints and burns are never taxed.
contract LpTaxQuote is ERC20("LpTaxQuote", "LTAXQ") {
    mapping(address => bool) public isPair;
    bool public taxAll;

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setPair(address p, bool v) external {
        isPair[p] = v;
    }

    function setTaxAll(bool v) external {
        taxAll = v;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && (taxAll || isPair[to])) {
            uint256 fee = value / 20;
            super._update(from, address(0xfee), fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}

/// @notice As GangBuybackSplitterPairTax (re-review L-1, 2026-10-29): the buy half is priced on what the pair received
///         and `minTokensOut` scales down to it (LP audit 2026-10-30 L-1 kept that branch), so a quote that taxes
///         transfers into pairs still adds liquidity through the keeper's previewWork / work until it is not worth a
///         call, and a quote that taxes every transfer leaves the split's books whole.
contract GangLiquiditySplitterPairTaxTest is GangFixture {
    address keeper = makeAddr("keeper");
    GangHandlerAdmin admin;
    GangLiquiditySplitterFactory factory;
    LpTaxQuote tq;

    function _newPairFactory() internal override returns (address) {
        return address(new LpMockPairFactory());
    }

    function _onNewAgent(address who) internal override {
        if (address(tq) == address(0)) return;
        tq.mint(who, 1_000 ether);
        vm.prank(who);
        tq.approve(address(pad), type(uint256).max);
    }

    function setUp() public {
        _deployGang(keeper);
        admin = new GangHandlerAdmin(owner, address(handler));
        vm.startPrank(owner);
        handler.transferOwnership(address(admin));
        admin.exec(abi.encodeCall(Ownable2Step.acceptOwnership, ()));
        vm.stopPrank();
        factory = new GangLiquiditySplitterFactory(address(pad), address(admin));
        vm.prank(owner);
        admin.setFactory(address(factory), true);
        tq = new LpTaxQuote();
        vm.prank(owner);
        quoteRegistry.setQuote(address(tq), true, 15 ether);
    }

    function _next(uint256 dt) internal {
        vm.warp(vm.getBlockTimestamp() + dt);
        vm.roll(block.number + 1);
    }

    /// @dev A graduated token over `tq` paying a splitter at `bps`, the pair marked as taxed.
    function _setup(uint16 bps) internal returns (GangLiquiditySplitter s, address t, address dev, address pair) {
        dev = _newAgent();
        vm.prank(dev);
        s = GangLiquiditySplitter(factory.create(bps, bytes32(uint256(1)), address(0)));
        t = _createV3(dev, address(tq), _tax(100, 100, 0, address(s)));
        s.bind(t);
        vm.prank(dev);
        pad.buy(t, 1 ether, 0);
        _graduate(t);
        pair = _curvePair(t);
        tq.setPair(pair, true);
    }

    /// @dev The keeper's loop: work(previewWork's minOut) whenever due, a chunk per CHUNK_GAP, until it is not due
    ///      for a whole TWAP window (what is left is under WORK_MIN_BPS of the reserve).
    function _workToTheEnd(GangLiquiditySplitter s, address pair) internal returns (uint256 chunks) {
        uint256 idle;
        for (uint256 i = 0; i < 2_000 && idle < 6; i++) {
            (bool due, uint256 minOut) = s.previewWork();
            if (due) {
                idle = 0;
                uint256 lp0 = LpMockPair(pair).totalSupply();
                s.work(minOut);
                if (LpMockPair(pair).totalSupply() > lp0) chunks++;
            } else {
                idle++;
            }
            _next(4 minutes);
        }
    }

    function _floor(GangLiquiditySplitter s, address t) internal view returns (uint256) {
        (, uint256 rQ) = _reserves(t, s.pair());
        return (rQ * s.WORK_MIN_BPS()) / 10_000;
    }

    function test_pairTaxQuote_keeperAddsUntilDust() public {
        (GangLiquiditySplitter s, address t,, address pair) = _setup(10_000);
        assertEq(s.moduleType(), bytes32("lp-burn-v1"));
        tq.mint(address(s), 2 ether);
        s.split();
        assertEq(s.lpLeft(), 2 ether);

        uint256 lp0 = LpMockPair(pair).balanceOf(s.DEAD());
        uint256 chunks = _workToTheEnd(s, pair);
        assertGt(chunks, 1);
        s.split();
        assertLt(s.lpLeft(), _floor(s, t), "added until under the keeper's floor");
        assertEq(IERC20(t).balanceOf(address(s)), 0);
        assertGt(LpMockPair(pair).balanceOf(s.DEAD()), lp0);
        assertEq(LpMockPair(pair).balanceOf(address(s)), 0);
    }

    /// @dev `minTokensOut` scales to what the pair got: the previewed buy passes, a bar the 95% can't meet fails.
    function test_pairTaxQuote_slippageScaled() public {
        (GangLiquiditySplitter s,,,) = _setup(10_000);
        tq.mint(address(s), 2 ether);
        s.addChunk(0);
        _next(10 minutes);
        (bool ok,, uint256 pOut) = s.previewAdd();
        assertTrue(ok);
        uint256 tooMuch = (pOut * 100) / 95 + 1e9;
        vm.expectRevert(GangLiquiditySplitter.Slippage.selector);
        s.addChunk(tooMuch);
        (uint256 q, uint256 tokensIn, uint256 liq) = s.addChunk(pOut);
        assertGt(q, 0);
        assertGt(tokensIn, 0);
        assertGt(liq, 0);
    }

    /// @dev A quote that taxes every transfer: the dev gets 95% of its part, the chunks still run, nothing owed and
    ///      the books match the balance.
    function test_allTransfersTaxed_splitStaysWhole() public {
        (GangLiquiditySplitter s, address t, address dev, address pair) = _setup(4_000);
        tq.setTaxAll(true);
        uint256 dev0 = tq.balanceOf(dev);
        tq.mint(address(s), 10 ether);
        s.split();
        assertEq(s.lpLeft(), 4 ether);
        assertEq(s.devOwed(), 0);
        assertEq(tq.balanceOf(dev) - dev0, (6 ether * 95) / 100, "the quote's own tax on the dev's part");
        assertEq(tq.balanceOf(address(s)), 4 ether, "held = balance");

        uint256 chunks = _workToTheEnd(s, pair);
        assertGt(chunks, 1);
        s.split();
        assertLt(s.lpLeft(), _floor(s, t));
        assertEq(s.devOwed(), 0);
        assertEq(tq.balanceOf(address(s)), s.lpLeft() + s.unsplit());
    }
}
