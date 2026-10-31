// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {GangFixture} from "../utils/GangFixture.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {CurveLogic} from "../../src/gang/CurveLogic.sol";

/// @notice The creator's graduation target on GangLaunchpad 2.0 (docs/SPEC-CURVE-GRAD-TARGET-2026-10-31.md): one of
///         6 / 9 / 12 / 15 BNB raised, default 9 BNB; converted to the quote as the fixed 15 BNB was; the curve shape
///         scales with it (virtual quote = target / 3, graduation market cap = 5x the target).
contract GradTargetTest is GangFixture {
    event GradTargetSet(address indexed token, uint256 gradBnb);

    address internal creator;

    function setUp() public {
        _deployGang(address(this));
        creator = _newAgent();
    }

    function _create(address quote, uint256 gradBnb) internal returns (address t) {
        vm.prank(creator);
        t = pad.createWithGradTarget(
            "Curve", "CRV", "logo", "meta", quote, address(0), _tax(0, 0, 0, address(0)), gradBnb
        );
    }

    /// @dev The one GradTargetSet the pad emitted since `vm.recordLogs()`: its token topic and target.
    function _gradTargetLog() internal returns (address token, uint256 gradBnb) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 n;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(pad) && logs[i].topics[0] == GradTargetSet.selector) {
                token = address(uint160(uint256(logs[i].topics[1])));
                gradBnb = abi.decode(logs[i].data, (uint256));
                n++;
            }
        }
        assertEq(n, 1, "one GradTargetSet");
    }

    function _gradAmt(address t) internal view returns (uint256 g) {
        (,,,, g,,,,,,,) = pad.curves(t);
    }

    function _virtualQuote(address t) internal view returns (uint256 v) {
        (,,,,, v,,,,,,) = pad.curves(t);
    }

    function test_constants() public view {
        assertEq(pad.TARGET_GRAD_BNB(), 9 ether, "default target");
        uint256[4] memory tiers = pad.GRAD_BNB_TIERS();
        assertEq(tiers[0], 6 ether);
        assertEq(tiers[1], 9 ether);
        assertEq(tiers[2], 12 ether);
        assertEq(tiers[3], 15 ether);
        // GRAD_BNB_TIERS has 4 slots: the library's MIN / MAX / STEP must keep exactly 4 tiers
        assertEq(CurveLogic.MAX_GRAD_BNB, CurveLogic.MIN_GRAD_BNB + 3 * CurveLogic.GRAD_BNB_STEP, "4 tiers");
        assertEq(pad.REGISTRY_REF_BNB(), 15 ether, "registry rates stay 15 BNB worth");
    }

    /// @notice `create` (no target) locks the default: 9 BNB → 9 WBNB, 3 WBNB virtual.
    function test_create_defaultsTo9Bnb() public {
        vm.recordLogs();
        address t = _createV3(creator, address(0), _tax(0, 0, 0, address(0)));
        (address logged, uint256 g) = _gradTargetLog();
        assertEq(logged, t, "event names the token");
        assertEq(g, 9 ether, "event carries the default");
        assertEq(pad.gradTargetOf(t), 9 ether);
        assertEq(_gradAmt(t), 9 ether);
        assertEq(_virtualQuote(t), 3 ether);
        assertEq(pad.graduationAmountOf(address(0), address(0)), 9 ether);
    }

    function test_eachTier_locksItsTarget_WBNB() public {
        uint256[4] memory tiers = pad.GRAD_BNB_TIERS();
        for (uint256 i; i < 4; i++) {
            vm.recordLogs();
            address t = _create(address(0), tiers[i]);
            (address logged, uint256 g) = _gradTargetLog();
            assertEq(logged, t, "event names the token");
            assertEq(g, tiers[i], "event carries the pick");
            assertEq(pad.gradTargetOf(t), tiers[i], "target kept");
            assertEq(_gradAmt(t), tiers[i], "WBNB: target = amount");
            assertEq(_virtualQuote(t), tiers[i] / 3, "virtual quote = target / 3");
            assertEq(pad.graduationAmountFor(address(0), address(0), tiers[i]), tiers[i], "view = what create locks");
        }
    }

    /// @notice A registry quote: the rate is "15 BNB worth", scaled to the target.
    function test_registryQuote_scalesToTarget() public {
        vm.prank(owner);
        quoteRegistry.setQuote(address(quoteTok), true, 30 ether); // 15 BNB = 30 quote
        address t6 = _create(address(quoteTok), 6 ether);
        address t12 = _create(address(quoteTok), 12 ether);
        assertEq(_gradAmt(t6), 12 ether);
        assertEq(_gradAmt(t12), 24 ether);
        assertEq(pad.graduationAmountFor(address(quoteTok), address(0), 6 ether), 12 ether);
        assertEq(pad.graduationAmountOf(address(quoteTok), address(0)), 18 ether, "default 9 BNB = 18 quote");
    }

    function test_offTier_reverts() public {
        uint256[6] memory bad = [uint256(0), 5 ether, 6 ether + 1, 10 ether, 16 ether, 1e30];
        for (uint256 i; i < bad.length; i++) {
            vm.prank(creator);
            vm.expectRevert(IGangLaunchpad.BadGradTarget.selector);
            pad.createWithGradTarget("C", "C", "", "", address(0), address(0), _tax(0, 0, 0, address(0)), bad[i]);
            vm.expectRevert(IGangLaunchpad.BadGradTarget.selector);
            pad.graduationAmountFor(address(0), address(0), bad[i]);
        }
        assertEq(pad.tokenCount(), 0, "nothing created");
    }

    /// @notice The gate, the tax check and the quote check still apply to a picked target.
    function test_pickedTarget_keepsCreateChecks() public {
        address stranger = makeAddr("noAgentId");
        vm.prank(stranger);
        vm.expectRevert(IGangLaunchpad.NotAgent.selector);
        pad.createWithGradTarget("C", "C", "", "", address(0), address(0), _tax(0, 0, 0, address(0)), 6 ether);

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(IGangLaunchpad.BadTaxConfig.selector, "recipient not listed"));
        pad.createWithGradTarget(
            "C", "C", "", "", address(0), address(0), _tax(300, 300, 0, makeAddr("unlisted")), 6 ether
        );

        vm.prank(creator);
        vm.expectRevert(IGangLaunchpad.QuoteNotAllowed.selector);
        pad.createWithGradTarget(
            "C", "C", "", "", makeAddr("notAQuote"), address(0), _tax(0, 0, 0, address(0)), 6 ether
        );
    }

    /// @notice Each tier graduates once the raise reaches its target; the pool opens at 5x the target in market cap
    ///         (same curve shape: 800M sold, 200M + the raise into the pool).
    function test_eachTier_graduatesAtTarget() public {
        uint256[4] memory tiers = pad.GRAD_BNB_TIERS();
        for (uint256 i; i < 4; i++) {
            address t = _create(address(quoteTok), tiers[i]);
            _graduate(t);
            assertEq(_curveSold(t), CURVE_SUPPLY_, "the whole curve sold");
            (uint256 rT, uint256 rQ) = _reserves(t, _curvePair(t));
            assertGe(rQ, tiers[i], "the raise (>= the target) went to the pool");
            assertLe(rQ, tiers[i] + 1, "and no more");
            uint256 mcap = (rQ * TOTAL_SUPPLY) / rT;
            assertApproxEqRel(mcap, 5 * tiers[i], 0.02e18, "pool opens at ~5x the target");
        }
    }

    uint256 internal constant CURVE_SUPPLY_ = 800_000_000 ether;
}
