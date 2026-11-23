// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {GangMainnetRefs as M} from "../../config/GangDeployRefs.sol";
import {SharedPlatformFeeBucket} from "../../src/common/SharedPlatformFeeBucket.sol";
import {GangLaunchpad3} from "../../src/gang/GangLaunchpad3.sol";
import {Pad3Module} from "../../src/gang/Pad3Module.sol";
import {Pad3GangSwapStore} from "../../src/gang/Pad3GangSwapStore.sol";
import {Pad3VanityDeployer} from "../../src/gang/Pad3VanityDeployer.sol";
import {GangPadRegistry} from "../../src/gang/GangPadRegistry.sol";
import {GangBond} from "../../src/gang/GangBond.sol";
import {IGangBond} from "../../src/gang/interfaces/IGangBond.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {IGangSwapPad} from "../../src/gang/interfaces/IGangSwapPad.sol";
import {GangGateway} from "../../src/router/GangGateway.sol";
import {GangRouter} from "../../src/router/GangRouter.sol";
import {Pad3VanitySalt} from "../../script/Pad3VanitySalt.sol";
import {DeployGang} from "../../script/DeployGang.s.sol";
import {GangRouterDeployLib as R} from "../../script/GangRouterDeployLib.sol";
import {WindowBatchHarness} from "./Pad3AgentWindowFork.t.sol";

interface IWBNBGs {
    function deposit() external payable;
}

interface IGsMigrator {
    function addLaunchpad(address) external;
    function wired() external view returns (bool);
}

interface IGsPair {
    function getReserves() external view returns (uint112, uint112, uint32);
    function quoteIs0() external view returns (bool);
    function virtualReserve() external view returns (uint256);
    function realQuoteReserve() external view returns (uint256);
    function feeAccrued() external view returns (uint256);
    function totalSupply() external view returns (uint256);
}

interface IGsBoost {
    function step(address) external returns (uint256, uint256);
    function boosts(address) external view returns (address, uint64, bool, uint128, uint128);
}

interface IGsFees {
    function collect(address) external returns (uint256);
    function claim(address, address) external returns (uint256);
    function creatorFeeOf(address) external view returns (uint256);
    function pendingPlatform() external view returns (uint256);
}

interface IGsRouter {
    function getAmountsOut(uint256, address[] calldata) external view returns (uint256[] memory);
    function swapExactETHForTokens(uint256, address[] calldata, address, uint256)
        external
        payable
        returns (uint256[] memory);
    function swapExactETHForTokensSupportingFeeOnTransferTokens(uint256, address[] calldata, address, uint256)
        external
        payable;
    function swapExactTokensForETH(uint256, uint256, address[] calldata, address, uint256)
        external
        returns (uint256[] memory);
}

