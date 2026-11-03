// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GangLaunchpad} from "../../src/gang/GangLaunchpad.sol";
import {GangLaunchpad3} from "../../src/gang/GangLaunchpad3.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {IGangLaunchpad3} from "../../src/gang/interfaces/IGangLaunchpad3.sol";
import {GangFixture} from "../utils/GangFixture.sol";

/// @dev An aggregator router doing a multi-hop sell: the Gang hop pays this contract (four.meme's pay-to
///      `sellToken`), then it goes on with the proceeds — here the "next hop" just hands them to its caller.
contract MultiHopRouter {
    GangLaunchpad3 public immutable entry;

    constructor(GangLaunchpad3 entry_) {
        entry = entry_;
    }

    receive() external payable {}

    /// @dev The Gang hop only (the proceeds stay here, as before a next hop).
    function gangHop(address token, uint256 amount, uint256 minFunds) external returns (uint256) {
        return entry.sellToken(0, token, msg.sender, address(this), amount, minFunds);
    }

    /// @dev A router that sends the proceeds to someone other than itself (must be refused unless that is listed).
    function gangHopTo(address token, address to, uint256 amount) external returns (uint256) {
        return entry.sellToken(0, token, msg.sender, to, amount, 0);
    }

    /// @dev The Gang hop, then the next hop (to the caller, in the quote or native BNB).
    function sellThenForward(address token, address quote, uint256 amount, uint256 minFunds)
        external
        returns (uint256 got)
    {
        got = entry.sellToken(0, token, msg.sender, address(this), amount, minFunds);
        if (quote == address(0)) {
            (bool ok,) = msg.sender.call{value: got}("");
            require(ok, "bnb");
        } else {
            IERC20(quote).transfer(msg.sender, got);
        }
    }
}

