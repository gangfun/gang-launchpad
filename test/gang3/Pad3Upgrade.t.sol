// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Pad3Impl} from "../../script/Pad3Impl.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GangLaunchpad} from "../../src/gang/GangLaunchpad.sol";
import {GangLaunchpad3} from "../../src/gang/GangLaunchpad3.sol";
import {Pad3Module} from "../../src/gang/Pad3Module.sol";
import {IGangLaunchpad3} from "../../src/gang/interfaces/IGangLaunchpad3.sol";
import {DeployGang} from "../../script/DeployGang.s.sol";
import {UpgradeGangLaunchpad3} from "../../script/UpgradeGangLaunchpad3.s.sol";
import {GangLaunchpad3V2Mock} from "../mocks/GangLaunchpad3V2Mock.sol";
import {GangFixture} from "../utils/GangFixture.sol";
import {Pad3CurveSwapMock, MockWBNBFallback} from "../mocks/GangLaunchpad3Review3Mocks.sol";
import {GangHandlerAdmin} from "../../src/gang/GangHandlerAdmin.sol";

/// @dev Answers `handler()` / `owner()` as the owner's GangHandlerAdmin would, with other code (final audit M-2).
contract FakeHandlerAdmin {
    address public immutable handler;
    address public immutable owner;
    address public pendingOwner;

    constructor(address owner_, address handler_) {
        owner = owner_;
        handler = handler_;
    }
}

/// @dev Exposes the upgrade script's own checks (the same code the script runs).
contract UpgradeHarness is UpgradeGangLaunchpad3 {
    /// @dev Per harness, not the process-wide env (tests run in parallel): the version this build "ships".
    bool internal v2;

    function setV2(bool on) external {
        v2 = on;
    }

    function _newImplWith(GangLaunchpad3 cur, address m) internal override returns (address) {
        if (!v2) return super._newImplWith(cur, m);
        Pad3Impl.Deps memory d = Pad3Impl.depsOf(cur);
        return address(
            new GangLaunchpad3V2Mock(
                d.quoteRegistry,
                d.dividendVault,
                d.platformBucket,
                d.taxHandler,
                d.tokenDeployer,
                d.wbnb,
                d.padRegistry,
                m
            )
        );
    }

    address[] internal callers;

    function setCallers(address[] memory c) external {
        callers = c;
    }

    function _callers() internal view override returns (address[] memory) {
        return callers;
    }

    /// @dev As the script: the vault flag is read before an upgrade and kept for the read after it.
    function snap(GangLaunchpad3 p, DeployGang.Stack memory s) external view returns (Snapshot memory) {
        return _snapshot(p, s, _servesVaultMode(address(p)), new bool[](0));
    }

    function snapAs(GangLaunchpad3 p, DeployGang.Stack memory s, bool vault, bool[] memory newFairEntry)
        external
        view
        returns (Snapshot memory)
    {
        return _snapshot(p, s, vault, newFairEntry);
    }

    function checkImpl(address current, address impl) external {
        _checkImpl(current, impl);
    }

    function vaultState(GangLaunchpad3 p, address t) external view returns (bytes memory) {
        return _vaultState(p, t);
    }

    function derivedCalls(address t) external pure returns (bytes[] memory) {
        return _derivedCalls(t);
    }

    function checkImplCode(address impl) external {
        _checkImplCode(impl, false);
    }

    function isOwnersAdmin(address who, address handler, address owner) external view returns (bool) {
        return _isOwnersAdmin(who, handler, owner);
    }

    function checkSeen(DeployGang.Stack memory s, address gateway, bool routers, address[] memory seen) external view {
        Ctx memory x;
        x.gateway = gateway;
        _checkSeen(s, x, routers, seen);
    }

    function wantVersion(address impl, uint64 current, bytes memory init) external view returns (uint64) {
        return _wantVersion(impl, current, init);
    }
}

