// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {QuoteRegistry} from "../../src/launchpad-v2/QuoteRegistry.sol";
import {SharedDividendVault} from "../../src/common/SharedDividendVault.sol";
import {PlatformFeeBucket} from "../../src/launchpad-v2/PlatformFeeBucket.sol";
import {SharedMigrator} from "../../src/common/SharedMigrator.sol";
import {TokenDeployer} from "../../src/common/TokenDeployer.sol";
import {MockSPCXB} from "../../src/launchpad-v2/mocks/MockSPCXB.sol";
import {MockPairFactory} from "../../src/launchpad-v2/mocks/MockPairFactory.sol";
import {GangLaunchpad as LaunchpadV3} from "../../src/gang/GangLaunchpad.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {GangTaxHandler as TaxHandlerV3} from "../../src/gang/GangTaxHandler.sol";
import {IGangLaunchpad as ILaunchpadV3} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {GangLaunchpad as FairMintPad} from "../../src/gang/GangLaunchpad.sol";
import {GangTaxHandler as HolderRewardHandler} from "../../src/gang/GangTaxHandler.sol";
import {GangRouter} from "../../src/router/GangRouter.sol";
import {MockAgentId} from "../mocks/MockAgentId.sol";
import {MockWBNB} from "../mocks/MockWBNB.sol";

