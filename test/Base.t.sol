// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Launchpad} from "../src/Launchpad.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {MockMigrator} from "./mocks/MockMigrator.sol";
import {MockAgentId} from "./mocks/MockAgentId.sol";

abstract contract BaseTest is Test {
    Launchpad internal pad;
    MockMigrator internal mockMigrator;
    MockAgentId internal agentId;
    LaunchToken internal tok;

    address internal owner = makeAddr("owner");
    address internal vault = makeAddr("vault");
    address internal alice = makeAddr("alice"); // agent
    address internal bob = makeAddr("bob"); // agent
    address internal agent = makeAddr("agent"); // agent
    address internal human = makeAddr("human"); // no Agent ID

    uint256 internal nextId = 1;

    function setUp() public virtual {
        agentId = new MockAgentId();
        pad = new Launchpad(owner, vault, address(agentId));
        mockMigrator = new MockMigrator();
        vm.startPrank(owner);
        pad.setMigrator(address(mockMigrator));
        // Pack source: create is BAW Dev allowlist. The test contract deploys curves.
        pad.setDev(address(this), true);
        vm.stopPrank();
        _mintAgent(alice);
        _mintAgent(bob);
        _mintAgent(agent);
        tok = LaunchToken(pad.create("Gang Test", "GTT"));
        vm.deal(alice, 1000 ether);
        vm.deal(bob, 1000 ether);
        vm.deal(agent, 1000 ether);
        vm.deal(human, 1000 ether);
    }

    function _mintAgent(address who) internal {
        agentId.mint(who, nextId++);
    }

    function _buy(address buyer, uint256 value) internal returns (uint256 out) {
        vm.prank(buyer);
        out = pad.buy{value: value}(address(tok), 0);
    }

    function _buyAsAgent(address buyer, uint256 value) internal returns (uint256 out) {
        return _buy(buyer, value);
    }

    /// @dev Fills the curve to graduation with fresh agent wallets (each capped at 1%). Returns wallets used.
    function _fillCurve() internal returns (uint256 n) {
        for (n = 0; n < 200 && !_graduated(); n++) {
            address w = address(uint160(0xA0000 + n));
            _mintAgent(w);
            vm.deal(w, 10 ether);
            vm.prank(w);
            pad.buy{value: 2 ether}(address(tok), 0);
        }
    }

    function _sell(address seller, uint256 amount) internal returns (uint256 out) {
        vm.startPrank(seller);
        tok.approve(address(pad), amount);
        out = pad.sell(address(tok), amount, 0);
        vm.stopPrank();
    }

    function _realBnb() internal view returns (uint256 r) {
        (, r,,,) = pad.curves(address(tok));
    }

    function _sold() internal view returns (uint256 s) {
        (,, s,,) = pad.curves(address(tok));
    }

    function _graduated() internal view returns (bool g) {
        (,,, g,) = pad.curves(address(tok));
    }
}
