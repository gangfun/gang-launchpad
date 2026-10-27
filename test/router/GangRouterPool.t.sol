// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {GangFixture} from "../utils/GangFixture.sol";
import {GangRouter} from "../../src/router/GangRouter.sol";
import {GangRouterDeployLib as R} from "../../script/GangRouterDeployLib.sol";
import {MockPancakeV2Swap, ReenteringToken, PoolReenterer} from "../mocks/GangRouterV2Mock.sol";

/// @notice The router's Pancake V2 pool entries against a 1:1 stand-in Pancake (the real one: test/fork/RouterPoolFork):
///         paths, measured outputs, the refused inputs (Expired / ZeroAmount / TooLittleReceived), exact approvals set
///         back to 0, nothing left in the router, and the reentrancy guard on every pool entry.
contract GangRouterPoolTest is GangFixture {
    MockPancakeV2Swap internal pancake;
    GangRouter internal pr; // a router proxy whose Pancake is the stand-in
    address internal u = makeAddr("poolUser");

    function setUp() public {
        _deployGang(makeAddr("keeper"));
        pancake = new MockPancakeV2Swap();
        R.Router memory r = R.deploy(address(pad), address(wbnb), address(pancake), owner, R.MAINNET_MIN_DELAY);
        pr = GangRouter(payable(r.proxy));
        // the stand-in pays out of its own stock (WBNB backed by BNB so unwraps work)
        vm.deal(address(pancake), 0);
        vm.deal(address(this), 1_000 ether);
        wbnb.deposit{value: 1_000 ether}();
        wbnb.transfer(address(pancake), 1_000 ether);
        quoteTok.mintUnlimited(address(pancake), 1_000 ether);
        blq.mint(address(pancake), 1_000 ether);
        // u: BNB, quote and "token" (blq plays the token)
        vm.deal(u, 100 ether);
        quoteTok.mintUnlimited(u, 100 ether);
        blq.mint(u, 100 ether);
        vm.startPrank(u);
        quoteTok.approve(address(pr), type(uint256).max);
        blq.approve(address(pr), type(uint256).max);
        vm.stopPrank();
    }

    function _clean(address t, address q) internal view {
        assertEq(address(pr).balance, 0, "BNB");
        assertEq(wbnb.balanceOf(address(pr)), 0, "WBNB");
        assertEq(IERC20(q).balanceOf(address(pr)), 0, "quote");
        assertEq(IERC20(t).balanceOf(address(pr)), 0, "token");
        assertEq(wbnb.allowance(address(pr), address(pancake)), 0, "WBNB allowance");
        assertEq(IERC20(q).allowance(address(pr), address(pancake)), 0, "quote allowance");
        assertEq(IERC20(t).allowance(address(pr), address(pancake)), 0, "token allowance");
    }

    function test_pool_allFour_measuredAndClean() public {
        address t = address(blq);
        address q = address(quoteTok);
        uint256 dl = vm.getBlockTimestamp();
        vm.startPrank(u);
        uint256 b = blq.balanceOf(u);
        assertEq(pr.poolBuyBNB{value: 1 ether}(t, q, 1 ether, dl), 1 ether, "[WBNB, quote, token]");
        assertEq(blq.balanceOf(u) - b, 1 ether);
        _clean(t, q);
        assertEq(pr.poolBuyBNB{value: 1 ether}(t, address(wbnb), 1 ether, dl), 1 ether, "[WBNB, token]");
        _clean(t, q);
        assertEq(pr.poolBuy(t, q, 2 ether, 2 ether, dl), 2 ether);
        _clean(t, q);
        uint256 qb = quoteTok.balanceOf(u);
        assertEq(pr.poolSell(t, q, 3 ether, 3 ether, dl), 3 ether);
        assertEq(quoteTok.balanceOf(u) - qb, 3 ether, "quote straight to the user");
        _clean(t, q);
        uint256 bnb = u.balance;
        assertEq(pr.poolSellForBNB(t, q, 4 ether, 4 ether, dl), 4 ether, "[token, quote, WBNB]");
        assertEq(u.balance - bnb, 4 ether, "unwrapped and sent");
        _clean(t, q);
        assertEq(pr.poolSellForBNB(t, address(wbnb), 1 ether, 1 ether, dl), 1 ether, "[token, WBNB]");
        _clean(t, q);
        vm.stopPrank();
    }

    function test_pool_refusals() public {
        address t = address(blq);
        address q = address(quoteTok);
        uint256 dl = vm.getBlockTimestamp();
        vm.warp(dl + 1);
        vm.startPrank(u);
        vm.expectRevert(GangRouter.Expired.selector);
        pr.poolBuyBNB{value: 1 ether}(t, q, 0, dl);
        vm.expectRevert(GangRouter.Expired.selector);
        pr.poolBuy(t, q, 1 ether, 0, dl);
        vm.expectRevert(GangRouter.Expired.selector);
        pr.poolSell(t, q, 1 ether, 0, dl);
        vm.expectRevert(GangRouter.Expired.selector);
        pr.poolSellForBNB(t, q, 1 ether, 0, dl);
        dl = vm.getBlockTimestamp();
        vm.expectRevert(GangRouter.ZeroAmount.selector);
        pr.poolBuyBNB(t, q, 0, dl);
        vm.expectRevert(GangRouter.ZeroAmount.selector);
        pr.poolBuy(t, q, 0, 0, dl);
        vm.expectRevert(GangRouter.ZeroAmount.selector);
        pr.poolSell(t, q, 0, 0, dl);
        vm.expectRevert(GangRouter.ZeroAmount.selector);
        pr.poolSellForBNB(t, q, 0, 0, dl);
        // a short fill (90%): the caller's minimum is checked on what arrived
        vm.stopPrank();
        pancake.setRate(9_000);
        vm.startPrank(u);
        vm.expectRevert(abi.encodeWithSelector(GangRouter.TooLittleReceived.selector, 0.9 ether, 1 ether));
        pr.poolBuyBNB{value: 1 ether}(t, q, 1 ether, dl);
        vm.expectRevert(abi.encodeWithSelector(GangRouter.TooLittleReceived.selector, 0.9 ether, 1 ether));
        pr.poolBuy(t, q, 1 ether, 1 ether, dl);
        vm.expectRevert(abi.encodeWithSelector(GangRouter.TooLittleReceived.selector, 0.9 ether, 1 ether));
        pr.poolSell(t, q, 1 ether, 1 ether, dl);
        vm.expectRevert(abi.encodeWithSelector(GangRouter.TooLittleReceived.selector, 0.9 ether, 1 ether));
        pr.poolSellForBNB(t, q, 1 ether, 1 ether, dl);
        vm.stopPrank();
        _clean(t, q);
    }

    /// A hostile token re-entering from inside the router's pull: the guard stops it.
    function test_pool_reentrancy_fromToken() public {
        ReenteringToken evil = new ReenteringToken();
        evil.mint(u, 10 ether);
        evil.mint(address(pancake), 10 ether);
        vm.prank(u);
        evil.approve(address(pr), type(uint256).max);
        evil.arm(pr, address(quoteTok));
        vm.prank(u);
        pr.poolSell(address(evil), address(quoteTok), 1 ether, 0, vm.getBlockTimestamp());
        assertEq(evil.innerError(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        _clean(address(evil), address(quoteTok));
    }

    /// A caller re-entering from the BNB payout of poolSellForBNB: the guard stops it.
    function test_pool_reentrancy_fromBnbPayout() public {
        PoolReenterer a = new PoolReenterer(pr);
        blq.mint(address(a), 5 ether);
        a.sellForBnb(address(blq), address(wbnb), 1 ether);
        assertEq(a.reentries(), 1);
        assertEq(a.innerError(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(address(a).balance, 1 ether, "the payout arrived");
        _clean(address(blq), address(wbnb));
    }
}
