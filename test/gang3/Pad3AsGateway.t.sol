// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {GangLaunchpad3} from "../../src/gang/GangLaunchpad3.sol";
import {GangLaunchpad} from "../../src/gang/GangLaunchpad.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GangGatewayTest, LyingPad, PointingToken} from "../router/GangGateway.t.sol";
import {IGangGateway} from "../../src/router/interfaces/IGangGateway.sol";
import {IGangLaunchpad3} from "../../src/gang/interfaces/IGangLaunchpad3.sol";
import {GangGatewayFlywheelTest} from "../router/GangGatewayFlywheel.t.sol";
import {GangGatewayPhishingTest} from "../router/GangGatewayPhishing.t.sol";

/// @dev GangLaunchpad 3.0 used ONLY as the aggregator entry for another pad's tokens (it creates none here, so its
///      own curve dependencies are placeholders): the implementation behind its proxy, owned by `owner_`.
library Pad3Entry {
    function deploy(address wbnb, address registry, address owner_) internal returns (address) {
        GangLaunchpad3 impl = new GangLaunchpad3(
            address(0xA001), address(0xA002), address(0xA003), address(0xA004), address(0xA005), wbnb, registry
        );
        return address(
            new TransparentUpgradeableProxy(
                address(impl), address(0xA0FF), abi.encodeCall(GangLaunchpad3.initialize, (owner_, address(0xA006)))
            )
        );
    }
}

/// @notice GangGateway's suites re-run with GangLaunchpad 3.0's built-in aggregator entry in the Gateway's place,
///         forwarding to the suite's pad (2.0, or 铸币飞轮 V2) as its listed router — LegacyRoute: same quotes, trades,
///         refunds, fee split, whitelist and phishing guard as the Gateway, and 3.0 left holding nothing.
///         Not re-run (the Gateway's own deployment, not the entry): its deploy self-check, initializer, zero-address
///         and timelock-upgrade tests; the owner hand-over test (3.0 is OZ Ownable2Step: other revert data), which
///         GangLaunchpad3.t.sol covers.
contract Pad3AsGatewayTest is GangGatewayTest {
    function _newGateway(address reg_) internal override returns (address) {
        return Pad3Entry.deploy(address(wbnb), reg_, owner);
    }

    function test_deploy_selfCheckPasses() public view override {}
    function test_deploy_implAndProxyCannotBeInitializedAgain() public override {}
    function test_deploy_zeroAddressesRefused() public override {}
    function test_upgrade_onlyThroughTimelock() public override {}
    function test_whitelist_onlyOwner_twoStepHandOver() public override {}

    /// @dev Audit 3B I-4 (spec): a forwarded trade names the older pad it went to.
    function test_forward_emitsRouted() public {
        address t = _v3();
        (,, uint256 est,,,,,) = gw.tryBuy(t, alice, 0, 0.01 ether);
        vm.expectEmit(address(gw));
        emit IGangLaunchpad3.Routed(t, address(pad), alice, true, 0.01 ether, est);
        vm.prank(alice, alice);
        gw.buyTokenAMAP{value: 0.01 ether}(t, alice, 0.01 ether, est);
        (,, uint256 funds,) = gw.trySell(t, est);
        vm.startPrank(alice, alice);
        IERC20(t).approve(address(gw), est);
        vm.expectEmit(address(gw));
        emit IGangLaunchpad3.Routed(t, address(pad), alice, false, funds, est);
        gw.sellToken(0, t, alice, est, 0, 0, address(0));
        vm.stopPrank();
    }
}

contract Pad3AsGatewayFlywheelTest is GangGatewayFlywheelTest {
    function _newGateway(address reg_) internal override returns (address) {
        return Pad3Entry.deploy(address(wbnb), reg_, owner);
    }
}

contract Pad3AsGatewayPhishingTest is GangGatewayPhishingTest {
    function _newGateway(address reg_) internal override returns (address) {
        return Pad3Entry.deploy(address(wbnb), reg_, owner);
    }
}

