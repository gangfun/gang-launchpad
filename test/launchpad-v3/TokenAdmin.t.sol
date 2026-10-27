// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GangToken as LaunchTokenV3} from "../../src/gang/stub/GangToken.sol";
import {GangToken as TaxLaunchTokenV3} from "../../src/gang/stub/GangToken.sol";
import {TokenURI} from "../../src/launchpad-v3/TokenURI.sol";
import {LaunchpadV3Test} from "./LaunchpadV3.t.sol";

/// @notice The pad's power over V3 tokens is fixed and one-shot; tokens carry the creator's metadata URI.
contract TokenAdminV3Test is LaunchpadV3Test {
    string internal constant LOGO = "ipfs://bafy-logo";
    string internal constant URI = "ipfs://bafy-meta.json";

    function _createWithUri(uint16 buyBps) internal returns (address token) {
        vm.prank(agent);
        token = pad.create(
            "Meta",
            "META",
            LOGO,
            URI,
            address(quoteTok),
            address(0),
            _tax(buyBps, buyBps, 0, buyBps == 0 ? address(0) : treasury)
        );
    }

    function test_uri_fromCreate_taxedAndUntaxed() public {
        address taxed = _createWithUri(200);
        address untaxed = _createWithUri(0);
        for (uint256 i = 0; i < 2; i++) {
            address t = i == 0 ? taxed : untaxed;
            assertEq(TokenURI(t).contractURI(), URI, "contractURI");
            assertEq(TokenURI(t).metaURI(), URI, "metaURI");
            assertEq(pad.logoURIOf(t), LOGO, "pad keeps the logo, not the metadata");
        }
    }

    function test_taxed_handlerFixedAtCreate_noAdminLeftAfterGraduation() public {
        address t = _createWithUri(200);
        TaxLaunchTokenV3 tok = TaxLaunchTokenV3(t);
        assertEq(tok.taxHandler(), address(handler), "handler set at construction");
        assertTrue(tok.isExcluded(address(handler)));
        assertEq(tok.pair(), address(0));

        // before graduation: setPair needs the unlock first; only the pad can call either
        vm.prank(address(pad));
        vm.expectRevert(TaxLaunchTokenV3.StillLocked.selector);
        tok.setPair(makeAddr("p"));
        vm.prank(stranger);
        vm.expectRevert(TaxLaunchTokenV3.OnlyLaunchpad.selector);
        tok.unlock(stranger);

        _graduate(t);
        assertFalse(tok.locked());
        assertTrue(tok.isExcluded(address(migrator)), "migrator excluded by unlock");
        address pair = tok.pair();
        assertTrue(pair != address(0));

        // after graduation even the pad cannot change anything
        vm.startPrank(address(pad));
        vm.expectRevert(TaxLaunchTokenV3.AlreadyUnlocked.selector);
        tok.unlock(stranger);
        vm.expectRevert(TaxLaunchTokenV3.PairAlreadySet.selector);
        tok.setPair(stranger);
        // merge: a V3 token is never reclaimable (only 打新 tokens are, and only while locked)
        vm.expectRevert(TaxLaunchTokenV3.NotReclaimable.selector);
        tok.reclaim(stranger, 1);
        (bool ok,) = t.call(abi.encodeWithSignature("setTaxHandler(address)", stranger));
        assertFalse(ok, "no setTaxHandler");
        (ok,) = t.call(abi.encodeWithSignature("exclude(address,bool)", stranger, true));
        assertFalse(ok, "no exclude");
        (ok,) = t.call(abi.encodeWithSignature("burn(uint256)", 1));
        assertFalse(ok, "no burn");
        vm.stopPrank();
        assertEq(tok.pair(), pair);
        assertEq(tok.taxHandler(), address(handler));
    }

    function test_untaxed_unlockOnce_noBurn() public {
        address t = _createWithUri(0);
        LaunchTokenV3 tok = LaunchTokenV3(t);
        _graduate(t);
        assertFalse(tok.locked());
        vm.startPrank(address(pad));
        vm.expectRevert(LaunchTokenV3.AlreadyUnlocked.selector);
        tok.unlock(stranger);
        // untaxed: never a pair, so the handler is never called on a transfer (merge: one token contract)
        vm.expectRevert(LaunchTokenV3.Untaxed.selector);
        tok.setPair(stranger);
        vm.expectRevert(LaunchTokenV3.NotReclaimable.selector);
        tok.reclaim(stranger, 1);
        (bool ok,) = t.call(abi.encodeWithSignature("burn(uint256)", 1));
        assertFalse(ok, "no burn");
        vm.stopPrank();
        // and it trades freely, without ever touching the handler
        address holder = address(uint160(0xB0000));
        uint256 bal = IERC20(t).balanceOf(holder);
        vm.expectCall(address(handler), bytes(""), 0);
        vm.prank(holder);
        IERC20(t).transfer(stranger, bal);
        assertEq(IERC20(t).balanceOf(stranger), bal);
    }
}