/// @notice The pay-to `sellToken(origin, token, from, to, amount, minFunds)` (four.meme's multi-hop sell, same
///         selector) on 3.0's own curve tokens: the proceeds after the pad's fee go to a listed aggregator contract
///         `to`, never through the seller; tokens straight from the seller into the pad; the pad's books stay whole.
///         Forwarded tokens of older pads: test/gang3/Pad3AsGateway.t.sol.
contract Pad3SellToTest is GangFixture {
    GangLaunchpad3 internal pad3;
    MultiHopRouter internal hop;
    address internal alice;

    function _newPad() internal override returns (GangLaunchpad) {
        return _newPad3();
    }

    function setUp() public {
        _deployGang(address(this));
        pad3 = GangLaunchpad3(payable(address(pad)));
        alice = _newAgent();
        hop = new MultiHopRouter(pad3);
        vm.prank(owner);
        pad3.setCaller(address(hop), true);
    }

    function _bought(address quote, uint256 funds) internal returns (address t, uint256 out) {
        t = _createV3(alice, quote, _tax(0, 0, 0, address(0)));
        if (quote == address(wbnb)) {
            vm.prank(alice, alice);
            (out,) = pad3.buyTokenAMAP{value: funds}(t, alice, funds, 0);
        } else {
            vm.prank(alice);
            IERC20(quote).approve(address(pad), funds);
            vm.prank(alice, alice);
            (out,) = pad3.buyTokenAMAP(t, alice, funds, 0);
        }
        vm.prank(alice);
        IERC20(t).approve(address(pad), out);
    }

    function _solvent(address t, address quote) internal view {
        (,, uint128 rq,,,,,,,,,) = pad.curves(t);
        assertGe(IERC20(quote).balanceOf(address(pad)), uint256(rq) + pad.creatorFeeOf(t), "books");
        assertEq(address(pad).balance, 0, "no BNB on the pad");
    }

    function test_selector_isFourMemes() public pure {
        bytes4 sel = bytes4(keccak256("sellToken(uint256,address,address,address,uint256,uint256)"));
        assertEq(sel, bytes4(0x930cc050), "four.meme TokenManager2's pay-to sell");
    }

    /// @dev BNB-quoted: the proceeds land on the router in native BNB (= trySell's funds); the seller gets nothing
    ///      directly; the tokens go from the seller into the pad.
    function test_sellTo_bnb_proceedsToTheRouter() public {
        (address t, uint256 out) = _bought(address(wbnb), 0.02 ether);
        uint256 amount = out / 2;
        (,, uint256 funds,) = pad3.trySell(t, amount);
        uint256 a0 = alice.balance;
        uint256 padTokens = IERC20(t).balanceOf(address(pad));
        vm.expectEmit(address(pad));
        emit IGangLaunchpad3.GatewaySellTo(t, alice, address(hop), address(hop), amount, funds);
        vm.prank(alice, alice);
        uint256 got = hop.gangHop(t, amount, funds);
        assertEq(got, funds, "= trySell");
        assertEq(address(hop).balance, funds, "native BNB on the router");
        assertEq(alice.balance, a0, "nothing to the seller directly");
        assertEq(IERC20(t).balanceOf(alice), out - amount);
        assertEq(IERC20(t).balanceOf(address(hop)), 0, "tokens never on the router");
        assertEq(IERC20(t).balanceOf(address(pad)) - padTokens, amount, "seller -> pad");
        _solvent(t, address(wbnb));
    }

    /// @dev ERC-20-quoted: the quote ERC-20 lands on the router, which goes on with it.
    function test_sellTo_erc20_proceedsToTheRouter_thenNextHop() public {
        (address t, uint256 out) = _bought(address(quoteTok), 0.02 ether);
        (,, uint256 funds,) = pad3.trySell(t, out);
        uint256 a0 = quoteTok.balanceOf(alice);
        vm.prank(alice, alice);
        uint256 got = hop.sellThenForward(t, address(quoteTok), out, funds);
        assertEq(got, funds);
        assertEq(quoteTok.balanceOf(alice) - a0, funds, "next hop delivered");
        assertEq(quoteTok.balanceOf(address(hop)), 0);
        _solvent(t, address(quoteTok));
    }

    function test_sellTo_userDirect_toAListedRouter() public {
        (address t, uint256 out) = _bought(address(wbnb), 0.01 ether);
        (,, uint256 funds,) = pad3.trySell(t, out);
        vm.prank(alice, alice);
        pad3.sellToken(0, t, alice, address(hop), out, funds);
        assertEq(address(hop).balance, funds);
    }

    /// @dev Only a listed contract receives: an unlisted router (even called by the seller), an EOA, the pad itself.
    function test_sellTo_recipientMustBeListed() public {
        (address t, uint256 out) = _bought(address(wbnb), 0.01 ether);
        MultiHopRouter other = new MultiHopRouter(pad3);
        vm.prank(alice, alice);
        vm.expectRevert(IGangLaunchpad3.NotWhitelisted.selector);
        other.gangHop(t, out, 0); // unlisted caller
        vm.prank(alice, alice);
        vm.expectRevert(IGangLaunchpad3.RecipientNotListed.selector);
        hop.gangHopTo(t, address(other), out); // listed caller, unlisted recipient
        vm.prank(alice, alice);
        vm.expectRevert(IGangLaunchpad3.RecipientNotListed.selector);
        pad3.sellToken(0, t, alice, makeAddr("eoa"), out, 0);
        vm.prank(owner);
        pad3.setCaller(address(pad), true); // even if the owner lists the pad, it never receives
        vm.prank(alice, alice);
        vm.expectRevert(IGangLaunchpad3.RecipientNotListed.selector);
        pad3.sellToken(0, t, alice, address(pad), out, 0);
    }

    /// @dev The seller is the wallet that sent the tx: a listed router can't sell someone else's tokens to itself.
    function test_sellTo_sellerMustBeTxOrigin() public {
        (address t, uint256 out) = _bought(address(wbnb), 0.01 ether);
        address mallory = _newAgent();
        vm.prank(address(hop), mallory);
        vm.expectRevert(IGangLaunchpad.TraderNotOrigin.selector);
        pad3.sellToken(0, t, alice, address(hop), out, 0);
    }

    function test_sellTo_minFundsAndGraduated() public {
        (address t, uint256 out) = _bought(address(wbnb), 0.01 ether);
        (,, uint256 funds,) = pad3.trySell(t, out);
        vm.prank(alice, alice);
        vm.expectRevert(IGangLaunchpad.Slippage.selector);
        hop.gangHop(t, out, funds + 1);

        vm.prank(owner);
        pad.setWalletCapEnabled(false);
        address bob = _newAgent();
        vm.deal(bob, 30 ether);
        vm.prank(bob, bob);
        pad3.buyTokenAMAP{value: 30 ether}(t, bob, 30 ether, 0);
        vm.prank(alice, alice);
        vm.expectRevert(IGangLaunchpad3.NotCurveToken.selector);
        hop.gangHop(t, out, 0);
    }
}
