// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PostGradHandlerBase} from "../../src/common/PostGradHandlerBase.sol";
import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {QuoteRegistry} from "../../src/launchpad-v2/QuoteRegistry.sol";
import {SharedDividendVault} from "../../src/common/SharedDividendVault.sol";
import {PlatformFeeBucket} from "../../src/launchpad-v2/PlatformFeeBucket.sol";
import {SharedMigrator} from "../../src/common/SharedMigrator.sol";
import {TokenDeployer} from "../../src/common/TokenDeployer.sol";
import {GangToken as LaunchTokenV3} from "../../src/gang/GangToken.sol";
import {MockSPCXB} from "../../src/launchpad-v2/mocks/MockSPCXB.sol";
import {MockPairFactory, MockPair} from "../../src/launchpad-v2/mocks/MockPairFactory.sol";
import {GangLaunchpad as LaunchpadV3} from "../../src/gang/GangLaunchpad.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {GangToken as TaxLaunchTokenV3} from "../../src/gang/GangToken.sol";
import {GangTaxHandler as TaxHandlerV3} from "../../src/gang/GangTaxHandler.sol";
import {IGangLaunchpad as ILaunchpadV3} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {MockAgentId} from "../mocks/MockAgentId.sol";

/// @dev A contract creator (holds an Agent ID itself) that also relays create for whoever calls it (§22 review).
contract CreatorContract {
    function create(LaunchpadV3 pad, address quote, IGangLaunchpad.TaxConfig memory t) external returns (address) {
        return pad.create("C", "C", "", "", quote, address(0), t);
    }

    receive() external payable {
        revert("no bnb");
    }
}

