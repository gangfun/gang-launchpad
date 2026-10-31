// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MockPair} from "../../src/launchpad-v2/mocks/MockPairFactory.sol";
import {SharedMigrator} from "../../src/common/SharedMigrator.sol";
import {PostGradHandlerBase} from "../../src/common/PostGradHandlerBase.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {GangToken as TaxLaunchTokenV3} from "../../src/gang/GangToken.sol";
import {GangTaxHandler as HolderRewardHandler} from "../../src/gang/GangTaxHandler.sol";
import {LaunchpadV3Test} from "../launchpad-v3/LaunchpadV3.t.sol";
import {SharedInfraTest} from "../common/SharedInfra.t.sol";

/// @dev 18-decimal quote whose 1% transfer fee can be switched on after create (or is on from the start).
contract SwitchFeeQuote is ERC20("Switch Fee", "SWF") {
    bool public feeOn;

    function setFee(bool on) external {
        feeOn = on;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (feeOn && from != address(0) && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, address(0), fee);
            value -= fee;
        }
        super._update(from, to, value);
    }
}

/// @notice Internal audit round 4 (audit4-a / -b / -c) regressions on LaunchpadV3, its tax handler and the shared vault.
contract Audit4V3RegressionTest is LaunchpadV3Test {
    SwitchFeeQuote internal swf;

    function _createOnSwf(uint16 dividendBps) internal returns (address token) {
        swf = new SwitchFeeQuote();
        vm.prank(owner);
        quoteRegistry.setQuote(address(swf), true, 15 ether); // fixed rate: no reference pool needed in the fixture
        vm.prank(agent);
        // the 15 BNB target (1.0's): the pool these cases trade against is the depth they were written for
        token = pad.createWithGradTarget(
            "S", "S", "", "", address(swf), address(0), _tax(300, 300, dividendBps, treasury), 15 ether
        );
    }

    function _fundSwf(address who) internal {
        _agent(who);
        swf.mint(who, 1_000 ether);
        vm.prank(who);
        swf.approve(address(pad), type(uint256).max);
    }

    /// @dev audit4-c F-1/F-2, audit4-a F-1, audit4-b F-2: a fee-on-transfer quote is refused on the first pull, so it
    ///      can neither strand a curve before graduation nor under-fund the shared vault / bucket.
    function test_audit4_fotQuoteRefusedOnFirstBuy() public {
        address t = _createOnSwf(5000);
        swf.setFee(true);
        _fundSwf(agent2);
        vm.prank(agent2);
        vm.expectRevert(IGangLaunchpad.FeeOnTransferQuote.selector);
        pad.buy(t, 1 ether, 0);
    }

    /// @dev audit4-c F-3 / F-4, audit4-b F1, audit4-a F-2: no token of this platform can be a quote — not a locked
    ///      sibling (wallet-cap bypass), not an untaxed one the vault never registered, not a graduated dividend token.
    function test_audit4_launchTokenIsNeverAQuote() public {
        address plain = _create(_tax(0, 0, 0, address(0))); // untaxed: TokenDeployer knows it, the vault does not
        assertEq(divVault.launchpadOf(plain), address(0));
        address divTok = _create(_tax(300, 300, 10_000, address(0)));
        _graduate(divTok);
        address[2] memory quotes = [plain, divTok];
        for (uint256 i = 0; i < 2; i++) {
            vm.prank(owner);
            quoteRegistry.setQuote(quotes[i], true, 15 ether);
            vm.prank(agent);
            vm.expectRevert(IGangLaunchpad.QuoteNotAllowed.selector);
            pad.create("Y", "Y", "", "", quotes[i], address(0), _tax(300, 300, 5000, treasury));
        }
    }

    /// @dev audit4-a F-2 / audit4-c F-4: the vault never holds a dividend share of its own.
    function test_audit4_vaultExcludesItself() public view {
        assertTrue(divVault.excluded(address(divVault)));
    }

    /// @dev audit4-a F-1 / audit4-c F-2 (defensive) and audit4-b Info: a quote that turns a fee on after graduation.
    ///      The direct-pair sale re-checks what arrived (Slippage instead of a short payout), and the vault credits only
    ///      the quote that actually reached it.
    function test_audit4_feeSwitchedOnLater_pairSaleRechecks_vaultCreditsArrived() public {
        vm.prank(owner);
        pad.setWalletCapEnabled(false);
        address t = _createOnSwf(5000);
        _fundSwf(agent2);
        vm.prank(agent2);
        pad.buy(t, 2 ether, 0); // a dividend holder
        address w = makeAddr("filler");
        _fundSwf(w);
        vm.prank(w);
        pad.buy(t, 20 ether, 0); // graduates
        assertTrue(_graduated(t));

        // pool buy → tax accrues on the handler (fee still off)
        MockPair pair = MockPair(TaxLaunchTokenV3(t).pair());
        swf.mint(address(pair), 5 ether);
        (uint256 rT, uint256 rQ) = _reserves(t, pair);
        uint256 out = (5 ether * rT) / (rQ + 5 ether) / 2;
        if (pair.token0() == t) pair.swap(out, 0, agent2, "");
        else pair.swap(0, out, agent2, "");
        uint256 acc = handler.accruedTax(t);
        assertGt(acc, 0);

        swf.setFee(true);
        (rT, rQ) = _reserves(t, pair);
        uint256 expected = (acc * 9975 * rQ) / (rT * 10_000 + acc * 9975);
        vm.prank(keeper);
        vm.expectRevert(PostGradHandlerBase.Slippage.selector); // 1% less arrives than the pair quoted
        handler.process(t, type(uint256).max, expected);

        uint256 vaultBefore = swf.balanceOf(address(divVault));
        vm.prank(keeper);
        handler.process(t, type(uint256).max, 1);
        uint256 arrived = swf.balanceOf(address(divVault)) - vaultBefore;
        // post-grad dividends are credited at tax time in units and settle at the quote their sale brought in
        (,, uint64 settled) = divVault.pipeOf(t);
        (,, uint256 credited,,) = divVault.batchOf(t, settled);
        assertGt(arrived, 0);
        assertLe(credited, arrived, "never credits more than arrived");
        assertGt(credited, arrived - arrived / 1e6, "credits what arrived (rounding only)");
    }

    /// @dev audit4-a F-4: the first LP position must go to 0xdead whole — a pair already holding LP is refused.
    function test_audit4_migratorRefusesPairWithLp() public {
        SharedMigrator m = new SharedMigrator(owner, address(pairFactory));
        vm.prank(owner);
        m.addLaunchpad(address(this));
        MockSPCXB2 a = new MockSPCXB2();
        MockSPCXB2 b = new MockSPCXB2();
        address p = pairFactory.createPair(address(a), address(b));
        a.mint(address(m), 2 ether);
        b.mint(address(m), 2 ether);

        vm.mockCall(p, abi.encodeWithSignature("totalSupply()"), abi.encode(uint256(1000)));
        vm.expectRevert(SharedMigrator.PairHasLiquidity.selector);
        m.migrate(address(a), address(b), 1 ether, 1 ether);

        vm.mockCall(p, abi.encodeWithSignature("totalSupply()"), abi.encode(uint256(0)));
        assertEq(m.migrate(address(a), address(b), 1 ether, 1 ether), p, "an empty pre-created pair still works");
        vm.clearMockedCalls();
    }
}

