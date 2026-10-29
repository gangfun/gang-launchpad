// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {GangMintToken} from "../../src/flywheel/GangMintToken.sol";
import {MintTokenDeployer} from "../../src/flywheel/MintTokenDeployer.sol";
import {HookRecorder} from "../gang/GangToken.t.sol";

/// @notice GangMintToken on its own: GangToken's rules (lock, reclaim, pullFor, pool tax, hooks) plus a starting supply
///         (0 allowed) and `padMint`, which only the pad can call, before or after launch, up to `maxSupply`.
contract GangMintTokenTest is Test {
    MintTokenDeployer deployer;
    HookRecorder hooks;
    address pad = makeAddr("pad");
    address migrator = makeAddr("migrator");
    address pair = makeAddr("pair");
    address alice = makeAddr("alice");

    uint256 constant START = 1_900_000_000 ether;
    uint256 constant CAP = 190_000_000_000 ether;

    function setUp() public {
        deployer = new MintTokenDeployer(address(this));
        deployer.setLaunchpad(pad, true);
        hooks = new HookRecorder();
    }

    function _deploy(uint16 sellBps) internal returns (GangMintToken t) {
        vm.prank(pad);
        t = GangMintToken(deployer.deploy("Mint", "MINT", "ipfs://m.json", address(hooks), 100, sellBps, START, CAP));
    }

    function _launch(GangMintToken t) internal {
        vm.startPrank(pad);
        t.unlock(migrator);
        t.setPair(pair);
        vm.stopPrank();
    }

    function test_startsWithTheStartingSupplyAtThePad() public {
        GangMintToken t = _deploy(200);
        assertEq(t.totalSupply(), START);
        assertEq(t.balanceOf(pad), START);
        assertEq(t.maxSupply(), CAP);
        assertEq(t.buyTaxBps(), 100);
        assertEq(t.sellTaxBps(), 200);
        assertTrue(t.reclaimable());
        assertTrue(t.locked());
        assertTrue(deployer.isLaunchToken(address(t)));
    }

    function test_deployRefusesUnlistedCaller() public {
        vm.expectRevert(MintTokenDeployer.OnlyLaunchpad.selector);
        deployer.deploy("Mint", "MINT", "u", address(hooks), 100, 100, START, CAP);
    }

    function test_constructorRefusesStartAboveCapOrZeroCap() public {
        vm.startPrank(pad);
        vm.expectRevert(GangMintToken.BadSupply.selector);
        deployer.deploy("Mint", "MINT", "u", address(hooks), 100, 100, CAP + 1, CAP);
        vm.expectRevert(GangMintToken.BadSupply.selector);
        deployer.deploy("Mint", "MINT", "u", address(hooks), 100, 100, 0, 0);
        vm.stopPrank();
    }

    function test_zeroStartSupplyMintsAsMintersMintWhileLocked() public {
        vm.prank(pad);
        GangMintToken t =
            GangMintToken(deployer.deploy("Mint", "MINT", "u", address(hooks), 100, 100, 0, CAP));
        assertEq(t.totalSupply(), 0);
        vm.prank(pad);
        t.padMint(alice, 3 ether); // a pre-launch mint: allowed although transfers are locked
        assertEq(t.balanceOf(alice), 3 ether);
        assertEq(hooks.calls(), 0); // no pair yet: no hooks
        vm.prank(alice);
        vm.expectRevert(GangMintToken.TransfersLocked.selector);
        t.transfer(pad, 1 ether);
    }

    function test_padMintOnlyByPad() public {
        GangMintToken t = _deploy(100);
        _launch(t);
        vm.prank(alice);
        vm.expectRevert(GangMintToken.OnlyLaunchpad.selector);
        t.padMint(alice, 1 ether);
    }

    function test_padMintUpToTheCap() public {
        GangMintToken t = _deploy(100);
        _launch(t);
        vm.prank(pad);
        t.padMint(alice, CAP - START);
        assertEq(t.totalSupply(), CAP);
        assertEq(t.balanceOf(alice), CAP - START);
        vm.prank(pad);
        vm.expectRevert(GangMintToken.CapExceeded.selector);
        t.padMint(alice, 1);
    }

    function test_padMintIsUntaxedAndSyncsTheReceiver() public {
        GangMintToken t = _deploy(100);
        _launch(t);
        uint256 syncs = hooks.syncs();
        vm.prank(pad);
        t.padMint(alice, 5 ether);
        assertEq(hooks.notifies(), 0);
        assertEq(hooks.syncs(), syncs + 1);
    }

    function test_mintRoomTracksTheCap() public {
        GangMintToken t = _deploy(100);
        assertEq(t.mintRoom(), CAP - START);
        _launch(t);
        vm.prank(pad);
        t.padMint(alice, 7 ether);
        assertEq(t.mintRoom(), CAP - START - 7 ether);
    }

    function test_poolTaxUsesBuyAndSellRates() public {
        GangMintToken t = _deploy(200);
        _launch(t);
        vm.prank(pad);
        t.transfer(pair, 1_000 ether); // pad excluded: untaxed
        vm.prank(pair);
        t.transfer(alice, 100 ether); // buy: 1%
        assertEq(hooks.lastRate(), 100);
        assertEq(t.balanceOf(alice), 99 ether);
        vm.prank(alice);
        t.transfer(pair, 50 ether); // sell: 2%
        assertEq(hooks.lastRate(), 200);
        assertEq(hooks.lastTax(), 1 ether);
    }

    function test_lockedUntilLaunchReclaimWhileLocked() public {
        GangMintToken t = _deploy(100);
        vm.prank(pad);
        t.transfer(alice, 10 ether);
        vm.prank(alice);
        vm.expectRevert(GangMintToken.TransfersLocked.selector);
        t.transfer(pair, 1 ether);
        vm.prank(pad);
        t.reclaim(alice, 4 ether);
        assertEq(t.balanceOf(alice), 6 ether);
        _launch(t);
        vm.prank(pad);
        vm.expectRevert(GangMintToken.NotLocked.selector);
        t.reclaim(alice, 1 ether);
    }

    function testFuzz_padMintNeverExceedsCap(uint256 a, uint256 b) public {
        GangMintToken t = _deploy(100);
        _launch(t);
        a = bound(a, 0, CAP);
        b = bound(b, 0, CAP);
        vm.startPrank(pad);
        if (a <= CAP - START) t.padMint(alice, a);
        else {
            vm.expectRevert(GangMintToken.CapExceeded.selector);
            t.padMint(alice, a);
            a = 0;
        }
        if (START + a + b <= CAP) t.padMint(alice, b);
        else {
            vm.expectRevert(GangMintToken.CapExceeded.selector);
            t.padMint(alice, b);
        }
        vm.stopPrank();
        assertLe(t.totalSupply(), CAP);
    }
}