/// @dev Quote that refuses transfers to blacklisted addresses (USDT-style), to make a recipient push fail.
contract BlacklistQuote is ERC20("Blacklist USD", "BUSD") {
    mapping(address => bool) public blocked;

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function mintUnlimited(address to, uint256 amount) external {
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

interface IMintableQuote {
    function mintUnlimited(address to, uint256 amount) external;
}

/// @notice LaunchpadV3 (tax recipient) on mocks: create rules, no tax on the curve (only the 1% protocol fee, §19),
///         buy / sell tax on the pool, the 0.5%-of-volume platform part, dividend share, recipient pushes,
///         owed + release, TaxPaid events, G-01.
contract LaunchpadV3Test is Test {
    QuoteRegistry internal quoteRegistry;
    SharedDividendVault internal divVault;
    TokenDeployer internal tokenDeployer;
    PlatformFeeBucket internal bucket;
    TaxHandlerV3 internal handler;
    LaunchpadV3 internal pad;
    SharedMigrator internal migrator;
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
    event Buy(
        address indexed token,
        address indexed buyer,
        uint256 quoteIn,
        uint256 protocolFee,
        uint256 tax,
        uint256 tokensOut,
        uint256 realQuote
    );
    event Sell(
        address indexed token,
        address indexed seller,
        uint256 tokensIn,
        uint256 protocolFee,
        uint256 tax,
        uint256 quoteOut,
        uint256 realQuote
    );

    function setUp() public {
        quoteTok = new MockSPCXB();
        wbnb = new MockSPCXB();
        pairFactory = new MockPairFactory();
        agents = new MockAgentId();

        quoteRegistry = new QuoteRegistry(owner);
        divVault = new SharedDividendVault(owner);
        tokenDeployer = new TokenDeployer(owner);
        bucket = new PlatformFeeBucket(owner, feeVault);
        handler = new TaxHandlerV3(owner, address(divVault), address(bucket), address(0));
        pad = new LaunchpadV3(
            owner,
            address(quoteRegistry),
            address(divVault),
            address(bucket),
            address(handler),
            address(tokenDeployer),
            address(wbnb),
            address(pairFactory)
        );
        migrator = new SharedMigrator(owner, address(pairFactory));

        vm.startPrank(owner);
        quoteRegistry.setQuote(address(quoteTok), true, 15 ether);
        divVault.setLaunchpad(address(pad), true);
        divVault.setOperator(address(handler), address(pad));
        migrator.addLaunchpad(address(pad));
        tokenDeployer.setLaunchpad(address(pad), true);
        bucket.setLaunchpad(address(pad));
        bucket.setOperator(address(handler), true);
        handler.setLaunchpad(address(pad));
        handler.setKeeper(keeper);
        handler.list(treasury, "partner treasury");
        pad.setMigrator(address(migrator));
        pad.setAgentGate(true, address(agents));
        vm.stopPrank();

        _agent(agent);
        _agent(agent2);
    }

    // ---------------------------------------------------------------- helpers
    function _agent(address who) internal {
        _agent(who, address(quoteTok));
    }

    function _agent(address who, address quote) internal {
        if (agents.balanceOf(who) == 0) agents.mint(who, nextId++);
        IMintableQuote(quote).mintUnlimited(who, 1_000 ether);
        vm.prank(who);
        IERC20(quote).approve(address(pad), type(uint256).max);
    }

    function _quoteOf(address token) internal view returns (address q) {
        (, q,,,,,,,,,,) = pad.curves(token);
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
        token = pad.create("Tax", "TAX", "", "", address(quoteTok), address(0), t);
    }

    function _expectBad(ILaunchpadV3.TaxConfig memory t, string memory reason) internal {
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(IGangLaunchpad.BadTaxConfig.selector, reason));
        pad.create("X", "X", "", "", address(quoteTok), address(0), t);
    }

    function _graduated(address token) internal view returns (bool g) {
        (,,,,,, g,,,,,) = pad.curves(token);
    }

    /// @dev Distinct agent wallets buy 1 quote each (the 1% cap truncates) until the curve graduates.
    function _graduate(address token) internal {
        for (uint256 i = 0; i < 400 && !_graduated(token); i++) {
            address w = address(uint160(0xB0000 + i));
            _agent(w, _quoteOf(token));
            vm.prank(w);
            pad.buy(token, 1 ether, 0);
        }
        assertTrue(_graduated(token), "graduated");
    }

    function _poolBuy(address token, address who, uint256 quoteIn) internal {
        MockPair pair = MockPair(TaxLaunchTokenV3(token).pair());
        IMintableQuote(_quoteOf(token)).mintUnlimited(address(pair), quoteIn);
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
        assertEq(LaunchTokenV3(u).TOTAL_SUPPLY(), 1_000_000_000 ether, "untaxed = LaunchTokenV3");
        assertEq(LaunchTokenV3(u).buyTaxBps() + LaunchTokenV3(u).sellTaxBps(), 0, "0 / 0");
        assertEq(LaunchTokenV3(u).taxHandler(), address(0), "no handler");
        assertFalse(LaunchTokenV3(u).reclaimable());
        _create(_tax(100, 500, 10_000, address(0))); // holder-dividend only, no recipient
    }

    function test_delistedRecipient_onlyBlocksNewTokens() public {
        address t = _create(_tax(200, 200, 0, treasury));
        vm.prank(owner);
        handler.delist(treasury);
        _expectBad(_tax(200, 200, 0, treasury), "recipient not listed");

        _graduate(t);
        _poolBuy(t, stranger, 1 ether);
        vm.prank(keeper);
        handler.process(t, type(uint256).max, 1);
        assertGt(quoteTok.balanceOf(treasury), 0, "existing token keeps paying its recipient (pool tax)");
    }

    // ---------------------------------------------------------------- creator as recipient (2026-10-27, §22)
    /// @notice The creator may name itself as the recipient without being listed; the pool tax after graduation pays
    ///         it exactly like a listed recipient (platform 0.5% of volume, the rest to the creator in quote).
    function test_creatorAsRecipient_createsAndIsPaidAfterGraduation() public {
        assertFalse(handler.isListed(agent), "the creator is not on the whitelist");
        ILaunchpadV3.TaxConfig memory tx_ = _tax(100, 300, 0, agent);
        (bool ok, string memory reason) = pad.checkTaxConfigFor(agent, tx_);
        assertTrue(ok, reason);
        // the creator-blind view only knows the whitelist
        (ok, reason) = pad.checkTaxConfig(tx_);
        assertFalse(ok);
        assertEq(reason, "recipient not listed");

        address t = _create(tx_);
        (,,, address r) = pad.taxConfigOf(t);
        assertEq(r, agent, "recipient = creator, fixed at create");
        (address creator,,,,,,,,,,,) = pad.curves(t);
        assertEq(creator, agent);

        _graduate(t);
        uint256 recBefore = quoteTok.balanceOf(agent);
        _poolBuy(t, stranger, 1 ether);
        uint256 platformTokens = handler.accruedPlatformTax(t);
        uint256 totalTokens = handler.accruedTax(t);
        assertEq(platformTokens, totalTokens / 2, "buy: 0.5 of 1% to the platform");
        uint256 bucketBefore = bucket.accruedQuote(address(quoteTok));
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(keeper);
        uint256 quoteOut = handler.process(t, type(uint256).max, 1);
        uint256 platformQuote = (quoteOut * platformTokens) / totalTokens;
        assertGt(quoteOut, 0);
        assertEq(bucket.accruedQuote(address(quoteTok)) - bucketBefore, platformQuote);
        assertEq(quoteTok.balanceOf(agent) - recBefore, quoteOut - platformQuote, "the rest to the creator, in quote");
        assertEq(handler.owedOf(t), 0);
    }

    /// @notice With a dividend share the creator gets the recipient's part: holders' part to the vault first.
    function test_creatorAsRecipient_withDividend_splitByShare() public {
        address t = _create(_tax(300, 300, 4_000, agent));
        _graduate(t);
        uint256 recBefore = quoteTok.balanceOf(agent);
        uint256 vaultBefore = quoteTok.balanceOf(address(divVault));
        uint256 bucketBefore = bucket.accruedQuote(address(quoteTok));
        _poolBuy(t, stranger, 1 ether);
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(keeper);
        uint256 quoteOut = handler.process(t, type(uint256).max, 1);
        uint256 toHolders = quoteTok.balanceOf(address(divVault)) - vaultBefore;
        uint256 toPlatform = bucket.accruedQuote(address(quoteTok)) - bucketBefore;
        uint256 toCreator = quoteTok.balanceOf(agent) - recBefore;
        assertGt(toHolders, 0, "holders' part");
        assertGt(toCreator, 0, "recipient's part");
        assertEq(toHolders + toPlatform + toCreator, quoteOut, "every unit accounted for");
        // of the tax after the platform's 0.5%: 40% holders, 60% creator (rounding only)
        assertApproxEqRel(toHolders * 6_000, toCreator * 4_000, 1e15);
    }

    /// @notice A creator that cannot receive is owed like any recipient; anyone releases it to the creator.
    function test_creatorAsRecipient_owedAndRelease() public {
        BlacklistQuote bq = new BlacklistQuote();
        vm.prank(owner);
        quoteRegistry.setQuote(address(bq), true, 15 ether);
        bq.setBlocked(agent, true);
        vm.prank(agent);
        address t = pad.create("B", "B", "", "", address(bq), address(0), _tax(200, 200, 0, agent));
        _graduate(t);
        _poolBuy(t, stranger, 1 ether);
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(keeper);
        handler.process(t, type(uint256).max, 1);
        uint256 owedAmt = handler.owedOf(t);
        assertGt(owedAmt, 0, "booked as owed");

        bq.setBlocked(agent, false);
        vm.expectEmit(true, true, true, true, address(handler));
        emit TaxPaid(t, agent, address(bq), owedAmt);
        vm.prank(stranger);
        handler.release(t);
        assertEq(bq.balanceOf(agent), owedAmt, "released to the creator, not the caller");
        assertEq(handler.owedOf(t), 0);
    }

    /// @notice Third parties still need the whitelist: an unlisted address that is not the creator is refused, also
    ///         when it is some other creator's own address; a zero recipient still needs dividend 100%.
    function test_creatorAsRecipient_thirdPartyStillListedOnly() public {
        _expectBad(_tax(200, 200, 0, stranger), "recipient not listed");
        _expectBad(_tax(200, 200, 0, agent2), "recipient not listed"); // agent creates, names agent2
        (bool ok, string memory reason) = pad.checkTaxConfigFor(agent, _tax(200, 200, 0, stranger));
        assertFalse(ok);
        assertEq(reason, "recipient not listed");
        (ok, reason) = pad.checkTaxConfigFor(agent2, _tax(200, 200, 0, agent));
        assertFalse(ok);
        assertEq(reason, "recipient not listed");
        (ok, reason) = pad.checkTaxConfigFor(agent, _tax(200, 200, 5_000, address(0)));
        assertFalse(ok);
        assertEq(reason, "no recipient: dividendBps must be 10000");
        (ok, reason) = pad.checkTaxConfigFor(address(0), _tax(200, 200, 10_000, address(0)));
        assertTrue(ok, reason);
        (ok, reason) = pad.checkTaxConfigFor(agent, _tax(200, 200, 0, treasury));
        assertTrue(ok, reason);
        // the other bounds are unchanged for a creator recipient
        (ok, reason) = pad.checkTaxConfigFor(agent, _tax(99, 200, 0, agent));
        assertEq(reason, "buyTaxBps and sellTaxBps must each be 100-500 (1%-5%)");
        (ok, reason) = pad.checkTaxConfigFor(agent, _tax(200, 200, 10_001, agent));
        assertEq(reason, "dividendBps > 10000");
        (ok, reason) = pad.checkTaxConfigFor(agent, _tax(0, 0, 0, agent));
        assertEq(reason, "untaxed: dividendBps / recipient must be empty");
        // and agent2 may name itself
        vm.prank(agent2);
        address t = pad.create("Own", "OWN", "", "", address(quoteTok), address(0), _tax(200, 200, 0, agent2));
        (,,, address r) = pad.taxConfigOf(t);
        assertEq(r, agent2);
    }

    /// @notice A relaying contract cannot lend its caller's identity: naming the EOA that called it is refused, naming
    ///         the contract itself passes (the pad sees the contract as the creator).
    function test_creatorAsRecipient_relayCannotImpersonate() public {
        CreatorContract cc = new CreatorContract();
        agents.mint(address(cc), 9_999);
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(IGangLaunchpad.BadTaxConfig.selector, "recipient not listed"));
        cc.create(pad, address(quoteTok), _tax(200, 200, 0, agent));

        address t = cc.create(pad, address(quoteTok), _tax(200, 200, 0, address(cc)));
        (,,, address r) = pad.taxConfigOf(t);
        assertEq(r, address(cc));
        (address creator,,,,,,,,,,,) = pad.curves(t);
        assertEq(creator, address(cc));
    }

    /// @notice A contract creator that refuses native BNB is still paid: the pool tax is paid in the ERC20 quote.
    function test_creatorAsRecipient_contractCreatorPaidInQuote() public {
        CreatorContract cc = new CreatorContract();
        agents.mint(address(cc), 9_998);
        address t = cc.create(pad, address(quoteTok), _tax(200, 200, 0, address(cc)));
        _graduate(t);
        _poolBuy(t, stranger, 1 ether);
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(keeper);
        uint256 out = handler.process(t, type(uint256).max, 1);
        assertGt(out, 0);
        assertGt(quoteTok.balanceOf(address(cc)), 0);
        assertEq(handler.owedOf(t), 0);
    }

    /// @notice A creator recipient the quote blacklists does not block a user's pool sell (swap-back path): the chunk is
    ///         sold, the recipient's leg is booked as owed, the sell lands; release pays the creator later.
    function test_creatorAsRecipient_blockedCreatorDoesNotBlockSell() public {
        BlacklistQuote bq = new BlacklistQuote();
        vm.prank(owner);
        quoteRegistry.setQuote(address(bq), true, 15 ether);
        vm.prank(agent);
        address t = pad.create("B", "B", "", "", address(bq), address(0), _tax(300, 300, 0, agent));
        _graduate(t);
        bq.setBlocked(agent, true);
        _poolBuy(t, stranger, 1 ether); // accrues the buy tax in tokens
        assertGt(handler.accruedTax(t), 0);
        vm.roll(vm.getBlockNumber() + 1);
        address seller = address(uint160(0xB0000)); // a curve buyer
        uint256 bal = IERC20(t).balanceOf(seller);
        assertGt(bal, 0);
        _poolSell(t, seller, bal / 2);
        assertEq(IERC20(t).balanceOf(seller), bal - bal / 2, "sell landed");
        assertGt(handler.owedOf(t), 0, "recipient leg owed, not reverted");
        bq.setBlocked(agent, false);
        uint256 owed = handler.owedOf(t);
        vm.prank(stranger);
        handler.release(t);
        assertEq(bq.balanceOf(agent), owed);
        assertEq(handler.owedOf(t), 0);
    }

    /// @notice Listing and delisting the creator changes nothing for naming itself; the creator-blind view refuses it.
    function test_creatorAsRecipient_delistedCreatorStillSelf() public {
        vm.prank(owner);
        handler.list(agent, "agent");
        vm.prank(owner);
        handler.delist(agent);
        (bool ok, string memory reason) = pad.checkTaxConfigFor(agent, _tax(200, 200, 0, agent));
        assertTrue(ok, reason);
        (ok,) = pad.checkTaxConfig(_tax(200, 200, 0, agent));
        assertFalse(ok);
    }

    // ---------------------------------------------------------------- §19: no tax on the curve
    /// @dev A taxed token's curve buy pays only the 1% protocol fee (→ bucket); the recipient, the vault and the
    ///      handler get nothing, and `Buy.tax` is 0.
    function test_curveBuy_onlyProtocolFee_noTax() public {
        address t = _create(_tax(500, 500, 4_000, treasury));
        uint256 gross = 0.01 ether;
        uint256 fee = (gross * 100) / BPS;
        vm.expectEmit(true, true, false, false, address(pad));
        emit Buy(t, agent, gross - fee, fee, 0, 0, 0);
        vm.recordLogs();
        vm.prank(agent);
        pad.buy(t, gross, 0);
        _assertNoHandlerLogs();

        assertEq(quoteTok.balanceOf(agent), 1_000 ether - gross, "pays exactly the gross");
        uint256 creatorFee = (fee * 7_000) / BPS;
        assertEq(pad.creatorFeeOf(t), creatorFee, "70% of the 1% kept for the creator");
        assertEq(bucket.accruedQuote(address(quoteTok)), fee - creatorFee, "30% of the 1% to the platform");
        assertEq(quoteTok.balanceOf(treasury), 0, "recipient gets nothing on the curve");
        assertEq(quoteTok.balanceOf(address(divVault)), 0, "holders get nothing on the curve");
        assertEq(quoteTok.balanceOf(address(handler)), 0, "nothing reaches the handler");
        (,, uint128 realQuote,,,,,,,,,) = pad.curves(t);
        assertEq(realQuote, gross - fee, "99% enters the curve");
        assertEq(divVault.shares(t, agent), IERC20(t).balanceOf(agent), "share still synced on the curve");
    }

    /// @dev Curve sell with dividends 40%: only 1% of the curve's payout → bucket; holders and the recipient get
    ///      nothing; the seller's share drops to what it still holds; `Sell.tax` is 0.
    function test_curveSell_onlyProtocolFee_holdersAndRecipientGetNothing() public {
        address t = _create(_tax(100, 500, 4_000, treasury));
        vm.prank(agent);
        pad.buy(t, 0.01 ether, 0);
        vm.prank(agent2);
        pad.buy(t, 0.02 ether, 0);
        assertGt(divVault.shares(t, agent), 0, "agent holds dividend shares");
        uint256 bal = IERC20(t).balanceOf(agent2);
        uint256 bucketBefore = bucket.accruedQuote(address(quoteTok));
        uint256 creatorBefore = pad.creatorFeeOf(t);
        uint256 quoteBefore = quoteTok.balanceOf(agent2);

        vm.startPrank(agent2);
        IERC20(t).approve(address(pad), bal / 2);
        vm.expectEmit(true, true, false, false, address(pad));
        emit Sell(t, agent2, bal / 2, 0, 0, 0, 0);
        vm.recordLogs();
        uint256 toUser = pad.sell(t, bal / 2, 0);
        vm.stopPrank();
        _assertNoHandlerLogs();

        uint256 toPlatform = bucket.accruedQuote(address(quoteTok)) - bucketBefore;
        uint256 toCreator = pad.creatorFeeOf(t) - creatorBefore;
        uint256 fee = toPlatform + toCreator;
        uint256 quoteOut = toUser + fee; // what the curve paid out
        assertEq(fee, (quoteOut * 100) / BPS, "only the 1% protocol fee");
        assertEq(toCreator, (fee * 7_000) / BPS, "70% of it kept for the creator");
        assertEq(quoteTok.balanceOf(agent2) - quoteBefore, toUser);
        assertEq(quoteTok.balanceOf(treasury), 0, "recipient gets nothing on the curve");
        assertEq(quoteTok.balanceOf(address(divVault)), 0, "holders get nothing on the curve");
        assertEq(divVault.pending(t, agent), 0, "no curve dividend");
        assertEq(quoteTok.balanceOf(address(handler)), 0);
        assertEq(divVault.shares(t, agent2), IERC20(t).balanceOf(agent2), "seller's share follows its balance");
    }

    /// @dev Same trades on a 5%/5% taxed token and an untaxed one: same tokens out, same quote back.
    function test_curve_taxedPricesLikeUntaxed() public {
        address taxed = _create(_tax(500, 500, 0, treasury));
        address plain = _create(_tax(0, 0, 0, address(0)));
        vm.startPrank(agent);
        uint256 outT = pad.buy(taxed, 0.05 ether, 0);
        uint256 outP = pad.buy(plain, 0.05 ether, 0);
        assertEq(outT, outP, "same tokens out");
        IERC20(taxed).approve(address(pad), outT);
        IERC20(plain).approve(address(pad), outP);
        assertEq(pad.sell(taxed, outT, 0), pad.sell(plain, outP, 0), "same quote back");
        vm.stopPrank();
    }

    /// @dev Graduating a taxed dividend token through the curve: every quote the buyers spent is the pair's liquidity
    ///      plus the 1% protocol fee; nothing went to the recipient or holders. After graduation the pool tax pays
    ///      holders by the shares the curve wrote, the platform 0.5% of volume, the recipient the rest.
    function test_curveToGraduation_onlyFee_thenPoolTaxSplitsAsBefore() public {
        address t = _create(_tax(200, 400, 5_000, treasury));
        uint256 supplyBefore = quoteTok.totalSupply();
        _graduate(t);
        address pair = TaxLaunchTokenV3(t).pair();
        uint256 spent = quoteTok.totalSupply() - supplyBefore - _quoteHeldByBuyers();
        uint256 creatorFees = pad.creatorFeeOf(t);
        uint256 fees = bucket.accruedQuote(address(quoteTok)) + creatorFees;
        // the creator's part stays on the pad; graduation truncation leaves ≤ 1 wei more
        uint256 dust = quoteTok.balanceOf(address(pad)) - creatorFees;
        assertLe(dust, 1, "pad dust");
        assertEq(quoteTok.balanceOf(pair) + fees + dust, spent, "spent = liquidity + 1% fee");
        assertApproxEqAbs(fees, quoteTok.balanceOf(pair) / 99, 400, "fee is 1% of the gross");
        assertApproxEqAbs(creatorFees, (fees * 7_000) / BPS, 400, "70% of the fee kept for the creator");
        assertEq(quoteTok.balanceOf(treasury), 0, "no curve tax to the recipient");
        assertEq(quoteTok.balanceOf(address(divVault)), 0, "no curve tax to holders");
        assertEq(quoteTok.balanceOf(address(handler)), 0);

        address holder = address(uint160(0xB0000));
        assertEq(divVault.shares(t, holder), IERC20(t).balanceOf(holder), "curve wrote the holder's share");
        assertEq(divVault.pendingUnits(t, holder), 0, "nothing earned on the curve");

        // pool buy 2%: platform 0.5% of volume (a quarter of the tax), half of the rest to holders, half to recipient
        _poolBuy(t, stranger, 1 ether);
        uint256 taxTokens = handler.accruedTax(t);
        assertGt(taxTokens, 0, "pool buy taxed");
        assertEq(handler.accruedPlatformTax(t), taxTokens / 4, "0.5 of 2%");
        assertGt(divVault.pendingUnits(t, holder), 0, "curve holder credited at tax time");
        assertEq(divVault.pendingUnits(t, stranger), 0, "buyer earns nothing of its own buy tax");

        uint256 bucketBefore = bucket.accruedQuote(address(quoteTok));
        vm.prank(keeper);
        uint256 quoteOut = handler.process(t, type(uint256).max, 1);
        uint256 toPlatform = bucket.accruedQuote(address(quoteTok)) - bucketBefore;
        uint256 toRecipient = quoteTok.balanceOf(treasury);
        uint256 toHolders = quoteOut - toPlatform - toRecipient;
        assertApproxEqRel(toPlatform, quoteOut / 4, 0.01e18, "platform 0.5% of volume");
        assertApproxEqRel(toHolders, toRecipient, 0.01e18, "rest split 50/50");
        assertGt(divVault.pending(t, holder), 0, "holder can claim pool dividends");
    }

    /// @dev Sum of the quote still held by the graduating buyers (`_graduate` mints each 1_000; the setUp agents don't buy).
    function _quoteHeldByBuyers() internal view returns (uint256 held) {
        for (uint256 i = 0; i < 400; i++) {
            held += quoteTok.balanceOf(address(uint160(0xB0000 + i)));
        }
    }

    /// @dev The recorded logs hold nothing from the tax handler (no TaxDistributed / TaxPaid / TaxOwed on the curve).
    function _assertNoHandlerLogs() internal view {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            assertTrue(logs[i].emitter != address(handler), "no handler event on a curve trade");
        }
    }

    // ---------------------------------------------------------------- 5 / 6: failed push → owed → release by anyone
    function test_failedPush_isOwed_tradeStillWorks_anyoneReleases() public {
        BlacklistQuote bq = new BlacklistQuote();
        vm.prank(owner);
        quoteRegistry.setQuote(address(bq), true, 15 ether);
        bq.setBlocked(treasury, true);

        vm.prank(agent);
        address t = pad.create("B", "B", "", "", address(bq), address(0), _tax(200, 200, 0, treasury));
        _graduate(t); // the curve pays the recipient nothing, so a blocked recipient never matters there
        _poolBuy(t, stranger, 1 ether);
        uint256 bucketBefore = bucket.accruedQuote(address(bq));
        vm.recordLogs();
        vm.prank(keeper);
        uint256 quoteOut = handler.process(t, type(uint256).max, 1); // does not revert
        uint256 owedAmt = quoteOut - (bucket.accruedQuote(address(bq)) - bucketBefore);
        assertGt(owedAmt, 0);
        assertEq(handler.owedOf(t), owedAmt);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool owedSeen;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(handler) && logs[i].topics[0] == TaxOwed.selector) {
                owedSeen = abi.decode(logs[i].data, (uint256)) == owedAmt;
            }
        }
        assertTrue(owedSeen, "TaxOwed");

        vm.prank(stranger);
        vm.expectRevert(bytes("blacklisted"));
        handler.release(t); // still blocked: stays owed
        assertEq(handler.owedOf(t), owedAmt);

        bq.setBlocked(treasury, false);
        vm.expectEmit(true, true, true, true, address(handler));
        emit TaxPaid(t, treasury, address(bq), owedAmt);
        vm.prank(stranger);
        handler.release(t);
        assertEq(handler.owedOf(t), 0);
        assertEq(bq.balanceOf(treasury), owedAmt);

        vm.expectRevert(TaxHandlerV3.NothingOwed.selector);
        handler.release(t);
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
        uint256 bucket0 = bucket.accruedQuote(address(quoteTok));
        _poolSell(t, stranger, sold);
        // the sell first sold the buy tax (swap-back, well under the 0.5% chunk cap): only its own tax is left
        uint256 sellTax = handler.accruedTax(t);
        assertEq(sellTax, (sold * 300) / BPS, "the buy tax was sold before this sell");
        assertEq(handler.accruedPlatformTax(t), (sellTax * 50) / 300, "sell: 0.5 of 3%");
        assertGt(bucket.accruedQuote(address(quoteTok)) - bucket0, 0, "buy tax: platform part paid in quote");
        assertGt(quoteTok.balanceOf(treasury) - recBefore, 0, "buy tax: rest to the recipient, in quote");
        recBefore = quoteTok.balanceOf(treasury);

        uint256 platformTokens = handler.accruedPlatformTax(t);
        uint256 totalTokens = handler.accruedTax(t);
        uint256 bucketBefore = bucket.accruedQuote(address(quoteTok));
        // next block: the sell above moved the price far below this block's reference (audit 5: no chunk sells there)
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(keeper);
        uint256 quoteOut = handler.process(t, type(uint256).max, 1);
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
        uint256 fee = (0.01 ether * 100) / BPS;
        assertEq(pad.creatorFeeOf(t), (fee * 7_000) / BPS, "creator's 70% of the 1%");
        assertEq(bucket.accruedQuote(address(quoteTok)), fee - (fee * 7_000) / BPS, "platform's 30% of the 1%");
        assertEq(quoteTok.balanceOf(treasury), 0);
    }

    // ---------------------------------------------------------------- 7: V2 rules unchanged
    function test_agentGateAndWalletCapUnchanged() public {
        address t = _create(_tax(200, 200, 0, treasury));
        quoteTok.mintUnlimited(stranger, 1 ether);
        vm.startPrank(stranger);
        quoteTok.approve(address(pad), type(uint256).max);
        vm.expectRevert(IGangLaunchpad.NotAgent.selector);
        pad.buy(t, 0.01 ether, 0);
        vm.stopPrank();

        vm.prank(agent);
        pad.buy(t, 5 ether, 0);
        assertEq(IERC20(t).balanceOf(agent), pad.MAX_PER_WALLET(), "1% cap");
        vm.prank(agent);
        vm.expectRevert(IGangLaunchpad.WalletCapReached.selector);
        pad.buy(t, 0.01 ether, 0);
        assertEq(pad.TARGET_GRAD_BNB(), 15 ether);
    }

    // ---------------------------------------------------------------- audit G-01 on the V3 handler
    function test_auditG01_excludedHolderZeroedOnSync() public {
        address t = _create(_tax(200, 200, 10_000, address(0)));
        _graduate(t);
        address holder = address(uint160(0xB0000)); // first graduating buyer
        assertGt(divVault.shares(t, holder), 0);
        // audit 5 C-F5: only a contract can be excluded (say the buyer was a locker contract)
        vm.prank(owner);
        vm.expectRevert(SharedDividendVault.NotAContract.selector);
        divVault.setExcluded(holder, true);
        vm.etch(holder, hex"00");
        vm.prank(owner);
        divVault.setExcluded(holder, true);
        handler.syncShares(t, holder, address(0));
        assertEq(divVault.shares(t, holder), 0, "excluded holder no longer earns");
    }

    // ---------------------------------------------------------------- access control
    function test_router_accessControl() public {
        address t = _create(_tax(200, 200, 0, treasury));

        vm.expectRevert(TaxHandlerV3.OnlyLaunchpad.selector);
        handler.register(address(0xBEEF), address(quoteTok), treasury, 0, 1);

        vm.prank(address(pad));
        vm.expectRevert(TaxHandlerV3.AlreadyRegistered.selector);
        handler.register(t, address(quoteTok), treasury, 0, 1);

        vm.prank(address(pad));
        vm.expectRevert(TaxHandlerV3.BadDividendBps.selector);
        handler.register(address(0xBEEF), address(quoteTok), address(0), 5_000, 1);

        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", stranger));
        handler.setLaunchpad(stranger);
        vm.stopPrank();

        vm.prank(owner);
        vm.expectRevert(TaxHandlerV3.LaunchpadAlreadySet.selector);
        handler.setLaunchpad(stranger);
    }

    function test_recipientRegistry_accessControl() public {
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", stranger));
        handler.list(stranger, "me");
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", stranger));
        handler.delist(treasury);
        vm.stopPrank();

        vm.startPrank(owner);
        vm.expectRevert(TaxHandlerV3.AlreadyListed.selector);
        handler.list(treasury, "again");
        vm.expectRevert(PostGradHandlerBase.ZeroAddress.selector);
        handler.list(address(0), "zero");
        vm.expectRevert(TaxHandlerV3.NotListed.selector);
        handler.delist(stranger);
        handler.delist(treasury);
        handler.list(treasury, "relisted");
        vm.stopPrank();
        assertEq(handler.recipients().length, 1, "relisting does not duplicate");
        assertTrue(handler.isListed(treasury));
    }

    function test_handler_onlyTokenAndKeeper() public {
        address t = _create(_tax(200, 200, 0, treasury));
        vm.prank(stranger);
        vm.expectRevert(PostGradHandlerBase.OnlyToken.selector);
        handler.notifyTax(t, stranger, stranger, 1, 200);
        vm.prank(stranger);
        vm.expectRevert(PostGradHandlerBase.OnlyKeeperOrOwner.selector);
        handler.process(t, type(uint256).max, 1);
    }
}

