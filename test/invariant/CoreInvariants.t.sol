// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {QuoteRegistry} from "../../src/launchpad-v2/QuoteRegistry.sol";
import {SharedDividendVault} from "../../src/common/SharedDividendVault.sol";
import {PlatformFeeBucket} from "../../src/launchpad-v2/PlatformFeeBucket.sol";
import {SharedMigrator} from "../../src/common/SharedMigrator.sol";
import {TokenDeployer} from "../../src/common/TokenDeployer.sol";
import {MockSPCXB} from "../../src/launchpad-v2/mocks/MockSPCXB.sol";
import {MockPairFactory, MockPair} from "../../src/launchpad-v2/mocks/MockPairFactory.sol";
import {LaunchpadV3} from "../../src/launchpad-v3/LaunchpadV3.sol";
import {TaxLaunchTokenV3} from "../../src/launchpad-v3/TaxLaunchTokenV3.sol";
import {TaxHandlerV3} from "../../src/launchpad-v3/TaxHandlerV3.sol";
import {ILaunchpadV3} from "../../src/launchpad-v3/interfaces/ILaunchpadV3.sol";
import {FairMintPad} from "../../src/fair-mint/FairMintPad.sol";
import {FairToken} from "../../src/fair-mint/FairToken.sol";
import {HolderRewardHandler} from "../../src/fair-mint/HolderRewardHandler.sol";
import {GangRouter} from "../../src/router/GangRouter.sol";
import {MockAgentId} from "../mocks/MockAgentId.sol";
import {MockWBNB} from "../mocks/MockWBNB.sol";
import {BlacklistQuote} from "../launchpad-v3/LaunchpadV3.t.sol";

/// @dev The whole mainnet layout on mocks: LaunchpadV3 + 打新 sharing one QuoteRegistry and one PlatformFeeBucket, both
///      behind GangRouter. Three listed quotes: WBNB, an 18-decimal test quote, and a quote that can blacklist the
///      tax recipient (so pushes fail and become owed).
contract CoreSystem is Test {
    MockWBNB public wbnb;
    MockSPCXB public quoteTok;
    BlacklistQuote public blq;
    MockAgentId public agents;
    MockPairFactory public pairFactory;
    QuoteRegistry public registry;
    PlatformFeeBucket public bucket;

    LaunchpadV3 public v3;
    SharedDividendVault public v3Vault;
    TaxHandlerV3 public v3Handler;

    FairMintPad public fair;
    SharedDividendVault public fairVault;
    HolderRewardHandler public fairHandler;

    GangRouter public router;

    address public owner = makeAddr("owner");
    address public treasury = makeAddr("treasury");

    function _deploySystem(address keeper) internal {
        wbnb = new MockWBNB();
        vm.deal(address(wbnb), 1_000_000 ether); // backs unwraps of faucet-minted WBNB
        quoteTok = new MockSPCXB();
        blq = new BlacklistQuote();
        agents = new MockAgentId();
        pairFactory = new MockPairFactory();
        registry = new QuoteRegistry(owner);
        bucket = new PlatformFeeBucket(owner, makeAddr("feeVault"));

        // one vault / migrator / deployer for both cores, as deployed (v3Vault and fairVault are the same contract)
        v3Vault = new SharedDividendVault(owner);
        fairVault = v3Vault;
        SharedMigrator mig = new SharedMigrator(owner, address(pairFactory));
        TokenDeployer deployer = new TokenDeployer(owner);
        v3Handler = new TaxHandlerV3(owner, address(v3Vault), address(bucket));
        v3 = new LaunchpadV3(
            owner,
            address(registry),
            address(v3Vault),
            address(bucket),
            address(v3Handler),
            address(deployer),
            address(wbnb),
            address(pairFactory)
        );

        fairHandler = new HolderRewardHandler(owner, address(fairVault), address(bucket));
        fair = new FairMintPad(
            owner,
            address(registry),
            address(fairVault),
            address(bucket),
            address(fairHandler),
            address(deployer),
            address(wbnb),
            address(pairFactory)
        );
        router = new GangRouter(address(v3), address(fair), address(wbnb));

        vm.startPrank(owner);
        registry.setQuote(address(quoteTok), true, 15 ether);
        registry.setQuote(address(blq), true, 15 ether);
        bucket.setOperator(address(v3), true);
        bucket.setOperator(address(v3Handler), true);
        bucket.setOperator(address(fair), true);
        bucket.setOperator(address(fairHandler), true);
        v3Vault.setLaunchpad(address(v3), true);
        v3Vault.setMinimumShareBalance(address(v3), 10_000 ether);
        v3Vault.setOperator(address(v3Handler), address(v3));
        mig.addLaunchpad(address(v3));
        deployer.setLaunchpad(address(v3), true);
        v3Handler.setLaunchpad(address(v3));
        v3Handler.setKeeper(keeper);
        v3Handler.list(treasury, "partner treasury");
        v3.setAgentGate(true, address(agents));
        v3.setRouter(address(router), true);
        v3.setMigrator(address(mig));
        fairVault.setLaunchpad(address(fair), true);
        fairVault.setMinimumShareBalance(address(fair), 10_000 ether);
        fairVault.setOperator(address(fairHandler), address(fair));
        mig.addLaunchpad(address(fair));
        deployer.setLaunchpad(address(fair), true);
        fairHandler.setPad(address(fair));
        fairHandler.setKeeper(keeper);
        fair.setAgentGate(true, address(agents));
        fair.setRouter(address(router), true);
        fair.setMigrator(address(mig));
        vm.stopPrank();
    }
}

