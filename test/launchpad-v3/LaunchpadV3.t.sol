// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {QuoteRegistry} from "../../src/launchpad-v2/QuoteRegistry.sol";
import {DividendVault} from "../../src/launchpad-v2/DividendVault.sol";
import {PlatformFeeBucket} from "../../src/launchpad-v2/PlatformFeeBucket.sol";
import {MigratorV2} from "../../src/launchpad-v2/MigratorV2.sol";
import {LaunchToken} from "../../src/launchpad-v2/LaunchToken.sol";
import {MockSPCXB} from "../../src/launchpad-v2/mocks/MockSPCXB.sol";
import {MockPairFactory, MockPair} from "../../src/launchpad-v2/mocks/MockPairFactory.sol";
import {LaunchpadV3} from "../../src/launchpad-v3/LaunchpadV3.sol";
import {TaxLaunchTokenV3, TaxTokenDeployerV3} from "../../src/launchpad-v3/TaxLaunchTokenV3.sol";
import {PostGradTaxHandlerV3} from "../../src/launchpad-v3/PostGradTaxHandlerV3.sol";
import {TaxRouterV3} from "../../src/launchpad-v3/TaxRouterV3.sol";
import {RecipientRegistry} from "../../src/launchpad-v3/RecipientRegistry.sol";
import {ILaunchpadV3} from "../../src/launchpad-v3/interfaces/ILaunchpadV3.sol";
import {MockAgentId} from "../mocks/MockAgentId.sol";

/// @dev Quote that refuses transfers to blacklisted addresses (USDT-style), to make a recipient push fail.
contract BlacklistQuote is ERC20("Blacklist USD", "BUSD") {
    mapping(address => bool) public blocked;

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlocked(address a, bool b) external {
        blocked[a] = b;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blocked[to], "blacklisted");
        super._update(from, to, value);
    }
}