/// @notice GangSwap on a mainnet fork (docs/SPEC-GANGSWAP-2026-11-22.md §12, §13), in the rollout's order, with the
///         LIVE 3.0 GangRouter and the LIVE GangGateway left as they are: UpgradeGangLaunchpad3 (with the registry) run
///         against the live proxy and its upgrades sent as the Safe; createGangSwap still closed; the GangSwap set
///         deployed on the real WBNB and fee bucket, listed, and opened with setGangSwapMigrator alone. Then a token
///         through createWithSalt: curve trades on the pad, its aggregator entry and the live router (the live gateway
///         refuses it), graduation, the boost, GangSwapRouter, the fees into the real bucket, and everyone selling
///         back; a kind-1 token created BEFORE the upgrade still graduates to the real Pancake V2 pair and still trades
///         through the live gateway; the live GangBond refuses the GangSwap token. Last, the optional GangRouter upgrade
///         through its timelock, whose pool entries refuse it. Agent IDs are mocked per address on this fork only. No
///         broadcast.
/// @dev BSC_RPC_URL required (skipped if absent; an archive node with BSC_FORK_BLOCK: the run is long). Build the fork
///      first (`forge build --root gangswap`). Link the live PoolCheck:
///      --libraries src/launchpad-v2/PoolCheck.sol:PoolCheck:0xd2B159820749f178503E4faBCB18A7Ae4492bDb3
contract Pad3GangSwapForkTest is Test {
    address internal constant PAD3 = 0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29;
    address internal constant PAD1 = 0x15CFD2dc8278Fb87a1783ef42111618E20874365;
    address internal constant ROUTER3 = 0xec9717E5C68b9F18fA76D3961C9Cd7e67b5E61e7;
    address internal constant BOND = 0x830b38F695Ca1bCbdD313CD5AA5943e2125Be9D6;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 internal constant G = 6 ether;

    GangLaunchpad3 internal p = GangLaunchpad3(payable(PAD3));
    Pad3Module internal m = Pad3Module(payable(PAD3));
    GangPadRegistry internal reg = GangPadRegistry(M.PAD_REGISTRY);
    GangGateway internal gw = GangGateway(payable(M.GANG_GATEWAY));
    GangRouter internal router3 = GangRouter(payable(ROUTER3));
    uint256 internal _n;
    address[] internal _holders;

    IGsMigrator internal mig;
    IGsBoost internal boost;
    IGsFees internal fees;
    IGsRouter internal gsRouter;

    function test_fork_upgradeOpenGraduateTrade() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 forkBlock = vm.envOr("BSC_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);

        // before anything: a kind-1 token on the live code, part bought
        address oldCreator = _actor();
        address old = _saltCreate(
            oldCreator,
            "Old",
            abi.encodeCall(
                GangLaunchpad3.createWithGradTarget,
                ("Old", "GSF", "", "meta", address(0), address(0), _noTax(), uint256(G))
            )
        );
        _buy(_actor(), old, 0.2 ether);
        assertEq(p.kindOf(old), 1);
        bytes32 oldRecord = _record(old);

        _upgradePad();
        assertEq(_record(old), oldRecord, "the live token's record is unchanged");

        // closed until the last batch
        bytes memory closedData = _gsData();
        vm.prank(oldCreator, oldCreator);
        vm.expectRevert(IGangSwapPad.GangSwapNotOpen.selector);
        m.createWithSalt(bytes32(0), closedData);

        _deployGangSwap();
        vm.record();
        vm.prank(M.OWNER_SAFE);
        m.setGangSwapMigrator(address(mig));
        (, bytes32[] memory writes) = vm.accesses(PAD3);
        assertEq(writes.length, 1, "only the GangSwap namespace");
        assertEq(writes[0], Pad3GangSwapStore.SLOT);
        assertEq(m.gangSwapMigrator(), address(mig));

        address creator = _actor();
        address t = _saltCreate(creator, "Swap", _gsData());
        assertEq(p.kindOf(t), 4);
        (address rp, uint8 kind) = reg.lookup(t);
        assertEq(rp, PAD3);
        assertEq(kind, 4);
        _curveTrades(t);
        address pair = _graduate(t);
        _nextUpgrade(t);
        _afterGraduation(t, pair, creator);

        // the kind-1 token from before the upgrade, and a new one, still go to Pancake V2
        {
            address a = _actor();
            (uint8 s,,,,) = gw.getTokenInfo(old);
            assertEq(s, 1);
            vm.prank(a, a);
            (uint256 out,) = gw.buyTokenAMAP{value: 0.02 ether}(old, a, 0.02 ether, 0);
            assertGt(out, 0, "kind 1 through the live gateway");
        }
        _pancake(old);
        _pancake(
            _saltCreate(
                oldCreator,
                "New",
                abi.encodeCall(
                    GangLaunchpad3.createWithGradTarget,
                    ("New", "GSF", "", "meta", address(0), address(0), _noTax(), uint256(G))
                )
            )
        );

        // optional, any time later: the 3.0 router's new build refuses it, as token and as middle hop
        address live = R.implementationOf(ROUTER3);
        _timelocked(ROUTER3, address(new GangRouter()));
        assertTrue(R.implementationOf(ROUTER3) != live);
        assertEq(address(router3.pad()), PAD3);
        address w = _actor();
        vm.startPrank(w, w);
        vm.expectRevert(GangRouter.GangSwapToken.selector);
        router3.poolBuyBNB{value: 0.01 ether}(t, M.WBNB, 0, block.timestamp);
        vm.expectRevert(GangRouter.GangSwapToken.selector);
        router3.poolBuyBNB{value: 0.01 ether}(M.USDT, t, 0, block.timestamp);
        assertGt(router3.poolBuyBNB{value: 0.01 ether}(old, M.WBNB, 0, block.timestamp), 0);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- the rollout (§13)
    function _timelocked(address proxy, address impl) internal {
        address admin = R.adminOf(proxy);
        TimelockController tl = TimelockController(payable(ProxyAdmin(admin).owner()));
        bytes memory call =
            abi.encodeCall(ProxyAdmin.upgradeAndCall, (ITransparentUpgradeableProxy(proxy), impl, bytes("")));
        vm.startPrank(M.OWNER_SAFE);
        tl.schedule(admin, 0, call, bytes32(0), keccak256("gangswap fork"), R.MAINNET_MIN_DELAY);
        vm.warp(vm.getBlockTimestamp() + R.MAINNET_MIN_DELAY + 1);
        tl.execute(admin, 0, call, bytes32(0), keccak256("gangswap fork"));
        vm.stopPrank();
        assertEq(R.implementationOf(proxy), impl);
    }

    function _upgradePad() internal {
        (, uint256 key) = makeAddrAndKey("gangswap fork deployer");
        vm.deal(vm.addr(key), 10 ether);
        _env(key);
        WindowBatchHarness up = new WindowBatchHarness();
        vm.pauseGasMetering();
        up.run();
        vm.resumeGasMetering();
        address admin = R.adminOf(PAD3);
        address next = up.deployedImpl();
        vm.record();
        vm.prank(M.OWNER_SAFE);
        ProxyAdmin(admin).upgradeAndCall(ITransparentUpgradeableProxy(PAD3), next, "");
        (, bytes32[] memory writes) = vm.accesses(PAD3);
        assertEq(writes.length, 1, "only the implementation slot");
        assertEq(writes[0], R.IMPLEMENTATION_SLOT);
        address regAdmin = R.adminOf(M.PAD_REGISTRY);
        address regImpl = up.regImpl();
        vm.prank(M.OWNER_SAFE);
        ProxyAdmin(regAdmin).upgradeAndCall(ITransparentUpgradeableProxy(M.PAD_REGISTRY), regImpl, "");
        assertEq(m.gangSwapMigrator(), address(0), "closed after the upgrade");
    }

    /// @dev A later upgrade, with GangSwap open and a graduated and a curve GangSwap token: the script passes it, and
    ///      refuses one after which the pad's migrator or a token's reads differently, or GangSwap is not served (the
    ///      upgraded answers are mocked: the implementation itself is checked byte for byte before).
    function _nextUpgrade(address t) internal {
        uint256 snap = vm.snapshotState();
        _saltCreate(_actor(), "Swap", _gsData());
        (, uint256 key) = makeAddrAndKey("gangswap fork deployer");
        _env(key);
        vm.setEnv("PAD3_REGISTRY_UPGRADE", "false");
        vm.pauseGasMetering();
        new WindowBatchHarness().run();
        assertEq(_refused(0, t), "upgrade: GangSwap state changed");
        assertEq(_refused(1, t), "upgrade: GangSwap state changed");
        assertEq(_refused(2, t), "upgrade: GangSwap not served");
        vm.resumeGasMetering();
        vm.revertToState(snap);
    }

    function _refused(uint256 what, address t) internal returns (string memory why) {
        bytes[] memory rets = new bytes[](2);
        (rets[0], rets[1]) = (abi.encode(address(mig)), abi.encode(address(0xdead)));
        if (what == 0) vm.mockCalls(PAD3, abi.encodeCall(IGangSwapPad.gangSwapMigrator, ()), rets);
        else if (what == 1) vm.mockCalls(PAD3, abi.encodeCall(IGangSwapPad.gangSwapMigratorOf, (t)), rets);
        else vm.mockCall(PAD3, abi.encodeCall(IGangSwapPad.gangSwapMigratorOf, (PAD3)), "");
        try new WindowBatchHarness().run() {}
        catch (bytes memory ret) {
            assertEq(bytes4(ret), DeployGang.WiringCheck.selector);
            assembly ("memory-safe") {
                mstore(add(ret, 4), sub(mload(ret), 4))
                ret := add(ret, 4)
            }
            why = abi.decode(ret, (string));
        }
        vm.clearMockedCalls();
        for (uint256 i; i < _n; i++) {
            _mockAgent(makeAddr(string.concat("gangswap fork actor ", vm.toString(i))));
        }
    }

    function _deployGangSwap() internal {
        SharedPlatformFeeBucket bucket = SharedPlatformFeeBucket(address(p.platformBucket()));
        uint256 n = vm.getNonce(address(this));
        address mA = vm.computeCreateAddress(address(this), n);
        address bA = vm.computeCreateAddress(address(this), n + 1);
        address fA = vm.computeCreateAddress(address(this), n + 2);
        address facA = vm.computeCreateAddress(address(this), n + 3);
        mig = IGsMigrator(
            deployCode(
                "gangswap/out/GangSwapMigrator.sol/GangSwapMigrator.json", abi.encode(M.OWNER_SAFE, facA, bA, M.WBNB)
            )
        );
        boost = IGsBoost(deployCode("gangswap/out/GangSwapBoost.sol/GangSwapBoost.json", abi.encode(mA, M.WBNB)));
        fees = IGsFees(
            deployCode("gangswap/out/GangSwapFees.sol/GangSwapFees.json", abi.encode(facA, mA, address(bucket), M.WBNB))
        );
        address fac = deployCode("gangswap/out/GangSwapPair.sol/GangSwapFactory.json", abi.encode(mA, fA));
        gsRouter = IGsRouter(deployCode("gangswap/out/GangSwapRouter.sol/GangSwapRouter.json", abi.encode(fac, M.WBNB)));
        assertTrue(mig.wired());
        vm.prank(M.OWNER_SAFE);
        mig.addLaunchpad(PAD3);
        address bucketOwner = bucket.owner();
        vm.prank(bucketOwner);
        bucket.setOperator(address(fees), true);
    }

    // ---------------------------------------------------------------- the token
    function _curveTrades(address t) internal {
        (uint8 s,,, uint256 fee, uint256 left) = p.getTokenInfo(t);
        assertEq(s, 1);
        assertEq(fee, 100);
        assertEq(left, G);
        address a = _actor();
        uint256 got = _buy(a, t, 0.02 ether);
        vm.startPrank(a, a);
        IERC20(t).approve(PAD3, got / 2);
        p.sell(t, got / 2, 0);
        vm.stopPrank();

        // the pad's aggregator entry, the gateway (as quoted), the 3.0 router
        a = _actor();
        (,, uint256 est,,,,,) = p.tryBuy(t, a, 0, 0.02 ether);
        vm.prank(a, a);
        (uint256 out,) = p.buyTokenAMAP{value: 0.02 ether}(t, a, 0.02 ether, 0);
        assertEq(out, est);
        a = _actor();
        // the live gateway does not know kind 4: closed, not mis-routed
        (s,,,,) = gw.getTokenInfo(t);
        assertEq(s, 0);
        (,, est,,,,,) = gw.tryBuy(t, a, 0, 0.02 ether);
        assertEq(est, 0);
        vm.prank(a, a);
        vm.expectRevert();
        gw.buyTokenAMAP{value: 0.02 ether}(t, a, 0.02 ether, 0);
        a = _actor();
        vm.prank(a, a);
        assertGt(router3.v3BuyBNB{value: 0.02 ether}(t, 0, block.timestamp), 0);

        // the live bond refuses kind 4
        GangBond bond = GangBond(payable(BOND));
        vm.prank(a, a);
        vm.expectRevert(IGangBond.UnknownToken.selector);
        bond.post{value: 0.1 ether}(t, 0.1 ether, 1 ether, 7 days);
    }

    function _graduate(address t) internal returns (address pair) {
        for (uint256 i; i < 200; i++) {
            (uint8 s,,,,) = p.getTokenInfo(t);
            if (s != 1) break;
            _buy(_actor(), t, 0.2 ether);
        }
        uint8 st;
        uint256 fee;
        uint256 left;
        (st,, pair, fee, left) = p.getTokenInfo(t);
        assertEq(st, 4, "STATUS_GANGSWAP");
        assertEq(fee, 100);
        assertEq(left, 0);
        (uint8 gs,,,,) = gw.getTokenInfo(t);
        assertEq(gs, 0);

        IGsPair x = IGsPair(pair);
        uint256 v = x.virtualReserve();
        (uint256 rq, uint256 rt) = _reserves(x);
        assertEq(rq, G, "effective quote = the raise");
        assertEq(rt, IERC20(t).balanceOf(pair));
        assertEq(v, (G * rt) / 1e27);
        assertEq(IERC20(M.WBNB).balanceOf(pair), G - v);
        (address bp,,,, uint128 boostLeft) = boost.boosts(t);
        assertEq(bp, pair);
        assertEq(boostLeft, v);
        assertEq(IERC20(M.WBNB).balanceOf(address(boost)), v);
        assertEq(IERC20(pair).balanceOf(DEAD) + IERC20(pair).balanceOf(address(0)), x.totalSupply(), "LP burned");
    }

    function _afterGraduation(address t, address pair, address creator) internal {
        IGsPair x = IGsPair(pair);
        address a = _actor();
        // the boost: 40 steps on the real WBNB
        uint256 dead = IERC20(t).balanceOf(DEAD);
        uint256 steps;
        uint256 left = 1;
        while (left != 0) {
            vm.warp(vm.getBlockTimestamp() + 8);
            boost.step(t);
            steps++;
            (,,,, uint128 l) = boost.boosts(t);
            left = l;
        }
        emit log_named_uint("boost steps", steps);
        emit log_named_uint("boost burned (tokens)", (IERC20(t).balanceOf(DEAD) - dead) / 1e18);
        assertEq(IERC20(M.WBNB).balanceOf(address(boost)), 0);

        // GangSwapRouter: buy as quoted, plain and fee-on-transfer path; sell as quoted
        address[] memory buy = new address[](2);
        (buy[0], buy[1]) = (M.WBNB, t);
        address[] memory sell = new address[](2);
        (sell[0], sell[1]) = (t, M.WBNB);
        uint256 q = gsRouter.getAmountsOut(0.5 ether, buy)[1];
        vm.startPrank(a, a);
        gsRouter.swapExactETHForTokens{value: 0.5 ether}(q, buy, a, block.timestamp);
        assertEq(IERC20(t).balanceOf(a), q);
        uint256 q2 = gsRouter.getAmountsOut(0.1 ether, buy)[1];
        gsRouter.swapExactETHForTokensSupportingFeeOnTransferTokens{value: 0.1 ether}(q2, buy, a, block.timestamp);
        assertEq(IERC20(t).balanceOf(a), q + q2, "fee-on-transfer path as quoted");
        vm.stopPrank();

        // fees: 70% creator, 30% into the real bucket
        uint256 fee = x.feeAccrued();
        SharedPlatformFeeBucket bucket = SharedPlatformFeeBucket(address(p.platformBucket()));
        uint256 accrued = bucket.accruedQuote(M.WBNB);
        assertEq(fees.collect(pair), fee);
        uint256 mine = (fee * 7000) / 10_000;
        assertEq(fees.creatorFeeOf(t), mine);
        assertEq(fees.pendingPlatform(), 0);
        assertEq(bucket.accruedQuote(M.WBNB) - accrued, fee - mine);
        uint256 w0 = IERC20(M.WBNB).balanceOf(creator);
        vm.prank(creator);
        fees.claim(t, creator);
        assertEq(IERC20(M.WBNB).balanceOf(creator) - w0, mine);

        // everyone sells back
        for (uint256 i; i < _holders.length; i++) {
            uint256 bal = IERC20(t).balanceOf(_holders[i]);
            if (bal == 0) continue;
            vm.startPrank(_holders[i], _holders[i]);
            IERC20(t).approve(address(gsRouter), bal);
            gsRouter.swapExactTokensForETH(bal, 0, sell, _holders[i], block.timestamp);
            vm.stopPrank();
        }
        emit log_named_decimal_uint("real quote left in the pair", x.realQuoteReserve(), 18);
        emit log_named_decimal_uint("virtual reserve", x.virtualReserve(), 18);
        assertEq(IERC20(M.WBNB).balanceOf(pair), x.realQuoteReserve() + x.feeAccrued());
        assertLt(x.realQuoteReserve(), 0.1 ether);
        assertEq(
            IERC20(t).balanceOf(pair) + IERC20(t).balanceOf(DEAD), 1e27, "the whole supply is in the pair or burned"
        );
    }

    function _pancake(address t) internal {
        for (uint256 i; i < 200; i++) {
            (uint8 s0,,,,) = p.getTokenInfo(t);
            if (s0 != 1) break;
            _buy(_actor(), t, 0.2 ether);
        }
        (uint8 s,, address pair,,) = p.getTokenInfo(t);
        assertEq(s, 2, "Pancake V2");
        (bool ok, bytes memory ret) =
            M.PANCAKE_V2_FACTORY.staticcall(abi.encodeWithSignature("getPair(address,address)", t, M.WBNB));
        assertTrue(ok);
        assertEq(abi.decode(ret, (address)), pair);
        assertEq(IERC20(M.WBNB).balanceOf(pair), G, "the whole raise");
        assertEq(IERC20(t).balanceOf(pair), 200_000_000 ether);
        // the 3.0 router's pool entry still serves it
        address a = _actor();
        vm.prank(a, a);
        assertGt(router3.poolBuyBNB{value: 0.01 ether}(t, M.WBNB, 0, block.timestamp), 0);
    }

    // ---------------------------------------------------------------- helpers
    function _reserves(IGsPair x) internal view returns (uint256 rq, uint256 rt) {
        (uint112 r0, uint112 r1,) = x.getReserves();
        (rq, rt) = x.quoteIs0() ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }

    function _record(address t) internal view returns (bytes32) {
        (bool ok, bytes memory ret) = PAD3.staticcall(abi.encodeWithSignature("curves(address)", t));
        assertTrue(ok);
        (uint8 s, address q, address pr, uint256 f, uint256 l) = p.getTokenInfo(t);
        return keccak256(abi.encode(ret, s, q, pr, f, l));
    }

    function _noTax() internal pure returns (IGangLaunchpad.TaxConfig memory) {}

    function _gsData() internal view returns (bytes memory) {
        return
            abi.encodeCall(IGangSwapPad.createGangSwap, ("Swap", "GSF", "", "meta", uint256(G), m.gangSwapMigrator()));
    }

    function _saltCreate(address creator, string memory name, bytes memory data) internal returns (address t) {
        address factory = m.vanityDeployer();
        bytes32 hash = Pad3VanityDeployer(factory).tokenInitCodeHash(name, "GSF", "meta", address(0), 0, 0, false);
        (bytes32 salt, address expected) = Pad3VanitySalt.find(factory, creator, hash);
        vm.prank(creator, creator);
        t = m.createWithSalt(salt, data);
        assertEq(t, expected);
    }

    /// @dev A fresh Agent wallet (its Agent ID mocked on this fork).
    function _actor() internal returns (address a) {
        a = makeAddr(string.concat("gangswap fork actor ", vm.toString(_n++)));
        vm.deal(a, 20 ether);
        _mockAgent(a);
        _holders.push(a);
    }

    function _mockAgent(address a) internal {
        vm.mockCall(address(p.agentIdRegistry()), abi.encodeCall(IERC721.balanceOf, (a)), abi.encode(uint256(1)));
    }

    function _buy(address who, address t, uint256 amt) internal returns (uint256 out) {
        vm.startPrank(who, who);
        IWBNBGs(M.WBNB).deposit{value: amt}();
        IERC20(M.WBNB).approve(PAD3, amt);
        out = p.buy(t, amt, 0);
        vm.stopPrank();
    }

    function _env(uint256 key) private {
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(key));
        vm.setEnv("GANG_PAD", vm.toString(PAD1));
        vm.setEnv("GANG_PAD3", vm.toString(PAD3));
        vm.setEnv("GANG_ROUTER3", vm.toString(ROUTER3));
        vm.setEnv("OWNER", vm.toString(M.OWNER_SAFE));
        vm.setEnv("KEEPER", vm.toString(M.KEEPER));
        vm.setEnv("GANG_GATEWAY", vm.toString(M.GANG_GATEWAY));
        vm.setEnv("GANG_PAD_REGISTRY", vm.toString(M.PAD_REGISTRY));
        vm.setEnv("PAD3_ABCD_DEPLOYER", vm.toString(address(0)));
        vm.setEnv("PAD3_BASE_VAULT_IMPL", vm.toString(address(0)));
        vm.setEnv("PAD3_GRAD_REWARD", "false");
        vm.setEnv("PAD3_GRAD_HANDLER_ADMIN", vm.toString(address(0)));
        vm.setEnv("PAD3_GRAD_COUNTDOWN_FACTORY", vm.toString(address(0)));
        vm.setEnv("PAD3_IMPL", vm.toString(address(0)));
        vm.setEnv("PAD3_REGISTRY_UPGRADE", "true");
        vm.setEnv("PAD_REGISTRY_IMPL", vm.toString(address(0)));
        vm.setEnv("PAD3_INIT_CALL", "0x");
        vm.setEnv("PAD3_FLY_HANDLER", vm.toString(address(0)));
        vm.setEnv("PAD3_FLY_TOKEN_DEPLOYER", vm.toString(address(0)));
        vm.setEnv("PAD3_FLY_VAULT_CORE", vm.toString(address(0)));
        vm.setEnv("CALLERS", "");
        vm.setEnv("PAD3_NEW", "false");
        vm.setEnv("GANG_MAINNET_OK", "true");
        vm.setEnv("CUTOVER", "false");
        vm.setEnv("RECIPIENT", vm.toString(address(0)));
        vm.setEnv("TWAP_WINDOW", vm.toString(GangLaunchpad3(payable(PAD1)).twapWindow()));
    }
}
