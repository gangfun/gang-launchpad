// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MockSPCXB} from "../../src/launchpad-v2/mocks/MockSPCXB.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {GangRouter, IGangPadEntry} from "../../src/router/GangRouter.sol";
import {MockAgentId} from "../mocks/MockAgentId.sol";
import {MockWBNB} from "../mocks/MockWBNB.sol";
import {MockGangPad} from "./mocks/MockGangPad.sol";

/// @notice GangRouter in front of the one pad (V3 curves and 打新 sales): BNB in / refunds out, the trader (not the
///         router) gets tokens and shares, gate and cap apply to the trader; only listed routers may buy / mint for
///         someone; sells / withdraw / claim have no router entry at all; a token of the other kind is unknown.
/// @dev INTEGRATION: the pad is MockGangPad (test/router/mocks, router-facing surface only). Replace `_deployPad`,
///      `_v3Token` and `_fairSale` with GangFixture's real GangLaunchpad (`create(..., TaxConfig)` /
///      `create(..., MintConfig, 1)` pranked as `agent`) and delete the mock; every assertion below stays.
contract GangRouterTest is Test {
    MockWBNB internal wbnb;
    MockSPCXB internal quoteTok;
    MockAgentId internal agents;

    MockGangPad internal pad;
    GangRouter internal router;

    address internal owner = makeAddr("owner");
    address internal agent = makeAddr("agent");
    address internal agent2 = makeAddr("agent2");
    address internal human = makeAddr("human"); // no Agent ID
    uint256 internal nextId = 1;

    event Buy(
        address indexed token,
        address indexed buyer,
        uint256 quoteIn,
        uint256 protocolFee,
        uint256 tax,
        uint256 tokensOut,
        uint256 realQuote
    );

    function setUp() public {
        wbnb = new MockWBNB();
        vm.deal(address(wbnb), 10_000 ether); // backs withdrawals of faucet-minted WBNB
        quoteTok = new MockSPCXB();
        agents = new MockAgentId();
        _deployPad();
        router = new GangRouter(address(pad), address(wbnb));
        vm.prank(owner);
        pad.setRouter(address(router), true);

        _agent(agent);
        _agent(agent2);
        vm.deal(human, 100 ether);
    }

    // ---------------------------------------------------------------- pad (INTEGRATION: GangFixture)
    function _deployPad() internal {
        pad = new MockGangPad(owner, address(wbnb), address(agents));
    }

    /// @dev V3 token in `quote` (address(0) → WBNB), created by `agent`.
    function _v3Token(address quote) internal returns (address token) {
        vm.prank(agent);
        token = pad.createCurve(quote);
    }

    /// @dev WBNB 打新 sale (cap 100 shares, mint fee 1%), created by `agent` with 1 dev share.
    function _fairSale() internal returns (address token) {
        vm.prank(agent);
        token = pad.createSale(address(0), 1);
    }

    // ---------------------------------------------------------------- helpers
    function _agent(address who) internal {
        if (agents.balanceOf(who) == 0) agents.mint(who, nextId++);
        vm.deal(who, 1_000 ether);
        wbnb.mintUnlimited(who, 1_000 ether);
        quoteTok.mintUnlimited(who, 1_000 ether);
        vm.startPrank(who);
        wbnb.approve(address(pad), type(uint256).max);
        wbnb.approve(address(router), type(uint256).max);
        quoteTok.approve(address(pad), type(uint256).max);
        quoteTok.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _assertRouterEmpty() internal view {
        assertEq(wbnb.balanceOf(address(router)), 0, "router WBNB");
        assertEq(quoteTok.balanceOf(address(router)), 0, "router quote");
        assertEq(address(router).balance, 0, "router BNB");
    }

    function _v3Graduated(address token) internal view returns (bool g) {
        (,,,,,, g,,,,,) = pad.curves(token);
    }

    function _launched(address token) internal view returns (bool l) {
        (,,,,,, l,,,,,,,) = pad.sales(token);
    }

    // ---------------------------------------------------------------- one pad
    function test_bothGettersAreThePad() public view {
        assertEq(address(router.pad()), address(pad));
        assertEq(address(router.v3()), address(pad), "v3() = the pad");
        assertEq(address(router.fair()), address(pad), "fair() = the pad");
        assertEq(router.wbnb(), address(wbnb));
    }

    function test_constructorNeedsPadAndWbnb() public {
        vm.expectRevert(GangRouter.NotDeployed.selector);
        new GangRouter(address(0), address(wbnb));
        vm.expectRevert(GangRouter.NotDeployed.selector);
        new GangRouter(address(pad), address(0));
    }

    /// @dev Same pad, other kind: a 打新 token has no curve, a V3 token has no sale.
    function test_otherKindIsUnknown() public {
        address v3Token = _v3Token(address(0));
        address sale = _fairSale();
        vm.startPrank(agent2);
        vm.expectRevert(GangRouter.UnknownToken.selector);
        router.v3BuyBNB{value: 0.1 ether}(sale, 0, block.timestamp);
        vm.expectRevert(GangRouter.UnknownToken.selector);
        router.v3Buy(sale, 0.1 ether, 0, block.timestamp);
        vm.expectRevert(GangRouter.UnknownToken.selector);
        router.fairMintBNB{value: 1 ether}(v3Token, 10, 1, block.timestamp);
        vm.expectRevert(GangRouter.UnknownToken.selector);
        router.fairMint(v3Token, 10, 1, block.timestamp);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- V3 buys
    function test_v3BuyBNB_traderGetsTokens() public {
        address token = _v3Token(address(0));
        vm.expectEmit(true, true, false, false, address(pad));
        emit Buy(token, agent2, 0, 0, 0, 0, 0);
        vm.prank(agent2);
        uint256 out = router.v3BuyBNB{value: 0.1 ether}(token, 1, block.timestamp);
        assertGt(out, 0);
        assertEq(IERC20(token).balanceOf(agent2), out, "trader holds the tokens");
        assertEq(IERC20(token).balanceOf(address(router)), 0, "router holds none");
        _assertRouterEmpty();
    }

    function test_v3Buy_sameAsDirectBuy() public {
        address token = _v3Token(address(0));
        uint256 snap = vm.snapshotState();
        vm.prank(agent2);
        uint256 direct = pad.buy(token, 0.1 ether, 0);
        vm.revertToState(snap);
        vm.prank(agent2);
        uint256 routed = router.v3Buy(token, 0.1 ether, 0, block.timestamp);
        assertEq(routed, direct, "routing changes nothing on the curve");
        _assertRouterEmpty();
    }

    function test_v3Buy_erc20Quote() public {
        address token = _v3Token(address(quoteTok));
        uint256 before = quoteTok.balanceOf(agent2);
        vm.prank(agent2);
        uint256 out = router.v3Buy(token, 0.02 ether, 1, block.timestamp); // under the 1% cap: no refund
        assertEq(IERC20(token).balanceOf(agent2), out);
        assertEq(before - quoteTok.balanceOf(agent2), 0.02 ether);
        _assertRouterEmpty();
        // native BNB only buys WBNB-quoted tokens
        vm.prank(agent2);
        vm.expectRevert(GangRouter.NotWbnbQuote.selector);
        router.v3BuyBNB{value: 0.1 ether}(token, 0, block.timestamp);
    }

    function test_v3_gateIsOnTheTrader() public {
        address token = _v3Token(address(0));
        vm.prank(human);
        vm.expectRevert(IGangLaunchpad.NotAgent.selector);
        router.v3BuyBNB{value: 0.1 ether}(token, 0, block.timestamp);
    }

    function test_v3_capRefundComesBackAsBnb() public {
        address token = _v3Token(address(0));
        uint256 bal = agent2.balance;
        vm.prank(agent2);
        uint256 out = router.v3BuyBNB{value: 5 ether}(token, 0, block.timestamp); // far past the 1% cap
        assertEq(out, pad.MAX_PER_WALLET(), "capped at 1%");
        uint256 spent = bal - agent2.balance;
        assertLt(spent, 5 ether, "excess refunded");
        assertGt(spent, 0);
        _assertRouterEmpty();
        vm.prank(agent2);
        vm.expectRevert(IGangLaunchpad.WalletCapReached.selector);
        router.v3BuyBNB{value: 0.1 ether}(token, 0, block.timestamp);
    }

    /// @dev The pad sees the trader (dividend weight, cap and gate are the trader's), never the router.
    function test_v3_padSeesTheTrader() public {
        address token = _v3Token(address(0));
        vm.expectCall(
            address(pad), abi.encodeCall(IGangPadEntry.buyFor, (agent2, token, 0.5 ether, 0)), uint64(1)
        );
        vm.prank(agent2);
        router.v3BuyBNB{value: 0.5 ether}(token, 0, block.timestamp);
        assertGt(IERC20(token).balanceOf(agent2), 0, "trader holds");
        assertEq(IERC20(token).balanceOf(address(router)), 0, "router never holds");
    }

    function test_v3_graduatesThroughRouter() public {
        address token = _v3Token(address(0));
        for (uint256 i = 0; i < 200 && !_v3Graduated(token); i++) {
            address w = address(uint160(0xC0000 + i));
            _agent(w);
            vm.prank(w);
            router.v3BuyBNB{value: 1 ether}(token, 0, block.timestamp);
        }
        assertTrue(_v3Graduated(token), "graduated");
        _assertRouterEmpty();
    }

    function test_v3_expired() public {
        address token = _v3Token(address(0));
        vm.warp(1000);
        vm.prank(agent2);
        vm.expectRevert(GangRouter.Expired.selector);
        router.v3BuyBNB{value: 0.1 ether}(token, 0, 999);
    }

    function test_v3_onlyListedRouterBuysFor() public {
        address token = _v3Token(address(0));
        vm.prank(agent2);
        vm.expectRevert(IGangLaunchpad.OnlyRouter.selector);
        pad.buyFor(agent2, token, 0.1 ether, 0);

        vm.prank(owner);
        pad.setRouter(address(router), false);
        vm.prank(agent2);
        vm.expectRevert(IGangLaunchpad.OnlyRouter.selector);
        router.v3BuyBNB{value: 0.1 ether}(token, 0, block.timestamp);
    }

    /// @dev Worst case of a listed router: it buys for someone with its own money. The trader has approved the pad
    ///      for both the quote and the token (as anyone who sells does), yet nothing of theirs can move: the pad has
    ///      no entry that spends or sells for a trader, only buyFor / mintFor paid by the router itself.
    function test_v3_listedRouterOnlySpendsItsOwnQuote() public {
        address token = _v3Token(address(0));
        vm.prank(agent2);
        pad.buy(token, 0.01 ether, 0);
        vm.prank(agent2);
        IERC20(token).approve(address(pad), type(uint256).max); // a seller's standing approval

        address rogue = makeAddr("rogue");
        vm.prank(owner);
        pad.setRouter(rogue, true);
        wbnb.mintUnlimited(rogue, 1 ether);
        vm.prank(rogue);
        wbnb.approve(address(pad), type(uint256).max);

        uint256 quoteBefore = wbnb.balanceOf(agent2);
        uint256 tokensBefore = IERC20(token).balanceOf(agent2);
        vm.prank(rogue);
        uint256 out = pad.buyFor(agent2, token, 0.01 ether, 0);
        assertEq(wbnb.balanceOf(agent2), quoteBefore, "trader paid nothing");
        assertEq(IERC20(token).balanceOf(agent2), tokensBefore + out, "only a gift to the trader");
        assertEq(IERC20(token).balanceOf(rogue), 0);
        assertEq(wbnb.balanceOf(rogue), 1 ether - 0.01 ether, "the router spent its own quote");

        // no way to spend or sell for someone else
        bytes[4] memory calls = [
            abi.encodeWithSignature("sellFor(address,address,uint256,uint256)", agent2, token, tokensBefore, 0),
            abi.encodeWithSignature("buyFrom(address,address,uint256,uint256)", agent2, token, 0.1 ether, 0),
            abi.encodeWithSignature(
                "createFor(address,string,string,string,address,address,(uint16,uint16,uint16,address))",
                agent2,
                "X",
                "X",
                "",
                address(0),
                address(0),
                IGangLaunchpad.TaxConfig({buyTaxBps: 0, sellTaxBps: 0, dividendBps: 0, recipient: address(0)})
            ),
            abi.encodeWithSignature("sell(address,uint256,uint256)", token, tokensBefore, 0) // the rogue's own (none)
        ];
        for (uint256 i = 0; i < calls.length; i++) {
            vm.prank(rogue);
            (bool ok,) = address(pad).call(calls[i]);
            assertFalse(ok, "no spend-for-someone entry");
        }
        assertEq(IERC20(token).balanceOf(agent2), tokensBefore + out, "trader's tokens untouched");
        assertEq(wbnb.balanceOf(agent2), quoteBefore, "trader's quote untouched");
    }

    /// @dev Same for 打新: a listed router can mint for a trader with its own quote, and nothing else. The trader's
    ///      position (withdraw) and reward (claim) stay msg.sender-only.
    function test_fair_listedRouterOnlySpendsItsOwnQuote() public {
        address token = _fairSale();
        vm.prank(agent2);
        pad.mint(token, 20, 20);

        address rogue = makeAddr("rogue");
        vm.prank(owner);
        pad.setRouter(rogue, true);
        wbnb.mintUnlimited(rogue, 1 ether);
        vm.prank(rogue);
        wbnb.approve(address(pad), type(uint256).max);

        uint256 quoteBefore = wbnb.balanceOf(agent2);
        vm.prank(rogue);
        pad.mintFor(agent2, token, 10, 10);
        uint16 shares = pad.positions(token, agent2);
        assertEq(shares, 30, "gift of 10 shares");
        assertEq(wbnb.balanceOf(agent2), quoteBefore, "trader paid nothing");

        bytes[3] memory calls = [
            abi.encodeWithSignature("withdrawFor(address,address,uint256)", agent2, token, 30),
            abi.encodeWithSignature("refundFor(address,address)", agent2, token),
            abi.encodeWithSignature("withdraw(address,uint256,uint256)", token, 30, 0) // the rogue's own position (none)
        ];
        for (uint256 i = 0; i < calls.length; i++) {
            vm.prank(rogue);
            (bool ok,) = address(pad).call(calls[i]);
            assertFalse(ok, "no spend-for-someone entry");
        }
        shares = pad.positions(token, agent2);
        assertEq(shares, 30, "trader's position untouched");
        assertEq(wbnb.balanceOf(agent2), quoteBefore, "trader's quote untouched");
    }

    function test_unknownToken() public {
        vm.prank(agent2);
        vm.expectRevert(GangRouter.UnknownToken.selector);
        router.v3BuyBNB{value: 0.1 ether}(makeAddr("nope"), 0, block.timestamp);
        vm.prank(agent2);
        vm.expectRevert(GangRouter.UnknownToken.selector);
        router.fairMintBNB{value: 0.1 ether}(makeAddr("nope"), 1, 1, block.timestamp);
    }

    function test_rejectsStrayBnb() public {
        vm.prank(agent2);
        (bool ok,) = address(router).call{value: 1 ether}("");
        assertFalse(ok, "only WBNB unwraps may send BNB");
    }

    // ---------------------------------------------------------------- 打新 mints
    function test_fairMintBNB_positionIsTheTraders() public {
        address token = _fairSale();
        (, uint256 cost, uint256 fee) = pad.previewMint(token, agent2, 40);
        uint256 bal = agent2.balance;
        vm.prank(agent2);
        uint256 accepted = router.fairMintBNB{value: 1 ether}(token, 40, 40, block.timestamp);
        assertEq(accepted, 40);
        assertEq(bal - agent2.balance, cost + fee, "exactly cost + mint fee, rest refunded");
        uint16 shares = pad.positions(token, agent2);
        assertEq(shares, 40);
        uint16 routerShares = pad.positions(token, address(router));
        assertEq(routerShares, 0);
        assertEq(IERC20(token).balanceOf(agent2), 40 * pad.TOKENS_PER_SHARE());
        _assertRouterEmpty();
    }

    function test_fairMint_erc20AndCapTruncation() public {
        address token = _fairSale();
        vm.prank(agent2);
        uint256 a = router.fairMint(token, 150, 1, block.timestamp); // cap is 100 shares
        assertEq(a, 100);
        _assertRouterEmpty();
        vm.prank(agent2);
        vm.expectRevert(IGangLaunchpad.WalletCapReached.selector);
        router.fairMint(token, 1, 1, block.timestamp);
    }

    function test_fairMintBNB_notEnoughValue() public {
        address token = _fairSale();
        vm.prank(agent2);
        vm.expectRevert(GangRouter.NotEnoughValue.selector);
        router.fairMintBNB{value: 0.001 ether}(token, 40, 40, block.timestamp);
    }

    function test_fair_gateOnTrader_andOnlyRouter() public {
        address token = _fairSale();
        vm.prank(human);
        vm.expectRevert(IGangLaunchpad.NotAgent.selector);
        router.fairMintBNB{value: 1 ether}(token, 10, 1, block.timestamp);

        vm.prank(agent2);
        vm.expectRevert(IGangLaunchpad.OnlyRouter.selector);
        pad.mintFor(agent2, token, 10, 1);
    }

    /// @dev A mint made through the router sells back to the trader (never the router): once stale, at full principal.
    function test_fair_withdrawGoesToTheTrader() public {
        address token = _fairSale();
        (, uint256 cost,) = pad.previewMint(token, agent2, 30);
        vm.prank(agent2);
        router.fairMintBNB{value: 1 ether}(token, 30, 30, block.timestamp);
        vm.warp(block.timestamp + 7 days);
        uint256 before = wbnb.balanceOf(agent2);
        vm.prank(agent2);
        pad.withdraw(token, 30, 0);
        assertEq(wbnb.balanceOf(agent2) - before, cost, "stale: principal back, no exit fee");
        assertEq(wbnb.balanceOf(address(router)), 0);
    }

    function test_fair_fillsAndLaunchesThroughRouter() public {
        address token = _fairSale();
        for (uint256 i = 0; i < 101; i++) {
            address m = address(uint160(0xD0000 + i));
            _agent(m);
            vm.prank(m);
            router.fairMintBNB{value: 1 ether}(token, 100, 1, block.timestamp);
            if (_launched(token)) break;
        }
        (,,,,,, bool done,,,,, address pair,,) = pad.sales(token);
        assertTrue(done, "launched");
        assertTrue(pair != address(0));
        _assertRouterEmpty();
    }
}
