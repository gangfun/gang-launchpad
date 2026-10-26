// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {V2TaxChunkSeller} from "../../src/remedy/V2TaxChunkSeller.sol";
import {MerkleQuoteDistributor} from "../../src/remedy/MerkleQuoteDistributor.sol";

interface IHandler {
    function accruedTax(address token) external view returns (uint256);
    function process(address token, uint256 minQuoteOut) external returns (uint256);
    function setRouter(address router) external;
    function router() external view returns (address);
    function dividendVault() external view returns (address);
    function platformBucket() external view returns (address);
}

interface IVault {
    function setExcluded(address account, bool isExc) external;
    function shares(address token, address user) external view returns (uint256);
    function totalShares(address token) external view returns (uint256);
    function accRewardPerShare(address token) external view returns (uint256);
}

interface IBucket {
    function setOperator(address account, bool enabled) external;
    function accruedQuote(address quote) external view returns (uint256);
}

interface IPair {
    function token0() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
}

interface IRouter {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

/// @notice Mainnet fork rehearsal of the V2 backlog remedy (BSC_RPC_URL; nothing is broadcast).
///         Owner steps are pranked as the handlers' owner multisig, keeper steps as the live keeper.
contract V2TaxRemedyForkTest is Test {
    address constant MULTISIG = 0x4EEdcDF5fab775e10C0D09951b6F59Ab81ba19d3;
    address constant KEEPER = 0xB6f1F1BFb92476Abb0998B425dE0deC5F927cFc7;
    address constant PANCAKE_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;

    address constant H1 = 0xa2bd8e511Cf01aA8F9693a841FD6ee6E30253e29; // LaunchpadV2 0x1B8F…966E
    address constant H2 = 0xfC12DC54BA3B77cf9d089A95C12542C880D5ca2D; // older stocks pad 0xF81C…12cb
    address constant ANT = 0x5e9305a3d099b44bB7C50E2EEdb6EcF5bd322435; // 蚂蚁 / oANTHROPIC
    address constant FISH = 0xD421E4368Ac7d3878D589bb60ec22Dd54002feE8; // 大肥鱼 / FXIon
    address constant GSTOCK = 0x97ACca21FcF2435f1a0bFA94f9c27D412B88c1C8; // GStock / NVDAB
    address constant Q_ANT = 0x24B518b332543a4E1C3649d063daB199d103760a;
    address constant Q_FISH = 0x9b8E987e6fEc8Cf1380C4dcA7071e2C7853AEEA1;
    address constant Q_GSTOCK = 0x02Fca66C1D1aFB4E2A7884261eB00F63598a7436;
    address constant P_ANT = 0x3Db33Fc5cd00991abA972A2500D5eDF0ed50d283;
    address constant P_FISH = 0xfA87832F7dF6753dDC2d5f4c9C51A38cCfbc54D8;
    address constant P_GSTOCK = 0xB81b2F7bdE300c97f427014960eB34a3A5614504;

    MerkleQuoteDistributor dist;
    V2TaxChunkSeller s1;
    V2TaxChunkSeller s2;
    bool forked;

    struct Run {
        uint256 adopted;
        uint256 chunks;
        uint256 quoteOut;
        uint256 maxImpact;
        uint256 priceDropBps;
        uint256 oneShotOut;
    }

    function setUp() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;
        dist = new MerkleQuoteDistributor(MULTISIG);
        s1 = new V2TaxChunkSeller(MULTISIG, H1, PANCAKE_ROUTER, address(dist));
        s2 = new V2TaxChunkSeller(MULTISIG, H2, PANCAKE_ROUTER, address(dist));
    }

    modifier forkOnly() {
        if (!forked) return;
        _;
    }

    // ---------------------------------------------------------------- owner wiring (multisig)
    function _wire(V2TaxChunkSeller s, address handler, address[] memory tokens) internal {
        IVault vault = IVault(IHandler(handler).dividendVault());
        IBucket bucket = IBucket(IHandler(handler).platformBucket());
        vm.startPrank(MULTISIG);
        vault.setExcluded(address(s), true);
        bucket.setOperator(address(s), true);
        dist.setFunder(address(s), true);
        s.setKeeper(KEEPER);
        for (uint256 i; i < tokens.length; i++) s.arm(tokens[i], true);
        IHandler(handler).setRouter(address(s));
        vm.stopPrank();
    }

    /// @dev The seed: sell 1 token on Pancake for a few wei of quote, straight to the seller (what ops does by hand).
    function _seed(V2TaxChunkSeller s, address token, address quote) internal {
        address u = makeAddr("seeder");
        deal(token, u, 1 ether);
        vm.startPrank(u);
        IERC20(token).approve(PANCAKE_ROUTER, 1 ether);
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = quote;
        IRouter(PANCAKE_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            1 ether, 1, path, address(s), block.timestamp
        );
        vm.stopPrank();
        assertGt(IERC20(quote).balanceOf(address(s)), 0, "seed arrived");
    }