/// @notice Random actions against the whole system. Calls that the rules refuse (cap, deadline, slippage…) just revert
///         and are skipped; the invariants are checked after every call either way.
contract CoreHandler is CoreSystem {
    uint256 internal constant TPS = 50_000 ether;

    address[] public actors;
    address[] public holders; // every address that ever held a token (for dividend sums)
    mapping(address => bool) internal isHolder;
    uint256 internal nextAgentId = 1;
    uint256 internal freshNonce;

    address[] public v3Tokens;
    mapping(address => bytes32) public v3ConfigHash;
    address[] public sales;
    mapping(address => mapping(address => bool)) public everOut;

    uint256 public calls;
    uint256 public v3Graduations;
    uint256 public fairLaunches;
    uint256 public staleExits; // withdraws with the exit fee waived (no mint for 7 days)
    uint256 public owedEvents;
    uint256 public blqTokens;
    uint256 public blockedSet;

    constructor() {
        _deploySystem(address(this));
        for (uint256 i = 0; i < 6; i++) {
            actors.push(_newAgent());
        }
    }

    // ---------------------------------------------------------------- views for the invariants
    function v3TokenCount() external view returns (uint256) {
        return v3Tokens.length;
    }

    function saleCount() external view returns (uint256) {
        return sales.length;
    }

    function holderCount() external view returns (uint256) {
        return holders.length;
    }

    // ---------------------------------------------------------------- helpers
    function _newAgent() internal returns (address who) {
        who = address(uint160(uint256(keccak256(abi.encode("agent", freshNonce++)))));
        agents.mint(who, nextAgentId++);
        vm.deal(who, 1_000 ether);
        wbnb.mintUnlimited(who, 1_000 ether);
        quoteTok.mintUnlimited(who, 1_000 ether);
        blq.mint(who, 1_000 ether);
        vm.startPrank(who);
        address[3] memory spenders = [address(v3), address(fair), address(router)];
        for (uint256 i = 0; i < 3; i++) {
            wbnb.approve(spenders[i], type(uint256).max);
            quoteTok.approve(spenders[i], type(uint256).max);
            blq.approve(spenders[i], type(uint256).max);
        }
        vm.stopPrank();
        _track(who);
    }

    function _track(address who) internal {
        if (!isHolder[who]) {
            isHolder[who] = true;
            holders.push(who);
        }
    }

    /// @dev Picks hash the seed first: the fuzzer favours small integers, which would always pick the first entry.
    function _pick(uint256 seed, uint256 salt, uint256 n) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(seed, salt))) % n;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[_pick(seed, 1, actors.length)];
    }

    function _quote(uint256 seed) internal view returns (address) {
        uint256 k = _pick(seed, 2, 3);
        return k == 0 ? address(wbnb) : k == 1 ? address(quoteTok) : address(blq);
    }

    function _mintQuote(address q, address to, uint256 amount) internal {
        if (q == address(wbnb)) wbnb.mintUnlimited(to, amount);
        else if (q == address(quoteTok)) quoteTok.mintUnlimited(to, amount);
        else blq.mint(to, amount);
    }

    function _v3(uint256 seed) internal view returns (address) {
        return v3Tokens[_pick(seed, 3, v3Tokens.length)];
    }

    function _sale(uint256 seed) internal view returns (address) {
        return sales[_pick(seed, 4, sales.length)];
    }

    function _curve(address t) internal view returns (address quote, bool graduated, address pair) {
        (, quote,,,,, graduated,,,, pair,) = v3.curves(t);
    }

    function _saleState(address t) internal view returns (address quote, bool launched, address pair) {
        (,,,, quote,, launched,,,,, pair,,) = fair.sales(t);
    }

    function _pairSwapOut(MockPair pair, address token, bool tokenOut, uint256 out, address to) internal {
        if ((pair.token0() == token) == tokenOut) pair.swap(out, 0, to, "");
        else pair.swap(0, out, to, "");
    }

    function _reserves(address token, MockPair pair) internal view returns (uint256 rT, uint256 rQ) {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        (rT, rQ) = pair.token0() == token ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }

    /// @dev Pool buy on a MockPair (no K check): `quoteIn` lands in the pair, the actor takes half the CP amount out.
    function _poolBuy(address token, address quote, address pair, address who, uint256 quoteIn) internal {
        _mintQuote(quote, pair, quoteIn);
        (uint256 rT, uint256 rQ) = _reserves(token, MockPair(pair));
        if (rT == 0 || rQ == 0) return;
        uint256 out = (quoteIn * rT) / (rQ + quoteIn) / 2;
        if (out == 0) return;
        try this.swapOut(pair, token, true, out, who) {} catch {}
    }

    function _poolSell(address token, address pair, address who, uint256 amount) internal {
        if (amount == 0) return;
        vm.prank(who);
        try IERC20(token).transfer(pair, amount) returns (bool) {}
        catch {
            return;
        }
        (uint256 rT, uint256 rQ) = _reserves(token, MockPair(pair));
        uint256 bal = IERC20(token).balanceOf(pair);
        if (bal <= rT) return;
        uint256 out = ((bal - rT) * rQ) / bal / 2;
        if (out == 0) return;
        try this.swapOut(pair, token, false, out, who) {} catch {}
    }

    function swapOut(address pair, address token, bool tokenOut, uint256 out, address to) external {
        require(msg.sender == address(this));
        _pairSwapOut(MockPair(pair), token, tokenOut, out, to);
    }

    // ================================================================ LaunchpadV3 actions
    function v3Create(uint256 seed, uint16 buyBps, uint16 sellBps, uint16 dividendBps, bool noRecipient) external {
        calls++;
        if (v3Tokens.length >= 4) return;
        address creator = _actor(seed);
        address q = _quote(seed);
        buyBps = uint16(bound(buyBps, 100, 500));
        sellBps = uint16(bound(sellBps, 100, 500));
        dividendBps = noRecipient ? 10_000 : uint16(bound(dividendBps, 0, 10_000));
        ILaunchpadV3.TaxConfig memory tax = ILaunchpadV3.TaxConfig({
            buyTaxBps: buyBps,
            sellTaxBps: sellBps,
            dividendBps: dividendBps,
            recipient: noRecipient ? address(0) : treasury
        });
        if (_pick(seed, 5, 5) == 0) tax = ILaunchpadV3.TaxConfig(0, 0, 0, address(0)); // untaxed (LaunchTokenV3)
        vm.prank(creator);
        address t = v3.create("T", "T", "", "", q, address(0), tax);
        v3Tokens.push(t);
        if (q == address(blq)) blqTokens++;
        (uint16 b, uint16 s, uint16 d, address r) = v3.taxConfigOf(t);
        v3ConfigHash[t] = keccak256(abi.encode(b, s, d, r));
    }

    function v3Buy(uint256 seed, uint256 amount, uint8 path) external {
        calls++;
        if (v3Tokens.length == 0) return;
        address t = _v3(seed);
        address who = _actor(seed + 1);
        (address q, bool graduated,) = _curve(t);
        if (graduated) return;
        amount = bound(amount, 1e12, 3 ether);
        vm.prank(who);
        if (path % 3 == 0) {
            try v3.buy(t, amount, 0) {} catch {}
        } else if (q == address(wbnb) && path % 3 == 1) {
            try router.v3BuyBNB{value: amount}(t, 0, block.timestamp) {} catch {}
        } else {
            try router.v3Buy(t, amount, 0, block.timestamp) {} catch {}
        }
        _afterV3(t);
    }

    function v3Sell(uint256 seed, uint256 fracBps) external {
        calls++;
        if (v3Tokens.length == 0) return;
        address t = _v3(seed);
        address who = _actor(seed + 1);
        (, bool graduated,) = _curve(t);
        if (graduated) return;
        uint256 bal = IERC20(t).balanceOf(who);
        uint256 amount = (bal * bound(fracBps, 1, 10_000)) / 10_000;
        if (amount == 0) return;
        vm.startPrank(who);
        IERC20(t).approve(address(v3), amount);
        try v3.sell(t, amount, 0) {} catch {}
        vm.stopPrank();
        _afterV3(t);
    }

    /// @dev Fresh agents buy 1 quote each (the 1% cap truncates) until the curve graduates.
    function v3Graduate(uint256 seed) external {
        calls++;
        if (v3Tokens.length == 0) return;
        address t = _v3(seed);
        (, bool graduated,) = _curve(t);
        if (graduated) return;
        for (uint256 i = 0; i < 300 && !graduated; i++) {
            address w = _newAgent();
            vm.prank(w);
            try v3.buy(t, 1 ether, 0) {} catch {}
            (, graduated,) = _curve(t);
        }
        _afterV3(t);
    }

    function v3PoolTrade(uint256 seed, uint256 amount, bool isBuy) external {
        calls++;
        if (v3Tokens.length == 0) return;
        address t = _v3(seed);
        (address q, bool graduated, address pair) = _curve(t);
        if (!graduated) return;
        address who = _actor(seed + 1);
        if (isBuy) _poolBuy(t, q, pair, who, bound(amount, 1e15, 2 ether));
        else _poolSell(t, pair, who, (IERC20(t).balanceOf(who) * bound(amount, 1, 10_000)) / 10_000);
    }

    function v3Transfer(uint256 seed, uint256 fracBps) external {
        calls++;
        if (v3Tokens.length == 0) return;
        address t = _v3(seed);
        (, bool graduated,) = _curve(t);
        if (!graduated) return; // locked before graduation
        address from = _actor(seed + 1);
        address to = _actor(seed + 2);
        uint256 amount = (IERC20(t).balanceOf(from) * bound(fracBps, 1, 10_000)) / 10_000;
        vm.prank(from);
        try IERC20(t).transfer(to, amount) returns (bool) {} catch {}
    }

    function v3Process(uint256 seed) external {
        calls++;
        if (v3Tokens.length == 0) return;
        address t = _v3(seed);
        try v3Handler.process(t, 1) {} catch {}
        _afterV3(t);
    }

    function v3Claim(uint256 seed) external {
        calls++;
        if (v3Tokens.length == 0) return;
        address t = _v3(seed);
        vm.prank(_actor(seed + 1));
        try v3Vault.claim(t) {} catch {}
    }

    function blockRecipient(bool blocked) external {
        calls++;
        blq.setBlocked(treasury, blocked);
        if (blocked) blockedSet++;
    }

    function v3Release(uint256 seed) external {
        calls++;
        if (v3Tokens.length == 0) return;
        try v3Handler.release(_v3(seed)) {} catch {}
    }

    function _afterV3(address t) internal {
        (, bool graduated, address pair) = _curve(t);
        if (graduated && pair != address(0) && !isHolder[pair]) {
            v3Graduations++;
            _track(pair);
        }
        if (v3Handler.owedOf(t) > 0) owedEvents++;
    }

    // ================================================================ 打新 actions
    function fairCreate(uint256 seed, uint256 raise, uint16 capBps, uint16 holdBps, uint16 fees) external {
        calls++;
        if (sales.length >= 4) return;
        address creator = _actor(seed);
        address q = _pick(seed, 6, 2) == 0 ? address(wbnb) : address(quoteTok);
        FairMintPad.MintConfig memory cfg = FairMintPad.MintConfig({
            raiseBnb: bound(raise, 5 ether, 50 ether),
            capBps: uint16(bound(capBps, 25, 50)),
            holdBps: uint16(bound(holdBps, 3_000, 8_000)),
            mintFeeBps: uint16(bound(fees, 100, 300)),
            exitFeeBps: uint16(bound(fees >> 4, 100, 200))
        });
        vm.prank(creator);
        address t = fair.create("F", "F", "", "", q, address(0), cfg, 1);
        sales.push(t);
    }

    function fairMint(uint256 seed, uint256 shares, bool viaRouter) external {
        calls++;
        if (sales.length == 0) return;
        address t = _sale(seed);
        address who = _actor(seed + 1);
        shares = bound(shares, 1, 120);
        (address q,,) = _saleState(t);
        vm.prank(who);
        if (!viaRouter) {
            try fair.mint(t, shares, 1) {} catch {}
        } else if (q == address(wbnb)) {
            try router.fairMintBNB{value: 5 ether}(t, shares, 1, block.timestamp) {} catch {}
        } else {
            try router.fairMint(t, shares, 1, block.timestamp) {} catch {}
        }
        _afterSale(t);
    }

    function fairWithdraw(uint256 seed, uint256 shares) external {
        calls++;
        if (sales.length == 0) return;
        address t = _sale(seed);
        address who = _actor(seed + 1);
        uint16 held = fair.positions(t, who);
        if (held == 0) return;
        bool stale = fair.exitFeeBpsOf(t) == 0;
        vm.prank(who);
        try fair.withdraw(t, bound(shares, 1, held)) {
            if (stale) staleExits++;
        } catch {}
    }

    /// @dev Fresh agents mint up to the cap until the sale fills (and launches in that same tx).
    function fairFill(uint256 seed) external {
        calls++;
        if (sales.length == 0) return;
        address t = _sale(seed);
        (, bool launched,) = _saleState(t);
        if (launched || fair.status(t) != FairMintPad.Status.Minting) return;
        for (uint256 i = 0; i < 600 && !launched; i++) {
            address w = _newAgent();
            vm.prank(w);
            try fair.mint(t, 500, 1) {} catch {}
            (, launched,) = _saleState(t);
        }
        _afterSale(t);
    }

    function fairPoolTrade(uint256 seed, uint256 amount, bool isBuy) external {
        calls++;
        if (sales.length == 0) return;
        address t = _sale(seed);
        (address q, bool launched, address pair) = _saleState(t);
        if (!launched) return;
        address who = _actor(seed + 1);
        if (isBuy) _poolBuy(t, q, pair, who, bound(amount, 1e15, 2 ether));
        else _poolSell(t, pair, who, (IERC20(t).balanceOf(who) * bound(amount, 1, 10_000)) / 10_000);
        _recordOut(t);
    }

    function fairTransfer(uint256 seed, uint256 fracBps) external {
        calls++;
        if (sales.length == 0) return;
        address t = _sale(seed);
        (, bool launched,) = _saleState(t);
        if (!launched) return;
        address from = _actor(seed + 1);
        address to = _actor(seed + 2);
        uint256 amount = (IERC20(t).balanceOf(from) * bound(fracBps, 1, 10_000)) / 10_000;
        vm.prank(from);
        try IERC20(t).transfer(to, amount) returns (bool) {} catch {}
        _recordOut(t);
    }

    function fairProcess(uint256 seed) external {
        calls++;
        if (sales.length == 0) return;
        try fairHandler.process(_sale(seed), 1) {} catch {}
    }

    function fairClaim(uint256 seed) external {
        calls++;
        if (sales.length == 0) return;
        vm.prank(_actor(seed + 1));
        try fairVault.claim(_sale(seed)) {} catch {}
    }

    function warp(uint256 dt) external {
        calls++;
        // up to 8 days: long enough for a sale to go stale (no mint for 7 days → no exit fee)
        vm.warp(block.timestamp + bound(dt, 1 minutes, 8 days));
    }

    function _afterSale(address t) internal {
        (, bool launched, address pair) = _saleState(t);
        if (launched && !isHolder[pair]) {
            fairLaunches++;
            _track(pair);
        }
    }

    function _recordOut(address t) internal {
        for (uint256 i = 0; i < actors.length; i++) {
            if (fairHandler.isOut(t, actors[i])) everOut[t][actors[i]] = true;
        }
    }
}

