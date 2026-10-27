// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {QuoteRegistry} from "../../src/launchpad-v2/QuoteRegistry.sol";
import {PlatformFeeBucket} from "../../src/launchpad-v2/PlatformFeeBucket.sol";
import {IPancakeRouter02} from "../../src/launchpad-v2/interfaces/IPancake.sol";
import {SharedDividendVault} from "../../src/common/SharedDividendVault.sol";
import {SharedMigrator} from "../../src/common/SharedMigrator.sol";
import {TokenDeployer} from "../../src/common/TokenDeployer.sol";
import {GangLaunchpad} from "../../src/gang/GangLaunchpad.sol";
import {GangTaxHandler} from "../../src/gang/GangTaxHandler.sol";
import {GangToken} from "../../src/gang/GangToken.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {GangRouter} from "../../src/router/GangRouter.sol";
import {GangRouterDeployLib as R} from "../../script/GangRouterDeployLib.sol";
import {GangRouterV2Mock} from "../mocks/GangRouterV2Mock.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract PoolForkAgent {
    mapping(address => uint256) public balanceOf;

    function set(address a, uint256 b) external {
        balanceOf[a] = b;
    }
}

interface IFactoryLite {
    function getPair(address, address) external view returns (address);
}

/// @notice The router proxy's PancakeSwap V2 entries (poolBuyBNB / poolBuy / poolSell / poolSellForBNB) on a BSC mainnet
///         fork against the real Pancake V2 router, for every kind of token that trades on a V2 pair: graduated V3 tax
///         tokens quoted in WBNB and in USDT, a launched 打新 token, and a live mainnet V2 token (only swapped: nothing
///         here calls the live V2 handler's `process`). Each: BNB buy, quote buy, sell to quote, sell to BNB, a minimum
///         one wei above the result reverts, and the router ends with no BNB / WBNB / quote / token and no allowance.
///         A sell through the router books dividends and tax exactly like a direct Pancake sell, and the router never
///         holds a share or dividend units. The gas of a router sell that carries a swap-back chunk is logged.
/// @dev Needs BSC_RPC_URL (without it every test returns early).
contract RouterPoolForkTest is Test {
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant V2_FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address constant V2_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    /// @dev A graduated, taxed LaunchpadV2 token with a live Pancake V2 pair: AGI (allTokens[224] of the live
    ///      LaunchpadV2 0x1B8F…966E), quoted in GANG (AGI/GANG pair 0x43ab…70Cc, GANG/WBNB 0x0bd5…0b6D), so BNB in /
    ///      out takes the 3-hop path. Only swapped here: the live V2 handler's `process` is never called.
    address constant LIVE_V2_TOKEN = 0x400067859346b77Ee6A838e8ce6B8e712F96177A;
    address constant LIVE_V2_QUOTE = 0x0c6302401aa5325C2E36F170f52C00B1d220B405;
    address constant LIVE_V2_VAULT = 0x5e2Dd1D439b251d64B4147D8947445f83f3A2D62;
    uint16 constant TAX = 300;
    address constant SAFE = 0x2866369F7acEFC9760bdE7779362fae5cD68B41E;

    address owner = makeAddr("owner");
    address keeper = makeAddr("keeper");
    address treasury = makeAddr("treasury");
    address dev = makeAddr("dev");
    address user = makeAddr("user");

    SharedDividendVault vault;
    GangTaxHandler handler;
    GangLaunchpad pad;
    PoolForkAgent agent;
    GangRouter router;
    R.Router rs;
    uint256 nonce;

    modifier forkOnly() {
        if (address(pad) == address(0)) {
            vm.skip(true);
            return;
        }
        _;
    }

    function setUp() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);

        vm.startPrank(owner);
        QuoteRegistry reg = new QuoteRegistry(owner);
        vault = new SharedDividendVault(owner);
        SharedMigrator mig = new SharedMigrator(owner, V2_FACTORY);
        TokenDeployer deployer = new TokenDeployer(owner);
        PlatformFeeBucket bucket = new PlatformFeeBucket(owner, owner);
        handler = new GangTaxHandler(owner, address(vault), address(bucket), V2_ROUTER);
        pad = new GangLaunchpad(
            owner, address(reg), address(vault), address(bucket), address(handler), address(deployer), WBNB, V2_FACTORY
        );
        agent = new PoolForkAgent();
        vault.setLaunchpad(address(pad), true);
        vault.setMinimumShareBalance(address(pad), 10_000 ether);
        vault.setOperator(address(handler), address(pad));
        vault.setExcluded(address(mig), true);
        vault.setExcluded(address(bucket), true);
        mig.addLaunchpad(address(pad));
        deployer.setLaunchpad(address(pad), true);
        bucket.setOperator(address(pad), true);
        bucket.setOperator(address(handler), true);
        handler.setLaunchpad(address(pad));
        handler.setKeeper(keeper);
        handler.list(treasury, "treasury");
        // USDT at a fixed rate (15 BNB = 1,500 USDT) keeps the fill short; the pool trades are what is tested
        reg.setQuote(USDT, true, 1_500 ether);
        pad.setMigrator(address(mig));
        pad.setAgentGate(true, address(agent));
        vm.stopPrank();

        // the router as deployed: impl → 48 h timelock (the platform Safe: on chain 56 the library builds no other)
        // → proxy; the pad lists the proxy
        rs = R.deploy(address(pad), WBNB, V2_ROUTER, SAFE, R.MAINNET_MIN_DELAY);
        router = GangRouter(payable(rs.proxy));
        vm.prank(owner);
        pad.setRouter(address(router), true);
        agent.set(dev, 1);
    }

    // ---------------------------------------------------------------- token set-up
    function _fresh() internal returns (address w) {
        w = address(uint160(uint256(keccak256(abi.encode("pool-fork", nonce++)))));
        agent.set(w, 1);
    }

    function _graduated(address t) internal view returns (bool g) {
        (,,,,,, g,,,,,) = pad.curves(t);
    }

    function _launchedSale(address t) internal view returns (bool l) {
        (,,,,,, l,,,,,,,) = pad.sales(t);
    }

    /// @dev Graduated V3 tax token in `quote`: 3% / 3%, half of the rest to holders, half to the treasury.
    function _v3(address quote, uint256 perBuy) internal returns (address t) {
        vm.prank(dev);
        t = pad.create(
            "Pool V3",
            "PV3",
            "",
            "",
            quote,
            address(0),
            IGangLaunchpad.TaxConfig({buyTaxBps: TAX, sellTaxBps: TAX, dividendBps: 5000, recipient: treasury})
        );
        for (uint256 i = 0; i < 400 && !_graduated(t); i++) {
            address w = _fresh();
            deal(quote, w, perBuy);
            vm.startPrank(w);
            IERC20(quote).approve(address(pad), perBuy);
            pad.buy(t, perBuy, 0);
            vm.stopPrank();
        }
        assertTrue(_graduated(t), "graduated");
    }

    /// @dev Launched 打新 token in WBNB: 15 BNB raise, 200 minters × 50 shares (the 0.5% cap).
    function _fair() internal returns (address t) {
        IGangLaunchpad.MintConfig memory cfg = IGangLaunchpad.MintConfig({
            raiseBnb: 15 ether, capBps: 50, holdBps: 5000, mintFeeBps: 100, exitFeeBps: 100
        });
        (, uint256 price) = pad.previewCreate(WBNB, address(0), 15 ether);
        deal(WBNB, dev, price * 2);
        vm.startPrank(dev);
        IERC20(WBNB).approve(address(pad), type(uint256).max);
        t = pad.create("Pool Fair", "PFAIR", "", "", WBNB, address(0), cfg, 1);
        vm.stopPrank();
        for (uint256 i = 0; i < 300 && !_launchedSale(t); i++) {
            address m = _fresh();
            deal(WBNB, m, price * 51 * 2);
            vm.startPrank(m);
            IERC20(WBNB).approve(address(pad), type(uint256).max);
            pad.mint(t, 50, 1);
            vm.stopPrank();
        }
        assertTrue(_launchedSale(t), "launched");
    }

    // ---------------------------------------------------------------- checks
    function _assertRouterClean(address t, address q) internal view {
        address r = address(router);
        assertEq(r.balance, 0, "router BNB");
        assertEq(IERC20(WBNB).balanceOf(r), 0, "router WBNB");
        assertEq(IERC20(q).balanceOf(r), 0, "router quote");
        assertEq(IERC20(t).balanceOf(r), 0, "router token");
        assertEq(IERC20(WBNB).allowance(r, V2_ROUTER), 0, "WBNB allowance");
        assertEq(IERC20(q).allowance(r, V2_ROUTER), 0, "quote allowance");
        assertEq(IERC20(t).allowance(r, V2_ROUTER), 0, "token allowance");
    }

    function _expectTooLittle(uint256 got) internal {
        vm.expectRevert(abi.encodeWithSelector(GangRouter.TooLittleReceived.selector, got, got + 1));
    }

    /// @dev All four entries for `t` / `q` by a fresh wallet (`perQuote` of the quote, `perBnb` BNB), each checked
    ///      against its own balance change, a minimum one above the result reverting first, and a clean router.
    function _exercise(address t, address q, uint256 perBnb, uint256 perQuote) internal {
        address u = _fresh();
        vm.deal(u, perBnb * 2);
        deal(q, u, perQuote);
        vm.startPrank(u);
        IERC20(q).approve(address(router), type(uint256).max);
        IERC20(t).approve(address(router), type(uint256).max);
        uint256 dl = vm.getBlockTimestamp();

        // BNB buy
        uint256 snap = vm.snapshotState();
        uint256 bal = IERC20(t).balanceOf(u);
        uint256 out = router.poolBuyBNB{value: perBnb}(t, q, 1, dl);
        assertGt(out, 0, "bnb buy");
        assertEq(IERC20(t).balanceOf(u) - bal, out, "bnb buy: measured on the user");
        _assertRouterClean(t, q);
        vm.revertToState(snap);
        _expectTooLittle(out);
        router.poolBuyBNB{value: perBnb}(t, q, out + 1, dl);
        router.poolBuyBNB{value: perBnb}(t, q, out, dl);
        _assertRouterClean(t, q);

        // quote buy
        snap = vm.snapshotState();
        bal = IERC20(t).balanceOf(u);
        uint256 qBal = IERC20(q).balanceOf(u);
        out = router.poolBuy(t, q, perQuote / 2, 1, dl);
        assertEq(IERC20(t).balanceOf(u) - bal, out, "quote buy");
        assertEq(qBal - IERC20(q).balanceOf(u), perQuote / 2, "spent exactly quoteIn");
        _assertRouterClean(t, q);
        vm.revertToState(snap);
        _expectTooLittle(out);
        router.poolBuy(t, q, perQuote / 2, out + 1, dl);
        router.poolBuy(t, q, perQuote / 2, out, dl);
        _assertRouterClean(t, q);

        // sell to quote
        uint256 held = IERC20(t).balanceOf(u);
        uint256 sellAmt = held / 3;
        snap = vm.snapshotState();
        qBal = IERC20(q).balanceOf(u);
        out = router.poolSell(t, q, sellAmt, 1, dl);
        assertGt(out, 0, "sell");
        assertEq(IERC20(q).balanceOf(u) - qBal, out, "sell: measured on the user");
        assertEq(held - IERC20(t).balanceOf(u), sellAmt, "sold exactly amountIn");
        _assertRouterClean(t, q);
        vm.revertToState(snap);
        _expectTooLittle(out);
        router.poolSell(t, q, sellAmt, out + 1, dl);
        router.poolSell(t, q, sellAmt, out, dl);
        _assertRouterClean(t, q);

        // sell to BNB
        snap = vm.snapshotState();
        uint256 bnb = u.balance;
        out = router.poolSellForBNB(t, q, sellAmt, 1, dl);
        assertGt(out, 0, "sell for BNB");
        assertEq(u.balance - bnb, out, "BNB to the user");
        _assertRouterClean(t, q);
        vm.revertToState(snap);
        _expectTooLittle(out);
        router.poolSellForBNB(t, q, sellAmt, out + 1, dl);
        router.poolSellForBNB(t, q, sellAmt, out, dl);
        _assertRouterClean(t, q);

        // refused inputs
        vm.expectRevert(GangRouter.ZeroAmount.selector);
        router.poolBuyBNB{value: 0}(t, q, 0, dl);
        vm.expectRevert(GangRouter.ZeroAmount.selector);
        router.poolBuy(t, q, 0, 0, dl);
        vm.expectRevert(GangRouter.ZeroAmount.selector);
        router.poolSell(t, q, 0, 0, dl);
        vm.expectRevert(GangRouter.ZeroAmount.selector);
        router.poolSellForBNB(t, q, 0, 0, dl);
        vm.expectRevert(GangRouter.Expired.selector);
        router.poolBuyBNB{value: perBnb}(t, q, 0, dl - 1);
        vm.expectRevert(GangRouter.Expired.selector);
        router.poolBuy(t, q, 1, 0, dl - 1);
        vm.expectRevert(GangRouter.Expired.selector);
        router.poolSell(t, q, 1, 0, dl - 1);
        vm.expectRevert(GangRouter.Expired.selector);
        router.poolSellForBNB(t, q, 1, 0, dl - 1);
        vm.stopPrank();
        _assertRouterClean(t, q);
        assertEq(vault.shares(t, address(router)), 0, "router never has a share");
    }

    // ---------------------------------------------------------------- the four kinds
    function test_fork_pool_v3Wbnb() public forkOnly {
        address t = _v3(WBNB, 1 ether);
        _exercise(t, WBNB, 0.05 ether, 0.1 ether);
    }

    function test_fork_pool_v3Usdt() public forkOnly {
        address t = _v3(USDT, 100 ether);
        // BNB in: [WBNB, USDT, token]; BNB out: [token, USDT, WBNB]
        _exercise(t, USDT, 0.05 ether, 50 ether);
    }

    function test_fork_pool_fair() public forkOnly {
        address t = _fair();
        _exercise(t, WBNB, 0.05 ether, 0.1 ether);
    }

    function test_fork_pool_liveV2Token() public forkOnly {
        (address t, address q) = (LIVE_V2_TOKEN, LIVE_V2_QUOTE);
        assertEq(IFactoryLite(V2_FACTORY).getPair(t, q), 0x43ab18b3BEF4e3E5b24FEC5Ea382bb7A7Aa170Cc, "live V2 pair");
        _exercise(t, q, 0.02 ether, 1_000 ether);
        assertEq(SharedDividendVault(LIVE_V2_VAULT).shares(t, address(router)), 0, "no V2 vault share for the router");
    }

    // ---------------------------------------------------------------- dividends and tax: router sell = direct sell
    struct Book {
        uint256 userQuote;
        uint256 userShare;
        uint256 userUnits;
        uint256 otherUnits;
        uint256 total;
        uint256 unsold;
        uint256 accrued;
        uint256 platform;
        uint256 treasuryQuote;
        uint256 routerShare;
        uint256 routerUnits;
        uint256 routerPending;
    }

    function _book(address t, address q, address u, address other) internal view returns (Book memory b) {
        b.userQuote = IERC20(q).balanceOf(u);
        b.userShare = vault.shares(t, u);
        b.userUnits = vault.pendingUnits(t, u);
        b.otherUnits = vault.pendingUnits(t, other);
        b.total = vault.totalShares(t);
        b.unsold = vault.unsoldUnits(t);
        b.accrued = handler.accruedTax(t);
        b.platform = handler.accruedPlatformTax(t);
        b.treasuryQuote = IERC20(q).balanceOf(treasury);
        b.routerShare = vault.shares(t, address(router));
        b.routerUnits = vault.pendingUnits(t, address(router));
        b.routerPending = vault.pending(t, address(router));
    }

    function _assertSame(Book memory a, Book memory b) internal pure {
        assertEq(a.userQuote, b.userQuote, "user quote out");
        assertEq(a.userShare, b.userShare, "user share");
        assertEq(a.userUnits, b.userUnits, "user units");
        assertEq(a.otherUnits, b.otherUnits, "other holder units");
        assertEq(a.total, b.total, "total shares");
        assertEq(a.unsold, b.unsold, "unsold units");
        assertEq(a.accrued, b.accrued, "accrued tax");
        assertEq(a.platform, b.platform, "platform tax");
        assertEq(a.treasuryQuote, b.treasuryQuote, "treasury");
    }

    function _directSell(address u, address t, address q, uint256 amount) internal returns (uint256 gasUsed) {
        address[] memory path = new address[](2);
        (path[0], path[1]) = (t, q);
        vm.startPrank(u);
        IERC20(t).approve(V2_ROUTER, amount);
        uint256 g = gasleft();
        IPancakeRouter02(V2_ROUTER)
            .swapExactTokensForTokensSupportingFeeOnTransferTokens(amount, 0, path, u, vm.getBlockTimestamp());
        gasUsed = g - gasleft();
        vm.stopPrank();
    }

    function _routerSell(address u, address t, address q, uint256 amount) internal returns (uint256 gasUsed) {
        vm.startPrank(u);
        IERC20(t).approve(address(router), amount);
        uint256 g = gasleft();
        router.poolSell(t, q, amount, 1, vm.getBlockTimestamp());
        gasUsed = g - gasleft();
        vm.stopPrank();
    }

    /// @dev Pool buys pile up tax past one swap-back chunk; `u` and `other` hold shares.
    function _backlog(address t, address q, uint256 n, uint256 each) internal returns (address u, address other) {
        u = _fresh();
        other = _fresh();
        address[2] memory holders = [u, other];
        for (uint256 i; i < 2; i++) {
            vm.deal(holders[i], 1 ether);
            vm.prank(holders[i]);
            router.poolBuyBNB{value: 0.5 ether}(t, q, 1, vm.getBlockTimestamp());
        }
        for (uint256 i = 0; i < n; i++) {
            address b = _fresh();
            vm.deal(b, each);
            vm.prank(b);
            router.poolBuyBNB{value: each}(t, q, 1, vm.getBlockTimestamp());
        }
        vm.roll(block.number + 1); // a fresh swap-back budget
    }

    function _equivalence(address t, address q) internal returns (uint256 gasUsed) {
        (address u, address other) = _backlog(t, q, 8, 2 ether);
        uint256 amount = IERC20(t).balanceOf(u) / 2;
        (, uint256 chunk) = handler.previewSell(t, amount);
        assertGt(chunk, 0, "this sell carries a swap-back chunk");
        assertGt(vault.shares(t, u), 0, "user holds a share");

        uint256 snap = vm.snapshotState();
        uint256 gasDirect = _directSell(u, t, q, amount);
        Book memory direct = _book(t, q, u, other);
        vm.revertToState(snap);
        gasUsed = _routerSell(u, t, q, amount);
        console.log("gas: the same sell straight on Pancake (no router)", gasDirect);
        Book memory routed = _book(t, q, u, other);

        _assertSame(direct, routed);
        assertEq(routed.routerShare, 0, "router share 0");
        assertEq(routed.routerUnits, 0, "router has no dividend units");
        assertEq(routed.routerPending, 0, "router has nothing to claim");
        _assertRouterClean(t, q);
    }

    function test_fork_pool_v3_routerSellBooksLikeDirect_gas() public forkOnly {
        address t = _v3(WBNB, 1 ether);
        uint256 g = _equivalence(t, WBNB);
        console.log("gas: router poolSell of a V3 tax token with a swap-back chunk", g);
    }

    /// Same sell with the router excluded in the dividend vault (DeployGang wires this): no share is ever written for
    /// it, so the pass-through costs less; the books still match a direct sell.
    function test_fork_pool_v3_routerExcluded_gas() public forkOnly {
        vm.prank(owner);
        vault.setExcluded(address(router), true);
        address t = _v3(WBNB, 1 ether);
        uint256 g = _equivalence(t, WBNB);
        console.log("gas: router poolSell with a swap-back chunk, router excluded in the vault", g);
    }

    function test_fork_pool_v3Usdt_routerSellBooksLikeDirect() public forkOnly {
        address t = _v3(USDT, 100 ether);
        uint256 g = _equivalence(t, USDT);
        console.log("gas: router poolSell of a V3 USDT tax token with a swap-back chunk", g);
    }

    function test_fork_pool_fair_routerSellBooksLikeDirect() public forkOnly {
        address t = _fair();
        // a minter's own sell (it holds a baseline): its reward share and hold line move exactly as when direct
        address m = address(0);
        for (uint256 i = 0; i < nonce && m == address(0); i++) {
            address c = address(uint160(uint256(keccak256(abi.encode("pool-fork", i)))));
            if (vault.shares(t, c) > 0) m = c;
        }
        assertTrue(m != address(0), "a minter with a share");
        (address u, address other) = _backlog(t, WBNB, 8, 2 ether);
        u; // pool buyers have no baseline in 打新: the minter sells
        uint256 amount = IERC20(t).balanceOf(m) / 10; // stays above the hold line
        uint256 snap = vm.snapshotState();
        _directSell(m, t, WBNB, amount);
        Book memory direct = _book(t, WBNB, m, other);
        bool outDirect = handler.isOut(t, m);
        vm.revertToState(snap);
        uint256 g = _routerSell(m, t, WBNB, amount);
        Book memory routed = _book(t, WBNB, m, other);
        _assertSame(direct, routed);
        assertEq(handler.isOut(t, m), outDirect, "hold line the same");
        assertEq(routed.routerShare + routed.routerUnits + routed.routerPending, 0, "router earns nothing");
        _assertRouterClean(t, WBNB);
        console.log("gas: router poolSell of a fair-mint token", g);
    }

    /// @dev The swap-back chunk's gas cap must be reachable through the router's extra frames: a router sell with a
    ///      chunk runs the chunk (accrued drops by it), it is not swallowed as out-of-gas.
    function test_fork_pool_v3_chunkRunsThroughRouter() public forkOnly {
        address t = _v3(WBNB, 1 ether);
        (address u,) = _backlog(t, WBNB, 8, 2 ether);
        uint256 amount = IERC20(t).balanceOf(u) / 2;
        (uint256 quoted, uint256 chunk) = handler.previewSell(t, amount);
        uint256 accrued = handler.accruedTax(t);
        vm.startPrank(u);
        IERC20(t).approve(address(router), amount);
        uint256 out = router.poolSell(t, WBNB, amount, quoted, vm.getBlockTimestamp());
        vm.stopPrank();
        assertEq(out, quoted, "previewSell is exact through the router");
        assertEq(handler.accruedTax(t), accrued - chunk + (amount * TAX) / 10_000, "chunk sold");
    }

    // ---------------------------------------------------------------- upgrade keeps the pool entries
    function test_fork_pool_afterUpgrade() public forkOnly {
        address t = _v3(WBNB, 1 ether);
        GangRouterV2Mock v2 = new GangRouterV2Mock();
        bytes memory call = abi.encodeCall(
            ProxyAdmin.upgradeAndCall,
            (
                ITransparentUpgradeableProxy(address(router)),
                address(v2),
                abi.encodeCall(GangRouterV2Mock.initializeV2, (1))
            )
        );
        TimelockController tl = TimelockController(payable(rs.timelock));
        vm.prank(SAFE);
        tl.schedule(rs.proxyAdmin, 0, call, bytes32(0), bytes32(0), 48 hours);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.prank(SAFE);
        tl.execute(rs.proxyAdmin, 0, call, bytes32(0), bytes32(0));
        assertEq(address(router.pancakeRouter()), V2_ROUTER, "pancakeRouter kept");
        assertEq(GangRouterV2Mock(payable(address(router))).version(), 2);
        _exercise(t, WBNB, 0.05 ether, 0.1 ether);
    }
}
