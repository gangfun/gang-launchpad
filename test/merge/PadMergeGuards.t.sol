// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {GangLaunchpad} from "../../src/gang/GangLaunchpad.sol";
import {IGangPadView} from "../../src/gang/interfaces/IGangPadView.sol";
import {CurveLogic} from "../../src/gang/CurveLogic.sol";
import {FairLogic} from "../../src/gang/FairLogic.sol";
import {GangRouterTest} from "../router/GangRouter.t.sol";

/// @notice Signature freeze and merge-specific guards for GangLaunchpad (MERGE-PLAN §7.3, pad side): topic0 of every
///         pad event equals the string the indexer subscribes to, the old selectors route, the `curves` / `sales` /
///         `positions` getters keep their layout, curves and sales on one quote never touch each other's escrow, the
///         libraries refuse direct calls, every contract stays under EIP-170 with margin, and the one vault floor.
contract PadMergeGuardsTest is GangRouterTest {
    uint256 internal constant SIZE_LIMIT = 24_064; // 24,576 − 512 margin

    // indexer strings (gangfun-server indexer/src/v3.js, fairMint.js)
    string internal constant V3_CREATED = "Created(address,address,string,string,string,address,address,uint256)";
    string internal constant FAIR_CREATED =
        "Created(address,address,string,string,string,address,address,uint256,uint256,uint256,uint256,uint256,uint256)";
    string internal constant TAX_CONFIGURED = "TaxConfigured(address,uint16,uint16,uint16,address)";
    string internal constant VQ_LOCKED = "VirtualQuoteLocked(address,uint256)";
    string internal constant BUY = "Buy(address,address,uint256,uint256,uint256,uint256,uint256)";
    string internal constant SELL = "Sell(address,address,uint256,uint256,uint256,uint256,uint256)";
    string internal constant GRADUATED = "Graduated(address,address,address,uint256,uint256)";
    string internal constant MINTED = "Minted(address,address,uint256,uint256,uint256,uint256,uint256)";
    string internal constant WITHDRAWN = "Withdrawn(address,address,uint256,uint256,uint256,uint256,uint256)";
    string internal constant LAUNCHED = "Launched(address,address,address,uint256,uint256)";
    string internal constant SHARE_WRITE_FAILED = "ShareWriteFailed(address,address,uint256)";
    string internal constant FEE_OWED = "FeeOwed(address,uint256)";
    string internal constant FEES_FLUSHED = "FeesFlushed(address,uint256)";

    function _cfg() internal pure returns (IGangLaunchpad.MintConfig memory) {
        return
            IGangLaunchpad.MintConfig({raiseBnb: 15 ether, capBps: 50, holdBps: 6000, mintFeeBps: 100, exitFeeBps: 200});
    }

    /// @dev Number of logs emitted by the pad with `topic0 == keccak(sig)`, each with `topics` topics.
    function _count(VmSafe.Log[] memory logs, string memory sig, uint256 topics) internal view returns (uint256 n) {
        bytes32 t0 = keccak256(bytes(sig));
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == t0) {
                assertEq(logs[i].emitter, address(v3), "emitted by the pad (library runs in its context)");
                assertEq(logs[i].topics.length, topics, sig);
                n++;
            }
        }
    }

    // ---------------------------------------------------------------- events
    function test_merge_eventTopics() public {
        // non-overloaded events: the declared selector is the indexer's string
        assertEq(IGangLaunchpad.TaxConfigured.selector, keccak256(bytes(TAX_CONFIGURED)));
        assertEq(IGangLaunchpad.VirtualQuoteLocked.selector, keccak256(bytes(VQ_LOCKED)));
        assertEq(IGangLaunchpad.Buy.selector, keccak256(bytes(BUY)));
        assertEq(IGangLaunchpad.Sell.selector, keccak256(bytes(SELL)));
        assertEq(IGangLaunchpad.Graduated.selector, keccak256(bytes(GRADUATED)));
        assertEq(IGangLaunchpad.Minted.selector, keccak256(bytes(MINTED)));
        assertEq(IGangLaunchpad.Withdrawn.selector, keccak256(bytes(WITHDRAWN)));
        assertEq(IGangLaunchpad.Launched.selector, keccak256(bytes(LAUNCHED)));
        assertEq(IGangLaunchpad.ShareWriteFailed.selector, keccak256(bytes(SHARE_WRITE_FAILED)));
        assertEq(IGangLaunchpad.FeeOwed.selector, keccak256(bytes(FEE_OWED)));
        assertEq(IGangLaunchpad.FeesFlushed.selector, keccak256(bytes(FEES_FLUSHED)));

        // the two Created overloads, and every event in its real flow: topic0, indexed count, emitter = pad
        vm.recordLogs();
        address a = _v3Token(5000);
        VmSafe.Log[] memory logs = vm.getRecordedLogs();
        assertEq(_count(logs, V3_CREATED, 4), 1, "V3 Created");
        assertEq(_count(logs, TAX_CONFIGURED, 3), 1, "TaxConfigured");
        assertEq(_count(logs, VQ_LOCKED, 2), 1, "VirtualQuoteLocked");
        assertEq(_count(logs, FAIR_CREATED, 4), 0, "no fair Created for a curve token");

        vm.recordLogs();
        address b = _fairSale();
        logs = vm.getRecordedLogs();
        assertEq(_count(logs, FAIR_CREATED, 4), 1, "fair Created");
        assertEq(_count(logs, MINTED, 3), 1, "creator's Minted");
        assertEq(_count(logs, V3_CREATED, 4), 0, "no V3 Created for a sale");

        vm.recordLogs();
        vm.prank(agent2);
        uint256 got = v3.buy(a, 1 ether, 0);
        vm.startPrank(agent2);
        IERC20(a).approve(address(v3), got);
        v3.sell(a, got / 2, 0);
        vm.stopPrank();
        vm.prank(agent2);
        v3.mint(b, 10, 1);
        vm.prank(agent2);
        v3.withdraw(b, 5, 0);
        logs = vm.getRecordedLogs();
        assertEq(_count(logs, BUY, 3), 1, "Buy");
        assertEq(_count(logs, SELL, 3), 1, "Sell");
        assertEq(_count(logs, MINTED, 3), 1, "Minted");
        assertEq(_count(logs, WITHDRAWN, 3), 1, "Withdrawn");

        vm.recordLogs();
        _graduate(a);
        _launch(b);
        logs = vm.getRecordedLogs();
        assertEq(_count(logs, GRADUATED, 3), 1, "Graduated");
        assertEq(_count(logs, LAUNCHED, 3), 1, "Launched");
    }

    // ---------------------------------------------------------------- selectors
    function test_merge_selectors() public {
        assertEq(GangLaunchpad.buy.selector, bytes4(keccak256("buy(address,uint256,uint256)")));
        assertEq(GangLaunchpad.buyFor.selector, bytes4(keccak256("buyFor(address,address,uint256,uint256)")));
        assertEq(GangLaunchpad.sell.selector, bytes4(keccak256("sell(address,uint256,uint256)")));
        assertEq(GangLaunchpad.mint.selector, bytes4(keccak256("mint(address,uint256,uint256)")));
        assertEq(GangLaunchpad.mintFor.selector, bytes4(keccak256("mintFor(address,address,uint256,uint256)")));
        assertEq(GangLaunchpad.withdraw.selector, bytes4(keccak256("withdraw(address,uint256,uint256)")));
        assertEq(GangLaunchpad.flushFees.selector, bytes4(keccak256("flushFees(address)")));
        assertEq(GangLaunchpad.baselineOf.selector, bytes4(keccak256("baselineOf(address,address)")));
        assertEq(GangLaunchpad.holdBpsOf.selector, bytes4(keccak256("holdBpsOf(address)")));
        assertEq(IGangPadView.kindOf.selector, bytes4(keccak256("kindOf(address)")));

        // the two create overloads keep their old selectors: call each by its signature string
        vm.prank(agent);
        (bool ok, bytes memory ret) = address(v3)
            .call(
                abi.encodeWithSignature(
                    "create(string,string,string,string,address,address,(uint16,uint16,uint16,address))",
                    "V",
                    "V",
                    "",
                    "",
                    address(0),
                    address(0),
                    _tax(5000)
                )
            );
        assertTrue(ok, "V3 create selector");
        assertEq(v3.kindOf(abi.decode(ret, (address))), 1);
        vm.prank(agent);
        (ok, ret) = address(v3)
            .call(
                abi.encodeWithSignature(
                    "create(string,string,string,string,address,address,(uint256,uint16,uint16,uint16,uint16),uint256)",
                    "F",
                    "F",
                    "",
                    "",
                    address(0),
                    address(0),
                    _cfg(),
                    uint256(1)
                )
            );
        assertTrue(ok, "fair create selector");
        assertEq(v3.kindOf(abi.decode(ret, (address))), 2);
    }

    // ---------------------------------------------------------------- getters
    function test_merge_getterLayout() public {
        address a = _v3Token(5000);
        address b = _fairSale();
        (bool ok, bytes memory ret) = address(v3).staticcall(abi.encodeWithSignature("curves(address)", a));
        assertTrue(ok);
        assertEq(ret.length, 12 * 32, "curves: 12 words");
        (address creator, address quote,,, uint128 gradAmt, uint128 vq,, uint16 buyBps,, uint16 divBps,,) = abi.decode(
            ret, (address, address, uint128, uint128, uint128, uint128, bool, uint16, uint16, uint16, address, address)
        );
        assertEq(creator, agent);
        assertEq(quote, address(wbnb));
        assertEq(gradAmt, 15 ether);
        assertEq(vq, uint128(15 ether) / 3);
        assertEq(buyBps, 200);
        assertEq(divBps, 5000);

        (ok, ret) = address(v3).staticcall(abi.encodeWithSignature("sales(address)", b));
        assertTrue(ok);
        assertEq(ret.length, 14 * 32, "sales: 14 words");
        (
            address sc,
            uint64 progressAt,
            uint16 cap,
            uint16 hold,
            address sq,
            uint16 sold,,
            uint16 mintFee,
            uint16 exitFee,
            address gate,
            uint128 price,,,
            uint16 mark
        ) = abi.decode(
            ret,
            (
                address,
                uint64,
                uint16,
                uint16,
                address,
                uint16,
                bool,
                uint16,
                uint16,
                address,
                uint128,
                address,
                address,
                uint16
            )
        );
        assertEq(sc, agent);
        assertEq(progressAt, block.timestamp);
        assertEq(cap, 100);
        assertEq(hold, 6000);
        assertEq(sq, address(wbnb));
        assertEq(sold, 1);
        assertEq(mintFee, 100);
        assertEq(exitFee, 200);
        assertEq(gate, address(agents));
        assertEq(price, 15 ether / 10_000);
        assertEq(mark, 1);

        (ok, ret) = address(v3).staticcall(abi.encodeWithSignature("positions(address,address)", b, agent));
        assertTrue(ok);
        assertEq(ret.length, 32, "positions: 1 word");
        assertEq(abi.decode(ret, (uint16)), 1);
    }

    // ---------------------------------------------------------------- escrow isolation (§5.4)
    /// @dev pad WBNB == Σ live realQuote + Σ live sale principal (sold × price) + owedFee + dust, dust ≥ 0 and never
    ///      shrinking, through curve buys / sells / graduation and 打新 mints / withdraws / launch, interleaved.
    function test_merge_sameQuoteIsolation_wbnb() public {
        address a1 = _v3Token(5000);
        address b1 = _fairSale();
        vm.prank(agent);
        address a2 = v3.create("Plain", "PLN", "", "", address(0), address(0), _plain());
        vm.prank(agent);
        address b2 = fair.create("Fair2", "F2", "", "", address(0), address(0), _cfg(), 1);
        address[] memory curvesL = new address[](2);
        (curvesL[0], curvesL[1]) = (a1, a2);
        address[] memory salesL = new address[](2);
        (salesL[0], salesL[1]) = (b1, b2);

        uint256 dust = _checkEscrow(curvesL, salesL, 0);
        for (uint256 i; i < 6; i++) {
            address w = address(uint160(0xD0000 + i));
            _agent(w);
            vm.startPrank(w);
            v3.buy(a1, 0.7 ether, 0);
            v3.mint(b1, 40, 1);
            v3.buy(a2, 0.3 ether, 0);
            v3.mint(b2, 20, 1);
            uint256 bal = IERC20(a1).balanceOf(w);
            IERC20(a1).approve(address(v3), bal);
            v3.sell(a1, bal / 3, 0);
            v3.withdraw(b1, 15, 0);
            vm.stopPrank();
            dust = _checkEscrow(curvesL, salesL, dust);
        }
        _launch(b1);
        dust = _checkEscrow(curvesL, salesL, dust);
        _graduate(a1);
        dust = _checkEscrow(curvesL, salesL, dust);
        // the survivors still pay out in full from their own escrow
        address w0 = address(uint160(0xD0000));
        uint256 shares = v3.positions(b2, w0);
        uint256 before = wbnb.balanceOf(w0);
        vm.prank(w0);
        uint256 payout = v3.withdraw(b2, shares, 0);
        assertEq(wbnb.balanceOf(w0) - before, payout);
        uint256 bal2 = IERC20(a2).balanceOf(w0);
        vm.startPrank(w0);
        IERC20(a2).approve(address(v3), bal2);
        v3.sell(a2, bal2, 0);
        vm.stopPrank();
        dust = _checkEscrow(curvesL, salesL, dust);
        _launch(b2);
        _graduate(a2);
        dust = _checkEscrow(curvesL, salesL, dust);
        assertLt(dust, 1e6, "only rounding dust is left");
    }

    function _plain() internal pure returns (IGangLaunchpad.TaxConfig memory) {
        return IGangLaunchpad.TaxConfig({buyTaxBps: 0, sellTaxBps: 0, dividendBps: 0, recipient: address(0)});
    }

    function _checkEscrow(address[] memory curvesL, address[] memory salesL, uint256 lastDust)
        internal
        view
        returns (uint256 dust)
    {
        uint256 owed = v3.owedFee(address(wbnb));
        for (uint256 i; i < curvesL.length; i++) {
            (,, uint128 realQuote,,,, bool graduated,,,,,) = v3.curves(curvesL[i]);
            if (!graduated) owed += realQuote;
            owed += v3.creatorFeeOf(curvesL[i]); // kept for the creator, live or graduated
        }
        for (uint256 i; i < salesL.length; i++) {
            (,,,,, uint16 sold, bool launched,,,, uint128 price,,,) = v3.sales(salesL[i]);
            if (!launched) owed += uint256(sold) * price;
        }
        uint256 bal = wbnb.balanceOf(address(v3));
        assertGe(bal, owed, "pad WBNB covers every curve reserve and every sale escrow");
        dust = bal - owed;
        assertGe(dust, lastDust, "dust only grows");
    }

    function _graduate(address token) internal {
        for (uint256 i; i < 200 && !_v3Graduated(token); i++) {
            address w = address(uint160(0xE1000 + i));
            _agent(w);
            vm.prank(w);
            v3.buy(token, 1 ether, 0);
        }
        assertTrue(_v3Graduated(token), "graduated");
    }

    function _launch(address token) internal {
        for (uint256 i; i < 200 && v3.status(token) != IGangLaunchpad.Status.Launched; i++) {
            address m = address(uint160(0xF1000 + i));
            _agent(m);
            vm.prank(m);
            v3.mint(token, 100, 1);
        }
        assertEq(uint8(v3.status(token)), uint8(IGangLaunchpad.Status.Launched), "launched");
    }

    // ---------------------------------------------------------------- libraries
    /// @dev The two libraries the pad delegatecalls on a buy / a mint (found from the call trace).
    function _libs() internal returns (address curveLib, address fairLib) {
        address a = _v3Token(0);
        address b = _fairSale();
        vm.startStateDiffRecording();
        vm.prank(agent2);
        v3.buy(a, 0.1 ether, 0);
        VmSafe.AccountAccess[] memory acc = vm.stopAndReturnStateDiff();
        curveLib = _delegatee(acc);
        vm.startStateDiffRecording();
        vm.prank(agent2);
        v3.mint(b, 1, 1);
        acc = vm.stopAndReturnStateDiff();
        fairLib = _delegatee(acc);
        assertTrue(curveLib != address(0) && fairLib != address(0) && curveLib != fairLib, "two libraries");
        // the logic libraries themselves (~11 KB each), not PoolCheck (~5 KB)
        assertGt(curveLib.code.length, 9_000, "CurveLogic code");
        assertGt(fairLib.code.length, 9_000, "FairLogic code");
    }

    function _delegatee(VmSafe.AccountAccess[] memory acc) internal view returns (address) {
        for (uint256 i; i < acc.length; i++) {
            if (
                acc[i].kind == VmSafe.AccountAccessKind.DelegateCall && acc[i].account != address(v3)
                    && acc[i].account.code.length > 0 && acc[i].account != address(this)
            ) {
                return acc[i].account;
            }
        }
        return address(0);
    }

    /// @dev Library call protection: a state-changing library function called directly (CALL, not DELEGATECALL)
    ///      reverts, so nobody can run the pad's logic against the library's own storage or balance.
    function test_merge_libsNotDirectlyCallable() public {
        (address curveLib, address fairLib) = _libs();
        IGangLaunchpad.Deps memory d;
        (bool ok,) = curveLib.call(
            abi.encodeWithSelector(
                CurveLogic.buy.selector, uint256(0), uint256(0), d, agent, address(1), uint256(1), uint256(0)
            )
        );
        assertFalse(ok, "CurveLogic.buy not callable directly");
        (ok,) = curveLib.call(
            abi.encodeWithSelector(CurveLogic.sell.selector, uint256(0), uint256(0), d, address(1), uint256(1), 0)
        );
        assertFalse(ok, "CurveLogic.sell not callable directly");
        (ok,) = fairLib.call(
            abi.encodeWithSelector(
                FairLogic.mint.selector, uint256(0), uint256(0), uint256(0), d, agent, address(1), uint256(1), 0
            )
        );
        assertFalse(ok, "FairLogic.mint not callable directly");
        (ok,) = fairLib.call(
            abi.encodeWithSelector(
                FairLogic.withdraw.selector, uint256(0), uint256(0), uint256(0), d, address(1), uint256(1), 0
            )
        );
        assertFalse(ok, "FairLogic.withdraw not callable directly");
        (ok,) = fairLib.call(abi.encodeWithSelector(FairLogic.flushFees.selector, uint256(0), d, address(wbnb)));
        assertFalse(ok, "FairLogic.flushFees not callable directly");
    }

    // ---------------------------------------------------------------- sizes / constants
    function test_sizes() public {
        (address curveLib, address fairLib) = _libs();
        address t = _v3Token(5000);
        assertLt(address(v3).code.length, SIZE_LIMIT, "GangLaunchpad");
        assertLt(curveLib.code.length, SIZE_LIMIT, "CurveLogic");
        assertLt(fairLib.code.length, SIZE_LIMIT, "FairLogic");
        assertLt(v3.taxHandler().code.length, SIZE_LIMIT, "GangTaxHandler");
        assertLt(t.code.length, SIZE_LIMIT, "GangToken");
        assertLt(address(tokenDeployer).code.length, SIZE_LIMIT, "TokenDeployer");
        assertLt(address(router).code.length, SIZE_LIMIT, "GangRouter");
    }

    function test_merge_floorConstantsEqual() public view {
        assertEq(v3.TAXED_MIN_SHARE(), v3.MIN_SHARE_BALANCE(), "one vault floor");
        assertEq(v3.TAXED_MIN_SHARE(), 10_000 ether);
        assertEq(v3.TARGET_GRAD_BNB(), v3.REGISTRY_REF_BNB(), "one 15 BNB reference");
        assertEq(v3.TOTAL_SUPPLY(), 1_000_000_000 ether);
        assertEq(v3.LP_SUPPLY() + v3.MINT_SUPPLY(), v3.TOTAL_SUPPLY());
    }
}
