// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {GangToken} from "../../src/gang/GangToken.sol";
import {FairMintTest} from "./FairMint.t.sol";

/// @notice The pad's power over 打新 tokens is fixed and one-shot; tokens carry the creator's metadata URI.
contract FairTokenAdminTest is FairMintTest {
    function test_uri_fromCreate() public {
        address t = _create(); // logoURI "ipfs://logo", metaURI "ipfs://meta.json"
        assertEq(GangToken(t).contractURI(), "ipfs://meta.json");
        assertEq(GangToken(t).metaURI(), "ipfs://meta.json");
        assertEq(pad.logoURIOf(t), "ipfs://logo", "pad keeps the logo, not the metadata");
    }

    function test_handlerFixedAtCreate_noAdminLeftAfterLaunch() public {
        address t = _create();
        GangToken tok = GangToken(t);
        assertEq(tok.taxHandler(), address(handler), "handler set at construction");
        assertTrue(tok.isExcluded(address(handler)));

        vm.prank(address(pad));
        vm.expectRevert(GangToken.StillLocked.selector);
        tok.setPair(makeAddr("p"));
        vm.prank(stranger);
        vm.expectRevert(GangToken.OnlyLaunchpad.selector);
        tok.unlock(stranger);

        _fill(t);
        assertFalse(tok.locked());
        assertTrue(tok.isExcluded(address(migrator)), "migrator excluded by unlock");
        address pair = tok.pair();
        assertTrue(pair != address(0));

        address m0 = _minter(0);
        vm.startPrank(address(pad));
        vm.expectRevert(GangToken.AlreadyUnlocked.selector);
        tok.unlock(stranger);
        vm.expectRevert(GangToken.PairAlreadySet.selector);
        tok.setPair(stranger);
        vm.expectRevert(GangToken.NotLocked.selector);
        tok.reclaim(m0, 1);
        (bool ok,) = t.call(abi.encodeWithSignature("setTaxHandler(address)", stranger));
        assertFalse(ok, "no setTaxHandler");
        (ok,) = t.call(abi.encodeWithSignature("exclude(address,bool)", stranger, true));
        assertFalse(ok, "no exclude");
        vm.stopPrank();
        assertEq(tok.pair(), pair);
    }
}