    function _spot(address token, address pair) internal view returns (uint256) {
        (uint112 r0, uint112 r1,) = IPair(pair).getReserves();
        return IPair(pair).token0() == token ? (uint256(r1) * 1e18) / r0 : (uint256(r0) * 1e18) / r1;
    }

    function _oneShot(address token, address pair, uint256 amount) internal view returns (uint256) {
        (uint112 r0, uint112 r1,) = IPair(pair).getReserves();
        (uint256 rIn, uint256 rOut) = IPair(pair).token0() == token ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 inFee = amount * 9975;
        return (inFee * rOut) / (rIn * 10_000 + inFee);
    }

    /// @dev Adopt one token's backlog and sell it all in ≤ maxImpact chunks (no buyers in between: worst case).
    function _run(V2TaxChunkSeller s, address handler, address token, address quote, address pair)
        internal
        returns (Run memory r)
    {
        IVault vault = IVault(IHandler(handler).dividendVault());
        IBucket bucket = IBucket(IHandler(handler).platformBucket());
        _seed(s, token, quote); // a taxed 1-token sale: its 0.01 tax joins the backlog
        uint256 backlog = IHandler(handler).accruedTax(token);
        assertGt(backlog, 0, "has backlog");
        assertEq(IERC20(token).balanceOf(handler), backlog, "handler holds exactly the backlog");
        r.oneShotOut = _oneShot(token, pair, backlog);
        uint256 spot0 = _spot(token, pair);
        uint256 bucketBefore = bucket.accruedQuote(quote);
        uint256 accBefore = vault.accRewardPerShare(token);

        vm.prank(KEEPER);
        IHandler(handler).process(token, 1); // adoption
        r.adopted = s.leftOf(token);
        assertEq(r.adopted, backlog, "whole backlog adopted");
        assertEq(IHandler(handler).accruedTax(token), 0);
        assertEq(IERC20(token).balanceOf(handler), 0, "handler emptied");
        assertEq(vault.shares(token, address(s)), 0, "seller earns no dividend share");
        assertEq(bucket.accruedQuote(quote), bucketBefore + 1, "handler's split this time: 1 wei to the platform");
        assertEq(vault.accRewardPerShare(token), accBefore, "and nothing to holders");

        uint256 distBefore = IERC20(quote).balanceOf(address(dist));
        while (s.leftOf(token) > 0) {
            uint256 amt = s.maxChunk(token);
            uint256 imp = s.impactBpsOf(token, amt);
            if (imp > r.maxImpact) r.maxImpact = imp;
            uint256 exp = s.quoteChunk(token, amt);
            vm.prank(KEEPER);
            r.quoteOut += s.sellChunk(token, amt, (exp * 995) / 1000);
            r.chunks++;
            require(r.chunks < 500, "too many chunks");
        }
        r.priceDropBps = 10_000 - (_spot(token, pair) * 10_000) / spot0;

        (,,, uint256 qo, uint256 toH, uint256 toP,,) = s.backlogOf(token);
        assertEq(qo, r.quoteOut, "quote out booked");
        assertEq(toH + toP, qo, "split conserves");
        assertEq(IERC20(quote).balanceOf(address(dist)) - distBefore, toH, "holders' half at the distributor");
        assertEq(IERC20(token).balanceOf(address(s)), 0, "all tokens sold");
        assertLe(r.maxImpact, 100, "each chunk within 1%");
        // the 1% token tax each chunk paid came back to the handler as ordinary new tax
        assertApproxEqRel(IHandler(handler).accruedTax(token), backlog / 100, 0.01e18, "1% re-accrued");
    }

    function test_fork_remedy_allThree() public forkOnly {
        address[] memory t1 = new address[](2);
        t1[0] = ANT;
        t1[1] = FISH;
        address[] memory t2 = new address[](1);
        t2[0] = GSTOCK;
        _wire(s1, H1, t1);
        _wire(s2, H2, t2);

        Run memory a = _run(s1, H1, ANT, Q_ANT, P_ANT);
        Run memory f = _run(s1, H1, FISH, Q_FISH, P_FISH);
        Run memory g = _run(s2, H2, GSTOCK, Q_GSTOCK, P_GSTOCK);
        _log(unicode"蚂蚁", a);
        _log(unicode"大肥鱼", f);
        _log("GStock", g);

        // after: the new 1% (and any future tax) goes through the handler as before, via the passthrough
        _processNormally(H1, ANT, P_ANT);
        _processNormally(H2, GSTOCK, P_GSTOCK);
        // the same holds for normal trading on top
        _trade(H1, FISH, Q_FISH, P_FISH);
    }

    /// @dev Keeper processes the re-accrued tax: passthrough into the pair, handler splits 50/50 as before.
    function _processNormally(address handler, address token, address pair) internal {
        uint256 acc = IHandler(handler).accruedTax(token);
        IVault vault = IVault(IHandler(handler).dividendVault());
        uint256 accBefore = vault.accRewardPerShare(token);
        uint256 exp = _oneShot(token, pair, acc);
        vm.prank(KEEPER);
        uint256 out = IHandler(handler).process(token, (exp * 99) / 100);
        assertApproxEqRel(out, exp, 0.001e18, "passthrough pays the pair price");
        assertEq(IHandler(handler).accruedTax(token), 0);
        assertGt(vault.accRewardPerShare(token), accBefore, "holders got their half, as before");
        assertEq(IERC20(token).balanceOf(handler), 0);
    }

