// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {QuoteRegistry} from "../src/launchpad-v2/QuoteRegistry.sol";
import {SharedDividendVault} from "../src/common/SharedDividendVault.sol";
import {SharedPlatformFeeBucket} from "../src/common/SharedPlatformFeeBucket.sol";
import {SharedMigrator} from "../src/common/SharedMigrator.sol";
import {TokenDeployer} from "../src/common/TokenDeployer.sol";
import {GangLaunchpad3} from "../src/gang/GangLaunchpad3.sol";
import {Pad3Module} from "../src/gang/Pad3Module.sol";
import {Pad3FlyVaultCore} from "../src/gang/Pad3FlyVaultCore.sol";
import {GangPadRegistry} from "../src/gang/GangPadRegistry.sol";
import {GangTaxHandler} from "../src/gang/GangTaxHandler.sol";
import {FlywheelTaxHandler} from "../src/flywheel/FlywheelTaxHandler.sol";
import {MintTokenDeployer} from "../src/flywheel/MintTokenDeployer.sol";
import {IGangSwapPad} from "../src/gang/interfaces/IGangSwapPad.sol";
import {IGangAgentWindow} from "../src/gang/interfaces/IGangAgentWindow.sol";
import {Pad3VanityDeployer} from "../src/gang/Pad3VanityDeployer.sol";
import {MockWBNB} from "../test/mocks/MockWBNB.sol";
import {MockAgentId} from "../test/mocks/MockAgentId.sol";
import {Pad3VanitySalt} from "./Pad3VanitySalt.sol";
import {Pad3Impl} from "./Pad3Impl.sol";
import {WindowTestTrader} from "./AgentWindowTestnetAcceptance.s.sol";

interface IAccMigrator {
    function addLaunchpad(address) external;
    function wired() external view returns (bool);
    function factory() external view returns (address);
    function boost() external view returns (address);
}

interface IAccFactory {
    function fees() external view returns (address);
    function getPair(address, address) external view returns (address);
}

