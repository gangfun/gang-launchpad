// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GangFixture} from "../utils/GangFixture.sol";
import {GangLaunchpad} from "../../src/gang/GangLaunchpad.sol";
import {GangLaunchpad3} from "../../src/gang/GangLaunchpad3.sol";
import {Pad3Module} from "../../src/gang/Pad3Module.sol";
import {Pad3FlyModule} from "../../src/gang/Pad3FlyModule.sol";
import {Pad3FlyStore} from "../../src/gang/Pad3FlyStore.sol";
import {IGangLaunchpad3} from "../../src/gang/interfaces/IGangLaunchpad3.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {Pad3FlyVaultCore} from "../../src/gang/Pad3FlyVaultCore.sol";
import {SharedDividendVault} from "../../src/common/SharedDividendVault.sol";
import {IFlywheelPad} from "../../src/flywheel/interfaces/IFlywheelPad.sol";

/// @dev A contract to list as a router (the test pranks as it).
contract FlyRouterStub {}
import {TwapMockPair, TwapMockPairFactory} from "../mocks/TwapMockPair.sol";

/// @notice GangLaunchpad 3.0's 铸币飞轮 mode next to its curve and 打新 tokens, on the mainnet wiring (GangFixture: the
///         vault's one operator for 3.0 is the curve / 打新 handler, the pad's floor 10,000 tokens; the 铸币飞轮 tokens
///         are registered under the pad's vault core, whose operator is the 铸币飞轮 handler). The V2 rules themselves:
///         test/gang3/Pad3FlyParity.t.sol.
contract Pad3FlyTest is GangFixture {
    uint256 internal constant FLY_TPS = 100_000 ether;

    GangLaunchpad3 internal p3;
    Pad3FlyModule internal fly;

    function _newPad() internal override returns (GangLaunchpad) {
        return _newPad3();
    }

    /// @dev The 铸币飞轮 handler's oracle reads the pair's cumulative prices.
    function _newPairFactory() internal override returns (address) {
        return address(new TwapMockPairFactory());
    }

    address internal keeper = makeAddr("keeper");

    function setUp() public {
        _deployGang(keeper);
        p3 = GangLaunchpad3(payable(address(pad)));
        fly = Pad3FlyModule(address(pad));
    }

    function _flyCfg() internal pure returns (IFlywheelPad.FlyConfig memory) {
        return IFlywheelPad.FlyConfig({
            raiseBnb: 20 ether,
            baseQuota: 10,
            inviteBonus: 1,
            maxPerTx: 10,
            holdBps: 6_000,
            mintFeeBps: 100,
            exitFeeBps: 100,
            devCutBps: 1_000,
            buyBps: 3_000,
            sellTaxBps: 200,
            launchDelay: 60,
            window: 600,
            windowCapMul: 1,
            postMint: true,
            tierMode: 1,
            stepBps: 0,
            stepShares: 0,
            maxMulX100: 0,
            supplyCapMul: 100,
            guardBps: 0,
            twapWindow: 1800
        });
    }

    function _createFly(address creator) internal returns (address t) {
        string[4] memory text = ["Fly", "FLY", "ipfs://logo", "ipfs://meta"];
        vm.prank(creator);
        t = fly.create(text, address(0), address(0), _flyCfg(), 1);
    }

    function _fillAndLaunch(address t) internal {
        vm.pauseGasMetering();
        for (uint256 i; i < 2_000 && fly.sales(t).filledAt == 0; i++) {
            address w = _newAgent();
            vm.startPrank(w);
            while (fly.quotaLeft(t, w) > 0 && fly.sales(t).filledAt == 0) fly.mint(t, 10, 1, address(0));
            vm.stopPrank();
        }
        vm.warp(vm.getBlockTimestamp() + fly.sales(t).launchDelay);
        fly.launch(t);
        vm.resumeGasMetering();
    }

    function test_namespace_pinned() public pure {
        assertEq(
            Pad3FlyStore.SLOT, keccak256(abi.encode(uint256(keccak256("gang.pad3.fly")) - 1)) & ~bytes32(uint256(0xff))
        );
    }

    /// @dev One pad, three kinds: each token answers the views it shares by name with its own kind's rules.
    function test_kinds_sideBySide() public {
        address dev = _newAgent();
        address fair = _createFair(dev, address(wbnb), 1);
        address t = _createFly(dev);
        assertEq(p3.kindOf(fair), 2);
        assertEq(p3.kindOf(t), 3);
        assertEq(p3.tokenVersionOf(t), p3.TOKEN_VERSION());
        assertEq(p3.allTokens(p3.tokenCount() - 1), t);
        Pad3Module m = Pad3Module(payable(address(pad)));
        assertEq(m.shareSizeOf(fair), 50_000 ether);
        assertEq(m.shareSizeOf(t), FLY_TPS);
        // `sales`: V2's Sale for the 铸币飞轮 token, 打新's for the other
        IFlywheelPad.Sale memory s = fly.sales(t);
        assertEq(s.creator, dev);
        assertEq(s.sold, 1);
        (address fairCreator,,,,, uint16 fairSold,,,,,,,,) = p3.sales(fair);
        assertEq(fairCreator, dev);
        assertEq(fairSold, 1);
        // the hold line and baseline the two tax handlers read, by kind
        assertEq(p3.baselineOf(t, dev), FLY_TPS);
        assertEq(p3.baselineOf(fair, dev), 50_000 ether);
        assertEq(p3.holdBpsOf(t), 6_000);
        // the vault: the 铸币飞轮 token under the vault core at V2's floor; the 打新 token under the pad at 3.0's
        assertEq(divVault.launchpadOf(t), address(flyCore));
        assertEq(divVault.minimumShareBalanceFor(t), 1_000 ether);
        assertEq(divVault.launchpadOf(fair), address(pad));
        assertEq(divVault.minimumShareBalanceFor(fair), 10_000 ether);
        assertEq(divVault.shares(t, dev), FLY_TPS);
        // `withdraw` by kind: the 铸币飞轮 sell-back and the 打新 one
        address w = _newAgent();
        vm.startPrank(w);
        fly.mint(t, 2, 2, address(0));
        p3.withdraw(t, 1, 0);
        assertEq(IERC20(t).balanceOf(w), FLY_TPS);
        assertEq(fly.accounts(t, w).baseline, FLY_TPS);
        vm.stopPrank();
    }

    /// @dev Only the pad drives the vault core; only the 铸币飞轮 handler (its operator) writes the 铸币飞轮 tokens'
    ///      shares besides it; the curve / 打新 handler (3.0's own operator) cannot touch them.
    function test_vaultCore_wiring() public {
        address dev = _newAgent();
        address t = _createFly(dev);
        address stranger = makeAddr("stranger");
        vm.startPrank(stranger);
        vm.expectRevert(Pad3FlyVaultCore.OnlyPad.selector);
        flyCore.setShare(t, stranger, 1e24);
        vm.expectRevert(Pad3FlyVaultCore.OnlyPad.selector);
        flyCore.registerToken(stranger, address(wbnb));
        vm.expectRevert(Pad3FlyVaultCore.OnlyPad.selector);
        flyCore.ensureMinimumShareBalance(1e30);
        vm.stopPrank();
        vm.prank(address(handler));
        vm.expectRevert(SharedDividendVault.OnlyLaunchpad.selector);
        divVault.setShare(t, stranger, 1e24);
        assertEq(divVault.operatorOf(address(flyHandler)), address(flyCore));
        assertEq(divVault.operatorFor(address(pad)), address(handler));
        assertEq(address(flyHandler.dividendVault()), address(divVault));
        assertEq(flyHandler.launchpad(), address(pad));
        assertEq(m3FlyModule().flyVaultCore(), address(flyCore));
        assertEq(flyCore.pad(), address(pad));
        assertEq(flyCore.minimumShareBalanceOf(address(pad)), 1_000 ether);
    }

    /// @dev Code written for the pad's other kinds (50,000-token shares) is not a 铸币飞轮 router: the pad's router
    ///      list does not reach `withdrawFor` / `mintFor` of a 铸币飞轮 token; the mode's own list does (audit B M-1).
    function test_flyRouters_separateList() public {
        address dev = _newAgent();
        address t = _createFly(dev);
        address r = address(new FlyRouterStub());
        vm.prank(owner);
        p3.setRouter(r, true);
        vm.prank(r, dev);
        vm.expectRevert(IGangLaunchpad.OnlyRouter.selector);
        p3.withdrawFor(dev, t, 1, 0);
        vm.prank(r, dev);
        vm.expectRevert(IGangLaunchpad.OnlyRouter.selector);
        fly.mintFor(dev, t, 1, 1, address(0));
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", address(this)));
        fly.setFlyRouter(r, true);
        vm.prank(owner);
        vm.expectRevert(IGangLaunchpad3.NotAContract.selector);
        fly.setFlyRouter(makeAddr("eoa"), true);
        vm.prank(owner);
        fly.setFlyRouter(r, true);
        assertTrue(fly.flyRouters(r));
        // V2's rule: the router pulls with the trader's allowance to the router
        vm.prank(dev);
        IERC20(t).approve(r, FLY_TPS);
        vm.prank(r, dev);
        p3.withdrawFor(dev, t, 1, 0);
        assertEq(fly.accounts(t, dev).baseline, 0);
    }

    function m3FlyModule() internal view returns (Pad3FlyModule) {
        return Pad3FlyModule(Pad3Module(payable(p3.module())).flyModule());
    }

    /// @dev After launch the 铸币飞轮 handler writes holder shares and pays dividends in the vault as the vault core's
    ///      operator: a transfer re-syncs both sides, a minter below its hold line is out, a pool sell's tax reaches the
    ///      holders.
    function test_handler_sharesAndDividendsAfterLaunch() public {
        address dev = _newAgent();
        address t = _createFly(dev);
        address minter = _newAgent();
        vm.prank(minter);
        fly.mint(t, 10, 10, address(0));
        _fillAndLaunch(t);
        vm.warp(vm.getBlockTimestamp() + _flyCfg().window + 1);
        vm.roll(vm.getBlockNumber() + 1);

        uint256 base = 10 * FLY_TPS;
        assertEq(divVault.shares(t, minter), base);
        address other = makeAddr("other");
        // below the baseline, above the hold line: share = balance
        vm.prank(minter);
        IERC20(t).transfer(other, 3 * FLY_TPS);
        assertEq(divVault.shares(t, minter), 7 * FLY_TPS);
        assertEq(divVault.shares(t, other), 0);
        assertFalse(flyHandler.isOut(t, minter));

        // a pool sell taxes; the keeper's processing converts the holders' part in the vault (through the pad)
        address seller = _newAgent();
        vm.prank(seller);
        fly.mintPost(t, 1, 0, type(uint256).max, address(0));
        _poolSell(t, seller, IERC20(t).balanceOf(seller));
        uint256 accrued = flyHandler.accruedTax(t);
        assertGt(accrued, 0);
        vm.prank(keeper);
        flyHandler.process(t, accrued, 1);
        assertGt(divVault.pending(t, minter), 0, "dividends reach a holder");

        // below the hold line: out
        vm.prank(minter);
        IERC20(t).transfer(other, 2 * FLY_TPS);
        assertTrue(flyHandler.isOut(t, minter));
        assertEq(divVault.shares(t, minter), 0);
    }

    /// @dev 3.0's own entry for its 铸币飞轮 token: whole shares at the base price plus the mint fee, sold back whole.
    function test_entry_roundTrip() public {
        address dev = _newAgent();
        address t = _createFly(dev);
        (uint8 st, address q,,,) = p3.getTokenInfo(t);
        assertEq(st, 1);
        assertEq(q, address(0));
        address w = _newAgent();
        (,, uint256 amount, uint256 cost,, uint256 msgValue,,) = p3.tryBuy(t, w, 0, 0.0123 ether);
        assertEq(amount % FLY_TPS, 0);
        assertGt(amount, 0);
        assertEq(msgValue, cost);
        vm.prank(w, w);
        (uint256 out, uint256 used) = p3.buyTokenAMAP{value: msgValue}(t, w, msgValue, amount);
        assertEq(out, amount);
        assertEq(used, cost);

        (,, uint256 funds,) = p3.trySell(t, FLY_TPS);
        assertGt(funds, 0);
        uint256 bnb0 = w.balance;
        vm.startPrank(w, w);
        IERC20(t).approve(address(pad), FLY_TPS);
        uint256 paid = p3.sellToken(0, t, w, FLY_TPS, funds, 0, address(0));
        vm.stopPrank();
        assertEq(paid, funds);
        assertEq(w.balance - bnb0, funds);
        assertEq(IERC20(t).balanceOf(w), amount - FLY_TPS);
    }

    function _poolSell(address t, address who, uint256 amount) internal returns (uint256 out) {
        TwapMockPair p = TwapMockPair(fly.sales(t).pair);
        vm.prank(who);
        IERC20(t).transfer(address(p), amount);
        (uint112 r0, uint112 r1,) = p.getReserves();
        bool t0 = p.token0() == t;
        (uint256 rT, uint256 rQ) = t0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 inAmt = IERC20(t).balanceOf(address(p)) - rT;
        uint256 inFee = inAmt * 9975;
        out = (inFee * rQ) / (rT * 10_000 + inFee);
        p.swap(t0 ? 0 : out, t0 ? out : 0, who, "");
    }
}
