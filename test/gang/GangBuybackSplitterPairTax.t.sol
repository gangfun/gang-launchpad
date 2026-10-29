// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {GangFixture} from "../utils/GangFixture.sol";
import {TwapMockPairFactory} from "../mocks/TwapMockPair.sol";
import {GangBuybackSplitter} from "../../src/gang/GangBuybackSplitter.sol";
import {GangBuybackSplitterFactory} from "../../src/gang/GangBuybackSplitterFactory.sol";
import {GangHandlerAdmin} from "../../src/gang/GangHandlerAdmin.sol";

/// @dev An 18-decimal quote that charges 5% on transfers: only INTO addresses marked as AMM pairs (a common BSC
///      pattern), or on every transfer once `taxAll` is on. Mints and burns are never taxed.
contract TaxQuote is ERC20("TaxQuote", "TAXQ") {
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

/// @notice Re-review L-1 (2026-10-29), as GangBond: a chunk is priced on what the pair received, so a quote that taxes
///         transfers into pairs still buys back to the end through the keeper's previewWork / work, and a quote that
///         taxes every transfer leaves the split's books whole.
contract GangBuybackSplitterPairTaxTest is GangFixture {
    address keeper = makeAddr("keeper");
    GangHandlerAdmin admin;
    GangBuybackSplitterFactory factory;
    TaxQuote tq;

    function _newPairFactory() internal override returns (address) {
        return address(new TwapMockPairFactory());
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
        factory = new GangBuybackSplitterFactory(address(pad), address(admin));
        vm.prank(owner);
        admin.setFactory(address(factory), true);
        tq = new TaxQuote();
        vm.prank(owner);
        quoteRegistry.setQuote(address(tq), true, 15 ether);
    }

    function _next(uint256 dt) internal {
        vm.warp(vm.getBlockTimestamp() + dt);
        vm.roll(block.number + 1);
    }

    /// @dev A graduated token over `tq` paying a splitter at `bps`, the pair marked as taxed.
    function _setup(uint16 bps) internal returns (GangBuybackSplitter s, address t, address dev, address pair) {
        dev = _newAgent();
        vm.prank(dev);
        s = GangBuybackSplitter(factory.create(bps, bytes32(uint256(1)), address(0)));
        t = _createV3(dev, address(tq), _tax(100, 100, 0, address(s)));
        s.bind(t);
        vm.prank(dev);
        pad.buy(t, 1 ether, 0);
        _graduate(t);
        pair = _curvePair(t);
        tq.setPair(pair, true);
    }

    /// @dev The keeper's loop: work(previewWork's minOut) whenever due, a chunk per CHUNK_GAP, until nothing is left.
    function _workToTheEnd(GangBuybackSplitter s) internal returns (uint256 chunks) {
        for (uint256 i = 0; i < 2_000 && s.buybackLeft() != 0; i++) {
            (bool due, uint256 minOut) = s.previewWork();
            if (due) {
                uint256 left = s.buybackLeft();
                s.work(minOut);
                if (s.buybackLeft() < left) chunks++;
            }
            _next(4 minutes);
        }
    }

    function test_pairTaxQuote_keeperBuysBackToTheEnd() public {
        (GangBuybackSplitter s, address t,,) = _setup(10_000);
        assertEq(s.moduleType(), bytes32("buyback-burn-v4"));
        tq.mint(address(s), 2 ether);
        s.split();
        assertEq(s.buybackLeft(), 2 ether);

        uint256 dead0 = IERC20(t).balanceOf(s.DEAD());
        uint256 chunks = _workToTheEnd(s);
        assertGt(chunks, 1);
        assertEq(s.buybackLeft(), 0, "bought back to the end");
        assertEq(tq.balanceOf(address(s)), 0, "no quote left behind");
        assertEq(IERC20(t).balanceOf(address(s)), 0);
        assertGt(IERC20(t).balanceOf(s.DEAD()), dead0);
    }

    /// @dev `minTokensOut` scales to what the pair got: the previewed burn passes, one token more still fails.
    function test_pairTaxQuote_slippageScaled() public {
        (GangBuybackSplitter s,,,) = _setup(10_000);
        tq.mint(address(s), 2 ether);
        s.burnChunk(0);
        _next(10 minutes);
        (bool ok,, uint256 pOut) = s.previewBurn();
        assertTrue(ok);
        // the preview prices the whole chunk; the pair gets 95% of it, so the burn is under the preview
        uint256 tooMuch = (pOut * 100) / 95 + 1e9;
        vm.expectRevert(GangBuybackSplitter.Slippage.selector);
        s.burnChunk(tooMuch);
        (, uint256 burned) = s.burnChunk(pOut);
        assertGt(burned, 0);
        assertLt(burned, pOut);
    }

    /// @dev A quote that taxes every transfer: the dev gets 95% of its part, the buy-back still runs to the end, and
    ///      nothing is left owed or held.
    function test_allTransfersTaxed_splitStaysWhole() public {
        (GangBuybackSplitter s,, address dev,) = _setup(4_000);
        tq.setTaxAll(true);
        uint256 dev0 = tq.balanceOf(dev);
        tq.mint(address(s), 10 ether);
        s.split();
        assertEq(s.buybackLeft(), 4 ether);
        assertEq(s.devOwed(), 0);
        assertEq(tq.balanceOf(dev) - dev0, (6 ether * 95) / 100, "the quote's own tax on the dev's part");
        assertEq(tq.balanceOf(address(s)), 4 ether, "held = balance");

        uint256 chunks = _workToTheEnd(s);
        assertGt(chunks, 1);
        assertEq(s.buybackLeft(), 0);
        assertEq(s.devOwed(), 0);
        assertEq(tq.balanceOf(address(s)), 0);
    }
}