interface IAccPair {
    function getReserves() external view returns (uint112, uint112, uint32);
    function quoteIs0() external view returns (bool);
    function virtualReserve() external view returns (uint256);
    function realQuoteReserve() external view returns (uint256);
    function feeAccrued() external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

interface IAccBoost {
    function step(address) external returns (uint256, uint256);
    function boosts(address) external view returns (address, uint64, bool, uint128, uint128);
}

interface IAccFees {
    function collect(address) external returns (uint256);
    function claim(address, address) external returns (uint256);
    function creatorFeeOf(address) external view returns (uint256);
    function pendingPlatform() external view returns (uint256);
}

interface IAccRouter {
    function getAmountsOut(uint256, address[] calldata) external view returns (uint256[] memory);
    function swapExactETHForTokensSupportingFeeOnTransferTokens(uint256, address[] calldata, address, uint256)
        external
        payable;
    function swapExactTokensForTokens(uint256, uint256, address[] calldata, address, uint256)
        external
        returns (uint256[] memory);
}

/// @notice GangSwap graduation acceptance on BSC testnet, on a THROWAWAY stack of its own: the real pad 3.0 and GangSwap
///         code over a mintable mock WBNB (the raise is 6 BNB, more than the testnet wallet holds) and a mock Agent ID
///         registry. Nothing here is listed in the real testnet pad, its registry or the CLI.
///         PHASE=1: deploy the stack, GangSwap version A, token A (1-minute agent window); then version B becomes the
///                  current one (a create naming A is refused, simulated) and token B is created on it.
///         PHASE=2 (after both windows opened): the trader graduates A and B; each lands in its own version.
///         PHASE=3 (after the boost, stepped in real time from outside): GangSwapRouter trades, fees, everyone sells back.
///         PHASE=4: the REAL testnet pad (PAD, after setGangSwapMigrator; MOCK_WBNB = its WBNB): a GangSwap token through
///                  createWithSalt, a curve buy with BNB on the pad's aggregator entry, and a sell.
/// @dev Env: DEPLOYER_PRIVATE_KEY, PAIR_FACTORY, PHASE; later phases the addresses phase 1 logs (PAD, MOCK_WBNB, TRADER,
///      MIG_A, MIG_B, ROUTER_A, ROUTER_B, TOKEN_A, TOKEN_B). Build gangswap/ first (its artifacts are deployed).
contract GangSwapTestnetAcceptance is Script {
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant G = 6 ether;

    uint256 internal pk;
    address internal dev;
    MockWBNB internal w;
    SharedPlatformFeeBucket internal bucket;
    GangLaunchpad3 internal p;
    Pad3Module internal m;

    error Check(string what);

    function run() external {
        require(block.chainid == 97, "testnet only");
        pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        dev = vm.addr(pk);
        uint256 phase = vm.envUint("PHASE");
        if (phase == 1) return _phase1();
        p = GangLaunchpad3(payable(vm.envAddress("PAD")));
        m = Pad3Module(payable(address(p)));
        w = MockWBNB(vm.envAddress("MOCK_WBNB"));
        bucket = SharedPlatformFeeBucket(address(p.platformBucket()));
        if (phase == 2) {
            _graduate(vm.envAddress("TOKEN_A"), vm.envAddress("MIG_A"));
            _graduate(vm.envAddress("TOKEN_B"), vm.envAddress("MIG_B"));
            console.log("ok: phase 2 (A graduated through version A while B is current; B through B)");
        } else if (phase == 4) {
            _realPad();
        } else {
            _trade(vm.envAddress("TOKEN_A"), vm.envAddress("MIG_A"), vm.envAddress("ROUTER_A"));
            _trade(vm.envAddress("TOKEN_B"), vm.envAddress("MIG_B"), vm.envAddress("ROUTER_B"));
            console.log("ok: phase 3 (router trades as quoted, fee split, all tokens sold back)");
        }
    }

    // ---------------------------------------------------------------- phase 1
    function _phase1() internal {
        vm.startBroadcast(pk);
        _stack();
        (IAccMigrator a, address ra) = _gangSwap();
        m.setGangSwapMigrator(address(a));
        address ta = _create("GangSwap Test A", "GSTA", address(a));
        (IAccMigrator b, address rb) = _gangSwap();
        m.setGangSwapMigrator(address(b));
        vm.stopBroadcast();

        // simulated (rolled back: the prank would use up one of the broadcaster's nonces)
        uint256 snap = vm.snapshotState();
        vm.prank(dev, dev);
        (bool ok, bytes memory ret) =
            address(p).call(abi.encodeCall(IGangSwapPad.createGangSwap, ("x", "x", "", "", G, address(a))));
        vm.revertToState(snap);
        if (
            ok
                || keccak256(ret)
                    != keccak256(abi.encodeWithSelector(IGangSwapPad.GangSwapVersionChanged.selector, address(b)))
        ) {
            revert Check("a create naming the old version must revert GangSwapVersionChanged");
        }

        vm.startBroadcast(pk);
        address tb = _create("GangSwap Test B", "GSTB", address(b));
        WindowTestTrader trader = new WindowTestTrader();
        vm.stopBroadcast();

        if (m.gangSwapMigratorOf(ta) != address(a) || m.gangSwapMigratorOf(tb) != address(b)) revert Check("versions");
        if (p.kindOf(ta) != 4 || p.kindOf(tb) != 4) revert Check("kind 4");
        console.log("PAD", address(p));
        console.log("MOCK_WBNB", address(w));
        console.log("TRADER", address(trader));
        console.log("MIG_A", address(a));
        console.log("MIG_B", address(b));
        console.log("ROUTER_A", ra);
        console.log("ROUTER_B", rb);
        console.log("TOKEN_A", ta);
        console.log("TOKEN_B", tb);
    }

    /// @dev GangFixture's 3.0 stack (no router, no dividend listings for modules this run never uses).
    function _stack() internal {
        address pairFactory = vm.envAddress("PAIR_FACTORY");
        w = new MockWBNB();
        MockAgentId agents = new MockAgentId();
        agents.mint(dev, 1);
        QuoteRegistry qr = new QuoteRegistry(dev);
        bucket = new SharedPlatformFeeBucket(dev, dev);
        SharedDividendVault div = new SharedDividendVault(dev);
        SharedMigrator mig = new SharedMigrator(dev, pairFactory);
        TokenDeployer td = new TokenDeployer(dev);
        GangTaxHandler handler = new GangTaxHandler(dev, address(div), address(bucket), address(0));
        GangPadRegistry reg = GangPadRegistry(
            address(
                new TransparentUpgradeableProxy(
                    address(new GangPadRegistry()),
                    dev,
                    abi.encodeCall(GangPadRegistry.initialize, (dev, new address[](0)))
                )
            )
        );
        MintTokenDeployer flyTd = new MintTokenDeployer(dev);
        FlywheelTaxHandler flyH = new FlywheelTaxHandler(dev, address(div), address(bucket), address(0));
        // creates from here: vault core, fly module, grad module, Pad3Module, implementation, proxy
        address predicted = vm.computeCreateAddress(dev, vm.getNonce(dev) + 5);
        Pad3FlyVaultCore core = new Pad3FlyVaultCore(address(div), predicted);
        address impl = Pad3Impl.deploy(
            Pad3Impl.Deps(
                address(qr), address(div), address(bucket), address(handler), address(td), address(w), address(reg)
            ),
            Pad3Impl.FlyDeps(address(flyH), address(flyTd), address(core))
        );
        p = GangLaunchpad3(
            payable(address(
                    new TransparentUpgradeableProxy(
                        impl, dev, abi.encodeCall(GangLaunchpad3.initialize, (dev, pairFactory))
                    )
                ))
        );
        if (address(p) != predicted) revert Check("the vault core's pad is the proxy");
        m = Pad3Module(payable(address(p)));
        bucket.setOperator(address(p), true);
        bucket.setOperator(address(handler), true);
        div.setLaunchpad(address(p), true);
        div.setMinimumShareBalance(address(p), 10_000 ether);
        div.setOperator(address(handler), address(p));
        div.setExcluded(address(mig), true);
        div.setExcluded(address(bucket), true);
        mig.addLaunchpad(address(p));
        td.setLaunchpad(address(p), true);
        handler.setLaunchpad(address(p));
        p.setAgentGate(true, address(agents));
        p.setMigrator(address(mig));
    }

    /// @dev gangswap/script/DeployGangSwap.s.sol's order, from gangswap/'s own artifacts; listed and an operator.
    function _gangSwap() internal returns (IAccMigrator mig, address router) {
        uint256 n = vm.getNonce(dev);
        address mA = vm.computeCreateAddress(dev, n);
        address bA = vm.computeCreateAddress(dev, n + 1);
        address fA = vm.computeCreateAddress(dev, n + 2);
        address facA = vm.computeCreateAddress(dev, n + 3);
        mig = IAccMigrator(
            _deploy("gangswap/out/GangSwapMigrator.sol/GangSwapMigrator.json", abi.encode(dev, facA, bA, w))
        );
        _deploy("gangswap/out/GangSwapBoost.sol/GangSwapBoost.json", abi.encode(mA, w));
        _deploy("gangswap/out/GangSwapFees.sol/GangSwapFees.json", abi.encode(facA, mA, bucket, w));
        _deploy("gangswap/out/GangSwapPair.sol/GangSwapFactory.json", abi.encode(mA, fA));
        router = _deploy("gangswap/out/GangSwapRouter.sol/GangSwapRouter.json", abi.encode(facA, w));
        if (address(mig) != mA || !mig.wired()) revert Check("wired");
        mig.addLaunchpad(address(p));
        bucket.setOperator(fA, true);
    }

    function _deploy(string memory artifact, bytes memory args) internal returns (address a) {
        a = deployCode(artifact, args);
    }

    function _create(string memory name, string memory symbol, address mig) internal returns (address) {
        return IGangAgentWindow(address(p))
            .createWithAgentWindow(1, abi.encodeCall(IGangSwapPad.createGangSwap, (name, symbol, "", "", G, mig)));
    }

    // ---------------------------------------------------------------- phase 2
    function _graduate(address t, address mig) internal {
        WindowTestTrader trader = WindowTestTrader(vm.envAddress("TRADER"));
        if (!IGangAgentWindow(address(p)).agentWindowOpen(t)) revert Check("not open yet: wait for agentOpenAt");
        (,,, uint256 fee, uint256 left) = p.getTokenInfo(t);
        if (fee != 100 || left != G) revert Check("curve");
        vm.startBroadcast(pk);
        w.mintUnlimited(address(trader), 8 ether);
        uint256 out = trader.buy(p, w, t, 0.5 ether);
        uint256 back = trader.sell(p, t, out / 2);
        trader.buy(p, w, t, 7 ether);
        vm.stopBroadcast();
        if (out == 0 || back == 0) revert Check("curve trades");

        uint8 st;
        address q;
        address pair;
        (st, q, pair, fee, left) = p.getTokenInfo(t);
        if (st != 4 || fee != 100 || left != 0) revert Check("status 4");
        if (IAccFactory(IAccMigrator(mig).factory()).getPair(t, address(w)) != pair) {
            revert Check("the version's pair");
        }
        IAccPair x = IAccPair(pair);
        (uint256 rq, uint256 rt) = _reserves(x);
        uint256 v = x.virtualReserve();
        if (rq != G || rt != IERC20(t).balanceOf(pair) || v != G * rt / 1e27) revert Check("reserves");
        if (w.balanceOf(pair) != G - v) revert Check("real quote");
        (address bp,,, uint128 bv, uint128 bl) = IAccBoost(IAccMigrator(mig).boost()).boosts(t);
        if (bp != pair || bv != v || bl != v) revert Check("boost");
        if (IERC20(pair).balanceOf(DEAD) + IERC20(pair).balanceOf(address(0)) != x.totalSupply()) revert Check("LP");
        console.log("token", t);
        console.log("pair", pair);
        console.log("V", v);
    }

    // ---------------------------------------------------------------- phase 3
    function _trade(address t, address mig, address router_) internal {
        IAccRouter r = IAccRouter(router_);
        address pair = IAccFactory(IAccMigrator(mig).factory()).getPair(t, address(w));
        IAccFees fees = IAccFees(IAccFactory(IAccMigrator(mig).factory()).fees());
        IAccPair x = IAccPair(pair);
        WindowTestTrader trader = WindowTestTrader(vm.envAddress("TRADER"));
        (address bp,,,, uint128 bl) = IAccBoost(IAccMigrator(mig).boost()).boosts(t);
        if (bp != pair || bl != 0 || w.balanceOf(IAccMigrator(mig).boost()) != 0) revert Check("boost not finished");
        address[] memory buy = new address[](2);
        (buy[0], buy[1]) = (address(w), t);
        address[] memory sell = new address[](2);
        (sell[0], sell[1]) = (t, address(w));

        uint256 b0 = IERC20(t).balanceOf(dev);
        uint256 deadline = block.timestamp + 1 hours;
        uint256 q1 = r.getAmountsOut(0.0005 ether, buy)[1];
        vm.startBroadcast(pk);
        r.swapExactETHForTokensSupportingFeeOnTransferTokens{value: 0.0005 ether}(q1, buy, dev, deadline);
        w.mintUnlimited(dev, 1 ether);
        w.approve(router_, type(uint256).max);
        vm.stopBroadcast();
        uint256 q2 = r.getAmountsOut(1 ether, buy)[1];
        vm.broadcast(pk);
        r.swapExactTokensForTokens(1 ether, q2, buy, dev, deadline);
        if (IERC20(t).balanceOf(dev) - b0 != q1 + q2) revert Check("buys as quoted");

        uint256 fee = x.feeAccrued();
        uint256 accrued = bucket.accruedQuote(address(w));
        uint256 had = fees.creatorFeeOf(t);
        vm.broadcast(pk);
        fees.collect(pair);
        uint256 mine = fee * 7000 / 10_000;
        if (fee == 0 || fees.creatorFeeOf(t) - had != mine) revert Check("creator 70%");
        if (bucket.accruedQuote(address(w)) - accrued != fee - mine || fees.pendingPlatform() != 0) {
            revert Check("platform 30%");
        }
        uint256 w0 = w.balanceOf(dev);
        vm.broadcast(pk);
        fees.claim(t, dev);
        if (w.balanceOf(dev) - w0 != had + mine) revert Check("claim");

        // everyone sells back
        vm.startBroadcast(pk);
        trader.sweep(IERC20(t), dev);
        IERC20(t).approve(router_, type(uint256).max);
        vm.stopBroadcast();
        uint256 all = IERC20(t).balanceOf(dev);
        uint256 out = r.getAmountsOut(all, sell)[1];
        vm.broadcast(pk);
        r.swapExactTokensForTokens(all, out, sell, dev, deadline);
        if (IERC20(t).balanceOf(pair) + IERC20(t).balanceOf(DEAD) != 1e27) {
            revert Check("supply in the pair or burned");
        }
        if (w.balanceOf(pair) != x.realQuoteReserve() + x.feeAccrued()) revert Check("pair balance");
        console.log("token", t);
        console.log("virtual reserve", x.virtualReserve());
        console.log("real quote left", x.realQuoteReserve());
        console.log("burned (tokens)", IERC20(t).balanceOf(DEAD) / 1e18);
    }

    // ---------------------------------------------------------------- phase 4
    function _realPad() internal {
        address mig = m.gangSwapMigrator();
        if (mig == address(0)) revert Check("not open");
        Pad3VanityDeployer f = Pad3VanityDeployer(m.vanityDeployer());
        bytes32 hash = f.tokenInitCodeHash("GangSwap Testnet", "GSTN", "", address(0), 0, 0, false);
        (bytes32 salt, address expected) = Pad3VanitySalt.find(address(f), dev, hash);
        bytes memory data = abi.encodeCall(IGangSwapPad.createGangSwap, ("GangSwap Testnet", "GSTN", "", "", G, mig));
        vm.startBroadcast(pk);
        address t = m.createWithSalt(salt, data);
        (uint256 out,) = p.buyTokenAMAP{value: 0.005 ether}(t, dev, 0.005 ether, 0);
        IERC20(t).approve(address(p), out / 2);
        uint256 back = p.sell(t, out / 2, 0);
        vm.stopBroadcast();
        if (t != expected || p.kindOf(t) != 4 || m.gangSwapMigratorOf(t) != mig) revert Check("token");
        (uint8 st,,, uint256 fee,) = p.getTokenInfo(t);
        if (st != 1 || fee != 100 || out == 0 || back == 0) revert Check("curve");
        console.log("token", t);
        console.log("ok: phase 4");
    }

    function _reserves(IAccPair x) internal view returns (uint256 rq, uint256 rt) {
        (uint112 r0, uint112 r1,) = x.getReserves();
        (rq, rt) = x.quoteIs0() ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }
}
