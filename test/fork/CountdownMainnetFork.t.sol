// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {GangMainnetRefs as M} from "../../config/GangDeployRefs.sol";
import {IGangPad} from "../../src/gang/interfaces/IGangPad.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {GangLaunchpad3} from "../../src/gang/GangLaunchpad3.sol";
import {Pad3Module} from "../../src/gang/Pad3Module.sol";
import {Pad3VanityDeployer} from "../../src/gang/Pad3VanityDeployer.sol";
import {GangCountdownReward} from "../../src/gang/GangCountdownReward.sol";
import {GangCountdownRewardFactory} from "../../src/gang/GangCountdownRewardFactory.sol";
import {DeployGangCountdownRewardFactory} from "../../script/DeployGangCountdownRewardFactory.s.sol";
import {Pad3VanitySalt} from "../../script/Pad3VanitySalt.sol";

interface ICdForkRouter {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface ICdForkHandler {
    function maxChunk(address token) external view returns (uint256);
    function process(address token, uint256 amount, uint256 minQuoteOut) external returns (uint256);
    function keeper() external view returns (address);
}

/// @notice The LIVE GangCountdownRewardFactory (deployed 2026-11-17) on a BSC mainnet fork: the script's checks (wiring,
///         mainnet rules, runtime code) against it, the archived Safe batch executed as is, then a full round on the live
///         GangLaunchpad 3.0, its abcd deployer, its GangTaxHandler and real PancakeSwap: an Agent computes its token's
///         address, clones a countdown module for it, creates the token there with createWithSalt, binds, seeds the pool;
///         the curve graduates into a real pair; router trades pay the tax and the live keeper role sells it into the
///         module (booked with the dev's part); counted buys go through the module on the real pair (BNB for a WBNB
///         token, the quote for USDT); after the deadline `work` settles the round and every buyer claims to the wei.
///         Agent IDs are mocked and the wallet cap is off so a few buyers fill the curve. No broadcast.
/// @dev Needs BSC_RPC_URL (skipped without it). Run each test alone.
contract CountdownMainnetForkTest is Test {
    address constant PAD3 = 0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29;
    address constant SAFE = 0x2866369F7acEFC9760bdE7779362fae5cD68B41E;
    address constant LIVE_ADMIN = 0xC833CEC2B283759003945C0Bf8C048aB1949Af76;
    address constant GANG = 0x0c6302401aa5325C2E36F170f52C00B1d220B405;
    address constant LIVE_FACTORY = 0xa1e3117a59104de7D97667cF22f9AB886a5f2957;
    string constant BATCH = "docs/MAINNET-COUNTDOWN-SET-FACTORY-SAFE-BATCH-2026-11-17.json";
    uint16 constant TAX = 300;
    uint256 constant BPS = 10_000;

    IGangPad p = IGangPad(PAD3);
    GangCountdownRewardFactory factory;
    GangCountdownReward m;
    address dev = makeAddr("countdown-fork-dev");
    address t;
    address quote;
    address pair;
    uint256 internal _n;

    function _liveFactory() internal returns (bool) {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return false;
        }
        vm.createSelectFork(rpc);
        vm.mockCall(M.AGENT_ID_REGISTRY, abi.encodeWithSelector(IERC721.balanceOf.selector), abi.encode(uint256(1)));
        vm.prank(SAFE);
        GangLaunchpad3(payable(PAD3)).setWalletCapEnabled(false);
        factory = GangCountdownRewardFactory(LIVE_FACTORY);
        DeployGangCountdownRewardFactory script = new DeployGangCountdownRewardFactory();
        script.check(PAD3, LIVE_ADMIN, LIVE_FACTORY);
        script.checkCode(LIVE_FACTORY);
        assertEq(GangCountdownReward(factory.implementation()).gangQuote(), GANG);
        assertTrue(factory.vanityEnabled());
        // the archived batch, executed as the Safe would: one call, to the admin, allowing exactly this factory
        string memory json = vm.readFile(BATCH);
        assertEq(vm.parseJsonUint(json, ".chainId"), 56);
        assertEq(vm.parseJsonAddress(json, ".meta.createdFromSafeAddress"), SAFE);
        assertEq(abi.decode(vm.parseJson(json, ".transactions"), (bytes[])).length, 1, "one call");
        address to = vm.parseJsonAddress(json, ".transactions[0].to");
        bytes memory data = vm.parseJsonBytes(json, ".transactions[0].data");
        assertEq(vm.parseJsonUint(json, ".transactions[0].value"), 0);
        assertEq(to, LIVE_ADMIN);
        assertEq(data, abi.encodeWithSignature("setFactory(address,bool)", LIVE_FACTORY, true));
        bytes[] memory pending = script.pendingBatch(LIVE_ADMIN, LIVE_FACTORY);
        assertEq(pending.length, 1);
        assertEq(pending[0], abi.encodePacked(to, data), "the file is what the script prints");
        vm.prank(SAFE);
        (bool ok,) = to.call(data);
        assertTrue(ok, "the Safe's call");
        assertEq(script.pendingBatch(LIVE_ADMIN, LIVE_FACTORY).length, 0, "allowed");
        return true;
    }

