// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {QuoteRegistry} from "../../src/launchpad-v2/QuoteRegistry.sol";
import {SharedDividendVault} from "../../src/common/SharedDividendVault.sol";
import {PlatformFeeBucket} from "../../src/launchpad-v2/PlatformFeeBucket.sol";
import {SharedMigrator} from "../../src/common/SharedMigrator.sol";
import {TokenDeployer} from "../../src/common/TokenDeployer.sol";
import {IV3FactoryLite, IV3PoolLite} from "../../src/launchpad-v2/PoolCheck.sol";
import {IPancakeRouter02} from "../../src/launchpad-v2/interfaces/IPancake.sol";
import {FairMintPad} from "../../src/fair-mint/FairMintPad.sol";
import {FairToken} from "../../src/fair-mint/FairToken.sol";
import {HolderRewardHandler} from "../../src/fair-mint/HolderRewardHandler.sol";

contract ForkAgent {
    mapping(address => uint256) public balanceOf;

    function set(address a, uint256 b) external {
        balanceOf[a] = b;
    }
}

interface IPancakeFactoryLite {
    function getPair(address a, address b) external view returns (address);
    function createPair(address a, address b) external returns (address);
}

interface IPancakePairFull {
    function getReserves() external view returns (uint112, uint112, uint32);
    function token0() external view returns (address);
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function sync() external;
}

