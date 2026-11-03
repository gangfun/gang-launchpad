// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GangLaunchpad} from "../../src/gang/GangLaunchpad.sol";
import {GangLaunchpad3} from "../../src/gang/GangLaunchpad3.sol";
import {Pad3Module} from "../../src/gang/Pad3Module.sol";
import {IGangLaunchpad3} from "../../src/gang/interfaces/IGangLaunchpad3.sol";
import {GangFixture} from "../utils/GangFixture.sol";

/// @notice From audit 3A: differential checks of the 3.0 aggregator entry against CurveLogic3's quotes, TradeV1 and the
///         pad's books (every curve's realQuote + creatorFeeOf, never more than the pad holds).
contract CurveLogic3ParityTest is GangFixture {
    GangLaunchpad3 internal pad3;
    address internal alice;
    address internal bob;
    address internal feeTo = makeAddr("feeTo");
    bytes32 internal constant TRADE_V1 =
        keccak256("TradeV1(address,address,bool,uint256,uint256,uint256,uint256,uint256,uint256,uint256)");

    function _newPad() internal override returns (GangLaunchpad) {
        return _newPad3();
    }

    function setUp() public {
        _deployGang(address(this));
        pad3 = GangLaunchpad3(payable(address(pad)));
        alice = _newAgent();
        bob = _newAgent();
    }

    function _q(bool erc20) internal view returns (address) {
        return erc20 ? address(quoteTok) : address(wbnb);
    }

    /// @dev Moves the curve to `level` of its graduation amount (capped below it) with the wallet cap off.
    function _prime(address t, uint256 level) internal {
        uint256 g = Pad3Module(address(pad)).gradAmtOf(t);
        uint256 target = level % g;
        if (target < 1e9) return;
        vm.prank(owner);
        pad.setWalletCapEnabled(false);
        address w = _newAgent();
        _mintQuote(_curveQuote(t), w, target * 2);
        // a gross that leaves realQuote just below target (fee 1%)
        vm.prank(w);
        pad.buy(t, (target * 100) / 99, 0);
        vm.prank(owner);
        pad.setWalletCapEnabled(true);
    }

    function _books() internal view returns (uint256 wantW, uint256 wantQ) {
        uint256 n = pad.tokenCount();
        for (uint256 i; i < n; i++) {
            address tok = pad.allTokens(i);
            (, address quote, uint128 realQuote,,,,,,,,,) = pad.curves(tok);
            uint256 held = uint256(realQuote) + pad.creatorFeeOf(tok);
            if (quote == address(wbnb)) wantW += held;
            else wantQ += held;
        }
    }

    function _assertSolvent() internal view {
        (uint256 wantW, uint256 wantQ) = _books();
        assertGe(wbnb.balanceOf(address(pad)), wantW, "WBNB books");
        assertLe(wbnb.balanceOf(address(pad)) - wantW, 10, "WBNB dust");
        assertGe(quoteTok.balanceOf(address(pad)), wantQ, "quote books");
        assertLe(quoteTok.balanceOf(address(pad)) - wantQ, 10, "quote dust");
        assertEq(address(pad).balance, 0, "no BNB");
    }

    function _tradeV1Quote(Vm.Log[] memory logs) internal view returns (uint256 quoteAmount, uint256 fee) {
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter == address(pad) && logs[i].topics[0] == TRADE_V1) {
                (, uint256 qa,, uint256 pf,,,,) =
                    abi.decode(logs[i].data, (bool, uint256, uint256, uint256, uint256, uint256, uint256, uint256));
                return (qa, pf);
            }
        }
        revert("no TradeV1");
    }

    struct Q {
        uint256 amount;
        uint256 cost;
        uint256 fee;
        uint256 amountFunds;
    }

    /// @dev tryBuy == buyTokenAMAP to the wei; TradeV1.quoteAmount == fundsUsed; the pad stays at its books.
    function testFuzz_buyParity(uint256 level, uint256 funds, bool erc20, bool preHeld) public {
        address t = _createV3(alice, _q(erc20), _tax(0, 0, 0, address(0)));
        _prime(t, level);
        if (preHeld) {
            vm.prank(bob);
            pad.buy(t, 0.01 ether, 0);
        }
        if (_graduated(t)) return;
        funds = bound(funds, 1, 20 ether);
        _mintQuote(_q(erc20), bob, funds);
        vm.deal(bob, funds);
        Q memory q;
        (,, q.amount, q.cost, q.fee,,, q.amountFunds) = pad3.tryBuy(t, bob, 0, funds);
        uint256 creatorBefore = pad.creatorFeeOf(t);
        vm.recordLogs();
        vm.prank(bob, bob);
        (uint256 out, uint256 used) = pad3.buyTokenAMAP{value: erc20 ? 0 : funds}(t, bob, funds, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(out, q.amount, "amount");
        assertEq(used, q.cost, "cost");
        (uint256 qa, uint256 pf) = _tradeV1Quote(logs);
        assertEq(pf, q.fee, "fee");
        assertEq(pad.creatorFeeOf(t) - creatorBefore, (q.fee * 7000) / 10_000, "creator fee");
        // audit 3A I-1 (fixed): TradeV1.quoteAmount is what the pad kept, the graduation cut's dust included
        assertEq(qa, used, "TradeV1.quoteAmount == fundsUsed");
        _assertSolvent();
    }

    /// @dev trySell == sellToken to the wei, the router fee split adds up, the pad stays at its books.
    function testFuzz_sellParity(uint256 level, uint256 buyFunds, uint256 sellPart, uint256 feeRate, bool erc20)
        public
    {
        address t = _createV3(alice, _q(erc20), _tax(0, 0, 0, address(0)));
        _prime(t, level);
        if (_graduated(t)) return;
        buyFunds = bound(buyFunds, 1e6, 0.5 ether);
        vm.prank(bob);
        pad.buy(t, buyFunds, 0);
        if (_graduated(t)) return;
        uint256 bal = IERC20(t).balanceOf(bob);
        uint256 amount = bound(sellPart, 1, bal);
        feeRate = bound(feeRate, 0, 500);
        (,, uint256 funds, uint256 fee) = pad3.trySell(t, amount);
        vm.prank(bob);
        IERC20(t).approve(address(pad), amount);
        uint256 bnbBefore = bob.balance;
        uint256 qBefore = quoteTok.balanceOf(bob);
        vm.recordLogs();
        vm.prank(bob, bob);
        uint256 toSeller = pad3.sellToken(0, t, bob, amount, 0, feeRate, feeTo);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint256 qa, uint256 pf) = _tradeV1Quote(logs);
        assertEq(pf, fee, "fee");
        assertEq(qa, funds + fee, "quoteOut");
        uint256 rf = (funds * feeRate) / 10_000;
        assertEq(toSeller, funds - rf, "to seller");
        if (erc20) {
            assertEq(quoteTok.balanceOf(bob) - qBefore, toSeller);
            assertEq(quoteTok.balanceOf(feeTo), rf);
        } else {
            assertEq(bob.balance - bnbBefore, toSeller);
            assertEq(feeTo.balance, rf);
        }
        _assertSolvent();
    }
}