    function _next(uint256 dt) internal {
        vm.warp(vm.getBlockTimestamp() + dt);
        vm.roll(vm.getBlockNumber() + 2);
    }

    function _agent() internal returns (address a) {
        a = makeAddr(string.concat("countdown-fork-agent-", vm.toString(_n++)));
    }

    function _path(address a, address b) internal pure returns (address[] memory path) {
        path = new address[](2);
        (path[0], path[1]) = (a, b);
    }

    function _cfg(uint256 minBuy, uint256 minPot) internal pure returns (GangCountdownReward.Config memory) {
        return GangCountdownReward.Config({
            window: 1 hours,
            maxRound: 6 hours,
            idle: 30 days,
            payoutBps: 3_000,
            lastBps: 2_000,
            devBps: 2_500,
            entries: 3,
            minBuy: minBuy,
            minPot: minPot,
            maxPayout: 1_000 ether
        });
    }

    /// @dev Address first, module cloned for it, token created there, bound, seeded; graduated into a real pair.
    function _token(address quote_, address refPool, uint256 minBuy, uint256 minPot, uint256 seed) internal {
        quote = quote_;
        Pad3VanityDeployer vd = Pad3VanityDeployer(Pad3Module(payable(PAD3)).vanityDeployer());
        bytes32 h = vd.tokenInitCodeHash("Countdown", "CDF", "m", p.taxHandler(), TAX, TAX, false);
        (bytes32 salt, address at) = Pad3VanitySalt.find(address(vd), dev, h);
        assertEq(at.code.length, 0, "the token does not exist yet");
        vm.prank(dev);
        m = GangCountdownReward(factory.create(at, quote_, _cfg(minBuy, minPot), bytes32(uint256(1))));
        assertEq(m.moduleType(), bytes32("countdown-v1"));
        assertEq(m.rewardToken(), at);
        bytes memory data = abi.encodeWithSignature(
            "create(string,string,string,string,address,address,(uint16,uint16,uint16,address))",
            "Countdown",
            "CDF",
            "l",
            "m",
            quote_,
            refPool,
            IGangLaunchpad.TaxConfig(TAX, TAX, 2_000, address(m))
        );
        vm.prank(dev, dev);
        t = Pad3Module(payable(PAD3)).createWithSalt(salt, data);
        assertEq(t, at);
        m.bind(t);
        deal(quote_, dev, seed);
        vm.startPrank(dev);
        IERC20(quote_).approve(address(m), seed);
        m.fund(seed);
        vm.stopPrank();
        assertEq(m.pot(), seed);

        bool graduated;
        uint256 per = p.gradAmtOf(t) / 3;
        for (uint256 i; i < 10 && !graduated; i++) {
            address b = _agent();
            deal(quote, b, per);
            vm.startPrank(b, b);
            IERC20(quote).approve(PAD3, type(uint256).max);
            try p.buy(t, per, 0) {} catch {}
            vm.stopPrank();
            (,,,,,, graduated,,,, pair,) = p.curves(t);
        }
        assertTrue(graduated, "graduated");
        assertGt(pair.code.length, 0, "a real pair");
    }

