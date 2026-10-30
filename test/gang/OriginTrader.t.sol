// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

import {GangFixture} from "../utils/GangFixture.sol";
import {GangLaunchpad} from "../../src/gang/GangLaunchpad.sol";
import {GangToken} from "../../src/gang/GangToken.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";

/// @dev A wallet aggregator's router, reduced to the pad calls (LiquidMesh-style): it pays for buys / mints out of its
///      own balance and keeps whatever a sell / withdraw pays it (a real one would continue the route). `trader` is a
///      parameter so the tests can name someone other than tx.origin.
contract MockAggregator {
    GangLaunchpad public immutable pad;

    constructor(GangLaunchpad pad_) {
        pad = pad_;
    }

    function approveQuote(address quote) external {
        IERC20(quote).approve(address(pad), type(uint256).max);
    }

    function buyFor(address trader, address token, uint256 quoteIn, uint256 minOut) external returns (uint256) {
        return pad.buyFor(trader, token, quoteIn, minOut);
    }

    function sellFor(address trader, address token, uint256 tokensIn, uint256 minOut) external returns (uint256) {
        return pad.sellFor(trader, token, tokensIn, minOut);
    }

    function mintFor(address trader, address token, uint256 shares, uint256 minShares) external returns (uint256) {
        return pad.mintFor(trader, token, shares, minShares);
    }

    function withdrawFor(address trader, address token, uint256 shares, uint256 minPayout) external returns (uint256) {
        return pad.withdrawFor(trader, token, shares, minPayout);
    }
}

/// @dev The integration pattern §23 asks for: `trader` is always this contract's own msg.sender (the pad then
///      requires it to be tx.origin) and the proceeds go only to that msg.sender.
contract SenderAggregator {
    GangLaunchpad public immutable pad;

    constructor(GangLaunchpad pad_) {
        pad = pad_;
    }

    function sell(address token, uint256 tokensIn, address quote) external returns (uint256 out) {
        out = pad.sellFor(msg.sender, token, tokensIn, 0);
        IERC20(quote).transfer(msg.sender, out);
    }
}

/// @dev The ANTI-pattern (§23.9 item 2 / 3): reads tx.origin itself and pays whoever called it.
contract OriginReadingAggregator {
    GangLaunchpad public immutable pad;

    constructor(GangLaunchpad pad_) {
        pad = pad_;
    }

    function sell(address token, uint256 tokensIn, address quote) external returns (uint256 out) {
        out = pad.sellFor(tx.origin, token, tokensIn, 0);
        IERC20(quote).transfer(msg.sender, out);
    }
}

interface ISellEntry {
    function sell(address token, uint256 tokensIn, address quote) external returns (uint256);
}

/// @dev A contract the victim is tricked into calling ("claim your airdrop"): it routes a sell of the victim's tokens
///      through an aggregator the victim has a standing approval on, and keeps the proceeds.
contract Phisher {
    function claim(ISellEntry agg, address token, address quote) external returns (uint256) {
        return agg.sell(token, IERC20(token).balanceOf(tx.origin), quote);
    }
}

