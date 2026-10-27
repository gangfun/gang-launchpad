// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy,
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {GangFixture} from "../utils/GangFixture.sol";
import {GangRouter} from "../../src/router/GangRouter.sol";
import {GangRouterDeployLib as R} from "../../script/GangRouterDeployLib.sol";
import {GangRouterV2Mock, GangRouterDrainMock, ReenteringBuyer} from "../mocks/GangRouterV2Mock.sol";

/// @notice The upgradeable router (AUDIT-BRIEF §21): implementation locked, proxy initialized once, ProxyAdmin owned by
///         the 48 h timelock and by nothing else, only the Safe (`owner` here) proposes / executes / cancels, an upgrade
///         keeps pad / WBNB and the pad's listing, the router never keeps a balance, and the reentrancy guard works in
///         proxy storage that starts at 0.
contract GangRouterUpgradeTest is GangFixture {
    address internal safe;
    address internal stranger = makeAddr("stranger");
    TimelockController internal tl;
    ProxyAdmin internal admin;

    function setUp() public {
        _deployGang(makeAddr("keeper"));
        safe = owner; // the fixture's owner plays the Safe: pad owner and the timelock's only role holder
        tl = TimelockController(payable(routerStack.timelock));
        admin = ProxyAdmin(routerStack.proxyAdmin);
    }

    // ---------------------------------------------------------------- helpers
    function _upgradeCall(address impl, bytes memory data) internal view returns (bytes memory) {
        return abi.encodeCall(ProxyAdmin.upgradeAndCall, (ITransparentUpgradeableProxy(address(router)), impl, data));
    }

    function _schedule(bytes memory call, bytes32 salt) internal returns (bytes32 id) {
        vm.prank(safe);
        tl.schedule(address(admin), 0, call, bytes32(0), salt, R.MAINNET_MIN_DELAY);
        id = tl.hashOperation(address(admin), 0, call, bytes32(0), salt);
    }

    function _execute(bytes memory call, bytes32 salt) internal {
        vm.prank(safe);
        tl.execute(address(admin), 0, call, bytes32(0), salt);
    }

    /// @dev Schedule as the Safe, wait 48 h, execute as the Safe.
    function _upgrade(address impl, bytes memory data) internal {
        bytes memory call = _upgradeCall(impl, data);
        _schedule(call, keccak256(abi.encode(impl)));
        vm.warp(vm.getBlockTimestamp() + R.MAINNET_MIN_DELAY);
        _execute(call, keccak256(abi.encode(impl)));
    }

    function _assertRouterEmpty() internal view {
        assertEq(wbnb.balanceOf(address(router)), 0, "router WBNB");
        assertEq(quoteTok.balanceOf(address(router)), 0, "router quote");
        assertEq(address(router).balance, 0, "router BNB");
    }

    function _wbnbCurve() internal returns (address t) {
        t = _createV3(_newAgent(), address(0), _tax(200, 200, 5000, treasury));
    }

    // ---------------------------------------------------------------- the deployed shape
    function test_shape_asDeployed() public view {
        R.check(
            routerStack,
            R.Expect({
                pad: address(pad),
                wbnb: address(wbnb),
                pancakeRouter: pancakeRouter,
                pancakeFactory: address(pairFactory),
                safe: safe,
                deployer: address(this),
                minDelay: 48 hours,
                mainnet: false
            })
        );
        assertEq(tl.getMinDelay(), 48 hours);
        assertEq(admin.owner(), address(tl));
        assertEq(R.implementationOf(address(router)), routerStack.impl);
        assertTrue(pad.routers(address(router)), "the pad lists the proxy");
        assertFalse(pad.routers(routerStack.impl), "never the implementation");
        // storage layout: slot 0 guard flag, slot 1 pad, slot 2 wbnb
        assertEq(address(uint160(uint256(vm.load(address(router), bytes32(uint256(1)))))), address(pad), "slot 1");
        assertEq(address(uint160(uint256(vm.load(address(router), bytes32(uint256(2)))))), address(wbnb), "slot 2");
        assertEq(address(uint160(uint256(vm.load(address(router), bytes32(uint256(3)))))), pancakeRouter, "slot 3");
        for (uint256 i = 4; i <= 51; i++) {
            assertEq(vm.load(address(router), bytes32(i)), bytes32(0), "gap and beyond empty");
        }
    }

    // ---------------------------------------------------------------- initialization
    function test_impl_cannotBeInitialized() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        GangRouter(payable(routerStack.impl)).initialize(address(pad), address(wbnb), pancakeRouter);
        // nor a fresh one: the constructor locks every implementation
        GangRouter fresh = new GangRouter();
        vm.prank(safe);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        fresh.initialize(address(pad), address(wbnb), pancakeRouter);
        (uint64 v,) = R.initState(address(fresh));
        assertEq(v, type(uint64).max, "locked");
        assertEq(address(fresh.pad()), address(0));
    }

    function test_proxy_cannotReinitialize() public {
        address[3] memory who = [stranger, safe, address(tl)];
        for (uint256 i; i < who.length; i++) {
            vm.prank(who[i]);
            vm.expectRevert(Initializable.InvalidInitialization.selector);
            router.initialize(stranger, stranger, stranger);
        }
        assertEq(address(router.pad()), address(pad));
        assertEq(router.wbnb(), address(wbnb));
        assertEq(address(router.pancakeRouter()), pancakeRouter);
        (uint64 v, bool initializing) = R.initState(address(router));
        assertEq(v, 1);
        assertFalse(initializing);
    }

    // ---------------------------------------------------------------- who can upgrade
    function test_proxyAdmin_onlyListensToTheTimelock() public {
        GangRouterV2Mock v2 = new GangRouterV2Mock();
        bytes memory call = _upgradeCall(address(v2), "");
        address[3] memory who = [safe, stranger, address(this)];
        for (uint256 i; i < who.length; i++) {
            vm.prank(who[i]);
            (bool ok, bytes memory err) = address(admin).call(call);
            assertFalse(ok);
            assertEq(err, abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, who[i]));
            vm.prank(who[i]);
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, who[i]));
            admin.transferOwnership(who[i]);
            vm.prank(who[i]);
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, who[i]));
            admin.renounceOwnership();
        }
        // the proxy's own upgrade entry answers its ProxyAdmin only: anyone else (the timelock included) falls through
        // to the router, which has no such function
        address[3] memory direct = [safe, stranger, address(tl)];
        for (uint256 i; i < direct.length; i++) {
            vm.prank(direct[i]);
            vm.expectRevert();
            ITransparentUpgradeableProxy(address(router)).upgradeToAndCall(address(v2), "");
        }
        // and the ProxyAdmin cannot use the router: only upgradeToAndCall
        vm.prank(address(admin));
        vm.expectRevert(TransparentUpgradeableProxy.ProxyDeniedAdminAccess.selector);
        router.pad();
        assertEq(R.implementationOf(address(router)), routerStack.impl, "unchanged");
    }

    function test_timelock_onlySafeProposes() public {
        GangRouterV2Mock v2 = new GangRouterV2Mock();
        bytes memory call = _upgradeCall(address(v2), "");
        bytes32 role = tl.PROPOSER_ROLE();
        address[3] memory who = [stranger, address(this), address(admin)];
        for (uint256 i; i < who.length; i++) {
            vm.prank(who[i]);
            vm.expectRevert(
                abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, who[i], role)
            );
            tl.schedule(address(admin), 0, call, bytes32(0), bytes32(0), 48 hours);
        }
        // the Safe cannot shorten the wait either
        vm.prank(safe);
        vm.expectRevert(
            abi.encodeWithSelector(TimelockController.TimelockInsufficientDelay.selector, 48 hours - 1, 48 hours)
        );
        tl.schedule(address(admin), 0, call, bytes32(0), bytes32(0), 48 hours - 1);
    }

    function test_timelock_48hThenExecute() public {
        GangRouterV2Mock v2 = new GangRouterV2Mock();
        bytes memory call = _upgradeCall(address(v2), abi.encodeCall(GangRouterV2Mock.initializeV2, (7)));
        uint256 t0 = vm.getBlockTimestamp();
        bytes32 id = _schedule(call, bytes32(0));
        assertTrue(tl.isOperationPending(id));
        assertEq(tl.getTimestamp(id), t0 + 48 hours);

        // not yet: right away and one second before
        vm.prank(safe);
        vm.expectRevert();
        tl.execute(address(admin), 0, call, bytes32(0), bytes32(0));
        vm.warp(t0 + 48 hours - 1);
        vm.prank(safe);
        vm.expectRevert(
            abi.encodeWithSelector(
                TimelockController.TimelockUnexpectedOperationState.selector,
                id,
                bytes32(1 << uint8(TimelockController.OperationState.Ready))
            )
        );
        tl.execute(address(admin), 0, call, bytes32(0), bytes32(0));

        // ready: only the Safe executes
        vm.warp(t0 + 48 hours);
        bytes32 exec = tl.EXECUTOR_ROLE();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, exec)
        );
        tl.execute(address(admin), 0, call, bytes32(0), bytes32(0));
        _execute(call, bytes32(0));
        assertTrue(tl.isOperationDone(id));
        assertEq(R.implementationOf(address(router)), address(v2), "upgraded");
        // once only
        vm.prank(safe);
        vm.expectRevert();
        tl.execute(address(admin), 0, call, bytes32(0), bytes32(0));
    }

    function test_timelock_safeCancels() public {
        GangRouterV2Mock v2 = new GangRouterV2Mock();
        bytes memory call = _upgradeCall(address(v2), "");
        bytes32 id = _schedule(call, bytes32(0));
        bytes32 cancelRole = tl.CANCELLER_ROLE();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, cancelRole)
        );
        tl.cancel(id);
        vm.prank(safe);
        tl.cancel(id);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.prank(safe);
        vm.expectRevert();
        tl.execute(address(admin), 0, call, bytes32(0), bytes32(0));
        assertEq(R.implementationOf(address(router)), routerStack.impl);
    }

    /// No admin: roles and the delay change only through a timelocked proposal of the timelock to itself.
    function test_timelock_rolesOnlyThroughItself() public {
        bytes32 proposer = tl.PROPOSER_ROLE();
        bytes32 adminRole = tl.DEFAULT_ADMIN_ROLE();
        vm.prank(safe);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, safe, adminRole)
        );
        tl.grantRole(proposer, stranger);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockUnauthorizedCaller.selector, safe));
        tl.updateDelay(0);

        bytes memory grant = abi.encodeCall(IAccessControl.grantRole, (proposer, stranger));
        vm.prank(safe);
        tl.schedule(address(tl), 0, grant, bytes32(0), bytes32(0), 48 hours);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.prank(safe);
        tl.execute(address(tl), 0, grant, bytes32(0), bytes32(0));
        assertTrue(tl.hasRole(proposer, stranger), "granted by the timelock itself, 48 h later");
    }

    // ---------------------------------------------------------------- an upgrade
    function test_upgrade_keepsStateAndListing_newLogicLive() public {
        address t = _wbnbCurve();
        address buyer = _newAgent();
        vm.prank(buyer);
        uint256 before = router.v3BuyBNB{value: 0.01 ether}(t, 1, vm.getBlockTimestamp());
        // v1 has no version()
        (bool ok,) = address(router).call(abi.encodeCall(GangRouterV2Mock.version, ()));
        assertFalse(ok);

        GangRouterV2Mock v2 = new GangRouterV2Mock();
        _upgrade(address(v2), abi.encodeCall(GangRouterV2Mock.initializeV2, (7)));

        GangRouterV2Mock r2 = GangRouterV2Mock(payable(address(router)));
        assertEq(r2.version(), 2, "new logic");
        assertEq(r2.v2Value(), 7, "reinitializer ran through upgradeAndCall");
        assertEq(address(r2.pad()), address(pad), "pad kept");
        assertEq(r2.wbnb(), address(wbnb), "wbnb kept");
        assertEq(address(r2.pancakeRouter()), pancakeRouter, "pancakeRouter kept");
        // the new variable took slot 4 from the gap; slots 0–3 did not move, the rest of the gap is still empty
        assertEq(uint256(vm.load(address(router), bytes32(uint256(4)))), 7, "v2Value at slot 4");
        for (uint256 i = 5; i <= 51; i++) {
            assertEq(vm.load(address(router), bytes32(i)), bytes32(0), "gap 5-50 and beyond empty");
        }
        assertEq(address(uint160(uint256(vm.load(address(router), bytes32(uint256(3)))))), pancakeRouter, "slot 3");
        (uint64 v,) = R.initState(address(router));
        assertEq(v, 2);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        r2.initializeV2(8);
        // same address, still listed: no setRouter, the old approvals still work
        assertTrue(pad.routers(address(router)));
        vm.prank(buyer);
        uint256 again = router.v3Buy(t, 0.01 ether, 1, vm.getBlockTimestamp());
        assertGt(again, 0);
        assertEq(IERC20(t).balanceOf(buyer), before + again);
        _assertRouterEmpty();
    }

    /// The risk §21 names: a malicious version could pull whatever users approved to the router address. It cannot run
    /// before 48 h of public notice; a user who approved only what each call needed has nothing left to pull.
    function test_upgrade_maliciousNeeds48h_exactApprovalLimitsIt() public {
        address t = _createV3(_newAgent(), address(quoteTok), _tax(200, 200, 5000, treasury));
        address loose = _newAgent(); // approved max to the router (GangFixture does)
        address exact = _newAgent();
        vm.startPrank(exact);
        quoteTok.approve(address(router), 0);
        quoteTok.approve(address(router), 0.01 ether);
        router.v3Buy(t, 0.01 ether, 1, vm.getBlockTimestamp());
        vm.stopPrank();
        assertEq(quoteTok.allowance(exact, address(router)), 0, "used up");

        GangRouterDrainMock evil = new GangRouterDrainMock();
        bytes memory call = _upgradeCall(address(evil), "");
        bytes32 id = _schedule(call, bytes32(0));
        // public for 48 h (CallScheduled on the timelock): the window to revoke
        assertTrue(tl.isOperationPending(id));
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        _execute(call, bytes32(0));

        address sink = makeAddr("sink");
        uint256 looseBal = quoteTok.balanceOf(loose);
        GangRouterDrainMock(payable(address(router))).drain(IERC20(address(quoteTok)), loose, sink);
        GangRouterDrainMock(payable(address(router))).drain(IERC20(address(quoteTok)), exact, sink);
        assertEq(quoteTok.balanceOf(sink), looseBal, "only the standing approval was exposed");
    }

    // ---------------------------------------------------------------- no balance, ever
    function test_routerEmptyAfterEveryCall() public {
        address w = _wbnbCurve();
        address q = _createV3(_newAgent(), address(quoteTok), _tax(200, 200, 5000, treasury));
        address fw = _createFair(_newAgent(), address(0), 1);
        address fq = _createFair(_newAgent(), address(quoteTok), 1);
        // one fresh Agent per call (the 1% wallet cap would stop a second buy of the same token)
        _call(abi.encodeCall(GangRouter.v3BuyBNB, (w, 1, vm.getBlockTimestamp())), 0.05 ether);
        _call(abi.encodeCall(GangRouter.v3BuyBNB, (w, 1, vm.getBlockTimestamp())), 50 ether); // cap refund as BNB
        _call(abi.encodeCall(GangRouter.v3Buy, (q, 0.01 ether, 1, vm.getBlockTimestamp())), 0);
        _call(abi.encodeCall(GangRouter.v3Buy, (q, 50 ether, 1, vm.getBlockTimestamp())), 0); // refund in the quote
        _call(abi.encodeCall(GangRouter.fairMintBNB, (fw, 10, 1, vm.getBlockTimestamp())), 5 ether); // far too much
        _call(abi.encodeCall(GangRouter.fairMint, (fq, 500, 1, vm.getBlockTimestamp())), 0); // cut to the cap
        assertEq(IERC20(w).balanceOf(address(router)) + IERC20(q).balanceOf(address(router)), 0);
        assertEq(IERC20(fw).balanceOf(address(router)) + IERC20(fq).balanceOf(address(router)), 0);
    }

    function _call(bytes memory data, uint256 value) internal {
        address a = _newAgent();
        vm.prank(a);
        (bool ok, bytes memory err) = address(router).call{value: value}(data);
        if (!ok) {
            assembly {
                revert(add(err, 32), mload(err))
            }
        }
        _assertRouterEmpty();
    }

    function testFuzz_routerEmpty_v3BuyBNB(uint96 value) public {
        uint256 v = bound(uint256(value), 1e9, 30 ether);
        address w = _wbnbCurve();
        address a = _newAgent();
        vm.prank(a);
        router.v3BuyBNB{value: v}(w, 0, vm.getBlockTimestamp());
        _assertRouterEmpty();
    }

    // ---------------------------------------------------------------- reentrancy (OZ 5.1 ReentrancyGuard in proxy storage)
    /// The guard's flag lives in proxy slot 0, which starts at 0 (the implementation's constructor wrote 1 into the
    /// IMPLEMENTATION's storage, not the proxy's). 0 is not ENTERED (2), so the first call passes and leaves 1.
    function test_reentrancy_guardStartsAtZeroInProxy() public {
        assertEq(uint256(vm.load(address(router), bytes32(0))), 0, "fresh proxy: 0");
        assertEq(uint256(vm.load(routerStack.impl, bytes32(0))), 1, "impl's own storage: NOT_ENTERED");
        address w = _wbnbCurve();
        address a = _newAgent();
        vm.prank(a);
        router.v3BuyBNB{value: 0.01 ether}(w, 1, vm.getBlockTimestamp());
        assertEq(uint256(vm.load(address(router), bytes32(0))), 1, "NOT_ENTERED after a call");
        vm.prank(a);
        router.v3BuyBNB{value: 0.01 ether}(w, 1, vm.getBlockTimestamp());
    }

    function _reenterer() internal returns (ReenteringBuyer b) {
        b = new ReenteringBuyer(router);
        agents.mint(address(b), _nextAgentId++);
        vm.deal(address(b), 100 ether);
    }

    function test_reentrancy_v3BuyBNB_refundCallback() public {
        address w = _wbnbCurve();
        ReenteringBuyer b = _reenterer();
        b.setTarget(w, 1);
        b.buyBnb(50 ether); // past the cap: the refund calls back
        assertEq(b.reentries(), 1, "callback ran");
        assertEq(b.innerError(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        _assertRouterEmpty();
    }

    function test_reentrancy_fairMintBNB_refundCallback() public {
        address f = _createFair(_newAgent(), address(0), 1);
        ReenteringBuyer b = _reenterer();
        b.setTarget(f, 2);
        b.mintBnb(5, 5 ether);
        assertEq(b.reentries(), 1);
        assertEq(b.innerError(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        _assertRouterEmpty();
    }

    /// Cross-entry: inside a BNB refund, the ERC-20 entry is locked too.
    function test_reentrancy_crossEntry() public {
        address w = _wbnbCurve();
        ReenteringBuyer b = _reenterer();
        b.setTarget(w, 3);
        b.buyBnb(50 ether);
        assertEq(b.reentries(), 1);
        assertEq(b.innerError(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        _assertRouterEmpty();
    }

    /// The guard survives an upgrade (same slot), and the flag is back to NOT_ENTERED.
    function test_reentrancy_afterUpgrade() public {
        address w = _wbnbCurve();
        _upgrade(address(new GangRouterV2Mock()), "");
        ReenteringBuyer b = _reenterer();
        b.setTarget(w, 1);
        b.buyBnb(50 ether);
        assertEq(b.innerError(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        _assertRouterEmpty();
    }

    // ---------------------------------------------------------------- BNB in
    function test_receive_onlyWbnb_throughProxy() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok, bytes memory err) = address(router).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(err, abi.encodeWithSelector(GangRouter.OnlyWbnb.selector));
        // WBNB's unwrap pays with `transfer` (gas 0 + the 2300 stipend of a value call). In the router's own unwrap
        // the implementation slot, the implementation and `wbnb` are warm (that call just read them). A probe playing
        // WBNB does the same inside one frame: read through the proxy, then pay it with exactly the stipend.
        WbnbStipendProbe probe = new WbnbStipendProbe();
        vm.deal(address(probe), 1 ether);
        R.Router memory pr = R.deploy(address(pad), address(probe), pancakeRouter, safe, R.MAINNET_MIN_DELAY);
        assertTrue(probe.payWarm(pr.proxy), "proxy + receive fit in the 2300 stipend");
        assertEq(pr.proxy.balance, 1);
        // a non-WBNB sender is refused even with plenty of gas
        vm.prank(stranger);
        (ok,) = address(router).call{value: 1, gas: 100_000}("");
        assertFalse(ok);
    }
}

/// @dev Plays WBNB for a router proxy: reads through the proxy (warming what a real unwrap has warm), then pays it 1 wei
///      the way WETH9 does (`transfer`: the 2300 stipend only).
contract WbnbStipendProbe {
    function payWarm(address router) external returns (bool ok) {
        GangRouter(payable(router)).wbnb();
        (ok,) = payable(router).call{value: 1, gas: 0}("");
    }
}
