// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {GangLaunchpad} from "../../src/gang/GangLaunchpad.sol";
import {GangLaunchpad3} from "../../src/gang/GangLaunchpad3.sol";
import {Pad3Module} from "../../src/gang/Pad3Module.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {IGangLaunchpad3} from "../../src/gang/interfaces/IGangLaunchpad3.sol";
import {SharedDividendVault} from "../../src/common/SharedDividendVault.sol";
import {GangFixture} from "../utils/GangFixture.sol";

/// quote with a hook on every transfer: calls whatever the attacker set, records the revert data
contract HookQuote is ERC20("Hook", "HOOK") {
    address public hookTarget;
    bytes public hookData;
    bytes public lastRet;
    bool public lastOk;
    uint256 public fired;
    bool internal inHook;

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }

    function arm(address t, bytes calldata d) external {
        hookTarget = t;
        hookData = d;
        fired = 0;
    }

    function _update(address f, address t, uint256 v) internal override {
        super._update(f, t, v);
        if (hookTarget != address(0) && !inHook) {
            inHook = true;
            (lastOk, lastRet) = hookTarget.call(hookData);
            fired++;
            inHook = false;
        }
    }
}

/// @notice The promoter share against the plain entry: the same trade on a token without a share, wei for wei, through
///         a cap cut, a graduation and random mixes; a quote that calls back into the pad; two quotes side by side.
contract Pad3PromoteParityTest is GangFixture {
    uint256 internal constant BPS = 10_000;
    GangLaunchpad3 internal pad3;
    Pad3Module internal pm;
    address internal creator;
    address internal promoter;

    function _newPad() internal override returns (GangLaunchpad) {
        return _newPad3();
    }

    function setUp() public {
        _deployGang(address(this));
        pad3 = GangLaunchpad3(payable(address(pad)));
        pm = Pad3Module(payable(address(pad)));
        creator = _newAgent();
        promoter = _newAgent();
    }

    function _p(address quote, uint16 share) internal returns (address t) {
        vm.prank(creator);
        t = pm.createWithPromote(
            "P", "P", "l", "m", quote, address(0), _tax(0, 0, 0, address(0)), 9 ether, share, 30 days
        );
    }

    function _plain(address quote) internal returns (address t) {
        vm.prank(creator);
        t = pad3.createWithGradTarget("P", "P", "l", "m", quote, address(0), _tax(0, 0, 0, address(0)), 9 ether);
    }

    // ---- entry parity: cap cut. Same state, buyWithPromoter on a promote token vs buyTokenAMAP on a plain one.
    function _parityCap(address q) internal {
        address a = _plain(q);
        address b = _p(q, 5_000);
        address u1 = _newAgent();
        address u2 = _newAgent();
        uint256 funds = 1 ether; // far above the 1% cap
        uint256 v = q == address(wbnb) ? funds : 0;
        uint256 q1 = IERC20(q).balanceOf(u1);
        uint256 q2 = IERC20(q).balanceOf(u2);
        uint256 bk = bucket.accruedQuote(q);
        vm.prank(u1, u1);
        (uint256 o1, uint256 used1) = pad3.buyTokenAMAP{value: v}(a, u1, funds, 0);
        uint256 bk1 = bucket.accruedQuote(q) - bk;
        vm.prank(u2, u2);
        (uint256 o2, uint256 used2) = pm.buyWithPromoter{value: v}(b, funds, 0, promoter);
        uint256 bk2 = bucket.accruedQuote(q) - bk - bk1;
        assertEq(o1, o2, "out");
        assertEq(used1, used2, "used");
        assertLt(used1, funds, "the cut really happened");
        assertEq(bk1, bk2, "platform");
        assertEq(_curveRealQuote(a), _curveRealQuote(b), "realQuote");
        assertEq(_curveSold(a), _curveSold(b), "sold");
        assertEq(pad.creatorFeeOf(a), pad.creatorFeeOf(b) + pm.promoterFeeOf(b, promoter), "70%");
        assertGt(pm.promoterFeeOf(b, promoter), 0);
        // refund to the wallet, same; the used figure == what the wallet saw
        uint256 r1 = IERC20(q).balanceOf(u1) + (q == address(wbnb) ? 0 : funds) - q1;
        uint256 r2 = IERC20(q).balanceOf(u2) + (q == address(wbnb) ? 0 : funds) - q2;
        assertEq(r1, r2, "refund");
        assertEq(used1 + r1, funds, "used+refund");
    }

    function test_parity_capCut_wbnb() public {
        _parityCap(address(wbnb));
    }

    function test_parity_capCut_erc20() public {
        _parityCap(address(quoteTok));
    }

    // ---- entry parity: graduation in the same buy, and the last buy over the cap too
    function _fillTo(address t, uint256 leaveAtLeast) internal {
        for (uint256 i; i < 400; i++) {
            uint256 grad = Pad3Module(payable(address(pad))).gradAmtOf(t);
            if (grad - _curveRealQuote(t) <= leaveAtLeast) break;
            address w = _newAgent();
            uint256 left = grad - _curveRealQuote(t) - leaveAtLeast;
            uint256 gross = left > 0.8 ether ? 1 ether : (left * 10_000) / 9_900;
            vm.prank(w);
            pad.buy(t, gross, 0);
        }
    }

    function _parityGrad(address q) internal {
        address a = _plain(q);
        address b = _p(q, 5_000);
        _fillTo(a, 0.02 ether);
        _fillTo(b, 0.02 ether);
        assertEq(_curveRealQuote(a), _curveRealQuote(b), "same start");
        assertFalse(_graduated(b));
        address u1 = _newAgent();
        address u2 = _newAgent();
        uint256 funds = 0.5 ether;
        uint256 v = q == address(wbnb) ? funds : 0;
        uint256 q1 = IERC20(q).balanceOf(u1);
        uint256 q2 = IERC20(q).balanceOf(u2);
        vm.prank(u1, u1);
        (uint256 o1, uint256 used1) = pad3.buyTokenAMAP{value: v}(a, u1, funds, 0);
        vm.prank(u2, u2);
        (uint256 o2, uint256 used2) = pm.buyWithPromoter{value: v}(b, funds, 0, promoter);
        assertTrue(_graduated(a), "a graduated");
        assertTrue(_graduated(b), "b graduated in the same buy");
        assertEq(o1, o2, "out");
        assertEq(used1, used2, "used");
        assertEq(
            IERC20(q).balanceOf(u1),
            q1 + (q == address(wbnb) ? funds - used1 : 0) - (q == address(wbnb) ? 0 : used1),
            "refund a"
        );
        assertEq(
            IERC20(q).balanceOf(u2),
            q2 + (q == address(wbnb) ? funds - used2 : 0) - (q == address(wbnb) ? 0 : used2),
            "refund b"
        );
        assertEq(pad.creatorFeeOf(a), pad.creatorFeeOf(b) + pm.promoterFeeOf(b, promoter), "70%");
        // books on the pad: only fees and known dust stay, and both claim
        uint256 owed = pm.promoterFeeOf(b, promoter);
        assertGt(owed, 0);
        vm.prank(promoter);
        pm.claimPromoterFee(b, promoter);
        vm.prank(creator);
        pad.claimCreatorFee(b, creator);
        vm.prank(creator);
        pad.claimCreatorFee(a, creator);
        assertLe(IERC20(q).balanceOf(address(pad)), 4, "dust only");
    }

    function test_parity_graduation_wbnb() public {
        _parityGrad(address(wbnb));
    }

    function test_parity_graduation_erc20() public {
        _parityGrad(address(quoteTok));
    }

    // ---- differential over a random mix: promote vs plain, identical to the wei for trader, curve, platform
    function testFuzz_diff_mix(uint256 seed, uint16 share) public {
        share = uint16(bound(share, 1, 5_000));
        address a = _plain(address(wbnb));
        address b = _p(address(wbnb), share);
        address[3] memory us = [_newAgent(), _newAgent(), _newAgent()];
        for (uint256 i; i < 3; i++) {
            vm.startPrank(us[i]);
            IERC20(a).approve(address(pad), type(uint256).max);
            IERC20(b).approve(address(pad), type(uint256).max);
            vm.stopPrank();
        }
        for (uint256 k; k < 40; k++) {
            uint256 r = uint256(keccak256(abi.encode(seed, k)));
            address u = us[r % 3];
            uint256 op = (r >> 8) % 4;
            uint256 amt = ((r >> 16) % 0.2 ether) + 1;
            if (op == 0) {
                vm.prank(u, u);
                (bool k1, bytes memory d1) =
                    address(pad).call{value: amt}(abi.encodeWithSelector(pad3.buyTokenAMAP.selector, a, u, amt, 0));
                vm.prank(u, u);
                (bool k2, bytes memory d2) =
                    address(pad).call{value: amt}(abi.encodeCall(pm.buyWithPromoter, (b, amt, 0, promoter)));
                assertEq(k1, k2, "same outcome");
                assertEq(d1, d2, "same result");
            } else if (op == 1) {
                uint256 bal = IERC20(a).balanceOf(u);
                if (bal == 0) continue;
                uint256 x = ((r >> 120) % bal) + 1;
                vm.prank(u, u);
                uint256 g1 = pad.sell(a, x, 0);
                vm.prank(u, u);
                uint256 g2 = pad.sell(b, x, 0);
                assertEq(g1, g2);
            } else if (op == 2) {
                uint256 bal = IERC20(a).balanceOf(u);
                if (bal == 0) continue;
                uint256 x = ((r >> 120) % bal) + 1;
                vm.prank(u, u);
                uint256 g1 = pad3.sellToken(0, a, u, x, 0, 0, address(0));
                vm.prank(u, u);
                uint256 g2 = pad3.sellToken(0, b, u, x, 0, 0, address(0));
                assertEq(g1, g2);
            } else {
                vm.warp(block.timestamp + ((r >> 96) % 10 days));
            }
            assertEq(_curveRealQuote(a), _curveRealQuote(b));
            assertEq(_curveSold(a), _curveSold(b));
            assertEq(pad.creatorFeeOf(a), pad.creatorFeeOf(b) + pm.promoterFeeOf(b, promoter));
            assertEq(
                wbnb.balanceOf(address(pad)),
                _curveRealQuote(a) + _curveRealQuote(b) + pad.creatorFeeOf(a) + pad.creatorFeeOf(b)
                    + pm.promoterFeeOf(b, promoter),
                "books"
            );
        }
    }

    // ---- reentrancy: a quote with a hook, on buy, claim and sell, into every guarded entry
    function test_reentrancy_hookQuote() public {
        HookQuote hq = new HookQuote();
        vm.prank(owner);
        quoteRegistry.setQuote(address(hq), true, 15 ether);
        address t = _p(address(hq), 5_000);
        address u = _newAgent();
        hq.mint(u, 100 ether);
        vm.prank(u);
        hq.approve(address(pad), type(uint256).max);
        bytes memory reent = abi.encodeCall(Pad3Module.claimPromoterFee, (t, address(hq)));
        bytes4 guard = bytes4(keccak256("ReentrancyGuardReentrantCall()"));

        // buyWithPromoter -> pull -> hook -> claim
        hq.arm(address(pad), reent);
        vm.prank(u, u);
        pm.buyWithPromoter(t, 0.1 ether, 0, promoter);
        assertFalse(hq.lastOk(), "reentered during buy");
        assertEq(bytes4(hq.lastRet()), guard, "guard fired on buy");

        // claim -> transfer -> hook -> claim again / buyWithPromoter
        hq.arm(address(pad), abi.encodeCall(Pad3Module.buyWithPromoter, (t, 1, 0, promoter)));
        uint256 owed = pm.promoterFeeOf(t, promoter);
        assertGt(owed, 0);
        vm.prank(promoter);
        pm.claimPromoterFee(t, promoter);
        assertFalse(hq.lastOk(), "reentered during claim");
        assertEq(bytes4(hq.lastRet()), guard, "guard fired on claim");
        assertEq(pm.promoterFeeOf(t, promoter), 0);
        assertEq(hq.balanceOf(promoter), owed);

        // sell -> quote out -> hook -> createWithPromote
        vm.prank(u);
        IERC20(t).approve(address(pad), type(uint256).max);
        hq.arm(
            address(pad),
            abi.encodeCall(
                Pad3Module.createWithPromote,
                ("x", "x", "l", "m", address(hq), address(0), _tax(0, 0, 0, address(0)), 9 ether, 1, 7 days)
            )
        );
        uint256 tb = IERC20(t).balanceOf(u);
        vm.prank(u, u);
        pad.sell(t, tb / 2, 0);
        assertFalse(hq.lastOk(), "reentered during sell");
        assertEq(bytes4(hq.lastRet()), guard, "guard fired on sell");
        hq.arm(address(0), "");
    }

    // ---- quote isolation: a hostile quote token on the same pad can't touch WBNB books
    function test_crossToken_noLeak() public {
        HookQuote hq = new HookQuote();
        vm.prank(owner);
        quoteRegistry.setQuote(address(hq), true, 15 ether);
        address tw = _p(address(wbnb), 5_000);
        address th = _p(address(hq), 5_000);
        address u = _newAgent();
        hq.mint(u, 100 ether);
        vm.startPrank(u, u);
        hq.approve(address(pad), type(uint256).max);
        pm.buyWithPromoter{value: 0.1 ether}(tw, 0.1 ether, 0, promoter);
        pm.buyWithPromoter(th, 0.1 ether, 0, promoter);
        vm.stopPrank();
        uint256 w0 = wbnb.balanceOf(address(pad));
        // the quote calls back on the claim's transfer, after the other token's fee: the guard stops it
        hq.arm(address(pad), abi.encodeCall(Pad3Module.claimPromoterFee, (tw, address(hq))));
        vm.prank(promoter);
        pm.claimPromoterFee(th, promoter);
        assertGt(hq.fired(), 0, "the hook ran");
        assertFalse(hq.lastOk(), "the callback was refused");
        assertEq(bytes4(hq.lastRet()), bytes4(keccak256("ReentrancyGuardReentrantCall()")), "by the guard");
        assertEq(wbnb.balanceOf(address(pad)), w0, "hook-quote claim leaves WBNB alone");
        assertEq(
            wbnb.balanceOf(address(pad)), _curveRealQuote(tw) + pad.creatorFeeOf(tw) + pm.promoterFeeOf(tw, promoter)
        );
        hq.arm(address(0), "");
    }

    // ---- taxed dividend token: share sync identical, promoter unaffected, through graduation
    function test_dividendToken_sharesSame() public {
        vm.prank(creator);
        address b = pm.createWithPromote(
            "P", "P", "l", "m", address(wbnb), address(0), _tax(300, 300, 10_000, address(0)), 9 ether, 5_000, 30 days
        );
        vm.prank(creator);
        address a = pad3.createWithGradTarget(
            "P", "P", "l", "m", address(wbnb), address(0), _tax(300, 300, 10_000, address(0)), 9 ether
        );
        address u = _newAgent();
        vm.prank(u, u);
        pad3.buyTokenAMAP{value: 0.1 ether}(a, u, 0.1 ether, 0);
        vm.prank(u, u);
        pm.buyWithPromoter{value: 0.1 ether}(b, 0.1 ether, 0, promoter);
        assertEq(IERC20(a).balanceOf(u), IERC20(b).balanceOf(u));
        assertGt(divVault.shares(a, u), 0, "the buy wrote the share");
        assertEq(divVault.shares(a, u), divVault.shares(b, u), "same dividend share after a buy");
        uint256 half = IERC20(b).balanceOf(u) / 2;
        vm.startPrank(u, u);
        IERC20(a).approve(address(pad), half);
        IERC20(b).approve(address(pad), half);
        pad.sell(a, half, 0);
        pad.sell(b, half, 0);
        vm.stopPrank();
        assertEq(divVault.shares(a, u), divVault.shares(b, u), "same dividend share after a sell");
        _graduate(b);
        assertTrue(_graduated(b));
        assertGt(pm.promoterFeeOf(b, promoter), 0);
        vm.prank(promoter);
        pm.claimPromoterFee(b, promoter);
        vm.prank(creator);
        pad.claimCreatorFee(b, creator);
    }
}
