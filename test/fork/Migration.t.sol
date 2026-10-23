// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Launchpad} from "../../src/Launchpad.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {Migrator} from "../../src/Migrator.sol";
import {IPancakeFactory, IPancakePair, IWBNB} from "../../src/interfaces/IPancake.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @dev Runs only when BSC_RPC_URL is set: forge test --match-path 'test/fork/*'
contract MigrationForkTest is Test {
    address constant FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73; // PancakeSwap V2
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address constant AGENT_ID = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F; // SPACE ID Agent ID (.ai)
    address constant REAL_AGENT = 0x562bbfBf922e20fE8E5BDEaD76546fAC14E0D571; // holds lazy.ai

    Launchpad pad;
    Migrator migrator;
    LaunchToken tok;
    address alice = makeAddr("alice");

    function setUp() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        pad = new Launchpad(address(this), makeAddr("vault"), AGENT_ID);
        migrator = new Migrator(FACTORY, WBNB, address(pad));
        pad.setMigrator(address(migrator));
        pad.setDev(address(this), true);
        tok = LaunchToken(pad.create("Gang Fork", "CFK"));
        vm.deal(alice, 100 ether);
    }

    /// @dev Pretend `who` holds an Agent ID on the real registry (fork-only shortcut).
    function _buyFrom(address who, uint256 value) internal {
        vm.mockCall(AGENT_ID, abi.encodeWithSelector(IERC721.balanceOf.selector, who), abi.encode(uint256(1)));
        vm.deal(who, value);
        vm.prank(who);
        pad.buy{value: value}(address(tok), 0);
    }

    /// @dev 80 agent wallets x 1% each fills the curve to graduation.
    function _fillCurve() internal {
        for (uint256 i; i < 100; i++) {
            (,,, bool graduated,) = pad.curves(address(tok));
            if (graduated) break;
            _buyFrom(address(uint160(0xF0000 + i)), 2 ether);
        }
    }

    function test_realAgentId_gatesBuy() public {
        if (address(pad) == address(0)) return;
        assertTrue(pad.isAgent(REAL_AGENT));
        assertFalse(pad.isAgent(alice));

        vm.deal(REAL_AGENT, 1 ether);
        vm.prank(REAL_AGENT);
        uint256 out = pad.buy{value: 0.5 ether}(address(tok), 0);
        assertGt(out, 0);

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(Launchpad.NotAgent.selector);
        pad.buy{value: 0.5 ether}(address(tok), 0);
    }

    function test_graduation_createsPancakePairAndBurnsLp() public {
        if (address(pad) == address(0)) return;
        _fillCurve();

        (,,, bool graduated, address pair) = pad.curves(address(tok));
        assertTrue(graduated);
        assertEq(pair, IPancakeFactory(FACTORY).getPair(address(tok), WBNB));

        (uint112 r0, uint112 r1,) = IPancakePair(pair).getReserves();
        uint256 tokRes = address(tok) < WBNB ? r0 : r1;
        uint256 bnbRes = address(tok) < WBNB ? r1 : r0;
        assertEq(bnbRes, 20 ether);
        assertApproxEqAbs(tokRes, 200_000_000 ether, 1e9);

        // LP burned, nothing left behind
        assertEq(IPancakePair(pair).balanceOf(DEAD), IPancakePair(pair).totalSupply() - 1000);
        assertEq(IERC20(address(tok)).balanceOf(address(migrator)), 0);
        assertEq(address(migrator).balance, 0);
        assertEq(IERC20(address(tok)).balanceOf(address(pad)), 0);

        // pool price == curve end price: 1e-7 BNB per token
        assertApproxEqRel(bnbRes * 1 ether / tokRes, 1e11, 1e12);

        // token is freely transferable now
        address w0 = address(uint160(0xF0000));
        vm.prank(w0);
        tok.transfer(address(0xCAFE), 1 ether);
    }

    function test_graduation_survivesWbnbDonationGriefing() public {
        if (address(pad) == address(0)) return;
        // Griefer pre-creates the pair, donates WBNB and syncs, which would brick router.addLiquidity
        address pair = IPancakeFactory(FACTORY).createPair(address(tok), WBNB);
        address griefer = makeAddr("griefer");
        vm.deal(griefer, 1 ether);
        vm.startPrank(griefer);
        IWBNB(WBNB).deposit{value: 1 ether}();
        IWBNB(WBNB).transfer(pair, 1 ether);
        (bool ok,) = pair.call(abi.encodeWithSignature("sync()"));
        require(ok);
        vm.stopPrank();

        _fillCurve();
        (,,, bool graduated, address p) = pad.curves(address(tok));
        assertTrue(graduated);
        assertEq(p, pair);
        (uint112 r0, uint112 r1,) = IPancakePair(pair).getReserves();
        uint256 bnbRes = address(tok) < WBNB ? r1 : r0;
        assertEq(bnbRes, 21 ether); // donation became burned liquidity
    }
}