/// @notice LaunchpadV3 (tax recipient) on mocks: create rules, buy / sell tax on the curve and on the pool, the
///         0.5%-of-volume platform part, dividend share, recipient pushes, owed + release, TaxPaid events, G-01.
contract LaunchpadV3Test is Test {
    QuoteRegistry internal quoteRegistry;
    DividendVault internal divVault;
    PlatformFeeBucket internal bucket;
    TaxRouterV3 internal router;
    RecipientRegistry internal recipients;
    PostGradTaxHandlerV3 internal handler;
    LaunchpadV3 internal pad;
    MigratorV2 internal migrator;
    MockPairFactory internal pairFactory;
    MockSPCXB internal quoteTok;
    MockSPCXB internal wbnb;
    MockAgentId internal agents;

    address internal owner = makeAddr("owner");
    address internal keeper = makeAddr("keeper");
    address internal feeVault = makeAddr("feeVault");
    address internal treasury = makeAddr("treasury"); // the partner's vault
    address internal agent = makeAddr("agent");
    address internal agent2 = makeAddr("agent2");
    address internal stranger = makeAddr("stranger");
    uint256 internal nextId = 1;

    uint256 internal constant BPS = 10_000;

    event TaxPaid(address indexed token, address indexed recipient, address indexed quote, uint256 amount);
    event TaxOwed(address indexed token, address indexed recipient, address indexed quote, uint256 amount);

    function setUp() public {
        quoteTok = new MockSPCXB();
        wbnb = new MockSPCXB();
        pairFactory = new MockPairFactory();
        agents = new MockAgentId();

        quoteRegistry = new QuoteRegistry(owner);
        divVault = new DividendVault(owner);
        bucket = new PlatformFeeBucket(owner, feeVault);
        router = new TaxRouterV3(owner, address(divVault), address(bucket));
        recipients = new RecipientRegistry(owner);
        handler = new PostGradTaxHandlerV3(owner, address(divVault), address(router));
        pad = new LaunchpadV3(
            owner,
            address(quoteRegistry),
            address(divVault),
            address(bucket),
            address(handler),
            address(router),
            address(recipients),
            address(new TaxTokenDeployerV3()),
            address(wbnb),
            address(pairFactory)
        );
        migrator = new MigratorV2(address(pairFactory), address(pad));

        vm.startPrank(owner);
        quoteRegistry.setQuote(address(quoteTok), true, 15 ether);
        divVault.setLaunchpad(address(pad));
        divVault.setOperator(address(router), true);
        divVault.setOperator(address(handler), true);
        bucket.setLaunchpad(address(pad));
        bucket.setOperator(address(router), true);
        router.setLaunchpad(address(pad));
        router.setSource(address(handler), true);
        handler.setKeeper(keeper);
        recipients.list(treasury, "partner treasury");
        pad.setMigrator(address(migrator));
        pad.setAgentGate(true, address(agents));
        vm.stopPrank();

        _agent(agent);
        _agent(agent2);
    }

    // ---------------------------------------------------------------- helpers
    function _agent(address who) internal {
        if (agents.balanceOf(who) == 0) agents.mint(who, nextId++);
        quoteTok.mintUnlimited(who, 1_000 ether);
        vm.prank(who);
        quoteTok.approve(address(pad), type(uint256).max);
    }

    function _tax(uint16 buyBps, uint16 sellBps, uint16 dividendBps, address recipient)
        internal
        pure
        returns (ILaunchpadV3.TaxConfig memory)
    {
        return ILaunchpadV3.TaxConfig({
            buyTaxBps: buyBps, sellTaxBps: sellBps, dividendBps: dividendBps, recipient: recipient
        });
    }

    function _create(ILaunchpadV3.TaxConfig memory t) internal returns (address token) {
        vm.prank(agent);
        token = pad.create("Tax", "TAX", "", address(quoteTok), address(0), t);
    }

    function _expectBad(ILaunchpadV3.TaxConfig memory t, string memory reason) internal {
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(LaunchpadV3.BadTaxConfig.selector, reason));
        pad.create("X", "X", "", address(quoteTok), address(0), t);
    }

    function _graduated(address token) internal view returns (bool g) {
        (,,,,,, g,,,,,) = pad.curves(token);
    }

    /// @dev Distinct agent wallets buy 1 quote each (the 1% cap truncates) until the curve graduates.
    function _graduate(address token) internal {
        for (uint256 i = 0; i < 400 && !_graduated(token); i++) {
            address w = address(uint160(0xB0000 + i));
            _agent(w);
            vm.prank(w);
            pad.buy(token, 1 ether, 0);
        }
        assertTrue(_graduated(token), "graduated");
    }

    function _poolBuy(address token, address who, uint256 quoteIn) internal {
        MockPair pair = MockPair(TaxLaunchTokenV3(token).pair());
        quoteTok.mintUnlimited(address(pair), quoteIn);
        (uint256 rT, uint256 rQ) = _reserves(token, pair);
        uint256 out = (quoteIn * rT) / (rQ + quoteIn) / 2; // well inside the curve; MockPair checks no K
        if (pair.token0() == token) pair.swap(out, 0, who, "");
        else pair.swap(0, out, who, "");
    }

    function _poolSell(address token, address who, uint256 amount) internal {
        MockPair pair = MockPair(TaxLaunchTokenV3(token).pair());
        vm.prank(who);
        IERC20(token).transfer(address(pair), amount);
        (uint256 rT, uint256 rQ) = _reserves(token, pair);
        uint256 inAmt = IERC20(token).balanceOf(address(pair)) - rT;
        uint256 out = (inAmt * rQ) / (rT + inAmt) / 2;
        if (pair.token0() == token) pair.swap(0, out, who, "");
        else pair.swap(out, 0, who, "");
    }

    function _reserves(address token, MockPair pair) internal view returns (uint256 rT, uint256 rQ) {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        (rT, rQ) = pair.token0() == token ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }

    // ---------------------------------------------------------------- 1 / 2 / 3: create rules
    function test_create_rules() public {
        _expectBad(_tax(99, 200, 0, treasury), "buyTaxBps and sellTaxBps must each be 100-500 (1%-5%)");
        _expectBad(_tax(200, 501, 0, treasury), "buyTaxBps and sellTaxBps must each be 100-500 (1%-5%)");
        _expectBad(_tax(200, 0, 0, treasury), "buyTaxBps and sellTaxBps must each be 100-500 (1%-5%)");
        _expectBad(_tax(200, 200, 10_001, treasury), "dividendBps > 10000");
        _expectBad(_tax(200, 200, 5_000, address(0)), "no recipient: dividendBps must be 10000");
        _expectBad(_tax(200, 200, 0, stranger), "recipient not listed");
        _expectBad(_tax(0, 0, 0, treasury), "untaxed: dividendBps / recipient must be empty");

        address t = _create(_tax(200, 200, 0, treasury));
        (uint16 b, uint16 s, uint16 d, address r) = pad.taxConfigOf(t);
        assertEq(b, 200);
        assertEq(s, 200);
        assertEq(d, 0);
        assertEq(r, treasury, "recipient fixed at create");
        assertEq(TaxLaunchTokenV3(t).buyTaxBps(), 200);
        assertEq(TaxLaunchTokenV3(t).sellTaxBps(), 200);

        address u = _create(_tax(0, 0, 0, address(0)));
        assertEq(LaunchToken(u).TOTAL_SUPPLY(), 1_000_000_000 ether, "untaxed = V2 LaunchToken");
        _create(_tax(100, 500, 10_000, address(0))); // holder-dividend only, no recipient
    }

    function test_delistedRecipient_onlyBlocksNewTokens() public {
        address t = _create(_tax(200, 200, 0, treasury));
        vm.prank(owner);
        recipients.delist(treasury);
        _expectBad(_tax(200, 200, 0, treasury), "recipient not listed");

        uint256 before = quoteTok.balanceOf(treasury);
        vm.prank(agent);
        pad.buy(t, 0.01 ether, 0);
        assertGt(quoteTok.balanceOf(treasury), before, "existing token keeps paying its recipient");
    }

    // ---------------------------------------------------------------- 2 / 3 / 4 / 6: curve tax split
    /// @dev buy 2%: 1% protocol fee + 2% tax; of the tax 0.5% of volume → platform, 1.5% → recipient (dividend 0).
    function test_bondingBuy_split_platformHalfPercent_restToRecipient() public {
        address t = _create(_tax(200, 200, 0, treasury));
        uint256 gross = 0.01 ether;
        vm.expectEmit(true, true, true, true, address(router));
        emit TaxPaid(t, treasury, address(quoteTok), (gross * 150) / BPS);
        vm.prank(agent);
        pad.buy(t, gross, 0);
        assertEq(quoteTok.balanceOf(treasury), (gross * 150) / BPS, "recipient 1.5%");
        assertEq(bucket.accruedQuote(address(quoteTok)), (gross * 100) / BPS + (gross * 50) / BPS, "1% fee + 0.5% tax");
    }

    /// @dev sell 3% with dividend 40%: platform 0.5%, rest 2.5% → 1% dividends / 1.5% recipient.
    function test_bondingSell_split_withDividends() public {
        address t = _create(_tax(100, 300, 4_000, treasury));
        vm.prank(agent);
        pad.buy(t, 0.01 ether, 0);
        vm.prank(agent2);
        pad.buy(t, 0.01 ether, 0); // agent now holds dividend shares
        uint256 bal = IERC20(t).balanceOf(agent2);
        uint256 vaultBefore = quoteTok.balanceOf(address(divVault));
        uint256 recBefore = quoteTok.balanceOf(treasury);
        uint256 bucketBefore = bucket.accruedQuote(address(quoteTok));

        vm.startPrank(agent2);
        IERC20(t).approve(address(pad), bal);
        uint256 toUser = pad.sell(t, bal, 0);
        vm.stopPrank();
        uint256 quoteOut = (toUser * BPS) / (BPS - 100 - 300); // what the curve paid before fee + tax

        uint256 rest = (quoteOut * 300) / BPS - (quoteOut * 50) / BPS;
        assertApproxEqAbs(
            quoteTok.balanceOf(address(divVault)) - vaultBefore, (rest * 4_000) / BPS, 2, "40% to holders"
        );
        assertApproxEqAbs(quoteTok.balanceOf(treasury) - recBefore, rest - (rest * 4_000) / BPS, 2, "60% to recipient");
        assertApproxEqAbs(bucket.accruedQuote(address(quoteTok)) - bucketBefore, (quoteOut * 150) / BPS, 2, "1% + 0.5%");
    }

    function test_firstBuy_noHolders_dividendLegGoesToRecipient() public {
        address t = _create(_tax(200, 200, 5_000, treasury));
        vm.prank(agent);
        pad.buy(t, 0.01 ether, 0);
        assertEq(quoteTok.balanceOf(address(divVault)), 0);
        assertEq(quoteTok.balanceOf(treasury), (0.01 ether * 150) / BPS, "whole 1.5% to recipient");
    }

    // ---------------------------------------------------------------- 5 / 6: failed push → owed → release by anyone
    function test_failedPush_isOwed_tradeStillWorks_anyoneReleases() public {
        BlacklistQuote bq = new BlacklistQuote();
        vm.prank(owner);
        quoteRegistry.setQuote(address(bq), true, 15 ether);
        bq.mint(agent, 10 ether);
        vm.prank(agent);
        bq.approve(address(pad), type(uint256).max);
        bq.setBlocked(treasury, true);

        vm.prank(agent);
        address t = pad.create("B", "B", "", address(bq), address(0), _tax(200, 200, 0, treasury));
        uint256 owedAmt = (0.01 ether * 150) / BPS;
        vm.expectEmit(true, true, true, true, address(router));
        emit TaxOwed(t, treasury, address(bq), owedAmt);
        vm.prank(agent);
        pad.buy(t, 0.01 ether, 0); // does not revert
        assertEq(router.owedOf(t), owedAmt);

        vm.prank(stranger);
        vm.expectRevert(bytes("blacklisted"));
        router.release(t); // still blocked: stays owed
        assertEq(router.owedOf(t), owedAmt);

        bq.setBlocked(treasury, false);
        vm.expectEmit(true, true, true, true, address(router));
        emit TaxPaid(t, treasury, address(bq), owedAmt);
        vm.prank(stranger);
        router.release(t);
        assertEq(router.owedOf(t), 0);
        assertEq(bq.balanceOf(treasury), owedAmt);

        vm.expectRevert(TaxRouterV3.NothingOwed.selector);
        router.release(t);
    }

    // ---------------------------------------------------------------- 2 / 3 / 4: pool tax, keeper sells to quote
    /// @dev Pool buy 1% / sell 3%: the platform part is 0.5% of each trade's volume (half of a buy's tax, a sixth of
    ///      a sell's), carried through the keeper's swap; the recipient gets the rest in quote, never the token.
    function test_postGrad_buySellRates_platformPerTrade_recipientInQuote() public {
        address t = _create(_tax(100, 300, 0, treasury));
        _graduate(t);
        uint256 recBefore = quoteTok.balanceOf(treasury);

        _poolBuy(t, stranger, 1 ether);
        uint256 buyTax = handler.accruedTax(t);
        assertEq(handler.accruedPlatformTax(t), buyTax / 2, "buy: 0.5 of 1%");
        uint256 sold = IERC20(t).balanceOf(stranger) / 2;
        _poolSell(t, stranger, sold);
        uint256 sellTax = handler.accruedTax(t) - buyTax;
        assertEq(sellTax, (sold * 300) / BPS);
        assertEq(handler.accruedPlatformTax(t), buyTax / 2 + (sellTax * 50) / 300, "sell: 0.5 of 3%");

        uint256 platformTokens = handler.accruedPlatformTax(t);
        uint256 totalTokens = handler.accruedTax(t);
        uint256 bucketBefore = bucket.accruedQuote(address(quoteTok));
        vm.prank(keeper);
        uint256 quoteOut = handler.process(t, 1);
        uint256 platformQuote = (quoteOut * platformTokens) / totalTokens;
        assertEq(bucket.accruedQuote(address(quoteTok)) - bucketBefore, platformQuote);
        assertEq(quoteTok.balanceOf(treasury) - recBefore, quoteOut - platformQuote, "rest to recipient, in quote");
        assertEq(IERC20(t).balanceOf(treasury), 0, "never paid in the token");
        assertEq(handler.accruedPlatformTax(t), 0);
    }

    function test_untaxed_noTaxAnywhere() public {
        address t = _create(_tax(0, 0, 0, address(0)));
        vm.prank(agent);
        pad.buy(t, 0.01 ether, 0);
        assertEq(bucket.accruedQuote(address(quoteTok)), (0.01 ether * 100) / BPS, "only the 1% protocol fee");
        assertEq(quoteTok.balanceOf(treasury), 0);
    }

    // ---------------------------------------------------------------- 7: V2 rules unchanged
    function test_agentGateAndWalletCapUnchanged() public {
        address t = _create(_tax(200, 200, 0, treasury));
        quoteTok.mintUnlimited(stranger, 1 ether);
        vm.startPrank(stranger);
        quoteTok.approve(address(pad), type(uint256).max);
        vm.expectRevert(LaunchpadV3.NotAgent.selector);
        pad.buy(t, 0.01 ether, 0);
        vm.stopPrank();

        vm.prank(agent);
        pad.buy(t, 5 ether, 0);
        assertEq(IERC20(t).balanceOf(agent), pad.MAX_PER_WALLET(), "1% cap");
        vm.prank(agent);
        vm.expectRevert(LaunchpadV3.WalletCapReached.selector);
        pad.buy(t, 0.01 ether, 0);
        assertEq(pad.TARGET_GRAD_BNB(), 15 ether);
    }

    // ---------------------------------------------------------------- audit G-01 on the V3 handler
    function test_auditG01_excludedHolderZeroedOnSync() public {
        address t = _create(_tax(200, 200, 10_000, address(0)));
        _graduate(t);
        address holder = address(uint160(0xB0000)); // first graduating buyer
        assertGt(divVault.shares(t, holder), 0);
        vm.prank(owner);
        divVault.setExcluded(holder, true);
        handler.syncShares(t, holder, address(0));
        assertEq(divVault.shares(t, holder), 0, "excluded holder no longer earns");
    }
}