contract MockSPCXB2 is ERC20("M2", "M2") {
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Round-4 regressions on the 打新 side of the shared infrastructure.
contract Audit4SharedRegressionTest is SharedInfraTest {
    /// @dev audit4-a F-3 / audit 5 C-F10, merged: the one handler takes tax reports only from tokens the pad
    ///      registered (route kind != 0) — not from any contract naming itself as `token`.
    function test_audit4_holderHandlerRefusesUnregisteredTokens() public {
        address fake = makeAddr("fakeToken");
        HolderRewardHandler h = HolderRewardHandler(fair.taxHandler());
        vm.prank(fake);
        vm.expectRevert(HolderRewardHandler.UnknownToken.selector);
        h.notifyTax(fake, address(1), address(2), 1e30, 100);

        address v3tok = _v3Token(10_000);
        address fairTok = _fairSale();
        (,,, uint8 k1) = h.routeOf(v3tok);
        (,,, uint8 k2) = h.routeOf(fairTok);
        assertEq(k1, 1, "curve route");
        assertEq(k2, 2, "fair route");
        assertEq(fair.kindOf(v3tok), 1);
        assertEq(fair.kindOf(fairTok), 2);
    }

    /// @dev audit4-c F-3 (打新 side): neither core's tokens can be a 打新 quote; nor a 打新 token a V3 quote.
    function test_audit4_crossCoreLaunchTokensAreNotQuotes() public {
        address v3tok = _v3Token(10_000);
        address fairTok = _fairSale();
        IGangLaunchpad.MintConfig memory cfg = IGangLaunchpad.MintConfig({
            raiseBnb: 15 ether, capBps: 50, holdBps: 6000, mintFeeBps: 100, exitFeeBps: 200
        });
        vm.startPrank(agent);
        vm.expectRevert(IGangLaunchpad.QuoteNotAllowed.selector);
        fair.create("Q", "Q", "", "", v3tok, address(0), cfg, 1);
        vm.expectRevert(IGangLaunchpad.QuoteNotAllowed.selector);
        fair.create("Q", "Q", "", "", fairTok, address(0), cfg, 1);
        vm.expectRevert(IGangLaunchpad.QuoteNotAllowed.selector);
        v3.create("Q", "Q", "", "", fairTok, address(0), _tax(10_000));
        vm.stopPrank();
        assertTrue(v3Vault.excluded(address(v3Vault)));
    }
}
