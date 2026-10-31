// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GangFixture} from "../utils/GangFixture.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {MockPair} from "../../src/launchpad-v2/mocks/MockPairFactory.sol";
import {MockSPCXB} from "../../src/launchpad-v2/mocks/MockSPCXB.sol";
import {PoolCheck} from "../../src/launchpad-v2/PoolCheck.sol";

/// @notice Graduation targets (SPEC-CURVE-GRAD-TARGET) on every pricing path and the economics around them: wallets
///         to graduate, reference / bridge pools and their depth floor, MIN_GRAD_AMT, rounding, a taxed 6 BNB token.
///         From the 2026-10-31 audit's PoCs.
contract GradTargetPricingTest is GangFixture {
    address internal creator;

    function setUp() public {
        _deployGang(address(this));
        creator = _newAgent();
    }

    function _createT(address quote, address ref, IGangLaunchpad.TaxConfig memory tax, uint256 g)
        internal
        returns (address t)
    {
        vm.prank(creator);
        t = pad.createWithGradTarget("C", "C", "", "", quote, ref, tax, g);
    }

    function _vq(address t) internal view returns (uint256 v) {
        (,,,,, v,,,,,,) = pad.curves(t);
    }

    /// 1% wallet cap: each tier still needs >= 80 distinct wallets; also report the BNB to fill one cap at the start.
    function test_capWalletsPerTier() public {
        uint256[4] memory tiers = pad.GRAD_BNB_TIERS();
        for (uint256 i; i < 4; i++) {
            address t = _createT(address(wbnb), address(0), _tax(0, 0, 0, address(0)), tiers[i]);
            uint256 n;
            for (; n < 400 && !_graduated(t); n++) {
                address w = _newAgent();
                vm.prank(w);
                pad.buy(t, 1 ether, 0);
            }
            assertTrue(_graduated(t));
            assertGe(n, 80, ">= 80 wallets");
            emit log_named_uint("tier (BNB)", tiers[i] / 1e18);
            emit log_named_uint("wallets to graduate", n);
            // first-buyer cost of a full 10M-token cap on a fresh curve of this tier
            address t2 = _createT(address(wbnb), address(0), _tax(0, 0, 0, address(0)), tiers[i]);
            address b = _newAgent();
            uint256 w0 = wbnb.balanceOf(b);
            vm.prank(b);
            pad.buy(t2, 1 ether, 0);
            emit log_named_decimal_uint("  WBNB spent for a full cap at start", w0 - wbnb.balanceOf(b), 18);
            assertEq(IERC20(t2).balanceOf(b), 10_000_000 ether);
        }
    }

    /// Default create == createWithGradTarget(9): same gradAmt / virtual quote.
    function test_defaultEqualsPicked9() public {
        address a = _createV3(creator, address(0), _tax(0, 0, 0, address(0)));
        address b = _createT(address(0), address(0), _tax(0, 0, 0, address(0)), 9 ether);
        assertEq(pad.gradAmtOf(a), pad.gradAmtOf(b));
        assertEq(_vq(a), _vq(b));
        assertEq(pad.gradTargetOf(a), pad.gradTargetOf(b));
    }

    /// Taxed dividend token at the lowest tier: graduates, the pool tax accrues and the keeper's process pays out.
    function test_tier6_taxedDividend_postGrad() public {
        address t = _createT(address(wbnb), address(0), _tax(300, 300, 5000, treasury), 6 ether);
        address holder = _newAgent();
        vm.prank(holder);
        pad.buy(t, 0.01 ether, 0);
        _graduate(t);
        address pair = _curvePair(t);
        (uint256 rT, uint256 rQ) = _reserves(t, pair);
        assertApproxEqAbs(rQ, 6 ether, 1);
        assertEq(rT, 200_000_000 ether);
        address trader = _newAgent();
        _poolBuy(t, address(wbnb), pair, trader, 0.5 ether);
        uint256 acc = handler.accruedTax(t);
        assertGt(acc, 0, "buy tax accrued");
        uint256 tre0 = wbnb.balanceOf(treasury);
        handler.process(t, type(uint256).max, 1);
        assertGt(wbnb.balanceOf(treasury), tre0, "recipient paid");
        assertGt(pad.creatorFeeOf(t), 0);
    }

    /// Reference V2 pool, WBNB counter: the depth floor is 1 BNB of counter at every tier (not 1/15 of the target).
    function test_refPool_depthFloorSameAtEveryTier() public {
        MockSPCXB q = new MockSPCXB();
        address ref = pairFactory.createPair(address(q), address(wbnb));
        q.mintUnlimited(ref, 2 ether);
        wbnb.mintUnlimited(ref, 1 ether); // exactly 1 BNB deep, 2 Q per BNB
        MockPair(ref).mint(address(0xdead));
        uint256[4] memory tiers = pad.GRAD_BNB_TIERS();
        for (uint256 i; i < 4; i++) {
            assertEq(pad.graduationAmountFor(address(q), ref, tiers[i]), 2 * tiers[i], "linear in the target");
        }
        // thinner than 1 BNB: refused at every tier
        MockSPCXB q2 = new MockSPCXB();
        address ref2 = pairFactory.createPair(address(q2), address(wbnb));
        q2.mintUnlimited(ref2, 2 ether);
        wbnb.mintUnlimited(ref2, 1 ether - 1);
        MockPair(ref2).mint(address(0xdead));
        for (uint256 i; i < 4; i++) {
            vm.expectRevert(PoolCheck.ThinReferencePool.selector);
            pad.graduationAmountFor(address(q2), ref2, tiers[i]);
        }
    }

    /// Bridge path (ref pool Q/X, bridge X/WBNB): scales linearly, depth floor = X worth 1 BNB at every tier.
    function test_bridgePath_scalesAndFloor() public {
        MockSPCXB x = new MockSPCXB(); // a USDT stand-in
        MockSPCXB q = new MockSPCXB();
        address bridge = pairFactory.createPair(address(x), address(wbnb));
        x.mintUnlimited(bridge, 600 ether);
        wbnb.mintUnlimited(bridge, 1 ether); // 600 X per BNB
        MockPair(bridge).mint(address(0xdead));
        vm.prank(owner);
        pad.setBridgePool(address(x), bridge);
        address ref = pairFactory.createPair(address(q), address(x));
        q.mintUnlimited(ref, 1_000 ether);
        x.mintUnlimited(ref, 600 ether); // exactly 1 BNB worth of X; 1000 Q per 600 X
        MockPair(ref).mint(address(0xdead));
        uint256[4] memory tiers = pad.GRAD_BNB_TIERS();
        for (uint256 i; i < 4; i++) {
            uint256 g = pad.graduationAmountFor(address(q), ref, tiers[i]);
            assertApproxEqAbs(g, 1_000 * tiers[i], 2, "1000 Q per BNB");
            address t = _createT(address(q), ref, _tax(0, 0, 0, address(0)), tiers[i]);
            assertEq(pad.gradAmtOf(t), g, "create locks the view");
        }
        // one wei shallower: refused at every tier
        MockSPCXB q2 = new MockSPCXB();
        address ref2 = pairFactory.createPair(address(q2), address(x));
        q2.mintUnlimited(ref2, 1_000 ether);
        x.mintUnlimited(ref2, 600 ether - 1);
        MockPair(ref2).mint(address(0xdead));
        for (uint256 i; i < 4; i++) {
            vm.expectRevert(PoolCheck.ThinReferencePool.selector);
            pad.graduationAmountFor(address(q2), ref2, tiers[i]);
        }
    }

    /// MIN_GRAD_AMT with a registry rate: a rate that clears the floor at 15 BNB can fail it at 6 BNB.
    function test_minGradAmt_registryEdge() public {
        MockSPCXB q = new MockSPCXB();
        vm.prank(owner);
        quoteRegistry.setQuote(address(q), true, 2e6); // 15 BNB worth = 2e6 wei of q
        assertEq(pad.graduationAmountFor(address(q), address(0), 15 ether), 2e6);
        assertEq(pad.graduationAmountFor(address(q), address(0), 6 ether), 8e5);
        vm.prank(creator);
        vm.expectRevert(IGangLaunchpad.GradAmtTooSmall.selector);
        pad.createWithGradTarget("C", "C", "", "", address(q), address(0), _tax(0, 0, 0, address(0)), 6 ether);
        _createT(address(q), address(0), _tax(0, 0, 0, address(0)), 15 ether);
    }

    /// Registry gradAmt not divisible by 3 at a low tier: sold at graduation stays at 800M (wei-level drift only).
    function test_registryRounding_soldAtGrad() public {
        MockSPCXB q = new MockSPCXB();
        vm.prank(owner);
        quoteRegistry.setQuote(address(q), true, 15 ether + 7); // 6 BNB → 6e18 + 2 (floor), not /3
        address t = _createT(address(q), address(0), _tax(0, 0, 0, address(0)), 6 ether);
        assertEq(pad.gradAmtOf(t), 6 ether + 2);
        for (uint256 i = 0; i < 400 && !_graduated(t); i++) {
            address w = _newAgent();
            q.mintUnlimited(w, 10 ether);
            vm.startPrank(w);
            q.approve(address(pad), type(uint256).max);
            pad.buy(t, 1 ether, 0);
            vm.stopPrank();
        }
        assertTrue(_graduated(t));
        assertApproxEqAbs(_curveSold(t), 800_000_000 ether, 1e12, "sold ~ 800M");
    }
}
