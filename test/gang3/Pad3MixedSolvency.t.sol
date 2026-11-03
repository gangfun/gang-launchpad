// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CurveLogic3ParityTest} from "./Pad3EntryParity.t.sol";

/// @notice Audit 3A: random mixes of direct and entry trades on several curves (both quotes, a dividend token), creator
///         claims and 打新 mints sharing the pad: the pad never falls below its books, keeps no BNB, and every live
///         curve's unsold tokens equal TOTAL_SUPPLY - sold.
contract Pad3MixedSolvencyTest is CurveLogic3ParityTest {
    address[4] internal toks;
    address[3] internal users;
    uint256 public okEntry;

    function _setUpMix() internal {
        toks[0] = _createV3(alice, address(wbnb), _tax(0, 0, 0, address(0)));
        toks[1] = _createV3(alice, address(quoteTok), _tax(0, 0, 0, address(0)));
        toks[2] = _createV3(alice, address(wbnb), _tax(300, 300, 10_000, address(0)));
        toks[3] = _createFair(alice, address(wbnb), 1);
        for (uint256 i; i < 3; i++) {
            users[i] = _newAgent();
            vm.startPrank(users[i]);
            for (uint256 j; j < 3; j++) {
                IERC20(toks[j]).approve(address(pad), type(uint256).max);
            }
            vm.stopPrank();
        }
    }

    function testFuzz_mixedOps(uint256 seed) public {
        _setUpMix();
        for (uint256 k; k < 24; k++) {
            uint256 r = uint256(keccak256(abi.encode(seed, k)));
            address u = users[r % 3];
            uint256 ti = (r >> 8) % 3;
            address t = toks[ti];
            uint256 amt = (r >> 16) % 0.05 ether + 1;
            uint256 op = (r >> 80) % 6;
            if (_graduated(t)) continue;
            bool erc20 = ti == 1;
            if (op == 0) {
                vm.prank(u);
                try pad.buy(t, amt, 0) {} catch {}
            } else if (op == 1) {
                vm.deal(u, amt);
                vm.prank(u, u);
                try pad3.buyTokenAMAP{value: erc20 ? 0 : amt}(t, u, amt, 0) {
                    okEntry++;
                } catch {}
            } else if (op == 2 || op == 3) {
                uint256 bal = IERC20(t).balanceOf(u);
                if (bal == 0) continue;
                uint256 a = ((r >> 120) % bal) + 1;
                vm.prank(u, u);
                if (op == 2) {
                    try pad.sell(t, a, 0) {} catch {}
                } else {
                    try pad3.sellToken(0, t, u, a, 0, (r >> 200) % 501, feeTo) {
                        okEntry++;
                    } catch {}
                }
            } else if (op == 4) {
                if (pad.creatorFeeOf(t) == 0) continue;
                vm.prank(alice);
                pad.claimCreatorFee(t, alice);
            } else {
                vm.prank(u);
                try pad.mint(toks[3], (r >> 120) % 20 + 1, 0) {} catch {}
            }
            _assertAll();
        }
    }

    function _assertAll() internal view {
        (uint256 wantW, uint256 wantQ) = _books();
        // live 打新 escrow (sold × price) on WBNB
        if (!_launched(toks[3])) wantW += uint256(_saleSold(toks[3])) * _sharePrice(toks[3]);
        wantW += pad.owedFee(address(wbnb));
        assertGe(wbnb.balanceOf(address(pad)), wantW, "WBNB books");
        assertLe(wbnb.balanceOf(address(pad)) - wantW, 10, "WBNB dust");
        assertGe(quoteTok.balanceOf(address(pad)), wantQ, "quote books");
        assertLe(quoteTok.balanceOf(address(pad)) - wantQ, 10, "quote dust");
        assertEq(address(pad).balance, 0, "no BNB");
        for (uint256 j; j < 3; j++) {
            address t = toks[j];
            if (!_graduated(t)) {
                assertEq(IERC20(t).balanceOf(address(pad)), TOTAL_SUPPLY - _curveSold(t), "unsold tokens");
            }
        }
    }
}

contract Pad3MixedCoverageTest is Pad3MixedSolvencyTest {
    /// @dev the mix really exercises the entry (small amounts keep wallets under the 1% cap)
    function test_mixedOps_coverage() public {
        uint256 total;
        for (uint256 s; s < 5; s++) {
            okEntry = 0;
            uint256 snap = vm.snapshotState();
            testFuzz_mixedOps(s);
            total += okEntry;
            vm.revertToState(snap);
        }
        emit log_named_uint("entry trades ok over 5 seeds", total);
        assertGt(total, 10);
    }
}
