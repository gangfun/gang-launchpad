// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {GangRouterDeployLib as R} from "../../script/GangRouterDeployLib.sol";
import {Pad3Impl} from "../../script/Pad3Impl.sol";
import {DeployGangPromotePoolModuleFactory as D} from "../../script/DeployGangPromotePoolModuleFactory.s.sol";
import {GangMainnetRefs as M} from "../../config/GangDeployRefs.sol";
import {GangLaunchpad3} from "../../src/gang/GangLaunchpad3.sol";
import {Pad3Module} from "../../src/gang/Pad3Module.sol";
import {GangHandlerAdmin} from "../../src/gang/GangHandlerAdmin.sol";
import {GangTaxHandler} from "../../src/gang/GangTaxHandler.sol";
import {GangPromotePoolModule as Mod} from "../../src/gang/GangPromotePoolModule.sol";
import {GangPromotePoolModuleFactory as F} from "../../src/gang/GangPromotePoolModuleFactory.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {IGangPad} from "../../src/gang/interfaces/IGangPad.sol";

interface IPoolForkRouter {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IPoolForkHandler {
    function maxChunk(address token) external view returns (uint256);
    function process(address token, uint256 amount, uint256 minQuoteOut) external returns (uint256);
    function keeper() external view returns (address);
}

/// @notice The pool side of the promoter share (docs/SPEC-PROMOTER-POOL-SHARE-2026-11-05.md) on a BSC mainnet fork: the
///         live 3.0 proxy runs this build (as the Safe would upgrade it), DeployGangPromotePoolModuleFactory deploys the
///         factory over the live GangHandlerAdmin, and the Safe's call it prints allows it. Then a token's whole life on
///         real contracts: live handler and keeper role, real Pancake pair and router, real quotes. Trades go through the
///         real router, the keeper sells the tax, and the settlement rule (§4) runs on the recorded logs. Agent IDs are
///         mocked; the wallet cap is off, so a few buyers fill the curve. No broadcast. Run each test alone (the script
///         reads process-wide env vars, and a plain node's old state doesn't last long).
/// @dev Needs BSC_RPC_URL (skipped without it). The upgrade itself is checked by Pad3PromoteUpgradeFork; this one makes the
///      implementation directly, like PAD3_FORK_THIS_BUILD in Pad3ModulesFork, and runs without --libraries.
contract PromotePoolMainnetForkTest is Test {
    address constant PAD3 = 0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29;
    address constant SAFE = 0x2866369F7acEFC9760bdE7779362fae5cD68B41E;
    address constant LIVE_ADMIN = 0xC833CEC2B283759003945C0Bf8C048aB1949Af76;
    address constant GANG = 0x0c6302401aa5325C2E36F170f52C00B1d220B405;
    address constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    address constant USD1 = 0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d;
    address constant USDC_REF = 0xd99c7F6C65857AC913a8f880A4cb84032AB2FC5b;
    address constant USD1_REF = 0x46b9217342CdC50c89FfA84A12Be45b2639eAf4A;
    uint256 constant BPS = 10_000;
    uint16 constant SHARE = 2_000;
    uint32 constant WINDOW = 30 days;

    GangLaunchpad3 p = GangLaunchpad3(payable(PAD3));
    Pad3Module pm = Pad3Module(payable(PAD3));
    address dev = makeAddr("pool-fork-dev");
    address promoter = makeAddr("pool-fork-promoter");
    address refWallet = makeAddr("pool-fork-ref-wallet");
    address plainWallet = makeAddr("pool-fork-plain-wallet");
    address settler = makeAddr("pool-fork-settler");
    uint256 internal _n;

    D script;
    F factory;
    Mod m;
    address t;
    address quote;
    address pair;
    uint16 buyTax;
    uint16 sellTax;

    // ---------------------------------------------------------------- the live deployment
    /// @dev This build on the live proxy, and the factory by its script. False: no RPC, skipped.
    function _live() internal returns (bool) {
        if (!_upgraded()) return false;
        _deploy();
        return true;
    }

    function _upgraded() internal returns (bool) {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return false;
        }
        vm.createSelectFork(rpc);
        GangLaunchpad3 cur = GangLaunchpad3(payable(PAD3));
        Pad3Impl.Deps memory d = Pad3Impl.depsOf(cur);
        (, Pad3Impl.FlyDeps memory fly) = Pad3Impl.flyDepsOf(cur);
        address impl = Pad3Impl.implWith(d, Pad3Impl.module(d, fly));
        vm.prank(SAFE);
        ProxyAdmin(R.adminOf(PAD3)).upgradeAndCall(ITransparentUpgradeableProxy(PAD3), impl, "");
        assertEq(R.implementationOf(PAD3), impl);
        vm.mockCall(M.AGENT_ID_REGISTRY, abi.encodeWithSelector(IERC721.balanceOf.selector), abi.encode(uint256(1)));
        vm.prank(SAFE);
        p.setWalletCapEnabled(false);
        uint256 pk = uint256(keccak256("promoter pool share fork test: throwaway, never funded"));
        vm.deal(vm.addr(pk), 1 ether);
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(pk));
        vm.setEnv("GANG_PAD3", vm.toString(PAD3));
        vm.setEnv("GANG_PAD2", vm.toString(address(0)));
        vm.setEnv("HANDLER_ADMIN", vm.toString(LIVE_ADMIN));
        vm.setEnv("PROMOTE_SETTLER", vm.toString(settler));
        vm.setEnv("PROMOTE_POOL_OWNER", vm.toString(SAFE));
        vm.setEnv("PROMOTE_POOL_FACTORY", vm.toString(address(0)));
        vm.setEnv("GANG_QUOTE", vm.toString(GANG));
        return true;
    }

    function _deploy() internal {
        script = new D();
        factory = script.run();
        bytes[] memory batch = script.pendingBatch(LIVE_ADMIN, address(factory));
        assertEq(batch.length, 1, "one Safe call");
        (address to, bytes memory data) = this.cut(batch[0]);
        vm.prank(SAFE);
        (bool ok,) = to.call(data);
        assertTrue(ok, "the Safe's call");
        assertEq(script.pendingBatch(LIVE_ADMIN, address(factory)).length, 0);
    }

    function cut(bytes calldata c) external pure returns (address, bytes memory) {
        return (address(bytes20(c[:20])), c[20:]);
    }

    // ---------------------------------------------------------------- pieces
    function _agent() internal returns (address a) {
        a = makeAddr(string.concat("pool-fork-agent-", vm.toString(_n++)));
    }

    function _next(uint256 dt) internal {
        vm.warp(vm.getBlockTimestamp() + dt);
        vm.roll(vm.getBlockNumber() + 2);
    }

    /// @dev A module for the dev and its token, named as the recipient and refWallet; both wallets buy on the curve, `refWallet`
    ///      through a promoter, so the curve share runs next to the pool's.
    function _token(address quote_, address ref, uint16 buy_, uint16 sell_, uint16 dividendBps) internal {
        (quote, buyTax, sellTax) = (quote_, buy_, sell_);
        vm.prank(dev);
        m = Mod(factory.create(keccak256(abi.encode("pool-fork", _n++))));
        vm.prank(dev);
        t = pm.createWithPromote(
            "Pool",
            "POOL",
            "l",
            "m",
            quote_,
            ref,
            IGangLaunchpad.TaxConfig(buy_, sell_, dividendBps, address(m)),
            6 ether,
            SHARE,
            WINDOW
        );
        m.bind(t);
        assertEq(m.token(), t);
        assertEq(m.quote(), quote_);
        assertTrue(m.keeperServes(quote_));

        uint256 gross = pm.gradAmtOf(t) / 20;
        _curveBuy(refWallet, gross, promoter);
        _curveBuy(plainWallet, gross, address(0));
    }

    function _curveBuy(address who, uint256 gross, address via) internal {
        if (quote == M.WBNB) {
            // a WBNB-quoted token takes BNB here
            vm.deal(who, gross);
            vm.prank(who, who);
            pm.buyWithPromoter{value: gross}(t, gross, 0, via);
            return;
        }
        deal(quote, who, IERC20(quote).balanceOf(who) + gross);
        vm.startPrank(who, who);
        IERC20(quote).approve(PAD3, type(uint256).max);
        pm.buyWithPromoter(t, gross, 0, via);
        vm.stopPrank();
    }

    function _graduate() internal {
        uint256 per = pm.gradAmtOf(t) / 3;
        bool graduated;
        for (uint256 i; i < 10 && !graduated; i++) {
            address b = _agent();
            deal(quote, b, per);
            vm.startPrank(b, b);
            IERC20(quote).approve(PAD3, type(uint256).max);
            try IGangPad(PAD3).buy(t, per, 0) {} catch {}
            vm.stopPrank();
            (,,,,,, graduated,,,, pair,) = IGangPad(PAD3).curves(t);
        }
        assertTrue(graduated, "graduated");
        assertGt(pair.code.length, 0, "a real pair");
    }

    function _path(address a, address b) internal pure returns (address[] memory path) {
        path = new address[](2);
        (path[0], path[1]) = (a, b);
    }

    /// @dev On the real Pancake router, as a wallet trades: the pair pays the wallet on a buy, the router moves the wallet's
    ///      tokens into the pair on a sell, so the wallet is `OuterTax`'s counterparty either way.
    function _poolBuy(address who, uint256 amount) internal {
        deal(quote, who, IERC20(quote).balanceOf(who) + amount);
        vm.startPrank(who, who);
        IERC20(quote).approve(M.PANCAKE_V2_ROUTER, type(uint256).max);
        IPoolForkRouter(M.PANCAKE_V2_ROUTER)
            .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                amount, 0, _path(quote, t), who, vm.getBlockTimestamp() + 60
            );
        vm.stopPrank();
        _next(60);
    }

    function _poolSell(address who, uint256 tokens) internal {
        vm.startPrank(who, who);
        IERC20(t).approve(M.PANCAKE_V2_ROUTER, type(uint256).max);
        IPoolForkRouter(M.PANCAKE_V2_ROUTER)
            .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                tokens, 0, _path(t, quote), who, vm.getBlockTimestamp() + 60
            );
        vm.stopPrank();
        _next(60);
    }

    /// @dev Both wallets, both ways, in the real pool.
    function _trade() internal {
        uint256 gross = pm.gradAmtOf(t) / 25;
        _poolBuy(refWallet, gross);
        _poolSell(refWallet, IERC20(t).balanceOf(refWallet) / 3);
        _poolSell(plainWallet, IERC20(t).balanceOf(plainWallet) / 3);
        _poolBuy(plainWallet, gross);
        _poolSell(refWallet, IERC20(t).balanceOf(refWallet) / 3);
    }

    /// @dev The keeper sells what accrued, on the live handler.
    function _keeperSells() internal {
        IPoolForkHandler h = IPoolForkHandler(IGangPad(PAD3).taxHandler());
        uint256 sold;
        for (uint256 i; i < 6; i++) {
            _next(60);
            uint256 chunk = h.maxChunk(t);
            if (chunk == 0) break;
            vm.prank(h.keeper());
            try h.process(t, chunk, 1) {
                sold++;
            } catch {
                break;
            }
        }
        assertGt(sold, 0, "the keeper sold tax");
    }

    function _leaf(address a, uint256 c) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(a, c))));
    }

    function _node(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    function _proof(bytes32 sibling) internal pure returns (bytes32[] memory proof) {
        proof = new bytes32[](1);
        proof[0] = sibling;
    }

    // ---------------------------------------------------------------- §4 on the recorded logs
    struct Fifo {
        uint256[] tokens;
        uint16[] rate;
        bool[] counts;
        uint256 head;
        uint256 tail;
        uint256 toRecipient;
        uint256 lastPaid;
        uint256 paid;
        uint256 due;
        uint256 chunks;
        uint256 holders;
    }

    function _fifo(Vm.Log[] memory logs) internal view returns (Fifo memory q) {
        q.tokens = new uint256[](logs.length);
        q.rate = new uint16[](logs.length);
        q.counts = new bool[](logs.length);
        address handler = IGangPad(PAD3).taxHandler();
        bytes32 outer = keccak256("OuterTax(address,address,uint256,uint256)");
        bytes32 taxPaid = keccak256("TaxPaid(address,address,address,uint256)");
        bytes32 taxOwed = keccak256("TaxOwed(address,address,address,uint256)");
        bytes32 dist = keccak256("TaxDistributed(address,uint8,uint256,uint256,uint256,uint256)");
        bytes32 sold = keccak256("TaxChunkSold(address,uint256,uint256,uint256,bool)");
        for (uint256 i; i < logs.length; i++) {
            Vm.Log memory l = logs[i];
            if (l.topics.length == 0) continue;
            bytes32 sig = l.topics[0];
            if (l.emitter == t && sig == outer) {
                _fifoTrade(q, l);
            } else if (l.emitter != handler) {
                continue;
            } else if (sig == taxOwed) {
                revert("a push to the module failed");
            } else if (sig == taxPaid && address(uint160(uint256(l.topics[1]))) == t) {
                assertEq(address(uint160(uint256(l.topics[2]))), address(m), "paid to the module");
                assertEq(address(uint160(uint256(l.topics[3]))), quote, "paid in the quote");
                q.lastPaid = abi.decode(l.data, (uint256));
            } else if (sig == dist) {
                uint256 toHolders;
                (,,, toHolders, q.toRecipient) = abi.decode(l.data, (uint8, uint256, uint256, uint256, uint256));
                q.holders += toHolders;
                // the order settle.mjs reads: the chunk's TaxPaid is the handler's log right before TaxDistributed
                assertEq(q.lastPaid, q.toRecipient, "TaxPaid, then TaxDistributed");
                q.paid += q.toRecipient;
                q.lastPaid = 0;
            } else if (sig == sold) {
                (uint256 tokens,,,) = abi.decode(l.data, (uint256, uint256, uint256, bool));
                _fifoChunk(q, tokens);
                q.chunks++;
            }
        }
    }

    function _fifoTrade(Fifo memory q, Vm.Log memory l) internal view {
        (uint256 taxed,) = abi.decode(l.data, (uint256, uint256));
        address from = address(uint160(uint256(l.topics[1])));
        address to = address(uint160(uint256(l.topics[2])));
        (address who, uint40 at,) = pm.bindingOf(t, from == pair ? to : from);
        q.tokens[q.tail] = taxed;
        q.rate[q.tail] = from == pair ? buyTax : sellTax;
        q.counts[q.tail++] = who == promoter && vm.getBlockTimestamp() < uint256(at) + WINDOW;
    }

    function _weight(uint256 tokens, uint256 rate) internal pure returns (uint256) {
        return rate <= 50 ? 0 : (tokens * (rate - 50)) / rate;
    }

    function _fifoChunk(Fifo memory q, uint256 sold) internal pure {
        uint256 left = sold;
        uint256 counted;
        uint256 all;
        while (left > 0) {
            assertTrue(q.head < q.tail, "a chunk sold what no trade taxed");
            uint256 take = q.tokens[q.head] < left ? q.tokens[q.head] : left;
            uint256 w = _weight(take, q.rate[q.head]);
            all += w;
            if (q.counts[q.head]) counted += w;
            q.tokens[q.head] -= take;
            left -= take;
            if (q.tokens[q.head] == 0) q.head++;
        }
        if (all != 0) q.due += (q.toRecipient * SHARE * counted) / (BPS * all);
    }

    // ---------------------------------------------------------------- a token's life
    function _life(address quote_, address ref, uint16 buy_, uint16 sell_, uint16 dividendBps) internal {
        _token(quote_, ref, buy_, sell_, dividendBps);
        uint256 curveFee = pm.promoterFeeOf(t, promoter);
        assertGt(curveFee, 0, "the curve share accrued");
        _graduate();
        uint256 curveAfter = pm.promoterFeeOf(t, promoter);

        vm.recordLogs();
        _trade();
        _keeperSells();
        Fifo memory q = _fifo(vm.getRecordedLogs());
        assertGt(q.chunks, 0);
        assertGt(q.paid, 0, "the module was paid");
        if (dividendBps != 0) assertGt(q.holders, 0, "holders got their part first");
        else assertEq(q.holders, 0);
        assertEq(m.undistributed(), q.paid, "all that arrived waits for a split");
        assertEq(pm.promoterFeeOf(t, promoter), curveAfter, "the pool side leaves the curve share alone");

        // the split, by the real quote's transfer
        (bool due,) = m.previewWork();
        console.log("previewWork due on the real pair", due);
        uint256 d0 = IERC20(quote).balanceOf(dev);
        uint256 g0 = gasleft();
        m.work(0);
        console.log("work gas", g0 - gasleft());
        uint256 x = m.escrowIn();
        assertEq(x, (q.paid * SHARE) / BPS, "the share escrowed");
        assertEq(IERC20(quote).balanceOf(dev) - d0, q.paid - x, "the rest pushed to the dev");
        assertEq(m.devOwed(), 0, "the push went through");
        assertEq(IERC20(quote).balanceOf(address(m)), x);
        assertEq(m.held(), x);
        assertGt(m.firstGradSeenAt(), 0);

        assertGt(q.due, 0, "the refWallet wallet's tokens were sold");
        assertLt(q.due, x, "the plainWallet wallet's share stays with the dev");
        _settleAndClaim(q.due, x);

        // the curve share is still there, in the same quote
        vm.prank(promoter);
        assertEq(pm.claimPromoterFee(t, promoter), curveAfter);
    }

    function _settleAndClaim(uint256 toPromoter, uint256 x) internal {
        uint256 toDev = x - toPromoter;
        vm.roll(vm.getBlockNumber() + 1);
        uint64 through = uint64(vm.getBlockNumber() - 1);

        // a wrong root: only the settler posts it, only the Safe vetoes it
        vm.prank(promoter);
        vm.expectRevert(Mod.NotSettler.selector);
        m.post(_leaf(promoter, x), x, through, "wrong");
        vm.prank(settler);
        m.post(_leaf(promoter, x), x, through, "wrong");
        vm.prank(promoter);
        vm.expectRevert(Mod.NotVetoer.selector);
        m.veto();
        vm.prank(SAFE);
        m.veto();
        vm.prank(settler);
        vm.expectRevert(Mod.BadAllocated.selector);
        m.post(_leaf(promoter, x), x + 1, through, "over");

        // the right one
        bytes32 lp = _leaf(promoter, toPromoter);
        bytes32 ld = _leaf(dev, toDev);
        vm.prank(settler);
        m.post(_node(lp, ld), x, through, "right");
        vm.prank(promoter);
        vm.expectRevert(Mod.BadProof.selector);
        m.claim(toPromoter, _proof(ld), promoter);
        _next(m.DISPUTE_WINDOW());

        uint256 p0 = IERC20(quote).balanceOf(promoter);
        vm.prank(promoter);
        assertEq(m.claim(toPromoter, _proof(ld), promoter), toPromoter);
        assertEq(IERC20(quote).balanceOf(promoter) - p0, toPromoter, "the promoter paid in the quote");
        vm.prank(plainWallet);
        vm.expectRevert(Mod.BadProof.selector);
        m.claim(toPromoter, _proof(ld), plainWallet);
        uint256 d0 = IERC20(quote).balanceOf(dev);
        vm.prank(dev);
        assertEq(m.claim(toDev, _proof(lp), dev), toDev);
        assertEq(IERC20(quote).balanceOf(dev) - d0, toDev, "the dev's part of the escrow");
        assertEq(m.held(), 0, "nothing left behind");
        assertEq(IERC20(quote).balanceOf(address(m)), 0);
    }

    // ---------------------------------------------------------------- tests
    /// @dev WBNB quote, different rates each way, 20% to holders.
    function test_fork_pool_wbnb() public {
        if (!_live()) return;
        _life(M.WBNB, address(0), 200, 400, 2_000);
    }

    /// @dev The stablecoins the keeper serves, on the quote's real transfer.
    function test_fork_pool_usdt() public {
        if (!_live()) return;
        _life(M.USDT, M.USDT_REF_POOL, 300, 300, 0);
    }

    function test_fork_pool_usdc() public {
        if (!_live()) return;
        _life(USDC, USDC_REF, 300, 300, 0);
    }

    /// @dev USD1 is an upgradeable proxy: its transfer must fit the module's push.
    function test_fork_pool_usd1() public {
        if (!_live()) return;
        _life(USD1, USD1_REF, 300, 300, 2_000);
    }

    /// @dev The script over the live admin: what it refuses, what it leaves for the Safe, and that it finds nothing left on
    ///      a second run. The live module set stays as it was.
    function test_fork_pool_deployScript() public {
        if (!_upgraded()) return;
        GangHandlerAdmin admin = GangHandlerAdmin(LIVE_ADMIN);
        assertEq(admin.owner(), SAFE);
        address[] memory before = admin.factories();

        script = new D();
        factory = script.run();
        assertEq(factory.owner(), SAFE);
        assertEq(factory.settler(), settler);
        assertEq(factory.pad(), PAD3);
        assertEq(factory.admin(), LIVE_ADMIN);
        assertEq(Mod(factory.implementation()).gangQuote(), GANG);
        assertFalse(admin.isFactory(address(factory)), "the script sends nothing on mainnet");
        vm.prank(_agent());
        vm.expectRevert();
        factory.create(bytes32(uint256(1))); // not allowed on the admin yet

        // a factory whose settler is its owner, or owned by anyone else, fails the mainnet check
        F same = new F(PAD3, LIVE_ADMIN, GANG, SAFE, SAFE);
        vm.expectRevert(abi.encodeWithSelector(D.WiringCheck.selector, "factory.settlerIsOwner"));
        script.check(PAD3, LIVE_ADMIN, address(same));
        F other = new F(PAD3, LIVE_ADMIN, GANG, dev, settler);
        vm.expectRevert(abi.encodeWithSelector(D.WiringCheck.selector, "factory.owner"));
        script.check(PAD3, LIVE_ADMIN, address(other));

        bytes[] memory batch = script.pendingBatch(LIVE_ADMIN, address(factory));
        assertEq(batch.length, 1);
        (address to, bytes memory data) = this.cut(batch[0]);
        assertEq(to, LIVE_ADMIN);
        vm.prank(dev);
        (bool ok,) = to.call(data);
        assertFalse(ok, "only the Safe");
        vm.prank(SAFE);
        (ok,) = to.call(data);
        assertTrue(ok);

        vm.setEnv("PROMOTE_POOL_FACTORY", vm.toString(address(factory)));
        assertEq(address(new D().run()), address(factory));
        assertEq(script.pendingBatch(LIVE_ADMIN, address(factory)).length, 0);
        address[] memory afterward = admin.factories();
        assertEq(afterward.length, before.length + 1);
        for (uint256 i; i < before.length; i++) {
            assertEq(afterward[i], before[i]);
            assertTrue(admin.isFactory(before[i]));
        }

        vm.prank(dev);
        address module = factory.create(bytes32(uint256(1)));
        assertEq(admin.moduleOf(module), address(factory));
        assertTrue(GangTaxHandler(IGangPad(PAD3).taxHandler()).isListed(module), "listed on the live handler");
    }

    /// @dev What `bind` refuses on live contracts; a live graduated token isn't a dev's to take.
    function test_fork_pool_bindRefusals() public {
        if (!_live()) return;
        vm.prank(dev);
        Mod mod = Mod(factory.create(bytes32(uint256(1))));
        IGangLaunchpad.TaxConfig memory tax = IGangLaunchpad.TaxConfig(300, 300, 0, address(mod));

        address liveToken = p.allTokens(0);
        vm.expectRevert(Mod.NotCreator.selector);
        mod.bind(liveToken);

        vm.prank(dev);
        address plain = p.createWithGradTarget("P", "P", "l", "m", M.WBNB, address(0), tax, 6 ether);
        vm.expectRevert(Mod.NotPromoted.selector);
        mod.bind(plain);

        // the token names another listed module
        vm.prank(dev);
        Mod another = Mod(factory.create(bytes32(uint256(2))));
        vm.prank(dev);
        address notNamed = pm.createWithPromote(
            "P",
            "P",
            "l",
            "m",
            M.WBNB,
            address(0),
            IGangLaunchpad.TaxConfig(300, 300, 0, address(another)),
            6 ether,
            SHARE,
            WINDOW
        );
        vm.expectRevert(Mod.NotRecipient.selector);
        mod.bind(notNamed);

        vm.prank(dev);
        address allHolders = pm.createWithPromote(
            "P",
            "P",
            "l",
            "m",
            M.WBNB,
            address(0),
            IGangLaunchpad.TaxConfig(300, 300, 10_000, address(mod)),
            6 ether,
            SHARE,
            WINDOW
        );
        vm.expectRevert(Mod.AllDividends.selector);
        mod.bind(allHolders);

        vm.prank(dev);
        t = pm.createWithPromote("P", "P", "l", "m", M.WBNB, address(0), tax, 6 ether, SHARE, WINDOW);
        quote = M.WBNB;
        _graduate();
        vm.expectRevert(Mod.AlreadyGraduated.selector);
        mod.bind(t);
    }

    /// @dev The settler silent past SETTLER_SILENCE on a real token: the dev takes back the unallocated escrow, the module
    ///      closes, and later tax goes to the dev whole, with no root possible.
    function test_fork_pool_reclaimThenAllToDev() public {
        if (!_live()) return;
        _token(M.WBNB, address(0), 300, 300, 0);
        _graduate();
        _trade();
        _keeperSells();
        m.work(0);
        uint256 x = m.escrowIn();
        assertGt(x, 0);
        vm.prank(dev);
        vm.expectRevert(Mod.StillActive.selector);
        m.reclaim(dev);
        _next(m.SETTLER_SILENCE());
        uint256 d0 = IERC20(quote).balanceOf(dev);
        vm.prank(dev);
        assertEq(m.reclaim(dev), x);
        assertEq(IERC20(quote).balanceOf(dev) - d0, x);
        assertTrue(m.closed());
        assertEq(m.held(), 0);

        _trade();
        _keeperSells();
        uint256 more = m.undistributed();
        assertGt(more, 0);
        d0 = IERC20(quote).balanceOf(dev);
        m.work(0);
        assertEq(IERC20(quote).balanceOf(dev) - d0, more, "all to the dev");
        assertEq(m.escrowIn(), x, "nothing more escrowed");
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(settler);
        vm.expectRevert(Mod.Closed.selector);
        m.post(bytes32(uint256(1)), x, uint64(vm.getBlockNumber() - 1), "closed");
    }

    /// @dev Past the last window and the grace, arrivals go to the dev whole, while the root keeps paying what it allocated.
    function test_fork_pool_escrowEndsAfterWindow() public {
        if (!_live()) return;
        _token(M.WBNB, address(0), 300, 300, 0);
        _graduate();
        _trade();
        _keeperSells();
        m.work(0);
        uint256 x = m.escrowIn();
        assertTrue(m.escrowOpen());
        vm.roll(vm.getBlockNumber() + 1);
        bytes32 root = _leaf(promoter, x);
        vm.prank(settler);
        m.post(root, x, uint64(vm.getBlockNumber() - 1), "all");

        _next(WINDOW + m.ESCROW_GRACE());
        assertFalse(m.escrowOpen());
        _trade();
        _keeperSells();
        uint256 more = m.undistributed();
        assertGt(more, 0);
        uint256 d0 = IERC20(quote).balanceOf(dev);
        m.work(0);
        assertEq(IERC20(quote).balanceOf(dev) - d0, more, "all to the dev");
        assertEq(m.escrowIn(), x);
        vm.prank(promoter);
        assertEq(m.claim(x, new bytes32[](0), promoter), x);
        assertEq(m.held(), 0);
    }
}
