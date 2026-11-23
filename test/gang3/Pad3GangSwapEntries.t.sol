// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;
// GangSwap curve tokens through every entry (2026-11-22 integration review): graduation via buyTokenAMAP and GangRouter
// buyFor on an agent-window token, sells after graduation, a pre-graduation donation to the predicted
// pair, and a value-carrying createWithSalt.

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pad3GangSwapTest} from "./Pad3GangSwap.t.sol";
import {IGangSwapPad} from "../../src/gang/interfaces/IGangSwapPad.sol";
import {IGangAgentWindow} from "../../src/gang/interfaces/IGangAgentWindow.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {IGangLaunchpad3} from "../../src/gang/interfaces/IGangLaunchpad3.sol";
import {Pad3VanityDeployer} from "../../src/gang/Pad3VanityDeployer.sol";

interface IGSFactoryX {
    function INIT_CODE_PAIR_HASH() external view returns (bytes32);
    function getPair(address a, address b) external view returns (address);
}

contract Pad3GangSwapEntriesTest is Pad3GangSwapTest {
    function _windowGS() internal returns (address t) {
        _open();
        bytes memory data =
            abi.encodeCall(IGangSwapPad.createGangSwap, ("Swap", "GSW", "logo", "meta", 6 ether, m.gangSwapMigrator()));
        vm.prank(creator);
        t = IGangAgentWindow(address(pad)).createWithAgentWindow(1, data);
        vm.warp(block.timestamp + 2 minutes);
        assertTrue(IGangAgentWindow(address(pad)).agentWindowOpen(t));
    }

    function test_gradViaBuyTokenAMAP() public {
        address t = _windowGS();
        address w = _newAgent();
        vm.prank(w, w);
        (uint256 out, uint256 used) = p.buyTokenAMAP{value: 20 ether}(t, w, 20 ether, 0);
        assertTrue(_graduated(t));
        assertGt(out, 0);
        assertLt(used, 20 ether);
        (uint8 s,, address pr,,) = p.getTokenInfo(t);
        assertEq(s, 4);
        assertEq(pr, IGSFactoryX(address(gsFactory)).getPair(t, address(wbnb)));
        // refund of the cut went to w as WBNB
        assertGt(wbnb.balanceOf(w), 1_000 ether);
    }

    function test_gradViaRouterBuyFor() public {
        address t = _windowGS();
        address w = _newAgent();
        vm.prank(w, w);
        router.v3BuyBNB{value: 20 ether}(t, 0, block.timestamp);
        assertTrue(_graduated(t));
        (uint8 s,,,,) = p.getTokenInfo(t);
        assertEq(s, 4);
    }

    function test_sellsAfterGradHitPad() public {
        address t = _windowGS();
        address w = _newAgent();
        vm.prank(w, w);
        uint256 got = pad.buy(t, 1 ether, 0);
        _graduate(t);
        vm.startPrank(w, w);
        IERC20(t).approve(address(pad), type(uint256).max);
        vm.expectRevert();
        pad.sell(t, got, 0);
        vm.expectRevert(IGangLaunchpad3.NotCurveToken.selector);
        p.sellToken(0, t, w, got, 0, 0, address(0));
        vm.stopPrank();
    }

    /// @dev WBNB donated to the predicted GangSwap pair before graduation does not brick it.
    function test_donationBeforeGrad() public {
        _open();
        address t = _createGS(creator, 6 ether);
        (address a, address b) = t < address(wbnb) ? (t, address(wbnb)) : (address(wbnb), t);
        address predicted = address(
            uint160(
                uint256(
                    keccak256(
                        abi.encodePacked(
                            hex"ff",
                            address(gsFactory),
                            keccak256(abi.encodePacked(a, b)),
                            IGSFactoryX(address(gsFactory)).INIT_CODE_PAIR_HASH()
                        )
                    )
                )
            )
        );
        address d = _newAgent();
        vm.prank(d);
        wbnb.transfer(predicted, 50 ether);
        // tokens can't be sent there before graduation (locked)
        vm.prank(d, d);
        uint256 got = pad.buy(t, 0.1 ether, 0);
        vm.prank(d);
        vm.expectRevert();
        IERC20(t).transfer(predicted, got);
        _graduate(t);
        assertEq(_curvePair(t), predicted);
    }

    function test_abcdValueRejected() public {
        _open();
        Pad3VanityDeployer f = new Pad3VanityDeployer(address(pad), address(tokenDeployer), address(flyDeployer));
        vm.prank(owner);
        m.enableVanity(address(f));
        bytes memory data = abi.encodePacked(IGangSwapPad.createGangSwap.selector, new bytes(32 * 24));
        vm.deal(creator, creator.balance + 1);
        vm.prank(creator);
        (bool ok, bytes memory ret) = address(m).call{value: 1}(abi.encodeCall(m.createWithSalt, (bytes32(0), data)));
        assertFalse(ok);
        assertEq(ret.length, 0);
        vm.prank(creator);
        (ok, ret) = address(m).call(abi.encodeCall(m.createWithSalt, (bytes32(0), data)));
        assertTrue(ok || ret.length != 0);
    }
}
