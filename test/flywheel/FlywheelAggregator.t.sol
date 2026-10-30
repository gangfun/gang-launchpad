// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {GangPadRegistry} from "../../src/gang/GangPadRegistry.sol";
import {GangFlywheelPad} from "../../src/flywheel/GangFlywheelPad.sol";
import {IFlywheelPad} from "../../src/flywheel/interfaces/IFlywheelPad.sol";
import {MockWBNB} from "../mocks/MockWBNB.sol";
import {FlywheelFixture} from "./FlywheelFixture.sol";

/// @dev An aggregator's entry contract: pays in WBNB it holds, acts for whoever sent the transaction.
contract RouterStub {
    GangFlywheelPad pad;
    MockWBNB wbnb;

    constructor(GangFlywheelPad pad_, MockWBNB wbnb_) {
        pad = pad_;
        wbnb = wbnb_;
        wbnb_.approve(address(pad_), type(uint256).max);
    }

    function mint(address trader, address token, uint256 shares) external returns (uint256) {
        return pad.mintFor(trader, token, shares, 1, address(0));
    }

    function withdraw(address trader, address token, uint256 shares) external returns (uint256) {
        return pad.withdrawFor(trader, token, shares, 0);
    }

    function mintPost(address trader, address token, uint256 shares) external returns (uint256 out, uint256 spent) {
        return pad.mintPostFor(trader, token, shares, 0, type(uint256).max, address(0));
    }
}

/// @notice What an aggregator needs: GangPadRegistry finds the pad's tokens (kind 3), listed routers trade them for
///         the wallet that sent the transaction, and the previews match what the trades do, wei for wei.
contract FlywheelAggregatorTest is FlywheelFixture {
    GangPadRegistry registry;
    RouterStub router;

    function setUp() public {
        _deploy();
        address impl = address(new GangPadRegistry());
        address[] memory none = new address[](0);
        registry = GangPadRegistry(
            address(
                new TransparentUpgradeableProxy(impl, owner, abi.encodeCall(GangPadRegistry.initialize, (owner, none)))
            )
        );
        router = new RouterStub(pad, wbnb);
        wbnb.mintUnlimited(address(router), 1_000 ether);
        vm.prank(owner);
        pad.setRouter(address(router), true);
    }

    // ------------------------------------------------------------ registry
    function test_registryListsThePadAndFindsItsTokens() public {
        vm.prank(owner);
        registry.addPad(address(pad));
        address t = _create(_wide(), 1);
        assertEq(registry.padOf(t), address(pad));
        (address p, uint8 kind) = registry.lookup(t);
        assertEq(p, address(pad));
        assertEq(kind, 3);
        // no curve here: the registry's curve quotes stay empty for kind 3
        (uint256 out,,,) = registry.previewBuy(t, address(0), 1 ether);
        assertEq(out, 0);
        // still found after launch
        _fillAndLaunch(t);
        assertEq(registry.padOf(t), address(pad));
    }

    // ------------------------------------------------------------ routers
    function test_routerMintsAndSellsBackForTheSender() public {
        address t = _create(_wide(), 1);
        address w = _newAgent();
        uint256 r0 = wbnb.balanceOf(address(router));
        vm.prank(w, w);
        uint256 spent = router.mint(w, t, 10);
        assertEq(r0 - wbnb.balanceOf(address(router)), spent); // the router paid
        assertEq(IERC20(t).balanceOf(w), 10 * TPS); // the trader got the shares
        assertEq(pad.quotaLeft(t, w), 0); // quota 10 (V2 ceiling with post-launch minting)
        // sell back through the router: the trader approves the router on the token
        vm.prank(w);
        IERC20(t).approve(address(router), 4 * TPS);
        uint256 rb = wbnb.balanceOf(address(router));
        vm.prank(w, w);
        uint256 payout = router.withdraw(w, t, 4);
        assertEq(wbnb.balanceOf(address(router)) - rb, payout);
        assertEq(IERC20(t).balanceOf(w), 6 * TPS);
    }

    function test_routerOnlyForTheSenderAndOnlyListed() public {
        address t = _create(_wide(), 1);
        address w = _newAgent();
        address other = _newAgent();
        vm.prank(other, other);
        vm.expectRevert(IFlywheelPad.TraderNotOrigin.selector);
        router.mint(w, t, 1);
        RouterStub unlisted = new RouterStub(pad, wbnb);
        wbnb.mintUnlimited(address(unlisted), 1 ether);
        vm.prank(w, w);
        vm.expectRevert(IFlywheelPad.OnlyRouter.selector);
        unlisted.mint(w, t, 1);
    }

    function test_routerMintsAfterLaunchForTheSender() public {
        address t = _create(_wide(), 1);
        _fillAndLaunch(t);
        vm.warp(vm.getBlockTimestamp() + 600);
        address w = _newAgent();
        vm.prank(w, w);
        (uint256 out,) = router.mintPost(w, t, 10);
        assertEq(IERC20(t).balanceOf(w), out);
        assertEq(pad.baselineOf(t, w), out);
    }

    // ------------------------------------------------------------ previews
    function test_previewsMatchTheTrades() public {
        address t = _create(_wide(), 1);
        address w = _newAgent();
        (uint256 acc, uint256 cost, uint256 fee) = pad.previewMint(t, w, 25);
        assertEq(acc, 10); // per-mint cap
        vm.prank(w);
        uint256 spent = pad.mint(t, 25, 1, address(0));
        assertEq(spent, cost + fee);
        (uint256 payout,) = pad.previewWithdraw(t, w, 3);
        vm.prank(w);
        assertEq(pad.withdraw(t, 3, 0), payout);

        _fillAndLaunch(t);
        vm.warp(vm.getBlockTimestamp() + 600);
        vm.roll(vm.getBlockNumber() + 1);
        address m = _newAgent();
        (uint256 a2, uint256 paid, uint256 fee2, uint256 out, bool ok) = pad.previewMintPost(t, m, 10);
        assertTrue(ok);
        assertEq(a2, 10);
        vm.prank(m);
        (uint256 got, uint256 spent2) = pad.mintPost(t, 10, 0, type(uint256).max, address(0));
        assertEq(got, out);
        assertEq(spent2, paid + fee2);
    }

    /// @dev V2: only a sale with the guard on refuses after a dump (the fixture's sales have it off).
    function test_previewMintPostSaysNoAfterADump() public {
        IFlywheelPad.FlyConfig memory c = _wide();
        c.guardBps = 2_000;
        address t = _create(c, 1);
        _fillAndLaunch(t);
        vm.warp(vm.getBlockTimestamp() + 600); // past the launch protection
        address whale = _newAgent();
        _poolBuy(t, whale, 6 ether);
        vm.warp(vm.getBlockTimestamp() + 1 hours);
        vm.roll(vm.getBlockNumber() + 1);
        _poolSell(t, whale, IERC20(t).balanceOf(whale)); // about −45%: past the 20% guard
        vm.roll(vm.getBlockNumber() + 1);
        (,,,, bool ok) = pad.previewMintPost(t, whale, 10);
        assertFalse(ok);
        vm.prank(whale);
        vm.expectRevert(IFlywheelPad.PriceBelowAverage.selector);
        pad.mintPost(t, 10, 0, type(uint256).max, address(0));
    }
}