/// @notice GangRouter in front of both cores: BNB in / refunds out, the trader (not the router) gets tokens, shares,
///         dividend weight, gate and cap; only listed routers may buy / mint for someone; sells / withdraw /
///         claim have no router entry at all.
contract GangRouterTest is Test {
    MockWBNB internal wbnb;
    MockSPCXB internal quoteTok;
    MockAgentId internal agents;
    MockPairFactory internal pairFactory;

    LaunchpadV3 internal v3;
    SharedDividendVault internal v3Vault;
    SharedMigrator internal sharedMig;
    TokenDeployer internal tokenDeployer;
    FairMintPad internal fair;
    GangRouter internal router;

    address internal owner = makeAddr("owner");
    address internal treasury = makeAddr("treasury");
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
        pairFactory = new MockPairFactory();
        // one vault / migrator / deployer for both cores, as deployed
        v3Vault = new SharedDividendVault(owner);
        sharedMig = new SharedMigrator(owner, address(pairFactory));
        tokenDeployer = new TokenDeployer(owner);
        _deployPad();
        // one pad for both kinds: GangRouter's two cores are the same address
        router = new GangRouter(address(v3), address(fair), address(wbnb));
        vm.prank(owner);
        v3.setRouter(address(router), true);

        _agent(agent);
        _agent(agent2);
        vm.deal(human, 100 ether);
    }

    function _deployPad() internal {
        QuoteRegistry reg = new QuoteRegistry(owner);
        PlatformFeeBucket bucket = new PlatformFeeBucket(owner, makeAddr("feeVault"));
        TaxHandlerV3 handler = new TaxHandlerV3(owner, address(v3Vault), address(bucket), address(0));
        v3 = new LaunchpadV3(
            owner,
            address(reg),
            address(v3Vault),
            address(bucket),
            address(handler),
            address(tokenDeployer),
            address(wbnb),
            address(pairFactory)
        );
        fair = v3;
        SharedMigrator mig = sharedMig;
        vm.startPrank(owner);
        reg.setQuote(address(quoteTok), true, 15 ether);
        v3Vault.setLaunchpad(address(v3), true);
        v3Vault.setOperator(address(handler), address(v3));
        mig.addLaunchpad(address(v3));
        tokenDeployer.setLaunchpad(address(v3), true);
        bucket.setLaunchpad(address(v3));
        bucket.setOperator(address(handler), true);
        handler.setLaunchpad(address(v3));
        handler.list(treasury, "partner treasury");
        handler.setKeeper(owner);
        v3.setMigrator(address(mig));
        v3.setAgentGate(true, address(agents));
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- helpers
    function _agent(address who) internal {
        if (agents.balanceOf(who) == 0) agents.mint(who, nextId++);
        vm.deal(who, 1_000 ether);
        wbnb.mintUnlimited(who, 1_000 ether);
        quoteTok.mintUnlimited(who, 1_000 ether);
        vm.startPrank(who);
        wbnb.approve(address(v3), type(uint256).max);
        wbnb.approve(address(fair), type(uint256).max);
        wbnb.approve(address(router), type(uint256).max);
        quoteTok.approve(address(v3), type(uint256).max);
        quoteTok.approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _tax(uint16 dividendBps) internal view returns (ILaunchpadV3.TaxConfig memory) {
        return ILaunchpadV3.TaxConfig({buyTaxBps: 200, sellTaxBps: 200, dividendBps: dividendBps, recipient: treasury});
    }

    /// @dev WBNB-quoted V3 token (quote = address(0) → WBNB)
    function _v3Token(uint16 dividendBps) internal returns (address token) {
        vm.prank(agent);
        token = v3.create("Tax", "TAX", "", "", address(0), address(0), _tax(dividendBps));
    }

    function _fairSale() internal returns (address token) {
        IGangLaunchpad.MintConfig memory cfg = IGangLaunchpad.MintConfig({
            raiseBnb: 15 ether, capBps: 50, holdBps: 5000, mintFeeBps: 100, exitFeeBps: 200
        });
        vm.prank(agent);
        token = fair.create("Fair", "FAIR", "", "", address(0), address(0), cfg, 1);
    }

    function _assertRouterEmpty() internal view {
        assertEq(wbnb.balanceOf(address(router)), 0, "router WBNB");
        assertEq(quoteTok.balanceOf(address(router)), 0, "router quote");
        assertEq(address(router).balance, 0, "router BNB");
    }

    function _v3Graduated(address token) internal view returns (bool g) {
        (,,,,,, g,,,,,) = v3.curves(token);
    }

    // ---------------------------------------------------------------- V3 buys
    function test_v3BuyBNB_traderGetsTokens() public {
        address token = _v3Token(0);
        vm.expectEmit(true, true, false, false, address(v3));
        emit Buy(token, agent2, 0, 0, 0, 0, 0);
        vm.prank(agent2);
        uint256 out = router.v3BuyBNB{value: 0.1 ether}(token, 1, block.timestamp);
        assertGt(out, 0);
        assertEq(IERC20(token).balanceOf(agent2), out, "trader holds the tokens");
        assertEq(IERC20(token).balanceOf(address(router)), 0, "router holds none");
        _assertRouterEmpty();
    }

    function test_v3Buy_sameAsDirectBuy() public {
        address token = _v3Token(0);
        uint256 snap = vm.snapshotState();
        vm.prank(agent2);
        uint256 direct = v3.buy(token, 0.1 ether, 0);
        vm.revertToState(snap);
        vm.prank(agent2);
        uint256 routed = router.v3Buy(token, 0.1 ether, 0, block.timestamp);
        assertEq(routed, direct, "routing changes nothing on the curve");
        _assertRouterEmpty();
    }

    function test_v3Buy_erc20Quote() public {
        vm.prank(agent);
        address token = v3.create("Q", "Q", "", "", address(quoteTok), address(0), _tax(0));
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
        address token = _v3Token(0);
        vm.prank(human);
        vm.expectRevert(IGangLaunchpad.NotAgent.selector);
        router.v3BuyBNB{value: 0.1 ether}(token, 0, block.timestamp);
    }

    function test_v3_capRefundComesBackAsBnb() public {
        address token = _v3Token(0);
        uint256 bal = agent2.balance;
        vm.prank(agent2);
        uint256 out = router.v3BuyBNB{value: 5 ether}(token, 0, block.timestamp); // far past the 1% cap
        assertEq(out, v3.MAX_PER_WALLET(), "capped at 1%");
        uint256 spent = bal - agent2.balance;
        assertLt(spent, 5 ether, "excess refunded");
        assertGt(spent, 0);
        _assertRouterEmpty();
        vm.prank(agent2);
        vm.expectRevert(IGangLaunchpad.WalletCapReached.selector);
        router.v3BuyBNB{value: 0.1 ether}(token, 0, block.timestamp);
    }

    function test_v3_dividendShareIsTheTraders() public {
        address token = _v3Token(5000);
        vm.prank(agent2);
        router.v3BuyBNB{value: 0.5 ether}(token, 0, block.timestamp);
        assertEq(v3Vault.shares(token, agent2), IERC20(token).balanceOf(agent2), "trader weighted");
        assertEq(v3Vault.shares(token, address(router)), 0, "router never weighted");
    }

    function test_v3_graduatesThroughRouter() public {
        address token = _v3Token(0);
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
        address token = _v3Token(0);
        vm.warp(1000);
        vm.prank(agent2);
        vm.expectRevert(GangRouter.Expired.selector);
        router.v3BuyBNB{value: 0.1 ether}(token, 0, 999);
    }

    function test_v3_onlyListedRouterBuysFor() public {
        address token = _v3Token(0);
        vm.prank(agent2);
        vm.expectRevert(IGangLaunchpad.OnlyRouter.selector);
        v3.buyFor(agent2, token, 0.1 ether, 0);

        vm.prank(owner);
        v3.setRouter(address(router), false);
        vm.prank(agent2);
        vm.expectRevert(IGangLaunchpad.OnlyRouter.selector);
        router.v3BuyBNB{value: 0.1 ether}(token, 0, block.timestamp);
    }

    /// @dev Worst case of a listed router: it buys for someone with its own money. The trader has approved the core
    ///      for both the quote and the token (as anyone who sells does), yet nothing of theirs can move: the cores have
    ///      no entry that spends or sells for a trader, only buyFor / mintFor paid by the router itself.
    function test_v3_listedRouterOnlySpendsItsOwnQuote() public {
        address token = _v3Token(0);
        vm.prank(agent2);
        v3.buy(token, 0.01 ether, 0);
        vm.prank(agent2);
        IERC20(token).approve(address(v3), type(uint256).max); // a seller's standing approval

        address rogue = makeAddr("rogue");
        vm.prank(owner);
        v3.setRouter(rogue, true);
        wbnb.mintUnlimited(rogue, 1 ether);
        vm.prank(rogue);
        wbnb.approve(address(v3), type(uint256).max);

        uint256 quoteBefore = wbnb.balanceOf(agent2);
        uint256 tokensBefore = IERC20(token).balanceOf(agent2);
        vm.prank(rogue);
        uint256 out = v3.buyFor(agent2, token, 0.01 ether, 0);
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
                _tax(0)
            ),
            abi.encodeWithSignature("sell(address,uint256,uint256)", token, tokensBefore, 0) // sells the rogue's own (none)
        ];
        for (uint256 i = 0; i < calls.length; i++) {
            vm.prank(rogue);
            (bool ok,) = address(v3).call(calls[i]);
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
        fair.mint(token, 20, 20);

        address rogue = makeAddr("rogue");
        vm.prank(owner);
        fair.setRouter(rogue, true);
        wbnb.mintUnlimited(rogue, 1 ether);
        vm.prank(rogue);
        wbnb.approve(address(fair), type(uint256).max);

        uint256 quoteBefore = wbnb.balanceOf(agent2);
        vm.prank(rogue);
        fair.mintFor(agent2, token, 10, 10);
        uint16 shares = fair.positions(token, agent2);
        assertEq(shares, 30, "gift of 10 shares");
        assertEq(wbnb.balanceOf(agent2), quoteBefore, "trader paid nothing");

        bytes[3] memory calls = [
            abi.encodeWithSignature("withdrawFor(address,address,uint256)", agent2, token, 30),
            abi.encodeWithSignature("refundFor(address,address)", agent2, token),
            abi.encodeWithSignature("withdraw(address,uint256,uint256)", token, 30, 0) // the rogue's own position (none)
        ];
        for (uint256 i = 0; i < calls.length; i++) {
            vm.prank(rogue);
            (bool ok,) = address(fair).call(calls[i]);
            assertFalse(ok, "no spend-for-someone entry");
        }
        shares = fair.positions(token, agent2);
        assertEq(shares, 30, "trader's position untouched");
        assertEq(wbnb.balanceOf(agent2), quoteBefore, "trader's quote untouched");
    }

    function test_unknownTokenAndNoCore() public {
        vm.prank(agent2);
        vm.expectRevert(GangRouter.UnknownToken.selector);
        router.v3BuyBNB{value: 0.1 ether}(makeAddr("nope"), 0, block.timestamp);

        GangRouter onlyFair = new GangRouter(address(0), address(fair), address(wbnb));
        vm.prank(agent2);
        vm.expectRevert(GangRouter.NotDeployed.selector);
        onlyFair.v3BuyBNB{value: 0.1 ether}(makeAddr("nope"), 0, block.timestamp);
    }

    function test_rejectsStrayBnb() public {
        vm.prank(agent2);
        (bool ok,) = address(router).call{value: 1 ether}("");
        assertFalse(ok, "only WBNB unwraps may send BNB");
    }

    // ---------------------------------------------------------------- 打新 mints
    function test_fairMintBNB_positionIsTheTraders() public {
        address token = _fairSale();
        (, uint256 cost, uint256 fee) = fair.previewMint(token, agent2, 40);
        uint256 bal = agent2.balance;
        vm.prank(agent2);
        uint256 accepted = router.fairMintBNB{value: 1 ether}(token, 40, 40, block.timestamp);
        assertEq(accepted, 40);
        assertEq(bal - agent2.balance, cost + fee, "exactly cost + mint fee, rest refunded");
        uint16 shares = fair.positions(token, agent2);
        assertEq(shares, 40);
        uint16 routerShares = fair.positions(token, address(router));
        assertEq(routerShares, 0);
        assertEq(IERC20(token).balanceOf(agent2), 40 * fair.TOKENS_PER_SHARE());
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
        fair.mintFor(agent2, token, 10, 1);
    }

    /// @dev A mint made through the router sells back to the trader (never the router): once stale, at full principal.
    function test_fair_withdrawGoesToTheTrader() public {
        address token = _fairSale();
        (, uint256 cost,) = fair.previewMint(token, agent2, 30);
        vm.prank(agent2);
        router.fairMintBNB{value: 1 ether}(token, 30, 30, block.timestamp);
        vm.warp(block.timestamp + 7 days);
        uint256 before = wbnb.balanceOf(agent2);
        vm.prank(agent2);
        fair.withdraw(token, 30, 0);
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
            (,,,,,, bool launched,,,,,,,) = fair.sales(token);
            if (launched) break;
        }
        (,,,,,, bool done,,,,, address pair,,) = fair.sales(token);
        assertTrue(done, "launched");
        assertTrue(pair != address(0));
        _assertRouterEmpty();
    }
}