/// @notice Audit 3A I-1 regression: the fuzzer's counterexample (the graduating, cut buy), where TradeV1.quoteAmount
///         was 1 wei below what the pad kept; now equal.
contract TradeV1GraduationDustTest is CurveLogic3ParityTest {
    function test_tradeV1_graduatingBuy_reportsWhatThePadKept() public {
        // the fuzzer's counterexample (ERC-20 quote, no prior holding)
        uint256 level = 560042618212444778092938209970255360083642504891693071341;
        address t = _createV3(alice, address(quoteTok), _tax(0, 0, 0, address(0)));
        _prime(t, level);
        uint256 funds = 20 ether;
        _mintQuote(address(quoteTok), bob, funds);
        (,,, uint256 cost,,,,) = pad3.tryBuy(t, bob, 0, funds);
        vm.recordLogs();
        vm.prank(bob, bob);
        (, uint256 used) = pad3.buyTokenAMAP(t, bob, funds, 0);
        (uint256 qa,) = _tradeV1Quote(vm.getRecordedLogs());
        assertTrue(_graduated(t), "graduating buy");
        assertEq(used, cost, "tryBuy == fundsUsed");
        assertEq(used, qa, "TradeV1.quoteAmount == fundsUsed");
        _assertSolvent();
    }
}