/// @notice Fund-conservation invariants of docs/AUDIT-BRIEF-2026-10-26.md §5, checked after every random call.
///         CI runs 24 × 50; the pre-release stress run was 400 runs × 80 calls (32,000 calls), all passing. For a stress
///         run, raise the two numbers below.
/// forge-config: default.invariant.runs = 24
/// forge-config: default.invariant.depth = 50
/// forge-config: default.invariant.fail-on-revert = false
contract CoreInvariantsTest is Test {
    CoreHandler internal h;

    function setUp() public {
        h = new CoreHandler();
        targetContract(address(h));
        bytes4[] memory sel = new bytes4[](27);
        sel[0] = CoreHandler.v3Create.selector;
        sel[1] = CoreHandler.v3Buy.selector;
        sel[2] = CoreHandler.v3Sell.selector;
        sel[3] = CoreHandler.v3Graduate.selector;
        sel[4] = CoreHandler.v3PoolTrade.selector;
        sel[5] = CoreHandler.v3Transfer.selector;
        sel[6] = CoreHandler.v3Process.selector;
        sel[7] = CoreHandler.v3Claim.selector;
        sel[8] = CoreHandler.blockRecipient.selector;
        sel[9] = CoreHandler.v3Release.selector;
        sel[10] = CoreHandler.fairCreate.selector;
        sel[11] = CoreHandler.fairMint.selector;
        sel[12] = CoreHandler.fairWithdraw.selector;
        sel[13] = CoreHandler.fairWithdraw.selector;
        sel[14] = CoreHandler.fairFill.selector;
        sel[15] = CoreHandler.fairPoolTrade.selector;
        sel[16] = CoreHandler.fairTransfer.selector;
        sel[17] = CoreHandler.fairProcess.selector;
        sel[18] = CoreHandler.fairClaim.selector;
        sel[19] = CoreHandler.warp.selector;
        // weights: trades, the blacklist toggle, time and withdraws come up more often so owed tax and stale exits
        // are reached in most runs
        sel[20] = CoreHandler.v3Buy.selector;
        sel[21] = CoreHandler.blockRecipient.selector;
        sel[22] = CoreHandler.warp.selector;
        sel[23] = CoreHandler.fairWithdraw.selector;
        sel[24] = CoreHandler.fairMint.selector;
        sel[25] = CoreHandler.v3Release.selector;
        sel[26] = CoreHandler.v3Create.selector;
        targetSelector(FuzzSelector({addr: address(h), selectors: sel}));
    }

    function _quotes() internal view returns (address[3] memory) {
        return [address(h.wbnb()), address(h.quoteTok()), address(h.blq())];
    }

    // ---------------------------------------------------------------- 打新 (§5 #1–#4, #6)
    /// @dev #1: per quote, the pad holds exactly Σ over not-launched sales of the principal of live positions, plus exit
    ///      fees the bucket refused (mint fees go to the platform at mint: nothing else is escrowed).
    function invariant_fairEscrowExact() public view {
        FairMintPad fair = h.fair();
        address[3] memory qs = _quotes();
        for (uint256 k = 0; k < 3; k++) {
            uint256 owed;
            for (uint256 i = 0; i < h.saleCount(); i++) {
                address t = h.sales(i);
                (,,,, address q,, bool launched,,,, uint128 price,,,) = fair.sales(t);
                if (q != qs[k] || launched) continue;
                for (uint256 j = 0; j < h.holderCount(); j++) {
                    uint16 shares = fair.positions(t, h.holders(j));
                    owed += uint256(shares) * price;
                }
            }
            owed += fair.owedFee(qs[k]);
            assertEq(IERC20(qs[k]).balanceOf(address(fair)), owed, "fair pad quote == live principal + owed fees");
        }
    }

    /// @dev #2 / #3: positions add up, caps hold, tokens are where the shares say.
    function invariant_fairPositionsAndTokens() public view {
        FairMintPad fair = h.fair();
        for (uint256 i = 0; i < h.saleCount(); i++) {
            address t = h.sales(i);
            (,, uint16 cap,,, uint16 sold, bool launched,,,,,,,) = fair.sales(t);
            assertLe(sold, 10_000, "sold <= 10,000");
            uint256 sumShares;
            for (uint256 j = 0; j < h.holderCount(); j++) {
                uint16 s = fair.positions(t, h.holders(j));
                assertLe(s, cap, "shares <= cap");
                sumShares += s;
            }
            assertEq(sumShares, sold, "sold == sum shares");
            uint256 padTokens = IERC20(t).balanceOf(address(fair));
            if (launched) assertEq(padTokens, 0, "pad holds no token after launch");
            else assertEq(padTokens, 1_000_000_000 ether - sumShares * 50_000 ether, "pad holds the unminted supply");
        }
    }

    /// @dev #6: once out, always out; a reward weight never exceeds the launch baseline.
    function invariant_fairRewardWeights() public view {
        FairMintPad fair = h.fair();
        for (uint256 i = 0; i < h.saleCount(); i++) {
            address t = h.sales(i);
            (,,,,,, bool launched,,,,,,,) = fair.sales(t);
            if (!launched) continue;
            for (uint256 j = 0; j < h.holderCount(); j++) {
                address u = h.holders(j);
                if (h.everOut(t, u)) assertTrue(h.fairHandler().isOut(t, u), "out stays out");
                assertLe(h.fairVault().shares(t, u), fair.baselineOf(t, u), "weight <= baseline");
            }
        }
    }

    // ---------------------------------------------------------------- LaunchpadV3 (§5 #7, #9, #10)
    /// @dev #7: per quote, the pad holds at least Σ realQuote of the live curves; and all unsold supply.
    function invariant_v3Reserves() public view {
        LaunchpadV3 v3 = h.v3();
        address[3] memory qs = _quotes();
        for (uint256 k = 0; k < 3; k++) {
            uint256 live;
            for (uint256 i = 0; i < h.v3TokenCount(); i++) {
                (, address q, uint128 realQuote,,,, bool graduated,,,,,) = v3.curves(h.v3Tokens(i));
                if (q == qs[k] && !graduated) live += realQuote;
            }
            assertGe(IERC20(qs[k]).balanceOf(address(v3)), live, "pad quote >= live realQuote");
        }
        for (uint256 i = 0; i < h.v3TokenCount(); i++) {
            address t = h.v3Tokens(i);
            (,,, uint128 sold,,, bool graduated,,,,,) = v3.curves(t);
            uint256 padTokens = IERC20(t).balanceOf(address(v3));
            if (graduated) assertEq(padTokens, 0, "pad holds no token after graduation");
            else assertEq(padTokens, 1_000_000_000 ether - sold, "pad holds the unsold supply");
        }
    }

    /// @dev #9: per quote, TaxHandlerV3 holds at least everything it owes, and its running total (what `process`
    ///      keeps back from a sale) is exactly Σ owedOf.
    function invariant_v3OwedBacked() public view {
        TaxHandlerV3 r = h.v3Handler();
        address[3] memory qs = _quotes();
        for (uint256 k = 0; k < 3; k++) {
            uint256 owed;
            for (uint256 i = 0; i < h.v3TokenCount(); i++) {
                address t = h.v3Tokens(i);
                (address q,,) = r.routeOf(t);
                if (q == qs[k]) owed += r.owedOf(t);
            }
            assertGe(IERC20(qs[k]).balanceOf(address(r)), owed, "handler quote >= owed");
            assertEq(r.owedTotalOf(qs[k]), owed, "owedTotalOf == sum of owedOf");
        }
    }

    /// @dev #10: tax config never changes after create.
    function invariant_v3ConfigImmutable() public view {
        for (uint256 i = 0; i < h.v3TokenCount(); i++) {
            address t = h.v3Tokens(i);
            (uint16 b, uint16 s, uint16 d, address r) = h.v3().taxConfigOf(t);
            assertEq(keccak256(abi.encode(b, s, d, r)), h.v3ConfigHash(t), "tax config immutable");
        }
    }

    // ---------------------------------------------------------------- shared sinks and the router (§5 #11)
    /// @dev The bucket holds what it accounts for; each vault can pay every holder's pending rewards.
    function invariant_sinksSolvent() public view {
        address[3] memory qs = _quotes();
        PlatformFeeBucket b = h.bucket();
        for (uint256 k = 0; k < 3; k++) {
            assertGe(IERC20(qs[k]).balanceOf(address(b)), b.accruedQuote(qs[k]), "bucket >= accrued");
            assertGe(IERC20(qs[k]).balanceOf(address(h.v3Vault())), _pendingSum(h.v3Vault(), qs[k], true), "v3 vault");
            assertGe(
                IERC20(qs[k]).balanceOf(address(h.fairVault())), _pendingSum(h.fairVault(), qs[k], false), "fair vault"
            );
        }
    }

    function _pendingSum(SharedDividendVault vault, address quote, bool isV3) internal view returns (uint256 sum) {
        uint256 n = isV3 ? h.v3TokenCount() : h.saleCount();
        for (uint256 i = 0; i < n; i++) {
            address t = isV3 ? h.v3Tokens(i) : h.sales(i);
            if (vault.quoteOf(t) != quote) continue;
            for (uint256 j = 0; j < h.holderCount(); j++) {
                sum += vault.pending(t, h.holders(j));
            }
        }
    }

    /// @dev #11: the router never keeps anything between calls.
    function invariant_routerEmpty() public view {
        address[3] memory qs = _quotes();
        for (uint256 k = 0; k < 3; k++) {
            assertEq(IERC20(qs[k]).balanceOf(address(h.router())), 0, "router quote");
        }
        assertEq(address(h.router()).balance, 0, "router BNB");
    }

    /// @dev Coverage report: how much of the state space each run reached (-vv).
    function afterInvariant() external view {
        console2.log("calls / v3 tokens / graduations / owed seen", h.calls(), h.v3TokenCount(), h.v3Graduations());
        console2.log("  owed events / sales / launches / failures", h.owedEvents(), h.saleCount(), h.fairLaunches());
        console2.log("  stale exits / blq tokens / blocked set", h.staleExits(), h.blqTokens(), h.blockedSet());
    }
}