    /// @dev A holder buys and sells after the remedy: taxed as before, the keeper processes it normally.
    function _trade(address handler, address token, address quote, address pair) internal {
        address u = makeAddr("trader");
        deal(token, u, 1_000_000 ether);
        vm.startPrank(u);
        IERC20(token).approve(PANCAKE_ROUTER, type(uint256).max);
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = quote;
        uint256 before = IHandler(handler).accruedTax(token);
        IRouter(PANCAKE_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            1_000_000 ether, 1, path, u, block.timestamp
        );
        vm.stopPrank();
        assertEq(IHandler(handler).accruedTax(token) - before, 10_000 ether, "1% tax accrued as usual");
        _processNormally(handler, token, pair);
    }

    function _log(string memory name, Run memory r) internal pure {
        console2.log(name);
        console2.log("  adopted tokens (1e18)", r.adopted / 1e18);
        console2.log("  chunks", r.chunks);
        console2.log("  max impact per chunk (bps)", r.maxImpact);
        console2.log("  quote out (1e-6)", r.quoteOut / 1e12);
        console2.log("  one-shot quote out (1e-6)", r.oneShotOut / 1e12);
        console2.log("  price drop if nobody buys in between (bps)", r.priceDropBps);
    }

    // ---------------------------------------------------------------- guards
    function test_fork_guards() public forkOnly {
        // not excluded in the vault yet → adoption refuses
        IVault vault1 = IVault(IHandler(H1).dividendVault());
        vm.startPrank(MULTISIG);
        s1.setKeeper(KEEPER);
        s1.arm(ANT, true);
        IHandler(H1).setRouter(address(s1));
        vm.stopPrank();
        _seed(s1, ANT, Q_ANT);
        vm.prank(KEEPER);
        vm.expectRevert(V2TaxChunkSeller.NotExcludedInVault.selector);
        IHandler(H1).process(ANT, 1);

        vm.prank(MULTISIG);
        vault1.setExcluded(address(s1), true);
        // adoption only with minOut = 1 (an ordinary keeper quote can't adopt by accident)
        vm.prank(KEEPER);
        vm.expectRevert(V2TaxChunkSeller.SeedMinOut.selector);
        IHandler(H1).process(ANT, 1000);

        // strangers can't drive the seller or call it as the handler
        address[] memory path = new address[](2);
        path[0] = ANT;
        path[1] = Q_ANT;
        vm.expectRevert(V2TaxChunkSeller.OnlyHandler.selector);
        s1.swapExactTokensForTokensSupportingFeeOnTransferTokens(1, 1, path, H1, block.timestamp);
        vm.expectRevert(V2TaxChunkSeller.OnlyKeeperOrOwner.selector);
        s1.sellChunk(ANT, 1, 1);
        // a token of another handler can't be armed here
        vm.prank(MULTISIG);
        vm.expectRevert(V2TaxChunkSeller.NotHandlersToken.selector);
        s1.arm(GSTOCK, true);

        // adopt, then a chunk above the impact cap is refused
        vm.prank(KEEPER);
        IHandler(H1).process(ANT, 1);
        uint256 big = s1.maxChunk(ANT) * 3;
        uint256 imp = s1.impactBpsOf(ANT, big);
        vm.prank(KEEPER);
        vm.expectRevert(abi.encodeWithSelector(V2TaxChunkSeller.ImpactTooHigh.selector, imp));
        s1.sellChunk(ANT, big, 1);
        // floor: a chunk that would leave the pool below the owner's floor is refused
        uint256 spot = s1.spotOf(ANT);
        vm.prank(MULTISIG);
        s1.setFloor(ANT, spot);
        uint256 amt = s1.maxChunk(ANT);
        uint256 exp = s1.quoteChunk(ANT, amt);
        vm.prank(KEEPER);
        vm.expectRevert(); // BelowFloor(priceAfter, spot)
        s1.sellChunk(ANT, amt, (exp * 995) / 1000);
        // the distributor must exist and the seller must be its funder for a chunk to go through
        vm.startPrank(MULTISIG);
        s1.setFloor(ANT, 0);
        IBucket(IHandler(H1).platformBucket()).setOperator(address(s1), true);
        dist.setFunder(address(s1), true);
        vm.stopPrank();
        vm.prank(KEEPER);
        s1.sellChunk(ANT, amt, (exp * 995) / 1000);
        // rescue: the multisig can always take the backlog out
        uint256 left = s1.leftOf(ANT);
        uint256 msBefore = IERC20(ANT).balanceOf(MULTISIG);
        vm.prank(MULTISIG);
        s1.rescue(ANT, MULTISIG, left);
        assertEq(IERC20(ANT).balanceOf(MULTISIG) - msBefore, left);
    }
}
