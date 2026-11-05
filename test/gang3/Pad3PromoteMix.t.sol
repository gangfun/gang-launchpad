// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GangLaunchpad} from "../../src/gang/GangLaunchpad.sol";
import {GangLaunchpad3} from "../../src/gang/GangLaunchpad3.sol";
import {Pad3Module} from "../../src/gang/Pad3Module.sol";
import {GangFixture} from "../utils/GangFixture.sol";

/// @notice The pad's balance == its books, per quote, with promote / plain curves on two quotes and a 打新 sale, across trades on every
/// entry, both claims, windows ending and graduations.
contract Pad3PromoteMixTest is GangFixture {
    GangLaunchpad3 internal pad3;
    Pad3Module internal pm;
    address internal creator;
    address[2] internal ps;
    address[5] internal toks; // 0,1 promote (wbnb, erc20); 2,3 plain (wbnb, erc20); 4 fair (wbnb)
    address[3] internal us;

    function _newPad() internal override returns (GangLaunchpad) {
        return _newPad3();
    }

    function setUp() public {
        _deployGang(address(this));
        pad3 = GangLaunchpad3(payable(address(pad)));
        pm = Pad3Module(payable(address(pad)));
        creator = _newAgent();
        ps = [_newAgent(), _newAgent()];
        vm.startPrank(creator);
        toks[0] = pm.createWithPromote(
            "a", "a", "l", "m", address(wbnb), address(0), _tax(0, 0, 0, address(0)), 6 ether, 5_000, 7 days
        );
        toks[1] = pm.createWithPromote(
            "b", "b", "l", "m", address(quoteTok), address(0), _tax(300, 300, 10_000, address(0)), 6 ether, 1, 90 days
        );
        toks[2] = pad3.createWithGradTarget(
            "c", "c", "l", "m", address(wbnb), address(0), _tax(0, 0, 0, address(0)), 6 ether
        );
        toks[3] = pad3.createWithGradTarget(
            "d", "d", "l", "m", address(quoteTok), address(0), _tax(0, 0, 0, address(0)), 6 ether
        );
        vm.stopPrank();
        toks[4] = _createFair(creator, address(wbnb), 1);
        us = [_newAgent(), _newAgent(), _newAgent()];
        for (uint256 i; i < 3; i++) {
            vm.startPrank(us[i]);
            for (uint256 j; j < 4; j++) {
                IERC20(toks[j]).approve(address(pad), type(uint256).max);
            }
            vm.stopPrank();
        }
    }

    function _books() internal view returns (uint256 w, uint256 q) {
        for (uint256 j; j < 4; j++) {
            uint256 b = _curveRealQuote(toks[j]) + pad.creatorFeeOf(toks[j]) + pm.promoterFeeOf(toks[j], ps[0])
                + pm.promoterFeeOf(toks[j], ps[1]);
            if (j % 2 == 0) w += b;
            else q += b;
        }
        if (!_launched(toks[4])) w += uint256(_saleSold(toks[4])) * _sharePrice(toks[4]);
        w += pad.owedFee(address(wbnb));
    }

    function _check() internal view {
        (uint256 w, uint256 q) = _books();
        assertGe(wbnb.balanceOf(address(pad)), w, "WBNB below books");
        assertLe(wbnb.balanceOf(address(pad)) - w, 10, "WBNB dust");
        assertGe(quoteTok.balanceOf(address(pad)), q, "quote below books");
        assertLe(quoteTok.balanceOf(address(pad)) - q, 10, "quote dust");
        assertEq(address(pad).balance, 0, "no BNB");
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_mix(uint256 seed) public {
        for (uint256 k; k < 40; k++) {
            uint256 r = uint256(keccak256(abi.encode(seed, k)));
            address u = us[r % 3];
            uint256 ti = (r >> 8) % 4;
            address t = toks[ti];
            address p = ps[(r >> 12) % 2];
            uint256 amt = ((r >> 16) % 0.2 ether) + 1;
            bool native = ti % 2 == 0;
            uint256 op = (r >> 80) % 9;
            if (_graduated(t) && op < 5) continue;
            if (op == 0) {
                vm.deal(u, amt);
                vm.prank(u, u);
                try pm.buyWithPromoter{value: native ? amt : 0}(t, amt, 0, p) {} catch {}
            } else if (op == 1) {
                vm.deal(u, amt);
                vm.prank(u, u);
                try pad3.buyTokenAMAP{value: native ? amt : 0}(t, u, amt, 0) {} catch {}
            } else if (op == 2) {
                vm.prank(u);
                try pad.buy(t, amt, 0) {} catch {}
            } else if (op == 3 || op == 4) {
                uint256 bal = IERC20(t).balanceOf(u);
                if (bal == 0) continue;
                uint256 a = ((r >> 120) % bal) + 1;
                vm.prank(u, u);
                if (op == 3) {
                    pad.sell(t, a, 0); // a sell must not revert here: no try
                } else {
                    pad3.sellToken(0, t, u, a, 0, (r >> 200) % 501, address(0xFEE));
                }
            } else if (op == 5) {
                if (pm.promoterFeeOf(t, p) == 0) continue;
                vm.prank(p);
                pm.claimPromoterFee(t, p);
            } else if (op == 6) {
                if (pad.creatorFeeOf(t) == 0) continue;
                vm.prank(creator);
                pad.claimCreatorFee(t, creator);
            } else if (op == 7) {
                vm.warp(block.timestamp + ((r >> 96) % 20 days));
            } else {
                if ((r >> 200) % 8 == 0 && !_graduated(t)) {
                    _graduate(t);
                } else {
                    vm.prank(u);
                    try pad.mint(toks[4], (r >> 120) % 20 + 1, 0) {} catch {}
                }
            }
            _check();
        }
    }

    function test_blockedPromoter_neverBlocksTrade() public {
        vm.prank(creator);
        address t = pm.createWithPromote(
            "b", "b", "l", "m", address(blq), address(0), _tax(0, 0, 0, address(0)), 6 ether, 5_000, 7 days
        );
        address u = _newAgent();
        vm.prank(u);
        IERC20(t).approve(address(pad), type(uint256).max);
        vm.prank(u, u);
        pm.buyWithPromoter(t, 0.1 ether, 0, ps[0]);
        blq.setBlocked(ps[0], true);
        uint256 bal = IERC20(t).balanceOf(u);
        vm.prank(u, u);
        pad.sell(t, bal / 2, 0);
        vm.prank(u, u);
        pad.buy(t, 0.01 ether, 0);
        vm.prank(ps[0]);
        vm.expectRevert();
        pm.claimPromoterFee(t, ps[0]);
        vm.prank(ps[0]);
        pm.claimPromoterFee(t, address(0xFEE));
        assertGt(blq.balanceOf(address(0xFEE)), 0);
    }
}
