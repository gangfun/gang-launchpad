// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GangLaunchpad} from "../../src/gang/GangLaunchpad.sol";
import {GangLaunchpad3} from "../../src/gang/GangLaunchpad3.sol";
import {IGangLaunchpad3} from "../../src/gang/interfaces/IGangLaunchpad3.sol";
import {GangFixture} from "../utils/GangFixture.sol";
import {PointingToken} from "../router/GangGateway.t.sol";

/// @dev A registered pad that takes nothing it was approved for and leaves the funds with the caller (here, 3.0).
contract LazyPad {
    uint256 public constant VIRTUAL_TOKEN = 1_066_666_666_666_666_666_666_666_667;
    uint256 public constant PROTOCOL_FEE_BPS = 100;
    address public immutable wbnb;
    mapping(address => uint8) public kindOf;

    constructor(address wbnb_) {
        wbnb = wbnb_;
    }

    function list(address token) external {
        kindOf[token] = 1;
    }

    function curves(address)
        external
        view
        returns (address, address, uint128, uint128, uint128, uint128, bool, uint16, uint16, uint16, address, address)
    {
        return (address(this), wbnb, 0, 1e18, 0, 0, false, 0, 0, 0, address(0), address(0));
    }

    function routers(address) external pure returns (bool) {
        return true;
    }

    function agentGateEnabled() external pure returns (bool) {
        return true;
    }

    function buyFor(address, address, uint256, uint256) external pure returns (uint256) {
        return 0;
    }

    function sellFor(address, address, uint256, uint256) external pure returns (uint256) {
        return 0;
    }
}

/// @notice GangLaunchpad 3.0's own additions to the aggregator entry: the escrow guard on forwarded trades, the
///         `TradeV1` event, and the sell-caller whitelist's owner. (Everything the entry shares with GangGateway is
///         test/gang3/Pad3AsGateway.t.sol.)
contract Pad3EntryTest is GangFixture {
    GangLaunchpad3 internal pad3;
    address internal alice;
    address internal bob;

    function _newPad() internal override returns (GangLaunchpad) {
        return _newPad3();
    }

    function setUp() public {
        _deployGang(address(this));
        pad3 = GangLaunchpad3(payable(address(pad)));
        alice = _newAgent();
        bob = _newAgent();
    }

    // ---------------------------------------------------------------- escrow guard
    /// @dev A forwarded buy whose pad leaves the funds on 3.0 would mix them into 3.0's escrow: refused, nothing moves.
    function test_forward_padThatTakesNothing_EscrowMoved() public {
        // 3.0 holds escrow of its own token first
        address own = _createV3(alice, address(wbnb), _tax(0, 0, 0, address(0)));
        vm.prank(bob);
        pad.buy(own, 1 ether, 0);
        uint256 escrow = wbnb.balanceOf(address(pad));

        LazyPad lazy = new LazyPad(address(wbnb));
        vm.prank(owner);
        padRegistry3.addPad(address(lazy));
        PointingToken fake = new PointingToken(address(lazy));
        lazy.list(address(fake));

        vm.prank(bob, bob);
        vm.expectRevert(IGangLaunchpad3.EscrowMoved.selector);
        pad3.buyTokenAMAP{value: 0.5 ether}(address(fake), bob, 0.5 ether, 0);
        assertEq(wbnb.balanceOf(address(pad)), escrow);
        assertEq(address(pad).balance, 0);
    }

    /// @dev Buys of 3.0's own tokens through the entry book exactly like a direct buy: same tokens, same curve state.
    function test_local_entryBuy_equalsDirectBuy() public {
        address t1 = _createV3(alice, address(wbnb), _tax(0, 0, 0, address(0)));
        address t2 = _createV3(alice, address(wbnb), _tax(0, 0, 0, address(0)));
        vm.prank(bob);
        uint256 direct = pad.buy(t1, 0.01 ether, 0);
        vm.prank(bob, bob);
        (uint256 viaEntry, uint256 used) = pad3.buyTokenAMAP{value: 0.01 ether}(t2, bob, 0.01 ether, 0);
        assertEq(viaEntry, direct);
        assertEq(used, 0.01 ether);
        (,, uint128 rq1, uint128 s1,,,,,,,,) = pad.curves(t1);
        (,, uint128 rq2, uint128 s2,,,,,,,,) = pad.curves(t2);
        assertEq(rq1, rq2);
        assertEq(s1, s2);
        assertEq(pad.creatorFeeOf(t1), pad.creatorFeeOf(t2));
    }

    // ---------------------------------------------------------------- TradeV1
    function test_tradeV1_buyAndSell() public {
        address t = _createV3(alice, address(wbnb), _tax(0, 0, 0, address(0)));
        uint256 gross = 0.01 ether;
        uint256 fee = gross / 100;
        uint256 creatorFee = (fee * 7000) / 10_000;
        (uint256 out,,,) = _quote(t, bob, gross);
        (,,,,, uint128 vq0,,,,,,) = _curveView(t);
        uint256 rqAfter = gross - fee;
        uint256 price = ((uint256(vq0) + rqAfter) * 1e18) / (pad.VIRTUAL_TOKEN() - out);
        vm.expectEmit(true, true, false, true, address(pad));
        emit IGangLaunchpad3.TradeV1(t, bob, true, gross, out, fee, creatorFee, price, rqAfter, out);
        vm.prank(bob);
        pad.buy(t, gross, 0);

        uint256 half = out / 2;
        (uint256 funds, uint256 sellFee) = _trySell(t, half);
        uint256 quoteOut = funds + sellFee;
        uint256 rq2 = rqAfter - quoteOut;
        uint256 price2 = ((uint256(vq0) + rq2) * 1e18) / (pad.VIRTUAL_TOKEN() - (out - half));
        vm.startPrank(bob);
        IERC20(t).approve(address(pad), type(uint256).max);
        vm.expectEmit(true, true, false, true, address(pad));
        emit IGangLaunchpad3.TradeV1(
            t, bob, false, quoteOut, half, sellFee, (sellFee * 7000) / 10_000, price2, rq2, out - half
        );
        pad.sell(t, half, 0);
        vm.stopPrank();
    }

    function _quote(address t, address who, uint256 funds)
        internal
        view
        returns (uint256 amount, uint256 cost, uint256 fee, uint256 amountFunds)
    {
        (,, amount, cost, fee,,, amountFunds) = pad3.tryBuy(t, who, 0, funds);
    }

    function _trySell(address t, uint256 amount) internal view returns (uint256 funds, uint256 fee) {
        (,, funds, fee) = pad3.trySell(t, amount);
    }

    function _curveView(address t)
        internal
        view
        returns (address, address, uint128, uint128, uint128, uint128, bool, uint16, uint16, uint16, address, address)
    {
        return pad.curves(t);
    }

    // ---------------------------------------------------------------- whitelist owner
    function test_setCaller_onlyOwner() public {
        PointingToken someContract = new PointingToken(address(0));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        pad3.setCaller(address(someContract), true);
        vm.expectEmit(true, false, false, true, address(pad));
        emit IGangLaunchpad3.CallerSet(address(someContract), true);
        vm.prank(owner);
        pad3.setCaller(address(someContract), true);
        assertTrue(pad3.isCaller(address(someContract)));
        vm.prank(owner);
        vm.expectRevert(IGangLaunchpad3.NotAContract.selector);
        pad3.setCaller(alice, true);
    }
}
