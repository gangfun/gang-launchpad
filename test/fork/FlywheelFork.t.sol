// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {QuoteRegistry} from "../../src/launchpad-v2/QuoteRegistry.sol";
import {SharedDividendVault} from "../../src/common/SharedDividendVault.sol";
import {SharedPlatformFeeBucket} from "../../src/common/SharedPlatformFeeBucket.sol";
import {SharedMigrator} from "../../src/common/SharedMigrator.sol";
import {MintTokenDeployer} from "../../src/flywheel/MintTokenDeployer.sol";
import {FlywheelTaxHandler} from "../../src/flywheel/FlywheelTaxHandler.sol";
import {GangFlywheelPad} from "../../src/flywheel/GangFlywheelPad.sol";
import {IFlywheelPad} from "../../src/flywheel/interfaces/IFlywheelPad.sol";
import {MockAgentId} from "../mocks/MockAgentId.sol";

interface IPancakeRouterFork {
    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable;
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IPairFork {
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function getReserves() external view returns (uint112, uint112, uint32);
    function token0() external view returns (address);
}

/// @notice The continuous-mint stack on a BSC mainnet fork against the real Pancake V2 factory, router and WBNB:
///         create, fill with BNB, launch, launch protection through the real router, post-launch mints (LP minted by
///         the real pair, dust falling back to `sync`), pool trades with the swap-back chunk, the keeper selling the
///         tax through the router, and the TWAP on the real pair's cumulative prices. A fresh Agent ID registry
///         stands in for the soulbound one. Skipped unless BSC_RPC_URL is set. Does not broadcast.
contract FlywheelForkTest is Test {
    address constant V2_FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address constant V2_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    MockAgentId agents;
    SharedDividendVault vault;
    SharedPlatformFeeBucket bucket;
    SharedMigrator migrator;
    MintTokenDeployer deployer;
    FlywheelTaxHandler handler;
    GangFlywheelPad pad;
    address owner = makeAddr("owner");
    address keeper = makeAddr("keeper");
    address dev;
    uint256 nonce;
    bool noFork;

    function setUp() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            noFork = true;
            return;
        }
        vm.createSelectFork(rpc);
        agents = new MockAgentId();
        QuoteRegistry registry = new QuoteRegistry(owner);
        bucket = new SharedPlatformFeeBucket(owner, makeAddr("feeVault"));
        vault = new SharedDividendVault(owner);
        migrator = new SharedMigrator(owner, V2_FACTORY);
        deployer = new MintTokenDeployer(owner);
        handler = new FlywheelTaxHandler(owner, address(vault), address(bucket), V2_ROUTER);
        pad = new GangFlywheelPad(
            owner,
            address(registry),
            address(vault),
            address(bucket),
            address(handler),
            address(deployer),
            WBNB,
            V2_FACTORY
        );
        vm.startPrank(owner);
        bucket.setOperator(address(pad), true);
        bucket.setOperator(address(handler), true);
        vault.setLaunchpad(address(pad), true);
        vault.setOperator(address(handler), address(pad));
        vault.setExcluded(address(migrator), true);
        vault.setExcluded(address(bucket), true);
        migrator.addLaunchpad(address(pad));
        deployer.setLaunchpad(address(pad), true);
        handler.setLaunchpad(address(pad));
        handler.setKeeper(keeper);
        pad.setAgentGate(true, address(agents));
        pad.setMigrator(address(migrator));
        vm.stopPrank();
        dev = _agent();
    }

    function _agent() internal returns (address who) {
        who = address(uint160(uint256(keccak256(abi.encode("fly-fork", nonce++)))));
        agents.mint(who, nonce);
        vm.deal(who, 100 ether);
    }

    function _cfg() internal pure returns (IFlywheelPad.FlyConfig memory) {
        return IFlywheelPad.FlyConfig({
            raiseBnb: 20 ether,
            baseQuota: 10, // V2: the ceiling with post-launch minting
            inviteBonus: 1,
            maxPerTx: 10,
            holdBps: 6_000,
            mintFeeBps: 100,
            exitFeeBps: 100,
            devCutBps: 1_000,
            buyBps: 3_000,
            sellTaxBps: 200,
            launchDelay: 60,
            window: 600,
            windowCapMul: 1,
            postMint: true,
            tierMode: 1,
            stepBps: 0,
            stepShares: 0,
            maxMulX100: 0,
            supplyCapMul: 100,
            guardBps: 2_000,
            twapWindow: 900
        });
    }

    function _path(address a, address b) internal pure returns (address[] memory p) {
        p = new address[](2);
        p[0] = a;
        p[1] = b;
    }

    function _routerBuy(address token, address who, uint256 bnb) internal {
        vm.prank(who);
        IPancakeRouterFork(V2_ROUTER).swapExactETHForTokensSupportingFeeOnTransferTokens{value: bnb}(
            0, _path(WBNB, token), who, block.timestamp
        );
    }

    function _routerSell(address token, address who, uint256 amount) internal {
        vm.startPrank(who);
        IERC20(token).approve(V2_ROUTER, amount);
        IPancakeRouterFork(V2_ROUTER)
            .swapExactTokensForETHSupportingFeeOnTransferTokens(amount, 0, _path(token, WBNB), who, block.timestamp);
        vm.stopPrank();
    }

    function test_fork_fullLifeOnRealPancake() public {
        if (noFork) return;
        // the creator's own first mint is paid in WBNB (create pulls the quote)
        vm.startPrank(dev);
        (bool ok,) = WBNB.call{value: 1 ether}(abi.encodeWithSignature("deposit()"));
        require(ok);
        IERC20(WBNB).approve(address(pad), type(uint256).max);
        vm.stopPrank();
        string[4] memory text = ["Fork", "FORK", "logo", "meta"];
        vm.prank(dev);
        address t = pad.create(text, address(0), address(0), _cfg(), 1);

        // fill with BNB
        uint256 g0 = gasleft();
        address first = _agent();
        vm.prank(first);
        pad.mintWithBnb{value: 1 ether}(t, 10, 1, address(0));
        emit log_named_uint("gas: pre-launch mint (BNB)", g0 - gasleft());
        for (uint256 i; pad.sales(t).filledAt == 0; i++) {
            address w = _agent();
            vm.startPrank(w);
            while (pad.quotaLeft(t, w) > 0 && pad.sales(t).filledAt == 0) {
                pad.mintWithBnb{value: 1 ether}(t, 10, 1, address(0));
            }
            vm.stopPrank();
        }
        vm.warp(vm.getBlockTimestamp() + 60);
        g0 = gasleft();
        pad.launch(t);
        emit log_named_uint("gas: launch", g0 - gasleft());
        address pair = pad.sales(t).pair;
        assertEq(IPairFork(pair).balanceOf(DEAD) + 1000, IPairFork(pair).totalSupply()); // all LP burned

        // launch protection through the real router: a wallet without an Agent ID is refused
        address plain = makeAddr("plain");
        vm.deal(plain, 10 ether);
        vm.prank(plain);
        vm.expectRevert();
        IPancakeRouterFork(V2_ROUTER).swapExactETHForTokensSupportingFeeOnTransferTokens{value: 0.01 ether}(
            0, _path(WBNB, t), plain, block.timestamp
        );
        address buyer = _agent();
        _routerBuy(t, buyer, 0.015 ether); // an Agent within the cap (quota 10 × 100,000 tokens, ~750,000 bought): fine

        // post-launch mints; LP really minted by the pair
        vm.warp(vm.getBlockTimestamp() + 600);
        vm.roll(vm.getBlockNumber() + 1);
        uint256 lp0 = IPairFork(pair).balanceOf(DEAD);
        address m = _agent();
        g0 = gasleft();
        vm.prank(m);
        (uint256 out,) = pad.mintPostWithBnb{value: 1 ether}(t, 10, 0, address(0));
        emit log_named_uint("gas: post-launch mint (BNB)", g0 - gasleft());
        assertGt(out, 0);
        assertGt(IPairFork(pair).balanceOf(DEAD), lp0);
        assertEq(vault.shares(t, m), out);

        // trading through the real router: buys, sells (swap-back chunk), then the keeper sells tax via the router
        address trader = _agent();
        _routerBuy(t, trader, 3 ether);
        vm.roll(vm.getBlockNumber() + 1);
        g0 = gasleft();
        _routerSell(t, trader, IERC20(t).balanceOf(trader) / 2);
        emit log_named_uint("gas: router sell with swap-back", g0 - gasleft());
        vm.roll(vm.getBlockNumber() + 1);
        uint256 chunk = handler.maxChunk(t);
        if (chunk > 0) {
            vm.prank(keeper);
            handler.process(t, chunk, 1);
        }
        assertGt(vault.pending(t, dev) + vault.pending(t, first), 0); // minters earn the tax

        // the oracle on the real pair's cumulative price (the sale's 15-minute window)
        vm.warp(vm.getBlockTimestamp() + 40 minutes);
        vm.roll(vm.getBlockNumber() + 1);
        handler.observe(t);
        (uint256 spot,,, uint256 avg) = pad.prices(t);
        assertGt(avg, 0);
        assertApproxEqRel(avg, spot, 0.2e18);
        (uint16 g, uint32 w) = pad.postRulesOf(t);
        assertEq(g, 2_000);
        assertEq(w, 900);

        // V2 on the real pair: a 30% dump refuses the next block's mint (guard 20%); the preview agrees
        address seller = _agent();
        _routerBuy(t, seller, 5 ether);
        vm.warp(vm.getBlockTimestamp() + 20 minutes);
        vm.roll(vm.getBlockNumber() + 1);
        handler.observe(t);
        vm.roll(vm.getBlockNumber() + 1);
        _routerSell(t, seller, IERC20(t).balanceOf(seller));
        vm.roll(vm.getBlockNumber() + 1);
        vm.warp(vm.getBlockTimestamp() + 3);
        (spot,,, avg) = pad.prices(t);
        assertLt(spot * 10, avg * 8, "the dump is past the guard");
        address late = _agent();
        (,,,, bool okPreview) = pad.previewMintPost(t, late, 10);
        assertFalse(okPreview);
        vm.prank(late);
        vm.expectRevert(IFlywheelPad.PriceBelowAverage.selector);
        pad.mintPostWithBnb{value: 1 ether}(t, 10, 0, address(0));
    }
}
