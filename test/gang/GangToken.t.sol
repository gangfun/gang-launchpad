// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {GangToken} from "../../src/gang/GangToken.sol";
import {TokenDeployer} from "../../src/common/TokenDeployer.sol";
import {IGangTaxHandler} from "../../src/gang/interfaces/IGangTaxHandler.sol";

/// @dev Records every hook the token calls; `swapBack` behaves as `mode` says. Only the 5-argument `notifyTax`
///      exists, so a token calling any other shape would revert.
contract HookRecorder {
    enum Mode {
        Ok,
        Fail,
        FlashSwap,
        BurnGas
    }

    Mode public mode;
    uint256 public notifies;
    uint256 public lastRate;
    uint256 public lastTax;
    uint256 public syncs;
    uint256 public swapBacks;
    uint256 public lastSellAmount;

    function setMode(Mode m) external {
        mode = m;
    }

    function calls() external view returns (uint256) {
        return notifies + syncs + swapBacks;
    }

    function notifyTax(address, address, address, uint256 taxAmount, uint256 rateBps) external {
        notifies++;
        lastTax = taxAmount;
        lastRate = rateBps;
    }

    function syncShares(address, address, address) external {
        syncs++;
    }

    function swapBack(address, uint256 sellAmount) external returns (uint256) {
        if (mode == Mode.Fail) revert("chunk failed");
        if (mode == Mode.FlashSwap) revert GangToken.SellDuringFlashSwap();
        if (mode == Mode.BurnGas) {
            while (true) {}
        }
        swapBacks++;
        lastSellAmount = sellAmount;
        return 0;
    }
}

