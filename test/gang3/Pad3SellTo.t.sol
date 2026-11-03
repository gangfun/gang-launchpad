// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";
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

/// @dev A listed router that keeps what it receives for anyone to sweep (pay-to review M): it must never receive a
///      seller's direct pay-to call.
contract SweepableRouter {
    receive() external payable {}

    function sweep(address to) external {
        (bool ok,) = to.call{value: address(this).balance}("");
        require(ok);
    }
}

/// @dev A `to` that reenters the pad on the BNB it receives, or refuses BNB.
contract ReenteringRouter {
    GangLaunchpad3 public immutable entry;
    bool public refuse;
    address internal token;

    constructor(GangLaunchpad3 entry_) {
        entry = entry_;
    }

    function setRefuse(bool r) external {
        refuse = r;
    }

    function gangHop(address t, uint256 amount) external returns (uint256) {
        token = t;
        return entry.sellToken(0, t, msg.sender, address(this), amount, 0);
    }

    receive() external payable {
        require(!refuse, "no BNB");
        entry.sellToken(0, token, tx.origin, address(this), 1e18, 0);
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

    /// @dev Pay-to review M: a seller's direct call cannot park the proceeds on a listed contract (one with an open
    ///      sweep would hand them to anyone); `to` must be the calling contract itself.
    function test_sellTo_userDirect_refused() public {
        (address t, uint256 out) = _bought(address(wbnb), 0.01 ether);
        SweepableRouter sweepable = new SweepableRouter();
        vm.prank(owner);
        pad3.setCaller(address(sweepable), true);
        vm.prank(alice, alice);
        vm.expectRevert(IGangLaunchpad3.RecipientNotListed.selector);
        pad3.sellToken(0, t, alice, address(sweepable), out, 0);
        vm.prank(alice, alice);
        vm.expectRevert(IGangLaunchpad3.RecipientNotListed.selector);
        pad3.sellToken(0, t, alice, address(hop), out, 0);
        assertEq(IERC20(t).balanceOf(alice), out, "nothing sold");
    }

    /// @dev Only a listed contract receives: an unlisted router (even called by the seller), an EOA, the pad itself.
    function test_sellTo_recipientMustBeListed() public {
        (address t, uint256 out) = _bought(address(wbnb), 0.01 ether);
        MultiHopRouter other = new MultiHopRouter(pad3);
        vm.prank(alice, alice);
        vm.expectRevert(IGangLaunchpad3.RecipientNotListed.selector);
        other.gangHop(t, out, 0); // unlisted caller paying itself
        vm.prank(alice, alice);
        vm.expectRevert(IGangLaunchpad3.RecipientNotListed.selector);
        hop.gangHopTo(t, address(other), out); // listed caller, unlisted recipient
        vm.prank(owner);
        pad3.setCaller(address(other), true);
        vm.prank(alice, alice);
        vm.expectRevert(IGangLaunchpad3.RecipientNotListed.selector);
        hop.gangHopTo(t, address(other), out); // listed caller, ANOTHER listed recipient
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

    /// @dev `to` gets native BNB after the books are final; reentering from it, or refusing BNB, reverts the whole sell.
    function test_sellTo_toReentersOrRefuses_reverts() public {
        (address t, uint256 out) = _bought(address(wbnb), 0.02 ether);
        ReenteringRouter r = new ReenteringRouter(pad3);
        vm.prank(owner);
        pad3.setCaller(address(r), true);
        vm.prank(alice, alice);
        vm.expectRevert(IGangLaunchpad3.BnbTransferFailed.selector);
        r.gangHop(t, out / 2);
        r.setRefuse(true);
        vm.prank(alice, alice);
        vm.expectRevert(IGangLaunchpad3.BnbTransferFailed.selector);
        r.gangHop(t, out / 2);
        assertEq(IERC20(t).balanceOf(alice), out, "nothing sold");
        _solvent(t, address(wbnb));
    }

    /// @dev The event names the seller, the recipient (= the caller) and the amounts, in the declared order.
    function test_sellTo_eventFields() public {
        (address t, uint256 out) = _bought(address(wbnb), 0.01 ether);
        (,, uint256 funds,) = pad3.trySell(t, out);
        vm.recordLogs();
        vm.prank(alice, alice);
        hop.gangHop(t, out, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 n;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] != IGangLaunchpad3.GatewaySellTo.selector) continue;
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(t))));
            assertEq(logs[i].topics[2], bytes32(uint256(uint160(alice))), "trader");
            assertEq(logs[i].topics[3], bytes32(uint256(uint160(address(hop)))), "to");
            (address caller, uint256 amount, uint256 f) = abi.decode(logs[i].data, (address, uint256, uint256));
            assertEq(caller, address(hop));
            assertEq(amount, out);
            assertEq(f, funds);
            n++;
        }
        assertEq(n, 1);
    }

    function test_sellTo_zeroAndFairTokens() public {
        (address t,) = _bought(address(wbnb), 0.01 ether);
        vm.prank(alice, alice);
        vm.expectRevert(IGangLaunchpad.ZeroAmount.selector);
        hop.gangHop(t, 0, 0);
        address f = _createFair(alice, address(wbnb), 1);
        vm.prank(alice, alice);
        vm.expectRevert(IGangLaunchpad3.NotCurveToken.selector);
        hop.gangHop(f, 1e18, 0);
    }
}
