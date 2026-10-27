// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SharedDividendVault} from "../../src/common/SharedDividendVault.sol";
import {SharedPlatformFeeBucket} from "../../src/common/SharedPlatformFeeBucket.sol";
import {GangTaxHandler} from "../../src/gang/GangTaxHandler.sol";
import {PostGradHandlerBase} from "../../src/common/PostGradHandlerBase.sol";
import {IGangPadView} from "../../src/gang/interfaces/IGangPadView.sol";
import {GangToken as TaxLaunchTokenV3} from "../../src/gang/stub/GangToken.sol";
import {GangToken as FairToken} from "../../src/gang/stub/GangToken.sol";
import {MockPair} from "../../src/launchpad-v2/mocks/MockPairFactory.sol";

contract KindQuote is ERC20("Quote", "Q") {
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Merge plan §7.3: one GangTaxHandler, one launchpad that registers both kinds (this contract plays the pad),
///         one vault core for both. Nothing but `routeOf.kind` tells the kinds apart, so each hook must follow the
///         kind the pad registered: the vault's `launchpadOf` is the same pad for both (R2-3, audit 4 F-3).
contract HandlerKindIsolationTest is Test, IGangPadView {
    using stdStorage for StdStorage;

    bytes32 constant OTP_CURVE = keccak256("OuterTaxProcessed(address,address,uint256,uint256,uint256)");
    bytes32 constant OTP_FAIR = keccak256("OuterTaxProcessed(address,address,uint256,uint256,uint256,uint256)");
    bytes32 constant TAX_DISTRIBUTED = keccak256("TaxDistributed(address,uint8,uint256,uint256,uint256,uint256)");

    SharedDividendVault vault;
    SharedPlatformFeeBucket bucket;
    GangTaxHandler handler;
    KindQuote quote;
    TaxLaunchTokenV3 curve;
    FairToken fair;
    MockPair curvePair;
    MockPair fairPair;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address seller = makeAddr("seller");
    address migrator = makeAddr("migrator");

    mapping(address token => mapping(address user => uint256)) internal _baseline;
    mapping(address token => uint16) internal _holdBps;
    mapping(address token => uint8) internal _kind;

    // ------------------------------------------------------------ IGangPadView (this test is the pad)
    function baselineOf(address token, address user) external view returns (uint256) {
        return _baseline[token][user];
    }

    function holdBpsOf(address token) external view returns (uint16) {
        return _holdBps[token];
    }

    function kindOf(address token) external view returns (uint8) {
        return _kind[token];
    }

    function setUp() public {
        quote = new KindQuote();
        vault = new SharedDividendVault(address(this));
        bucket = new SharedPlatformFeeBucket(address(this), makeAddr("feeVault"));
        handler = new GangTaxHandler(address(this), address(vault), address(bucket), address(0));
        handler.setLaunchpad(address(this));
        vault.setLaunchpad(address(this), true);
        vault.setOperator(address(handler), address(this));
        bucket.setOperator(address(handler), true);

        // Curve: 3% / 3%, all of the non-platform tax to holders. Fair: 1% / 1%, half to holders.
        curve = new TaxLaunchTokenV3("Curve", "CRV", "", address(this), address(handler), 300, 300, false);
        fair = new FairToken("Fair", "FAIR", "", address(this), address(handler), 100, 100, true);
        vault.registerToken(address(curve), address(quote));
        vault.registerToken(address(fair), address(quote));
        handler.register(address(curve), address(quote), address(0), 10_000, 1);
        handler.register(address(fair), address(quote), address(0), 5_000, 2);
        _kind[address(curve)] = 1;
        _kind[address(fair)] = 2;

        // the same holders in both tokens. Fair baselines: alice 100, bob 100, seller 100 (hold line 50%); the pad
        // also answers a baseline for the Curve token, which the handler must never use.
        _holdBps[address(fair)] = 5_000;
        _holdBps[address(curve)] = 9_000;
        address[3] memory who = [alice, bob, seller];
        for (uint256 i = 0; i < 3; i++) {
            _baseline[address(fair)][who[i]] = 100 ether;
            _baseline[address(curve)][who[i]] = 1 ether;
            curve.transfer(who[i], 300 ether);
            fair.transfer(who[i], 100 ether);
            vault.setShare(address(curve), who[i], 300 ether);
            vault.setShare(address(fair), who[i], 100 ether);
        }
        // alice also bought more Fair tokens after launch (above her baseline)
        fair.transfer(alice, 50 ether);

        curvePair = _launch(address(curve));
        fairPair = _launch(address(fair));
    }

    function _launch(address token) internal returns (MockPair pair) {
        if (token == address(curve)) curve.unlock(migrator);
        else fair.unlock(migrator);
        pair = new MockPair(token, address(quote));
        IERC20(token).transfer(address(pair), 1_000_000 ether);
        quote.mint(address(pair), 1_000 ether);
        pair.mint(address(0xdead));
        if (token == address(curve)) curve.setPair(address(pair));
        else fair.setPair(address(pair));
    }

    /// @dev `who` sells `amount` into `pair` (pool tax applies, swap-back runs first), then takes some quote out.
    function _poolSell(address token, MockPair pair, address who, uint256 amount) internal {
        vm.prank(who);
        IERC20(token).transfer(address(pair), amount);
        (uint112 r0, uint112 r1,) = pair.getReserves();
        bool t0 = pair.token0() == token;
        (uint256 rT, uint256 rQ) = t0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 inAmt = IERC20(token).balanceOf(address(pair)) - rT;
        uint256 out = (inAmt * rQ) / (rT + inAmt) / 2;
        if (t0) pair.swap(0, out, who, "");
        else pair.swap(out, 0, who, "");
    }

    function test_merge_kindIsolation_registerChecks() public {
        (address q, address recipient, uint16 dividendBps, uint8 kind) = handler.routeOf(address(fair));
        assertEq(q, address(quote));
        assertEq(recipient, address(0));
        assertEq(dividendBps, 5_000);
        assertEq(kind, 2);
        (,,, kind) = handler.routeOf(address(curve));
        assertEq(kind, 1);

        address t = makeAddr("t");
        vm.expectRevert(GangTaxHandler.BadKind.selector);
        handler.register(t, address(quote), address(0), 10_000, 0);
        vm.expectRevert(GangTaxHandler.BadKind.selector);
        handler.register(t, address(quote), address(0), 10_000, 3);
        // the Fair rule is fixed: no recipient, half to holders
        vm.expectRevert(GangTaxHandler.BadDividendBps.selector);
        handler.register(t, address(quote), alice, 5_000, 2);
        vm.expectRevert(GangTaxHandler.BadDividendBps.selector);
        handler.register(t, address(quote), address(0), 10_000, 2);
        // Curve: no recipient only with everything to holders
        vm.expectRevert(GangTaxHandler.BadDividendBps.selector);
        handler.register(t, address(quote), address(0), 5_000, 1);
        // write-once, whichever kind is asked the second time
        vm.expectRevert(GangTaxHandler.AlreadyRegistered.selector);
        handler.register(address(fair), address(quote), address(0), 10_000, 1);
        vm.expectRevert(GangTaxHandler.AlreadyRegistered.selector);
        handler.register(address(curve), address(quote), address(0), 5_000, 2);
        vm.prank(alice);
        vm.expectRevert(GangTaxHandler.OnlyLaunchpad.selector);
        handler.register(t, address(quote), address(0), 5_000, 2);
    }

    /// @dev The same holder, the same pad answers: Curve writes the balance, Fair min(balance, baseline) with the
    ///      hold line; neither rule leaks into the other token.
    function test_merge_kindIsolation_syncShares() public {
        vm.startPrank(alice);
        curve.transfer(bob, 200 ether); // alice 100 Curve left: below the 90% line the pad answers for Curve
        fair.transfer(bob, 10 ether); // alice 140 Fair: above her 100 baseline
        vm.stopPrank();

        assertEq(vault.shares(address(curve), alice), 100 ether, "Curve: balance (no baseline, no hold line)");
        assertEq(vault.shares(address(curve), bob), 500 ether, "Curve: balance, not capped at a baseline");
        assertFalse(handler.isOut(address(curve), alice), "no hold line on a Curve token");
        assertEq(vault.shares(address(fair), alice), 100 ether, "Fair: capped at the baseline");
        assertEq(vault.shares(address(fair), bob), 100 ether, "Fair: capped at the baseline");
        assertEq(handler.eligibleShare(address(curve), alice), 0, "eligibleShare is Fair only");
        assertEq(handler.eligibleShare(address(fair), alice), 100 ether);

        // below the Fair hold line: out for good on the Fair token only
        vm.prank(alice);
        fair.transfer(bob, 100 ether); // 40 < 50% of 100
        assertTrue(handler.isOut(address(fair), alice));
        assertEq(vault.shares(address(fair), alice), 0);
        vm.prank(bob);
        fair.transfer(alice, 100 ether);
        assertEq(vault.shares(address(fair), alice), 0, "buying back does not restore it");
        assertEq(vault.shares(address(curve), alice), 100 ether, "the Curve share is untouched");

        // permissionless, never reverts: anyone, unknown tokens included
        vm.prank(seller);
        handler.syncShares(makeAddr("unknown"), alice, bob);
        vm.prank(seller);
        handler.syncShares(address(curve), alice, bob);
        assertEq(vault.shares(address(curve), alice), 100 ether);
    }

    /// @dev Curve: platform 0.5% of volume first, then `dividendBps` of the rest; Fair: no platform part, half to the
    ///      holders. A Fair seller dropping below its line is out before the credit (C-F7). Unregistered → revert.
    function test_merge_kindIsolation_notifyTax() public {
        uint256 sold = 100 ether;
        _poolSell(address(curve), curvePair, seller, sold);
        uint256 cTax = (sold * 300) / 10_000;
        uint256 cPlatform = (cTax * 50) / 300;
        assertEq(handler.accruedTax(address(curve)), cTax);
        assertEq(handler.accruedPlatformTax(address(curve)), cPlatform, "Curve: 0.5% of volume");
        assertEq(vault.unsoldUnits(address(curve)), cTax - cPlatform, "Curve: the rest, all to holders");

        _poolSell(address(fair), fairPair, seller, 60 ether); // seller 40 < 50% of 100 → out
        uint256 fTax = (60 ether * 100) / 10_000;
        assertEq(handler.accruedTax(address(fair)), fTax);
        assertEq(handler.accruedPlatformTax(address(fair)), 0, "Fair: no platform part at tax time");
        assertEq(vault.unsoldUnits(address(fair)), (fTax * 5_000) / 10_000, "Fair: half to holders");
        assertTrue(handler.isOut(address(fair), seller), "C-F7: synced before the credit");
        assertEq(vault.pendingUnits(address(fair), seller), 0, "the seller earns nothing of its own sell");
        assertGt(vault.pendingUnits(address(fair), alice), 0);

        address fake = makeAddr("fake");
        vm.prank(fake);
        vm.expectRevert(GangTaxHandler.UnknownToken.selector);
        handler.notifyTax(fake, alice, bob, 1 ether, 100);
    }

    /// @dev Unregistered tokens can't ask for a swap-back; each kind's chunk emits its own event version, and only
    ///      the Curve chunk emits TaxDistributed.
    function test_merge_kindIsolation_swapBack() public {
        address fake = makeAddr("fake");
        vm.prank(fake);
        vm.expectRevert(GangTaxHandler.UnknownToken.selector);
        handler.swapBack(fake, 1 ether);

        _poolSell(address(curve), curvePair, seller, 100 ether);
        _poolSell(address(fair), fairPair, seller, 30 ether);
        vm.roll(block.number + 1);

        vm.recordLogs();
        _poolSell(address(curve), curvePair, bob, 50 ether); // the swap-back chunk runs inside this sell
        (uint256 cur, uint256 fai, uint256 dist) = _count(vm.getRecordedLogs());
        assertEq(cur, 1, "Curve: V3 event");
        assertEq(fai, 0);
        assertEq(dist, 1, "Curve: TaxDistributed");

        uint256 fee0 = bucket.accruedQuote(address(quote));
        vm.recordLogs();
        _poolSell(address(fair), fairPair, bob, 50 ether);
        (cur, fai, dist) = _count(vm.getRecordedLogs());
        assertEq(cur, 0);
        assertEq(fai, 1, "Fair: fair-mint event");
        assertEq(dist, 0, "Fair: no TaxDistributed");
        assertGt(bucket.accruedQuote(address(quote)), fee0, "Fair: the non-holder part is the platform's");
    }

    /// @dev §15: what is owed to recipients in a token (it can be another token's quote) is never sold — for both
    ///      kinds now (打新 used to sell its whole balance).
    function test_merge_sellableExcludesOwed_fair() public {
        _poolSell(address(fair), fairPair, seller, 30 ether);
        uint256 held = fair.balanceOf(address(handler));
        assertGt(held, 0);
        vm.roll(block.number + 1);
        stdstore.target(address(handler)).sig("owedTotalOf(address)").with_key(address(fair)).checked_write(held);
        assertEq(handler.maxChunk(address(fair)), 0, "owed tokens are not for sale");
        vm.expectRevert(PostGradHandlerBase.ZeroAmount.selector);
        handler.process(address(fair), type(uint256).max, 1);
    }

    function _count(Vm.Log[] memory logs) internal view returns (uint256 cur, uint256 fai, uint256 dist) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(handler)) continue;
            bytes32 t = logs[i].topics[0];
            if (t == OTP_CURVE) cur++;
            else if (t == OTP_FAIR) fai++;
            else if (t == TAX_DISTRIBUTED) dist++;
        }
    }
}