/// @notice GangToken on its own, all three kinds, deployed through TokenDeployer: V3 taxed (rates chosen at create),
///         V3 untaxed (0 / 0: no pair, never calls the handler) and 打新 (1% / 1%, `reclaim` while locked).
contract GangTokenTest is Test {
    TokenDeployer deployer;
    HookRecorder hooks;
    address pad = makeAddr("pad");
    address migrator = makeAddr("migrator");
    address pair = makeAddr("pair");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        deployer = new TokenDeployer(address(this));
        deployer.setLaunchpad(pad, true);
        hooks = new HookRecorder();
    }

    function _deploy(address handler, uint16 buyBps, uint16 sellBps, bool reclaimable) internal returns (GangToken t) {
        vm.prank(pad);
        t = GangToken(deployer.deploy("Gang", "GANG", "ipfs://meta.json", handler, buyBps, sellBps, reclaimable));
    }

    function _v3(uint16 buyBps, uint16 sellBps) internal returns (GangToken) {
        return _deploy(address(hooks), buyBps, sellBps, false);
    }

    function _plain() internal returns (GangToken) {
        return _deploy(address(0), 0, 0, false);
    }

    function _fair() internal returns (GangToken) {
        return _deploy(address(hooks), 100, 100, true);
    }

    /// @dev Graduate, then seed the pair and alice (both untaxed: from the excluded pad).
    function _live(GangToken t) internal {
        vm.startPrank(pad);
        t.unlock(migrator);
        t.setPair(pair);
        t.transfer(pair, 100_000_000 ether);
        t.transfer(alice, 10_000_000 ether);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ construction

    function test_v3_construction() public {
        GangToken t = _v3(200, 500);
        assertTrue(deployer.isLaunchToken(address(t)));
        assertFalse(t.reclaimable());
        assertEq(t.buyTaxBps(), 200);
        assertEq(t.sellTaxBps(), 500);
        assertEq(t.launchpad(), pad);
        assertEq(t.taxHandler(), address(hooks));
        assertEq(t.balanceOf(pad), t.TOTAL_SUPPLY());
        assertEq(t.totalSupply(), 1_000_000_000 ether);
        assertEq(t.contractURI(), "ipfs://meta.json");
        assertEq(t.metaURI(), "ipfs://meta.json");
        assertTrue(t.locked());
        assertEq(t.pair(), address(0));
        assertTrue(t.isExcluded(pad) && t.isExcluded(address(hooks)) && t.isExcluded(address(0xdead)));
    }

    function test_plain_construction() public {
        GangToken t = _plain();
        assertTrue(deployer.isLaunchToken(address(t)));
        assertEq(t.buyTaxBps(), 0);
        assertEq(t.sellTaxBps(), 0);
        assertEq(t.taxHandler(), address(0));
        assertFalse(t.reclaimable());
        assertFalse(t.isExcluded(pad), "untaxed: no exclusions written");
        assertEq(t.balanceOf(pad), t.TOTAL_SUPPLY());
        assertEq(t.metaURI(), "ipfs://meta.json");
    }

    function test_fair_construction() public {
        GangToken t = _fair();
        assertTrue(deployer.isLaunchToken(address(t)));
        assertTrue(t.reclaimable());
        assertEq(t.buyTaxBps(), 100);
        assertEq(t.sellTaxBps(), 100);
        assertTrue(t.isExcluded(pad) && t.isExcluded(address(hooks)));
    }

    /// @dev External so a constructor revert is a plain call revert (the test is built with a different profile than
    ///      the token, so `new` goes through `deployCode`).
    function deployRaw(address launchpad_, address handler_, uint16 buyBps, uint16 sellBps) external returns (address) {
        return address(new GangToken("X", "X", "", launchpad_, handler_, buyBps, sellBps, false));
    }

    function test_constructorChecks() public {
        vm.expectRevert(GangToken.ZeroAddress.selector);
        this.deployRaw(address(0), address(hooks), 100, 100);
        vm.expectRevert(GangToken.ZeroAddress.selector);
        this.deployRaw(address(0), address(0), 0, 0);
        // a taxed token needs a handler (either rate non-zero)
        vm.expectRevert(GangToken.ZeroAddress.selector);
        this.deployRaw(pad, address(0), 100, 100);
        vm.expectRevert(GangToken.ZeroAddress.selector);
        this.deployRaw(pad, address(0), 0, 100);
        // an untaxed one doesn't
        assertEq(GangToken(this.deployRaw(pad, address(0), 0, 0)).taxHandler(), address(0));
    }

    function test_deployer_onlyLaunchpads() public {
        vm.expectRevert(TokenDeployer.OnlyLaunchpad.selector);
        deployer.deploy("X", "X", "", address(hooks), 100, 100, false);
        deployer.setLaunchpad(pad, false);
        vm.prank(pad);
        vm.expectRevert(TokenDeployer.OnlyLaunchpad.selector);
        deployer.deploy("X", "X", "", address(0), 0, 0, false);
    }

    // ------------------------------------------------------------------ lock / one-shot admin (every kind)

    function _lockAndUnlock(GangToken t) internal {
        // locked: only the pad moves tokens
        vm.prank(pad);
        t.transfer(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(GangToken.TransfersLocked.selector);
        t.transfer(bob, 1);
        // a holder can approve, but a spender still can't move it
        vm.prank(alice);
        t.approve(bob, 1);
        vm.prank(bob);
        vm.expectRevert(GangToken.TransfersLocked.selector);
        t.transferFrom(alice, bob, 1);

        vm.prank(alice);
        vm.expectRevert(GangToken.OnlyLaunchpad.selector);
        t.unlock(alice);
        vm.startPrank(pad);
        vm.expectRevert(GangToken.ZeroAddress.selector);
        t.unlock(address(0));
        t.unlock(migrator);
        assertTrue(t.isExcluded(migrator));
        assertFalse(t.locked());
        vm.expectRevert(GangToken.AlreadyUnlocked.selector);
        t.unlock(migrator);
        vm.stopPrank();
        vm.prank(alice);
        t.transfer(bob, 1);
    }

    function _pairOnce(GangToken t) internal {
        vm.prank(pad);
        vm.expectRevert(GangToken.StillLocked.selector);
        t.setPair(pair);
        _lockAndUnlock(t);
        vm.startPrank(pad);
        vm.expectRevert(GangToken.ZeroAddress.selector);
        t.setPair(address(0));
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(GangToken.OnlyLaunchpad.selector);
        t.setPair(pair);
        vm.startPrank(pad);
        t.setPair(pair);
        vm.expectRevert(GangToken.PairAlreadySet.selector);
        t.setPair(bob);
        vm.stopPrank();
        assertFalse(t.isExcluded(pair), "pair is taxed");
    }

    function test_v3_lockAndOneShotAdmin() public {
        _pairOnce(_v3(300, 300));
    }

    function test_fair_lockAndOneShotAdmin() public {
        _pairOnce(_fair());
    }

    function test_plain_lockUnlockAndNoPair() public {
        GangToken t = _plain();
        vm.prank(pad);
        vm.expectRevert(GangToken.Untaxed.selector);
        t.setPair(pair);
        _lockAndUnlock(t);
        vm.prank(pad);
        vm.expectRevert(GangToken.Untaxed.selector);
        t.setPair(pair);
        assertEq(t.pair(), address(0));
    }

    /// @dev Even with a handler address passed in, an untaxed token never calls it: no pair, so no tax and no sync.
    function test_plain_neverCallsTheHandler() public {
        GangToken t = _deploy(address(hooks), 0, 0, false);
        _lockAndUnlock(t);
        vm.prank(pad);
        t.transfer(pair, 1000 ether);
        vm.prank(pair);
        t.transfer(alice, 500 ether);
        vm.prank(alice);
        t.transfer(pair, 400 ether);
        assertEq(hooks.calls(), 0);
        assertEq(t.balanceOf(address(hooks)), 0);
    }

    // ------------------------------------------------------------------ reclaim

    function test_fair_reclaimWhileLockedOnly() public {
        GangToken t = _fair();
        vm.prank(pad);
        t.transfer(alice, 50 ether);
        vm.prank(alice);
        vm.expectRevert(GangToken.OnlyLaunchpad.selector);
        t.reclaim(alice, 1);
        vm.prank(pad);
        t.reclaim(alice, 20 ether);
        assertEq(t.balanceOf(alice), 30 ether);
        assertEq(hooks.calls(), 0, "pre-launch: the pad writes shares itself");
        vm.prank(pad);
        t.unlock(migrator);
        vm.prank(pad);
        vm.expectRevert(GangToken.NotLocked.selector);
        t.reclaim(alice, 1);
    }

    function test_v3_noReclaimEver() public {
        GangToken[2] memory ts = [_v3(100, 100), _plain()];
        for (uint256 i = 0; i < 2; i++) {
            GangToken t = ts[i];
            vm.startPrank(pad);
            t.transfer(alice, 50 ether);
            vm.expectRevert(GangToken.NotReclaimable.selector);
            t.reclaim(alice, 1);
            t.unlock(migrator);
            vm.expectRevert(GangToken.NotReclaimable.selector);
            t.reclaim(alice, 1);
            vm.stopPrank();
            assertEq(t.balanceOf(alice), 50 ether);
        }
    }

    // ------------------------------------------------------------------ pool tax

    function test_v3_buyAndSellRates() public {
        GangToken t = _v3(200, 500);
        _live(t);
        uint256 syncs0 = hooks.syncs();

        // buy: from the pair at the buy rate, no swap-back (the pair is locked during a buy)
        vm.prank(pair);
        t.transfer(bob, 1000 ether);
        assertEq(t.balanceOf(bob), 980 ether);
        assertEq(t.balanceOf(address(hooks)), 20 ether);
        assertEq(hooks.notifies(), 1);
        assertEq(hooks.lastRate(), 200);
        assertEq(hooks.swapBacks(), 0);

        // sell: into the pair at the sell rate, swap-back first with the full sell amount
        vm.prank(alice);
        t.transfer(pair, 1000 ether);
        assertEq(t.balanceOf(address(hooks)), 70 ether);
        assertEq(hooks.notifies(), 2);
        assertEq(hooks.lastRate(), 500);
        assertEq(hooks.lastTax(), 50 ether);
        assertEq(hooks.swapBacks(), 1);
        assertEq(hooks.lastSellAmount(), 1000 ether);

        // wallet to wallet: untaxed, still synced
        vm.prank(alice);
        t.transfer(bob, 1 ether);
        assertEq(hooks.notifies(), 2);
        assertEq(hooks.syncs(), syncs0 + 3, "every transfer syncs");
    }

    function test_fair_onePercentWithItsRate() public {
        GangToken t = _fair();
        _live(t);
        // the handler's one hook shape (uint256 rate), never the old uint16 / rate-less ones
        vm.expectCall(
            address(hooks), abi.encodeCall(IGangTaxHandler.notifyTax, (address(t), pair, bob, 10 ether, uint256(100)))
        );
        vm.prank(pair);
        t.transfer(bob, 1000 ether);
        assertEq(t.balanceOf(bob), 990 ether);
        assertEq(hooks.lastRate(), 100, "the 5-argument hook, with this trade's rate");
        vm.prank(alice);
        t.transfer(pair, 1000 ether);
        assertEq(t.balanceOf(address(hooks)), 20 ether);
        assertEq(hooks.notifies(), 2);
        assertEq(hooks.lastRate(), 100);
        assertEq(hooks.swapBacks(), 1);
    }

    function test_excludedAndDustUntaxed() public {
        GangToken t = _v3(100, 100);
        _live(t);
        // the migrator (excluded) into the pair: untaxed, no swap-back
        vm.prank(pad);
        t.transfer(migrator, 10 ether);
        vm.prank(migrator);
        t.transfer(pair, 10 ether);
        // a dust sell (tax rounds to 0): no notify, no swap-back
        vm.prank(alice);
        t.transfer(pair, 99);
        assertEq(hooks.notifies(), 0);
        assertEq(hooks.swapBacks(), 0);
        assertEq(t.balanceOf(address(hooks)), 0);
    }

    // ------------------------------------------------------------------ swap-back guard

    function test_swapBackFailureSwallowed() public {
        GangToken t = _v3(100, 100);
        _live(t);
        hooks.setMode(HookRecorder.Mode.Fail);
        vm.expectEmit(address(t));
        emit GangToken.SwapBackFailed();
        vm.prank(alice);
        t.transfer(pair, 1000 ether);
        assertEq(t.balanceOf(address(hooks)), 10 ether, "sell went through, tax taken");
    }

    function test_flashSwapSellRefused_bothTaxedKinds() public {
        GangToken[2] memory ts = [_v3(100, 100), _fair()];
        hooks.setMode(HookRecorder.Mode.FlashSwap);
        for (uint256 i = 0; i < 2; i++) {
            _live(ts[i]);
            vm.prank(alice);
            vm.expectRevert(GangToken.SellDuringFlashSwap.selector);
            ts[i].transfer(pair, 1000 ether);
        }
    }

    function test_swapBackOutOfGas_revertsOnlyWhenCallerStarvesIt() public {
        GangToken t = _fair();
        _live(t);
        hooks.setMode(HookRecorder.Mode.BurnGas);
        // too little gas for the cap: the whole transfer reverts
        vm.prank(alice);
        (bool ok, bytes memory ret) = address(t).call{gas: 400_000}(abi.encodeCall(t.transfer, (pair, 1000 ether)));
        assertFalse(ok);
        assertEq(bytes4(ret), GangToken.SwapBackOutOfGas.selector);
        // enough gas: the chunk burns its 600k cap and is swallowed
        vm.prank(alice);
        (ok,) = address(t).call{gas: 2_000_000}(abi.encodeCall(t.transfer, (pair, 1000 ether)));
        assertTrue(ok, "a chunk failing on its own never fails the sell");
    }
}