/// @notice BSC mainnet fork: FairMintPad against the real Pancake V2 factory / router, WBNB and USDT.
///         Skipped unless BSC_RPC_URL is set (same convention as V2E2E). Does not broadcast.
contract FairMintForkTest is Test {
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    /// @dev Pancake V3 USDT/WBNB 0.01%, the deepest pool: the refPool a USDT-quoted create uses (no fixed rate on mainnet)
    address constant USDT_REF_POOL = 0x172fcD41E0913e95784454622d1c3724f546f849;
    address constant V2_FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address constant V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    address constant V2_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 constant Q96 = 2 ** 96;
    uint256 constant TPS = 50_000 ether;

    address owner = makeAddr("owner");
    address feeVault = makeAddr("feeVault");
    address keeper = makeAddr("keeper");
    address dev = makeAddr("dev");
    address buyer = makeAddr("buyer");

    QuoteRegistry reg;
    SharedDividendVault vault;
    PlatformFeeBucket bucket;
    HolderRewardHandler handler;
    FairMintPad pad;
    SharedMigrator mig;
    ForkAgent agent;
    address bridge;

    modifier forkOnly() {
        if (address(pad) == address(0)) return;
        _;
    }

    function setUp() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);

        vm.startPrank(owner);
        reg = new QuoteRegistry(owner);
        vault = new SharedDividendVault(owner);
        TokenDeployer deployer = new TokenDeployer(owner);
        bucket = new PlatformFeeBucket(owner, feeVault);
        handler = new HolderRewardHandler(owner, address(vault), address(bucket));
        agent = new ForkAgent();
        pad = new FairMintPad(
            owner,
            address(reg),
            address(vault),
            address(bucket),
            address(handler),
            address(deployer),
            WBNB,
            V2_FACTORY
        );
        mig = new SharedMigrator(owner, V2_FACTORY);

        vault.setLaunchpad(address(pad), true);
        vault.setMinimumShareBalance(address(pad), 10_000 ether);
        vault.setOperator(address(handler), address(pad));
        mig.addLaunchpad(address(pad));
        deployer.setLaunchpad(address(pad), true);
        bucket.setOperator(address(pad), true);
        bucket.setOperator(address(handler), true);
        handler.setPad(address(pad));
        handler.setDexRouter(V2_ROUTER);
        handler.setKeeper(keeper);
        pad.setMigrator(address(mig));
        pad.setAgentGate(true, address(agent));
        pad.setV3Factory(V3_FACTORY);
        bridge = IV3FactoryLite(V3_FACTORY).getPool(WBNB, USDT, 500);
        require(bridge != address(0), "no USDT/WBNB 0.05% pool");
        pad.setBridgePool(USDT, bridge);
        vm.stopPrank();

        agent.set(dev, 1);
    }

    // ---------------------------------------------------------------- helpers
    function _cfg() internal pure returns (FairMintPad.MintConfig memory) {
        return FairMintPad.MintConfig({raiseBnb: 15 ether, capBps: 50, holdBps: 5000, mintFeeBps: 100, exitFeeBps: 100});
    }

    function _minter(uint256 i) internal pure returns (address) {
        return address(uint160(0xFA1200000 + i));
    }

    function _prep(address who, address quote, uint256 amount) internal {
        agent.set(who, 1);
        deal(quote, who, amount);
        vm.prank(who);
        IERC20(quote).approve(address(pad), type(uint256).max);
    }

    function _create(address quote, address refPool) internal returns (address token) {
        (, uint256 price) = pad.previewCreate(quote, refPool, 15 ether);
        _prep(dev, quote, price * 2);
        vm.prank(dev);
        token = pad.create("Fair Fork", "FFORK", "", "", quote, refPool, _cfg(), 1);
    }

    /// @return lastMintGas gas of the mint that fills the sale (includes createPair + addLiquidity)
    function _fill(address token, address quote) internal returns (uint256 lastMintGas) {
        (,,,,,,,,,, uint128 price,,,) = pad.sales(token);
        uint256 need = (uint256(price) * 100 * 101) / 100;
        for (uint256 i = 0; i < 100; i++) {
            address m = _minter(i);
            _prep(m, quote, need);
            vm.prank(m);
            uint256 g = gasleft();
            pad.mint(token, 100, 1);
            if (i == 99) lastMintGas = g - gasleft();
        }
    }

    function _swap(address who, address tokenIn, address tokenOut, uint256 amountIn) internal returns (uint256 got) {
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
        vm.startPrank(who);
        IERC20(tokenIn).approve(V2_ROUTER, amountIn);
        uint256 before = IERC20(tokenOut).balanceOf(who);
        IPancakeRouter02(V2_ROUTER)
            .swapExactTokensForTokensSupportingFeeOnTransferTokens(amountIn, 0, path, who, block.timestamp);
        got = IERC20(tokenOut).balanceOf(who) - before;
        vm.stopPrank();
    }

    function _reserves(address token, address pair) internal view returns (uint256 rT, uint256 rQ) {
        (uint112 r0, uint112 r1,) = IPancakePairFull(pair).getReserves();
        (rT, rQ) = IPancakePairFull(pair).token0() == token ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }

    function _usdtPerBnbQ96(address pool) internal view returns (uint256) {
        (uint160 sqrtP,,,,,,) = IV3PoolLite(pool).slot0();
        uint256 p1per0 = Math.mulDiv(sqrtP, sqrtP, Q96);
        return IV3PoolLite(pool).token0() == WBNB ? p1per0 : Math.mulDiv(Q96, Q96, p1per0);
    }

    function _process(address token, address quote) internal returns (uint256 quoteOut) {
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = quote;
        uint256 chunk = handler.maxChunk(token);
        uint256 quoted = IPancakeRouter02(V2_ROUTER).getAmountsOut(chunk, path)[1];
        vm.prank(keeper);
        quoteOut = handler.process(token, chunk, (quoted * 99) / 100);
    }

    // ---------------------------------------------------------------- WBNB: create → fill → launch → trade → split
    function test_fork_wbnb_fullFlow() public forkOnly {
        address t = _create(WBNB, address(0));
        uint256 lastGas = _fill(t, WBNB);
        console.log("gas: filling mint incl. Pancake createPair + mint", lastGas);

        address pair = FairToken(t).pair();
        assertEq(pair, IPancakeFactoryLite(V2_FACTORY).getPair(t, WBNB), "real Pancake pair");
        (uint256 rT, uint256 rQ) = _reserves(t, pair);
        assertEq(rT, 500_000_000 ether);
        assertEq(rQ, 15 ether);
        assertEq(IPancakePairFull(pair).balanceOf(DEAD) + 1000, IPancakePairFull(pair).totalSupply(), "LP burned");
        assertEq(bucket.accruedQuote(WBNB), 0.15 ether, "1% of the raise");

        // post-launch buyer: taxed 1%, never earns
        deal(WBNB, buyer, 2 ether);
        uint256 bought = _swap(buyer, WBNB, t, 2 ether);
        assertGt(bought, 0);
        assertEq(vault.shares(t, buyer), 0);
        uint256 taxFromBuy = handler.accruedTax(t);
        assertApproxEqRel(taxFromBuy * 99, bought, 0.001e18, "buy taxed 1%");

        // minter sells 30%: share follows balance
        address m = _minter(0);
        uint256 g = gasleft();
        _swap(m, t, WBNB, 30 * TPS);
        console.log("gas: router sell by a minter (tax + reward sync)", g - gasleft());
        assertEq(vault.shares(t, m), 70 * TPS);

        // minter sells below the line: out for good
        _swap(m, t, WBNB, 25 * TPS);
        assertTrue(handler.isOut(t, m));
        assertEq(vault.shares(t, m), 0);

        uint256 vaultBefore = IERC20(WBNB).balanceOf(address(vault));
        uint256 bucketBefore = bucket.accruedQuote(WBNB);
        uint256 out = _process(t, WBNB);
        assertGt(out, 0);
        uint256 toHolders = IERC20(WBNB).balanceOf(address(vault)) - vaultBefore;
        assertApproxEqAbs(toHolders, out / 2, 1, "holders' half (their units of the chunk, rounded up)");
        assertEq(bucket.accruedQuote(WBNB) - bucketBefore, out - toHolders);

        address m5 = _minter(5);
        uint256 pend = vault.pending(t, m5);
        assertGt(pend, 0);
        vm.prank(m5);
        vault.claim(t);
        assertEq(IERC20(WBNB).balanceOf(m5), pend);
        // m held when the buy and its own first sell were taxed: those halves are m's even though it is out now
        assertGt(vault.pending(t, m), 0, "credited at tax time, kept after going out");
    }

    // ---------------------------------------------------------------- sell-time swap-back on a real Pancake pair
    /// @dev Buys pile tax past one chunk; a router sell first sells one chunk (≤ 0.5% of the token side, ~1% price
    ///      move) and still goes through with a normal slippage setting; the keeper drains the rest chunk by chunk.
    function test_fork_swapBack_realPancake() public forkOnly {
        address t = _create(WBNB, address(0));
        _fill(t, WBNB);
        address pair = FairToken(t).pair();
        for (uint256 i = 0; i < 12; i++) {
            address b = address(uint160(0xB0B000 + i));
            deal(WBNB, b, 3 ether);
            _swap(b, WBNB, t, 3 ether);
        }
        uint256 accrued = handler.accruedTax(t);
        (uint256 rT0,) = _reserves(t, pair);
        uint256 cap = (rT0 * 50) / 10_000;
        assertGt(accrued, cap, "backlog past one chunk");

        // a seller quoting with previewSell (chunk included) fills at that exact amount
        address m = _minter(10);
        uint256 amount = 50 * TPS;
        address[] memory path = new address[](2);
        path[0] = t;
        path[1] = WBNB;
        uint256 naive = IPancakeRouter02(V2_ROUTER).getAmountsOut(amount, path)[1];
        (uint256 quoted, uint256 chunk) = handler.previewSell(t, amount);
        assertEq(chunk, amount / 4 < cap ? amount / 4 : cap, "<= 25% of the sell, <= 0.5% of the token side");
        console.log("sell 50 shares: naive quote / previewSell (bps of naive)", naive, (quoted * 10_000) / naive);
        vm.startPrank(m);
        IERC20(t).approve(V2_ROUTER, amount);
        uint256 got0 = IERC20(WBNB).balanceOf(m);
        uint256 g = gasleft();
        IPancakeRouter02(V2_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amount, quoted, path, m, block.timestamp
        );
        uint256 gasWithChunk = g - gasleft();
        vm.stopPrank();
        assertEq(IERC20(WBNB).balanceOf(m) - got0, quoted, "previewSell is exact");
        assertEq(handler.accruedTax(t), accrued - chunk + amount / 100, "one chunk sold before the sell");

        // the keeper drains the rest, one chunk at a time
        uint256 rounds;
        while (handler.accruedTax(t) > 0 && rounds < 100) {
            assertLe(handler.maxChunk(t), cap * 2, "a chunk stays ~0.5% of the token side");
            _process(t, WBNB);
            rounds++;
        }
        assertEq(handler.accruedTax(t), 0, "drained");
        assertEq(vault.unsoldUnits(t), 0, "every holder unit sold");
        assertGt(vault.pending(t, _minter(5)), 0);

        // one chunk on its own: the price moves about 1%
        for (uint256 i = 0; i < 6; i++) {
            address b = address(uint160(0xB0C000 + i));
            deal(WBNB, b, 3 ether);
            _swap(b, WBNB, t, 3 ether);
        }
        (uint256 rTa, uint256 rQa) = _reserves(t, pair);
        vm.prank(t);
        handler.swapBack(t, type(uint128).max);
        (uint256 rTb, uint256 rQb) = _reserves(t, pair);
        assertLe(rTb - rTa, (rTa * 50) / 10_000, "<= 0.5% of the token side");
        assertGe(rQb * rTa * 1000, rQa * rTb * 989, "price moves <= ~1.1%");

        // a sell with nothing accrued: the same path without a chunk (gas baseline)
        while (handler.accruedTax(t) > 0) _process(t, WBNB);
        g = gasleft();
        _swap(_minter(11), t, WBNB, amount);
        uint256 gasNoChunk = g - gasleft();
        // the same holder again, a small chunk pending (warm storage: the usual case)
        deal(WBNB, buyer, 1 ether);
        _swap(buyer, WBNB, t, 1 ether);
        vm.roll(block.number + 1); // one swap-back per block
        g = gasleft();
        _swap(_minter(11), t, WBNB, amount);
        uint256 gasWarm = g - gasleft();
        console.log("gas: router sell with a swap-back chunk", gasWithChunk);
        console.log("gas: router sell, nothing accrued (first touch)", gasNoChunk);
        console.log("gas: router sell again, small chunk (warm)", gasWarm);
        console.log("keeper chunks to drain the backlog", rounds);
    }

    // ---------------------------------------------------------------- USDT quote via the USDT/WBNB V3 pool
    /// @dev No fixed rate on mainnet: USDT is priced from USDT_REF_POOL (30-min TWAP; counter WBNB, no bridge).
    function test_fork_usdt_raiseTracksBnbPrice() public forkOnly {
        (uint256 raiseQuote,) = pad.previewCreate(USDT, USDT_REF_POOL, 15 ether);
        uint256 spot = Math.mulDiv(15 ether, _usdtPerBnbQ96(USDT_REF_POOL), Q96);
        console.log("raise USDT (1e18)", raiseQuote / 1e18, "spot", spot / 1e18);
        assertApproxEqRel(raiseQuote, spot, 0.05e18, "TWAP within 5% of spot");
        (bool listed,) = reg.quotes(USDT);
        assertFalse(listed, "USDT has no fixed rate");

        address t = _create(USDT, USDT_REF_POOL);
        _fill(t, USDT);
        (,,,,,,,,,, uint128 price,,,) = pad.sales(t);
        (uint256 rT, uint256 rQ) = _reserves(t, FairToken(t).pair());
        assertEq(rT, 500_000_000 ether);
        assertEq(rQ, uint256(price) * 10_000);

        deal(USDT, buyer, 1_000 ether);
        _swap(buyer, USDT, t, 1_000 ether);
        uint256 out = _process(t, USDT);
        assertGt(out, 0);
        assertApproxEqAbs(IERC20(USDT).balanceOf(address(vault)), out / 2, 1);
    }

    /// @dev A fixed rate in QuoteRegistry still wins over the pool (scaled to the raise), refPool or not.
    function test_fork_usdt_fixedRateStillWins() public forkOnly {
        vm.prank(owner);
        reg.setQuote(USDT, true, 9_000 ether); // 15 BNB = 9,000 USDT, whatever the pool says
        (uint256 withPool,) = pad.previewCreate(USDT, USDT_REF_POOL, 15 ether);
        (uint256 noPool,) = pad.previewCreate(USDT, address(0), 30 ether);
        assertEq(withPool, 9_000 ether);
        assertEq(noPool, 18_000 ether);
    }

    // ---------------------------------------------------------------- pair created early + quote donated + sync()
    function test_fork_preCreatedPairWithSync() public forkOnly {
        address t = _create(WBNB, address(0));
        address early = IPancakeFactoryLite(V2_FACTORY).createPair(t, WBNB);
        deal(WBNB, address(this), 1 ether);
        IERC20(WBNB).transfer(early, 1 ether);
        IPancakePairFull(early).sync();

        _fill(t, WBNB);
        assertEq(FairToken(t).pair(), early);
        (uint256 rT, uint256 rQ) = _reserves(t, early);
        assertEq(rT, 500_000_000 ether);
        assertEq(rQ, 16 ether, "donation stays in the pool");
    }
}