/// @notice The independent re-review's three PoCs (review 3), as regressions: the upgrade script's record check sees a
///         same-type struct member swap; a new reinitializer can't be left open; a router fee to WBNB is refused.
contract Pad3UpgradeTest is GangFixture {
    bytes32 internal constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    GangLaunchpad3 internal pad3;
    UpgradeHarness internal h;
    address internal alice;

    function _newPad() internal override returns (GangLaunchpad) {
        return _newPad3();
    }

    function setUp() public {
        _deployGang(address(this));
        pad3 = GangLaunchpad3(payable(address(pad)));
        h = new UpgradeHarness();
        alice = _newAgent();
    }

    function _admin() internal view returns (ProxyAdmin) {
        return ProxyAdmin(address(uint160(uint256(vm.load(address(pad), ADMIN_SLOT)))));
    }

    function _stack() internal view returns (DeployGang.Stack memory s) {
        s.router = address(router);
    }

    function _v2() internal returns (address) {
        Pad3Impl.Deps memory d = Pad3Impl.Deps(
            address(quoteRegistry),
            address(divVault),
            address(bucket),
            address(handler),
            address(tokenDeployer),
            address(wbnb),
            address(padRegistry3)
        );
        return address(
            new GangLaunchpad3V2Mock(
                d.quoteRegistry,
                d.dividendVault,
                d.platformBucket,
                d.taxHandler,
                d.tokenDeployer,
                d.wbnb,
                d.padRegistry,
                GangLaunchpad3(payable(pad3Impl)).module()
            )
        );
    }

    /// @dev An upgrade to a fresh build of the same implementation: the snapshot reads back the same (no false alarm).
    function test_snapshot_sameCodeReadsTheSame() public {
        address t = _createV3(alice, address(wbnb), _tax(0, 0, 0, address(0)));
        vm.prank(alice, alice);
        pad.buy(t, 1 ether, 0);
        UpgradeGangLaunchpad3.Snapshot memory before = h.snap(pad3, _stack());
        address next = Pad3Impl.deploy(Pad3Impl.depsOf(GangLaunchpad3(payable(pad3Impl))));
        vm.prank(upgrader);
        _admin().upgradeAndCall(ITransparentUpgradeableProxy(address(pad)), next, "");
        UpgradeGangLaunchpad3.Snapshot memory afterUp = h.snapAs(pad3, _stack(), before.vault, before.newFairEntry);
        assertEq(afterUp.settings, before.settings);
        assertEq(afterUp.tokens.length, before.tokens.length);
        for (uint256 i; i < before.tokens.length; i++) {
            assertEq(afterUp.tokens[i], before.tokens[i]);
        }
    }

    /// @dev Two uint128 members of Curve swapped (realQuote <-> gradAmt, review 3 PoC): the raw record bytes stay the
    ///      same, but graduationRemaining — one of the snapshot's derived views (`_derivedCalls` index 3) — reads
    ///      another value, so the snapshot differs. (The mock lacks the other views; this checks the one that sees it.)
    function test_snapshot_seesSameTypeMemberSwap() public {
        address t = _createV3(alice, address(wbnb), _tax(0, 0, 0, address(0)));
        vm.prank(alice, alice);
        pad.buy(t, 1 ether, 0);
        bytes memory call = h.derivedCalls(t)[3];
        assertEq(bytes4(call), Pad3Module.graduationRemaining.selector, "index 3 is graduationRemaining");
        (, bytes memory before) = address(pad).staticcall(call);
        Pad3CurveSwapMock next = new Pad3CurveSwapMock();
        vm.prank(upgrader);
        _admin().upgradeAndCall(ITransparentUpgradeableProxy(address(pad)), address(next), "");
        (bool ok, bytes memory afterUp) = address(pad).staticcall(call);
        assertTrue(ok, "the mock answers graduationRemaining");
        assertTrue(keccak256(afterUp) != keccak256(before), "the swap shows in a derived view");
    }

    /// @dev A new reinitializer needs its set-up call inside the upgrade; a set-up call needs a new reinitializer.
    function test_wantVersion_reinitializerMustRunInTheUpgrade() public {
        address v2 = _v2();
        h.setV2(true);
        h.checkImpl(pad3Impl, v2);
        h.setV2(false);
        bytes memory init = abi.encodeCall(GangLaunchpad3V2Mock.initializeV2, (7));
        vm.expectRevert(
            abi.encodeWithSelector(DeployGang.WiringCheck.selector, "PAD3_INIT_CALL missing: reinitializer left open")
        );
        h.wantVersion(v2, 1, "");
        assertEq(h.wantVersion(v2, 1, init), 2);
        vm.expectRevert(
            abi.encodeWithSelector(DeployGang.WiringCheck.selector, "PAD3_INIT_CALL without a new reinitializer")
        );
        h.wantVersion(pad3Impl, 1, init);
        assertEq(h.wantVersion(pad3Impl, 1, ""), 1);
        vm.expectRevert(
            abi.encodeWithSelector(DeployGang.WiringCheck.selector, "PAD3_IMPL initVersion below the proxy's")
        );
        h.wantVersion(pad3Impl, 2, "");
    }

    /// @dev WBNB's payable fallback would book a BNB router fee as the pad's WBNB, outside every book: refused.
    function test_sellToken_feeToWbnb_refused() public {
        vm.etch(address(wbnb), address(new MockWBNBFallback()).code);
        address t = _createV3(alice, address(wbnb), _tax(0, 0, 0, address(0)));
        vm.prank(alice, alice);
        uint256 out = pad.buy(t, 1 ether, 0);
        vm.startPrank(alice, alice);
        IERC20(t).approve(address(pad), out);
        vm.expectRevert(IGangLaunchpad3.ZeroFeeRecipient.selector);
        pad3.sellToken(0, t, alice, out, 0, 500, address(wbnb));
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- final audit (deploy) fixes
    /// @dev M-1 / L-1: the implementation and its libraries must be this build's code; same views, other code fails.
    function test_implCode_thisBuildOnly() public {
        h.checkImplCode(pad3Impl);
        address v2 = _v2(); // every 3.0 view and the same dependencies, but not this build's GangLaunchpad3
        vm.expectRevert(abi.encodeWithSelector(DeployGang.WiringCheck.selector, "pad implementation code"));
        h.checkImplCode(v2);
    }

    /// @dev M-2: only this build's GangHandlerAdmin passes for the owner's admin, not a look-alike.
    function test_isOwnersAdmin_realCodeOnly() public {
        GangHandlerAdmin real = new GangHandlerAdmin(owner, address(handler));
        assertTrue(h.isOwnersAdmin(address(real), address(handler), owner));
        FakeHandlerAdmin fake = new FakeHandlerAdmin(owner, address(handler));
        assertFalse(h.isOwnersAdmin(address(fake), address(handler), owner));
    }

    /// @dev M-3: an address that got RouterSet / CallerSet and is listed now, beyond the router / gateway / CALLERS.
    function test_checkSeen_unexpectedListingRefused() public {
        DeployGang.Stack memory s = _stack();
        s.pad = address(pad);
        address gw = address(new FakeHandlerAdmin(owner, owner));
        address extra = address(new FakeHandlerAdmin(owner, owner));
        vm.startPrank(owner);
        pad3.setRouter(gw, true);
        pad3.setRouter(extra, true);
        pad3.setCaller(extra, true);
        vm.stopPrank();
        address[] memory seen = new address[](2);
        seen[0] = address(router);
        seen[1] = gw;
        h.checkSeen(s, gw, true, seen); // router + gateway: fine
        seen[1] = extra;
        vm.expectRevert(abi.encodeWithSelector(DeployGang.WiringCheck.selector, "pad.routers: unexpected router"));
        h.checkSeen(s, gw, true, seen);
        vm.expectRevert(abi.encodeWithSelector(DeployGang.WiringCheck.selector, "pad.isCaller: unexpected caller"));
        h.checkSeen(s, gw, false, seen);
        address[] memory ok = new address[](1);
        ok[0] = extra;
        h.setCallers(ok);
        h.checkSeen(s, gw, false, seen);
    }
}
