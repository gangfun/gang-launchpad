// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MerkleQuoteDistributor} from "../../src/remedy/MerkleQuoteDistributor.sol";

contract MockQuote is ERC20 {
    constructor() ERC20("Q", "Q") {
        _mint(msg.sender, 1e30);
    }
}

contract MerkleQuoteDistributorTest is Test {
    MerkleQuoteDistributor dist;
    MockQuote q;
    address owner = makeAddr("owner");
    address funder = makeAddr("funder");
    address token = makeAddr("token");
    address a = makeAddr("a");
    address b = makeAddr("b");
    address c = makeAddr("c");
    bytes32[3] leaves;
    bytes32 root;

    function _leaf(uint256 i, address acct, uint256 amt) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(i, acct, amt))));
    }

    function _h(bytes32 x, bytes32 y) internal pure returns (bytes32) {
        return x < y ? keccak256(abi.encode(x, y)) : keccak256(abi.encode(y, x));
    }

    function setUp() public {
        dist = new MerkleQuoteDistributor(owner);
        q = new MockQuote();
        q.transfer(funder, 1e24);
        vm.prank(owner);
        dist.setFunder(funder, true);
        leaves[0] = _leaf(0, a, 100);
        leaves[1] = _leaf(1, b, 200);
        leaves[2] = _leaf(2, c, 300);
        // tree: ((l0, l1), l2) — the odd leaf is carried up, as tools/remedy/merkle does
        root = _h(_h(leaves[0], leaves[1]), leaves[2]);
    }

    function _fund(uint256 amt) internal {
        vm.startPrank(funder);
        q.approve(address(dist), amt);
        dist.fund(token, address(q), amt);
        vm.stopPrank();
    }

    function test_claim_flow_and_sweep() public {
        _fund(650);
        vm.prank(owner);
        vm.expectRevert(MerkleQuoteDistributor.Underfunded.selector);
        dist.setRoot(token, root, 651, uint64(block.timestamp + 30 days));
        vm.prank(owner);
        dist.setRoot(token, root, 600, uint64(block.timestamp + 30 days));

        bytes32[] memory pa = new bytes32[](2);
        pa[0] = leaves[1];
        pa[1] = leaves[2];
        dist.claim(token, 0, a, 100, pa); // anyone may submit; a is paid
        assertEq(q.balanceOf(a), 100);
        vm.expectRevert(MerkleQuoteDistributor.AlreadyClaimed.selector);
        dist.claim(token, 0, a, 100, pa);
        vm.expectRevert(MerkleQuoteDistributor.BadProof.selector);
        dist.claim(token, 1, b, 999, pa);

        bytes32[] memory pc = new bytes32[](1);
        pc[0] = _h(leaves[0], leaves[1]);
        dist.claim(token, 2, c, 300, pc);
        assertEq(q.balanceOf(c), 300);

        vm.prank(owner);
        vm.expectRevert(MerkleQuoteDistributor.NotExpired.selector);
        dist.sweep(token, owner);
        vm.warp(block.timestamp + 31 days);
        bytes32[] memory pb = new bytes32[](2);
        pb[0] = leaves[0];
        pb[1] = leaves[2];
        vm.expectRevert(MerkleQuoteDistributor.Expired.selector);
        dist.claim(token, 1, b, 200, pb);
        vm.prank(owner);
        dist.sweep(token, owner);
        assertEq(q.balanceOf(owner), 650 - 400, "b's unclaimed 200 + 50 dust");
    }

    function test_onlyFunder_quoteFixed_rootOnce() public {
        vm.expectRevert(MerkleQuoteDistributor.OnlyFunder.selector);
        dist.fund(token, address(q), 1);
        _fund(10);
        MockQuote other = new MockQuote();
        vm.prank(funder);
        vm.expectRevert(MerkleQuoteDistributor.QuoteMismatch.selector);
        dist.fund(token, address(other), 1);
        vm.startPrank(owner);
        dist.setRoot(token, root, 10, uint64(block.timestamp + 1 days));
        vm.expectRevert(MerkleQuoteDistributor.RootAlreadySet.selector);
        dist.setRoot(token, root, 10, uint64(block.timestamp + 1 days));
        vm.stopPrank();
        vm.prank(a);
        vm.expectRevert();
        dist.setFunder(a, true);
    }
}