    /// @dev Real router trades both ways, then the live keeper role sells the tax into the module.
    function _poolTax() internal {
        address trader = _agent();
        uint256 size = p.gradAmtOf(t) / 10;
        for (uint256 i; i < 4; i++) {
            deal(quote, trader, IERC20(quote).balanceOf(trader) + size);
            vm.startPrank(trader, trader);
            IERC20(quote).approve(M.PANCAKE_V2_ROUTER, type(uint256).max);
            IERC20(t).approve(M.PANCAKE_V2_ROUTER, type(uint256).max);
            ICdForkRouter(M.PANCAKE_V2_ROUTER)
                .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                    size, 0, _path(quote, t), trader, vm.getBlockTimestamp() + 60
                );
            ICdForkRouter(M.PANCAKE_V2_ROUTER)
                .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                    IERC20(t).balanceOf(trader), 0, _path(t, quote), trader, vm.getBlockTimestamp() + 60
                );
            vm.stopPrank();
            _next(60);
        }
        ICdForkHandler h = ICdForkHandler(p.taxHandler());
        for (uint256 i; i < 10; i++) {
            _next(60);
            uint256 chunk = h.maxChunk(t);
            if (chunk == 0) break;
            vm.prank(h.keeper());
            try h.process(t, chunk, 1) {}
            catch {
                break;
            }
        }
        uint256 pot0 = m.pot();
        uint256 arrived = IERC20(quote).balanceOf(address(m)) - pot0;
        assertGt(arrived, 0, "the pool tax reached the module");
        m.settle(); // books it (no round runs yet)
        uint256 toDev = (arrived * 2_500) / BPS;
        assertEq(m.devOwed(), toDev, "the dev's part");
        assertEq(m.pot(), pot0 + arrived - toDev);
    }

    function _books() internal view {
        assertGe(
            IERC20(quote).balanceOf(address(m)),
            m.pot() + m.reservedTotal() + m.claimTotal() + m.devOwed(),
            "books covered by the balance"
        );
    }

    /// @dev Three counted buys through the module (a, b, a), the round settled after its deadline, claims to the wei.
    function _round(uint256 spend, bool bnb) internal {
        address a = _agent();
        address b = _agent();
        address[3] memory who = [a, b, a];
        for (uint256 i; i < 3; i++) {
            address w = who[i];
            uint256 mod0 = IERC20(quote).balanceOf(address(m));
            uint256 t0 = IERC20(t).balanceOf(w);
            uint256 out;
            if (bnb) {
                vm.deal(w, spend);
                vm.prank(w, w);
                out = m.buy{value: spend}(0, vm.getBlockTimestamp() + 60, true);
            } else {
                deal(quote, w, spend);
                vm.startPrank(w, w);
                IERC20(quote).approve(address(m), spend);
                out = m.buyWithQuote(spend, 0, vm.getBlockTimestamp() + 60, true);
                vm.stopPrank();
            }
            assertGt(out, 0);
            assertEq(IERC20(t).balanceOf(w) - t0, out, "the buyer got the tokens");
            assertEq(IERC20(quote).balanceOf(address(m)), mod0, "nothing of the buy stays in the module");
            _next(5 minutes);
        }
        (uint64 id, uint32 count,,,,) = m.round(m.cur());
        assertEq(id, 1);
        assertEq(count, 3);
        _books();
        vm.warp(m.deadline() + 1);
        (bool due,) = m.previewWork();
        assertTrue(due);
        uint256 avail = m.potAvailable();
        uint256 payout = (avail * 3_000) / BPS;
        uint256 extra = (payout * 2_000) / BPS;
        uint256 each = (payout - extra) / 3;
        m.work(0);
        assertEq(m.claimableOf(a), each * 2 + extra, "a: two shares and the last buy's extra");
        assertEq(m.claimableOf(b), each, "b: one share");
        _books();
        uint256 qa = IERC20(quote).balanceOf(a);
        vm.prank(a);
        m.claim(a);
        assertEq(IERC20(quote).balanceOf(a) - qa, each * 2 + extra);
        uint256 qd = IERC20(quote).balanceOf(dev);
        uint256 dv = m.devOwed();
        m.claimDev();
        assertEq(IERC20(quote).balanceOf(dev) - qd, dv);
        _books();
    }

    function test_liveFactory_wbnb_fullRound() public {
        if (!_liveFactory()) return;
        _token(M.WBNB, address(0), 0.05 ether, 0.1 ether, 1 ether);
        _poolTax();
        _round(0.1 ether, true);
    }

    function test_liveFactory_usdt_fullRound() public {
        if (!_liveFactory()) return;
        _token(M.USDT, M.USDT_WBNB_V3, 10 ether, 20 ether, 300 ether);
        _poolTax();
        _round(30 ether, false);
    }
}