/// @notice GangGateway's suite on GangLaunchpad 3.0's OWN tokens: the pad is 3.0 and the aggregator entry is the
///         pad itself (the local path: CurveLogic3 with prepaid funds / PULL_PAD sells, no router involved). Every
///         quote, trade, refund, fee split, whitelist and phishing case as the Gateway's, with one change of meaning:
///         the "gateway keeps nothing" check becomes "the pad holds exactly its books" (each curve's quote and
///         creator fee, each live sale's escrow, the exit fees owed; each live curve's unsold tokens; no BNB, no
///         allowance). Not re-run: the Gateway's deployment / timelock / hand-over tests (as above), and the two that
///         are about a separate router (delisting it from the pad; the pad's own allowance not counting) — the local
///         entry is the pad, so neither applies.
contract Pad3LocalEntryTest is GangGatewayTest {
    function _newPad() internal override returns (GangLaunchpad) {
        return _newPad3();
    }

    function _newGateway(address) internal view override returns (address) {
        return address(pad);
    }

    function _assertGatewayEmpty(address t) internal view override {
        assertEq(address(pad).balance, 0, "pad BNB");
        uint256 wantW;
        uint256 wantQ;
        uint256 n = pad.tokenCount();
        for (uint256 i; i < n; i++) {
            address tok = pad.allTokens(i);
            uint256 held;
            address q;
            if (pad.kindOf(tok) == 1) {
                (, address quote, uint128 realQuote, uint128 sold,,, bool graduated,,,,,) = pad.curves(tok);
                q = quote;
                held = uint256(realQuote) + pad.creatorFeeOf(tok);
                assertEq(IERC20(tok).balanceOf(address(pad)), graduated ? 0 : TOTAL_SUPPLY - sold, "unsold tokens");
            } else {
                (,,,, address quote, uint16 sold, bool launched,,,, uint128 sharePrice,,,) = pad.sales(tok);
                q = quote;
                if (!launched) held = uint256(sold) * sharePrice;
            }
            if (q == address(wbnb)) wantW += held;
            else if (q == address(quoteTok)) wantQ += held;
        }
        wantW += pad.owedFee(address(wbnb));
        wantQ += pad.owedFee(address(quoteTok));
        // never below its books; at most a few wei above: a curve buy cut at graduation keeps the 1-wei rounding of
        // its fee recompute (CurveLogic, as 2.0), in the pad's favour
        assertGe(wbnb.balanceOf(address(pad)), wantW, "pad WBNB >= its books");
        assertLe(wbnb.balanceOf(address(pad)) - wantW, 10, "pad WBNB dust");
        assertGe(quoteTok.balanceOf(address(pad)), wantQ, "pad quoteTok >= its books");
        assertLe(quoteTok.balanceOf(address(pad)) - wantQ, 10, "pad quoteTok dust");
        assertEq(wbnb.allowance(address(pad), address(pad)), 0, "no allowance");
        t;
    }

    function test_deploy_selfCheckPasses() public view override {}
    function test_deploy_implAndProxyCannotBeInitializedAgain() public override {}
    function test_deploy_zeroAddressesRefused() public override {}
    function test_upgrade_onlyThroughTimelock() public override {}
    function test_whitelist_onlyOwner_twoStepHandOver() public override {}
    function test_delisted_onlyRouter() public override {}
    function test_sell_padAllowanceDoesNotCount() public override {}

    /// @dev Gateway audit L-2 on 3.0: a pad 3.0's own registry returns cannot fake a fill (the suite's `reg` is not the
    ///      one 3.0 was built with here, so the liar goes into 3.0's).
    function test_buy_lyingPadCannotFakeAFill() public override {
        LyingPad liar = new LyingPad(address(wbnb));
        vm.prank(owner);
        padRegistry3.addPad(address(liar));
        PointingToken fake = new PointingToken(address(liar));
        liar.list(address(fake));
        (uint8 status,,,,) = gw.getTokenInfo(address(fake));
        assertEq(status, 1, "the registry vouches for it");
        vm.prank(alice, alice);
        vm.expectRevert(IGangGateway.Slippage.selector);
        gw.buyTokenAMAP{value: 0.01 ether}(address(fake), alice, 0.01 ether, 1);
        vm.prank(alice, alice);
        (uint256 out,) = gw.buyTokenAMAP{value: 0.01 ether}(address(fake), alice, 0.01 ether, 0);
        assertEq(out, 0, "not the 1e30 the pad claimed");
        _assertGatewayEmpty(address(0));
    }
}