/// @notice AUDIT-BRIEF §23: buyFor / sellFor / mintFor / withdrawFor need a listed router AND trader == tx.origin;
///         sellFor / withdrawFor also spend the trader's token allowance to the router; buyFor's cut refund goes to the
///         trader. Gate and caps are the trader's, exactly as the direct entries.
contract OriginTraderTest is GangFixture {
    event Sell(
        address indexed token,
        address indexed seller,
        uint256 tokensIn,
        uint256 protocolFee,
        uint256 tax,
        uint256 quoteOut,
        uint256 realQuote
    );
    event Withdrawn(
        address indexed token,
        address indexed user,
        uint256 shares,
        uint256 payout,
        uint256 fee,
        uint256 userShares,
        uint256 sold
    );

    MockAggregator internal agg;
    MockAggregator internal unlisted;
    address internal creator;
    address internal trader;
    address internal human = makeAddr("human"); // no Agent ID

    function setUp() public {
        _deployGang(address(this));
        agg = new MockAggregator(pad);
        unlisted = new MockAggregator(pad);
        vm.prank(owner);
        pad.setRouter(address(agg), true);
        agg.approveQuote(address(wbnb));
        unlisted.approveQuote(address(wbnb));
        wbnb.mintUnlimited(address(agg), 1_000 ether);
        wbnb.mintUnlimited(address(unlisted), 1_000 ether);
        creator = _newAgent();
        trader = _newAgent();
        wbnb.mintUnlimited(human, 1_000 ether);
        vm.prank(human);
        wbnb.approve(address(pad), type(uint256).max);
    }

    function _v3(uint16 dividendBps) internal returns (address t) {
        t = _createV3(creator, address(0), _tax(200, 200, dividendBps, dividendBps == 10_000 ? address(0) : treasury));
    }

    // ================================================================ buyFor
    function test_buyFor_listedAggregator_tokensToOrigin_capOnTrader() public {
        address t = _v3(0);
        uint256 aggBefore = wbnb.balanceOf(address(agg));
        uint256 traderQuoteBefore = wbnb.balanceOf(trader);

        vm.prank(trader, trader);
        uint256 out = agg.buyFor(trader, t, 0.01 ether, 1);

        assertGt(out, 0);
        assertEq(IERC20(t).balanceOf(trader), out, "tokens land in the EOA");
        assertEq(IERC20(t).balanceOf(address(agg)), 0, "router holds no tokens");
        assertEq(wbnb.balanceOf(address(agg)), aggBefore - 0.01 ether, "router paid");
        assertEq(wbnb.balanceOf(trader), traderQuoteBefore, "trader paid nothing");
        assertEq(pad.walletRoom(t, trader), pad.MAX_PER_WALLET() - out, "cap counted on the trader");
    }

    /// @dev The 1% cap cuts the buy: the refund goes to the trader (WBNB), the router's delta is exactly -quoteIn.
    ///      A second buy at the cap reverts as a direct buy does.
    function test_buyFor_capCut_refundToTrader() public {
        address t = _v3(0);
        uint256 aggBefore = wbnb.balanceOf(address(agg));
        uint256 traderQuoteBefore = wbnb.balanceOf(trader);

        vm.prank(trader, trader);
        uint256 out = agg.buyFor(trader, t, 1 ether, 1);

        assertEq(out, pad.MAX_PER_WALLET(), "cut to the cap");
        assertEq(IERC20(t).balanceOf(trader), pad.MAX_PER_WALLET());
        assertEq(wbnb.balanceOf(address(agg)), aggBefore - 1 ether, "router delta = -quoteIn, no refund to it");
        uint256 refund = wbnb.balanceOf(trader) - traderQuoteBefore;
        assertGt(refund, 0.9 ether, "refund to the trader");

        vm.prank(trader, trader);
        vm.expectRevert(IGangLaunchpad.WalletCapReached.selector);
        agg.buyFor(trader, t, 0.01 ether, 0);
        // same as the direct path
        vm.prank(trader, trader);
        vm.expectRevert(IGangLaunchpad.WalletCapReached.selector);
        pad.buy(t, 0.01 ether, 0);
    }

    /// @dev The graduation cut: the last buy through a listed aggregator graduates the curve; the cut goes back to
    ///      the trader, the router's delta is exactly -quoteIn.
    function test_buyFor_graduationCut_refundToTrader() public {
        address t = _v3(0);
        // small steps (0.1 BNB, or the cap) so no step graduates it: stops with 0.2-0.3 BNB left
        for (uint256 i = 0; i < 1_000 && pad.graduationRemaining(t) > 0.3 ether; i++) {
            address w = _newAgent();
            vm.prank(w);
            pad.buy(t, 0.1 ether, 0);
        }
        uint256 remaining = pad.graduationRemaining(t);
        assertGt(remaining, 0);
        uint256 aggBefore = wbnb.balanceOf(address(agg));
        uint256 traderQuoteBefore = wbnb.balanceOf(trader);

        vm.prank(trader, trader);
        agg.buyFor(trader, t, 1 ether, 1);

        assertTrue(_graduated(t), "graduated");
        assertEq(wbnb.balanceOf(address(agg)), aggBefore - 1 ether, "router delta = -quoteIn");
        uint256 refund = wbnb.balanceOf(trader) - traderQuoteBefore;
        assertGt(refund, 1 ether - remaining * 2, "the cut came back to the trader");
        assertEq(IERC20(address(wbnb)).balanceOf(address(agg)), aggBefore - 1 ether);
    }

    function test_buyFor_unlistedCaller_originTrader_reverts() public {
        address t = _v3(0);
        vm.prank(trader, trader);
        vm.expectRevert(IGangLaunchpad.OnlyRouter.selector);
        unlisted.buyFor(trader, t, 0.01 ether, 0);
    }

    function test_buyFor_listedCaller_traderNotOrigin_reverts() public {
        address t = _v3(0);
        address other = _newAgent();
        vm.prank(trader, trader);
        vm.expectRevert(IGangLaunchpad.TraderNotOrigin.selector);
        agg.buyFor(other, t, 0.01 ether, 0);
        // nor the future pair, nor the router itself
        vm.prank(trader, trader);
        vm.expectRevert(IGangLaunchpad.TraderNotOrigin.selector);
        agg.buyFor(address(agg), t, 0.01 ether, 0);
    }

    function test_buyFor_nonAgentOrigin_notAgent() public {
        address t = _v3(0);
        vm.prank(human, human);
        vm.expectRevert(IGangLaunchpad.NotAgent.selector);
        agg.buyFor(human, t, 0.01 ether, 0);
    }

    /// @dev The A-2 check stays on the listed path: with the gate off, buyFor reverts RouterNeedsGate even for origin.
    function test_buyFor_gateOff_routerNeedsGate() public {
        address t = _v3(0);
        vm.prank(owner);
        pad.setAgentGate(false, address(agents));
        vm.prank(trader, trader);
        vm.expectRevert(IGangLaunchpad.RouterNeedsGate.selector);
        agg.buyFor(trader, t, 0.01 ether, 0);
    }

    /// @dev Our own GangRouter calls buyFor(msg.sender): a contract wallet calling it (msg.sender != tx.origin) is
    ///      refused; EOAs are unaffected (every GangRouter test runs them as tx.origin).
    function test_gangRouter_contractCaller_traderNotOrigin() public {
        address t = _v3(0);
        vm.deal(address(agg), 1 ether);
        vm.prank(address(agg), trader);
        vm.expectRevert(IGangLaunchpad.TraderNotOrigin.selector);
        router.v3BuyBNB{value: 0.01 ether}(t, 0, block.timestamp);
    }

    // ================================================================ sellFor
    function _bought(address t) internal returns (uint256 out) {
        vm.prank(trader);
        out = pad.buy(t, 0.02 ether, 1);
    }

    function test_sellFor_withAllowance() public {
        address t = _v3(10_000); // dividend token: the share follows the trader
        uint256 held = _bought(t);
        uint256 amount = held / 2;
        vm.prank(trader);
        IERC20(t).approve(address(agg), amount + 1);

        uint256 aggBefore = wbnb.balanceOf(address(agg));
        uint256 traderQuoteBefore = wbnb.balanceOf(trader);
        vm.expectEmit(true, true, false, false, address(pad));
        emit Sell(t, trader, amount, 0, 0, 0, 0);
        vm.prank(trader, trader);
        uint256 out = agg.sellFor(trader, t, amount, 1);

        assertGt(out, 0);
        assertEq(IERC20(t).balanceOf(trader), held - amount, "pulled from the trader");
        assertEq(IERC20(t).allowance(trader, address(agg)), 1, "allowance spent");
        assertEq(wbnb.balanceOf(address(agg)), aggBefore + out, "proceeds to the router");
        assertEq(wbnb.balanceOf(trader), traderQuoteBefore, "nothing to the trader");
        assertEq(divVault.shares(t, trader), held - amount, "share synced on the trader");
    }

    function test_sellFor_withoutAllowance_reverts() public {
        address t = _v3(0);
        uint256 held = _bought(t);
        // an approval to the pad (a direct seller's) is not the router's allowance
        vm.prank(trader);
        IERC20(t).approve(address(pad), type(uint256).max);
        vm.prank(trader, trader);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(agg), 0, held));
        agg.sellFor(trader, t, held, 0);
    }

    function test_sellFor_unlisted_or_notOrigin_reverts() public {
        address t = _v3(0);
        uint256 held = _bought(t);
        vm.startPrank(trader);
        IERC20(t).approve(address(agg), type(uint256).max);
        IERC20(t).approve(address(unlisted), type(uint256).max);
        vm.stopPrank();

        // a contract the trader merely interacts with: not listed
        vm.prank(trader, trader);
        vm.expectRevert(IGangLaunchpad.OnlyRouter.selector);
        unlisted.sellFor(trader, t, held, 0);

        // someone else's tx through the listed router, with the trader's standing allowance to it
        address attacker = makeAddr("attacker");
        vm.prank(attacker, attacker);
        vm.expectRevert(IGangLaunchpad.TraderNotOrigin.selector);
        agg.sellFor(trader, t, held, 0);

        assertEq(IERC20(t).balanceOf(trader), held, "untouched");
    }

    function test_sellFor_nonAgent_notAgent() public {
        address t = _v3(0);
        vm.prank(owner);
        pad.setAgentGate(false, address(agents));
        vm.prank(human);
        uint256 held = pad.buy(t, 0.01 ether, 1);
        vm.prank(owner);
        pad.setAgentGate(true, address(agents));

        vm.prank(human);
        IERC20(t).approve(address(agg), type(uint256).max);
        vm.prank(human, human);
        vm.expectRevert(IGangLaunchpad.NotAgent.selector);
        agg.sellFor(human, t, held, 0);
    }

    /// @dev Direct `sell` is unchanged: msg.sender's tokens, its approval to the pad, the quote to msg.sender.
    function test_directSell_unchanged() public {
        address t = _v3(0);
        uint256 held = _bought(t);
        vm.prank(trader);
        IERC20(t).approve(address(pad), held);
        uint256 before = wbnb.balanceOf(trader);
        vm.prank(trader);
        uint256 out = pad.sell(t, held, 1);
        assertEq(wbnb.balanceOf(trader), before + out);
        assertEq(IERC20(t).balanceOf(trader), 0);
    }

    // ================================================================ mintFor / withdrawFor
    function _fair() internal returns (address t) {
        t = _createFair(creator, address(0), 1);
    }

    function test_mintFor_listedAggregator_origin_capOnTrader() public {
        address t = _fair();
        (, uint256 cost, uint256 fee) = pad.previewMint(t, trader, 40);
        uint256 aggBefore = wbnb.balanceOf(address(agg));

        vm.prank(trader, trader);
        uint256 accepted = agg.mintFor(trader, t, 40, 40);

        assertEq(accepted, 40);
        assertEq(pad.positions(t, trader), 40, "position on the trader");
        assertEq(IERC20(t).balanceOf(trader), 40 * TOKENS_PER_SHARE, "tokens to the trader");
        assertEq(wbnb.balanceOf(address(agg)), aggBefore - cost - fee, "router paid exactly cost + fee");

        // cap 100 shares: the next mint is cut to 60, then WalletCapReached
        vm.prank(trader, trader);
        assertEq(agg.mintFor(trader, t, 100, 1), 60, "cut to the cap");
        vm.prank(trader, trader);
        vm.expectRevert(IGangLaunchpad.WalletCapReached.selector);
        agg.mintFor(trader, t, 1, 1);
    }

    function test_mintFor_rejections() public {
        address t = _fair();
        vm.prank(trader, trader);
        vm.expectRevert(IGangLaunchpad.OnlyRouter.selector);
        unlisted.mintFor(trader, t, 1, 1);

        vm.prank(trader, trader);
        vm.expectRevert(IGangLaunchpad.TraderNotOrigin.selector);
        agg.mintFor(makeAddr("pair"), t, 1, 1);

        vm.prank(human, human);
        vm.expectRevert(IGangLaunchpad.NotAgent.selector);
        agg.mintFor(human, t, 1, 1);
    }

    function test_withdrawFor_withAllowance() public {
        address t = _fair();
        vm.prank(trader);
        pad.mint(t, 30, 30);
        uint256 amount = 10 * TOKENS_PER_SHARE;
        vm.prank(trader);
        IERC20(t).approve(address(agg), amount);
        (uint256 expected,) = pad.previewWithdraw(t, trader, 10);
        uint256 aggBefore = wbnb.balanceOf(address(agg));
        uint256 traderQuoteBefore = wbnb.balanceOf(trader);

        vm.expectEmit(true, true, false, true, address(pad));
        emit Withdrawn(t, trader, 10, expected, 10 * _sharePrice(t) - expected, 20, 1 + 20);
        vm.prank(trader, trader);
        uint256 payout = agg.withdrawFor(trader, t, 10, expected);

        assertEq(payout, expected);
        assertEq(pad.positions(t, trader), 20, "position on the trader");
        assertEq(IERC20(t).balanceOf(trader), 20 * TOKENS_PER_SHARE, "tokens pulled from the trader");
        assertEq(IERC20(t).allowance(trader, address(agg)), 0, "allowance spent");
        assertEq(wbnb.balanceOf(address(agg)), aggBefore + payout, "payout to the router");
        assertEq(wbnb.balanceOf(trader), traderQuoteBefore);
        assertEq(divVault.shares(t, trader), 20 * TOKENS_PER_SHARE, "share on the trader");
    }

    function test_withdrawFor_rejections() public {
        address t = _fair();
        vm.prank(trader);
        pad.mint(t, 30, 30);

        // no allowance to the router
        vm.prank(trader, trader);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(agg), 0, 10 * TOKENS_PER_SHARE
            )
        );
        agg.withdrawFor(trader, t, 10, 0);

        vm.startPrank(trader);
        IERC20(t).approve(address(agg), type(uint256).max);
        IERC20(t).approve(address(unlisted), type(uint256).max);
        vm.stopPrank();

        vm.prank(trader, trader);
        vm.expectRevert(IGangLaunchpad.OnlyRouter.selector);
        unlisted.withdrawFor(trader, t, 10, 0);

        address attacker = makeAddr("attacker");
        vm.prank(attacker, attacker);
        vm.expectRevert(IGangLaunchpad.TraderNotOrigin.selector);
        agg.withdrawFor(trader, t, 10, 0);

        // more than the trader holds
        vm.prank(trader, trader);
        vm.expectRevert(IGangLaunchpad.BadAmount.selector);
        agg.withdrawFor(trader, t, 31, 0);

        assertEq(pad.positions(t, trader), 30, "untouched");
    }

    // ================================================================ wrong state / wrong kind
    function test_sellFor_afterGraduation_alreadyGraduated() public {
        address t = _v3(0);
        uint256 held = _bought(t);
        vm.prank(trader);
        IERC20(t).approve(address(agg), type(uint256).max);
        _graduate(t);
        vm.prank(trader, trader);
        vm.expectRevert(IGangLaunchpad.AlreadyGraduated.selector);
        agg.sellFor(trader, t, held, 0);
    }

    function test_withdrawFor_afterLaunch_notMinting() public {
        address t = _fair();
        vm.prank(trader);
        pad.mint(t, 10, 10);
        vm.prank(trader);
        IERC20(t).approve(address(agg), type(uint256).max);
        _fill(t);
        vm.prank(trader, trader);
        vm.expectRevert(IGangLaunchpad.NotMinting.selector);
        agg.withdrawFor(trader, t, 10, 0);
    }

    function test_wrongKind_unknownToken() public {
        address v = _v3(0);
        address f = _fair();
        vm.prank(trader);
        pad.mint(f, 10, 10);
        _bought(v);
        vm.startPrank(trader);
        IERC20(v).approve(address(agg), type(uint256).max);
        IERC20(f).approve(address(agg), type(uint256).max);
        vm.stopPrank();

        vm.prank(trader, trader);
        vm.expectRevert(IGangLaunchpad.UnknownToken.selector);
        agg.sellFor(trader, f, TOKENS_PER_SHARE, 0);
        vm.prank(trader, trader);
        vm.expectRevert(IGangLaunchpad.UnknownToken.selector);
        agg.withdrawFor(trader, v, 1, 0);
    }

    // ================================================================ gate off: origin + allowance still hold
    function test_gateOff_sellFor_originAndAllowanceStillEnforced() public {
        address t = _v3(0);
        vm.prank(owner);
        pad.setAgentGate(false, address(agents));
        vm.prank(human);
        uint256 held = pad.buy(t, 0.01 ether, 1);

        vm.prank(human, human);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(agg), 0, held));
        agg.sellFor(human, t, held, 0);

        vm.prank(human);
        IERC20(t).approve(address(agg), held);
        address attacker = makeAddr("attacker");
        vm.prank(attacker, attacker);
        vm.expectRevert(IGangLaunchpad.TraderNotOrigin.selector);
        agg.sellFor(human, t, held, 0);
        vm.prank(human, human);
        vm.expectRevert(IGangLaunchpad.OnlyRouter.selector);
        unlisted.sellFor(human, t, held, 0);

        vm.prank(human, human);
        assertGt(agg.sellFor(human, t, held, 0), 0, "works for the origin, gate off");
        assertEq(IERC20(t).balanceOf(human), 0);
    }

    function test_gateOff_withdrawFor_originAndAllowanceStillEnforced() public {
        vm.prank(owner);
        pad.setAgentGate(false, address(agents));
        address t = _fair(); // ungated sale (gate snapshot 0)
        vm.prank(human);
        pad.mint(t, 10, 10);

        vm.prank(human, human);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(agg), 0, 10 * TOKENS_PER_SHARE
            )
        );
        agg.withdrawFor(human, t, 10, 0);

        vm.prank(human);
        IERC20(t).approve(address(agg), type(uint256).max);
        address attacker = makeAddr("attacker");
        vm.prank(attacker, attacker);
        vm.expectRevert(IGangLaunchpad.TraderNotOrigin.selector);
        agg.withdrawFor(human, t, 10, 0);

        vm.prank(human, human);
        assertGt(agg.withdrawFor(human, t, 10, 0), 0);
        assertEq(pad.positions(t, human), 0);
    }

    // ================================================================ ERC-20 quote refund
    function test_buyFor_erc20Quote_capRefundToTrader() public {
        address t = _createV3(creator, address(quoteTok), _tax(200, 200, 0, treasury));
        agg.approveQuote(address(quoteTok));
        quoteTok.mintUnlimited(address(agg), 100 ether);
        uint256 aggBefore = quoteTok.balanceOf(address(agg));
        uint256 traderBefore = quoteTok.balanceOf(trader);

        vm.prank(trader, trader);
        uint256 out = agg.buyFor(trader, t, 5 ether, 1);

        assertEq(out, pad.MAX_PER_WALLET(), "cut to the cap");
        assertEq(quoteTok.balanceOf(address(agg)), aggBefore - 5 ether, "router delta = -quoteIn");
        assertGt(quoteTok.balanceOf(trader) - traderBefore, 4 ether, "the cut came back to the trader in the quote");
        assertEq(
            quoteTok.balanceOf(address(pad)),
            _curveRealQuote(t) + pad.creatorFeeOf(t),
            "pad keeps only the curve's escrow and the creator's part"
        );
    }

    // ================================================================ phishing (why the §23.9 checklist exists)
    /// @dev An aggregator that reads tx.origin and pays msg.sender: a phishing contract the victim calls sells the
    ///      victim's tokens through it (standing approval) and walks away with the proceeds. Listing such a contract
    ///      is what §23.9 forbids.
    function test_phishing_originReadingAggregator_isExploitable() public {
        OriginReadingAggregator bad = new OriginReadingAggregator(pad);
        vm.prank(owner);
        pad.setRouter(address(bad), true);
        address t = _v3(0);
        uint256 held = _bought(t);
        vm.prank(trader);
        IERC20(t).approve(address(bad), type(uint256).max); // standing approval from an earlier, honest use

        Phisher m = new Phisher();
        vm.prank(trader, trader); // the victim's own tx: "claim airdrop"
        uint256 stolen = m.claim(ISellEntry(address(bad)), t, address(wbnb));

        assertEq(IERC20(t).balanceOf(trader), 0, "victim's tokens sold");
        assertGt(stolen, 0);
        assertEq(wbnb.balanceOf(address(m)), stolen, "proceeds with the phisher");
    }

    /// @dev The pattern §23 asks for (trader = msg.sender, proceeds → msg.sender) is not exploitable that way: through
    ///      the phisher, trader = the phisher ≠ tx.origin.
    function test_phishing_msgSenderAggregator_notExploitable() public {
        SenderAggregator good = new SenderAggregator(pad);
        vm.prank(owner);
        pad.setRouter(address(good), true);
        address t = _v3(0);
        uint256 held = _bought(t);
        vm.prank(trader);
        IERC20(t).approve(address(good), type(uint256).max);

        Phisher m = new Phisher();
        vm.prank(trader, trader);
        vm.expectRevert(IGangLaunchpad.TraderNotOrigin.selector);
        m.claim(ISellEntry(address(good)), t, address(wbnb));
        assertEq(IERC20(t).balanceOf(trader), held, "untouched");

        // the honest use still works: the victim calls the aggregator directly
        uint256 before = wbnb.balanceOf(trader);
        vm.prank(trader, trader);
        uint256 out = good.sell(t, held, address(wbnb));
        assertEq(wbnb.balanceOf(trader), before + out, "proceeds to the caller");
    }

    // ================================================================ GangToken.pullFor
    function test_pullFor_onlyPad_onlyLocked() public {
        address t = _v3(0);
        uint256 held = _bought(t);
        vm.prank(trader);
        IERC20(t).approve(address(agg), type(uint256).max);
        GangToken tok = GangToken(t);

        // nobody but the pad, not even the approved spender
        vm.prank(address(agg));
        vm.expectRevert(GangToken.OnlyLaunchpad.selector);
        tok.pullFor(trader, address(agg), held);
        vm.prank(trader);
        vm.expectRevert(GangToken.OnlyLaunchpad.selector);
        tok.pullFor(trader, trader, held);

        // the pad, while locked, only within the allowance
        vm.prank(address(pad));
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(pad), 0, held));
        tok.pullFor(trader, address(pad), held);

        // after graduation: never (no pool tax to skip, no pair transfer to move)
        _graduate(t);
        assertFalse(tok.locked());
        vm.prank(address(pad));
        vm.expectRevert(GangToken.NotLocked.selector);
        tok.pullFor(trader, address(agg), 1);
    }

    function test_pullFor_fairToken_afterLaunch_notLocked() public {
        address t = _fair();
        _fill(t);
        vm.prank(address(pad));
        vm.expectRevert(GangToken.NotLocked.selector);
        GangToken(t).pullFor(creator, address(agg), 1);
    }
}
