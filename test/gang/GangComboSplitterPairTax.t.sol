// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {GangFixture} from "../utils/GangFixture.sol";
import {LpMockPair, LpMockPairFactory} from "../mocks/LpMockPair.sol";
import {LpTaxQuote} from "./GangLiquiditySplitterPairTax.t.sol";
import {GangComboSplitter} from "../../src/gang/GangComboSplitter.sol";
import {GangComboSplitterFactory} from "../../src/gang/GangComboSplitterFactory.sol";
import {GangHandlerAdmin} from "../../src/gang/GangHandlerAdmin.sol";

/// @notice As the buy-back and liquidity splitters' pair-tax tests: a quote that taxes transfers into pairs still runs
///         both chunk kinds through the keeper's loop (minTokensOut scales down to what the pair got), and a quote that
///         taxes every transfer keeps the books whole.
contract GangComboSplitterPairTaxTest is GangFixture {
    address keeper = makeAddr("keeper");
    GangHandlerAdmin admin;
    GangComboSplitterFactory factory;
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
        factory = new GangComboSplitterFactory(address(pad), address(admin), address(0));
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

    /// @dev 40% buy-back, 40% liquidity, the dev and a KOL split the rest; a graduated token over `tq`, pair taxed.
    function _setup() internal returns (GangComboSplitter m, address t, address dev, address kol, address pair) {
        dev = _newAgent();
        kol = makeAddr("kol");
        address[] memory p = new address[](2);
        (p[0], p[1]) = (dev, kol);
        uint16[] memory s = new uint16[](2);
        (s[0], s[1]) = (5_000, 5_000);
        vm.prank(dev);
        m = GangComboSplitter(factory.create(4_000, 4_000, p, s, bytes32(uint256(1))));
        t = _createV3(dev, address(tq), _tax(100, 100, 0, address(m)));
        m.bind(t);
        vm.prank(dev);
        pad.buy(t, 1 ether, 0);
        _graduate(t);
        pair = _curvePair(t);
        tq.setPair(pair, true);
    }

    function _workToTheEnd(GangComboSplitter m, address t) internal returns (uint256 burns, uint256 adds) {
        uint256 idle;
        for (uint256 i = 0; i < 2_000 && idle < 6; i++) {
            (bool due, uint256 minOut) = m.previewWork();
            if (due) {
                idle = 0;
                uint256 dead0 = IERC20(t).balanceOf(m.DEAD());
                uint256 lp0 = LpMockPair(_curvePair(t)).totalSupply();
                m.work(minOut);
                if (IERC20(t).balanceOf(m.DEAD()) > dead0 && LpMockPair(_curvePair(t)).totalSupply() == lp0) burns++;
                if (LpMockPair(_curvePair(t)).totalSupply() > lp0) adds++;
            } else {
                idle++;
            }
            _next(4 minutes);
        }
    }

    function test_pairTaxQuote_keeperRunsBothKinds() public {
        (GangComboSplitter m, address t,,, address pair) = _setup();
        tq.mint(address(m), 5 ether);
        m.split();
        assertEq(m.buybackLeft(), 2 ether);
        assertEq(m.lpLeft(), 2 ether);
        uint256 lp0 = LpMockPair(pair).balanceOf(m.DEAD());
        (uint256 burns, uint256 adds) = _workToTheEnd(m, t);
        assertGt(burns, 1);
        assertGt(adds, 1);
        (, uint256 rQ) = _reserves(t, pair);
        m.split();
        assertLt(m.buybackLeft() * 10_000, rQ * m.WORK_MIN_BPS());
        assertLt(m.lpLeft() * 10_000, rQ * m.WORK_MIN_BPS());
        assertGt(LpMockPair(pair).balanceOf(m.DEAD()), lp0);
        assertEq(IERC20(t).balanceOf(address(m)), 0);
    }

    function test_allTransfersTaxed_booksStayWhole() public {
        (GangComboSplitter m, address t, address dev, address kol,) = _setup();
        tq.setTaxAll(true);
        uint256 dev0 = tq.balanceOf(dev);
        tq.mint(address(m), 10 ether);
        m.split();
        assertEq(m.buybackLeft(), 4 ether);
        assertEq(m.lpLeft(), 4 ether);
        assertEq(tq.balanceOf(kol), (1 ether * 95) / 100, "the quote's own tax on the push");
        assertEq(tq.balanceOf(dev) - dev0, (1 ether * 95) / 100);
        assertEq(tq.balanceOf(address(m)), 8 ether, "held = balance");
        _workToTheEnd(m, t);
        m.split();
        assertEq(tq.balanceOf(address(m)), m.buybackLeft() + m.lpLeft() + m.owedTotal(address(tq)) + m.unsplit());
    }
}
