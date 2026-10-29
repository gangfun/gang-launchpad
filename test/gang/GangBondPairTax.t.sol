// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GangFixture} from "../utils/GangFixture.sol";
import {TwapMockPairFactory} from "../mocks/TwapMockPair.sol";
import {GangBond} from "../../src/gang/GangBond.sol";
import {IGangBond} from "../../src/gang/interfaces/IGangBond.sol";

/// @dev An 18-decimal quote that charges 5% on transfers INTO addresses its owner marked as AMM pairs (a common BSC
///      pattern). The pull into GangBond is untaxed, so `post` accepts it.
contract PairTaxQuote is ERC20("PairTax", "PTAX") {
    mapping(address => bool) public isPair;

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setPair(address p, bool v) external {
        isPair[p] = v;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (isPair[to] && from != address(0)) {
            uint256 fee = value / 20;
            super._update(from, address(0xfee), fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}

/// @notice Re-review L-1 (2026-10-29): `burnChunk` prices what the pair actually received, so a quote that taxes
///         transfers into pairs still buys back to the end and the token can be bonded again.
contract GangBondPairTaxTest is GangFixture {
    GangBond bond;
    address keeper = makeAddr("keeper");
    address reporter = makeAddr("reporter");
    PairTaxQuote ptax;

    function _newPairFactory() internal override returns (address) {
        return address(new TwapMockPairFactory());
    }

    function _onNewAgent(address who) internal override {
        if (address(ptax) == address(0)) return;
        ptax.mint(who, 1_000 ether);
        vm.prank(who);
        ptax.approve(address(pad), type(uint256).max);
    }

    function setUp() public {
        _deployGang(keeper);
        bond = new GangBond(address(pad), address(wbnb));
    }

    function _next(uint256 dt) internal {
        vm.warp(vm.getBlockTimestamp() + dt);
        vm.roll(block.number + 1);
    }

    function test_pairTaxQuote_buysBackToTheEnd() public {
        ptax = new PairTaxQuote();
        vm.prank(owner);
        quoteRegistry.setQuote(address(ptax), true, 15 ether);

        address creator = _newAgent();
        address t = _createV3(creator, address(ptax), _tax(0, 0, 0, address(0)));
        vm.prank(creator);
        pad.buy(t, 1 ether, 0);
        _graduate(t);
        (,,,,,,,,,, address pair,) = pad.curves(t);
        ptax.setPair(pair, true);

        uint256 hold = IERC20(t).balanceOf(creator) / 2;
        address elsewhere = makeAddr("elsewhere");
        vm.startPrank(creator);
        ptax.approve(address(bond), type(uint256).max);
        bond.post(t, 1 ether, hold, 7 days);
        IERC20(t).transfer(elsewhere, hold + 1);
        vm.stopPrank();
        vm.prank(reporter);
        bond.report(t);

        uint256 deadBefore = IERC20(t).balanceOf(bond.DEAD());
        uint256 chunks;
        for (uint256 i = 0; i < 288 && bond.bondOf(t).burnLeft != 0; i++) {
            (uint256 q, uint256 burned) = bond.burnChunk(t, 0);
            if (q != 0) {
                assertGt(burned, 0, "each chunk buys");
                chunks++;
            }
            _next(5 minutes);
        }
        assertGt(chunks, 1);
        assertEq(bond.bondOf(t).burnLeft, 0, "bought back to the end");
        assertGt(IERC20(t).balanceOf(bond.DEAD()), deadBefore);
        assertEq(ptax.balanceOf(address(bond)), 0, "no quote left behind");

        vm.prank(elsewhere);
        IERC20(t).transfer(creator, hold + 1);
        vm.prank(creator);
        bond.post(t, 1 ether, hold, 7 days);
        assertEq(uint8(bond.bondOf(t).state), uint8(IGangBond.State.Active));
    }
}
