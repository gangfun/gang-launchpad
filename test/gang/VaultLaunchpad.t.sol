// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Vm} from "forge-std/Vm.sol";
import {GangFixture} from "../utils/GangFixture.sol";
import {GangLaunchpad} from "../../src/gang/GangLaunchpad.sol";
import {GangVaultLaunchpad} from "../../src/gang/GangVaultLaunchpad.sol";
import {GangToken} from "../../src/gang/GangToken.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {IGangVaultPad} from "../../src/gang/interfaces/IGangVaultPad.sol";
import {GangPadRegistry} from "../../src/gang/GangPadRegistry.sol";
import {GangPadRegistryDeployLib} from "../../script/GangPadRegistryDeployLib.sol";

/// @dev A lock vault as the pad expects one: locks / releases for whoever calls it, as tx.origin.
contract MockLockVault {
    GangVaultLaunchpad public immutable pad;

    constructor(GangVaultLaunchpad pad_) {
        pad = pad_;
    }

    function approvePad(address token) external {
        IERC20(token).approve(address(pad), type(uint256).max);
    }

    function lock(address token, uint256 amount) external {
        pad.vaultLock(token, tx.origin, amount);
    }

    function lockFor(address token, address user, uint256 amount) external {
        pad.vaultLock(token, user, amount);
    }

    function release(address token, uint256 amount) external {
        pad.vaultRelease(token, tx.origin, amount);
    }

    function releaseTo(address token, address user, uint256 amount) external {
        pad.vaultRelease(token, user, amount);
    }

    function transferOut(address token, address to, uint256 amount) external {
        IERC20(token).transfer(to, amount);
    }

    /// @dev What a buggy / hostile vault might try: trade the token on the curve itself.
    function curveBuy(address token, address quote, uint256 quoteIn) external {
        IERC20(quote).approve(address(pad), quoteIn);
        pad.buy(token, quoteIn, 0);
    }

    function curveSell(address token, uint256 amount) external {
        pad.sell(token, amount, 0);
    }

    function curveBuyFor(address token, uint256 quoteIn) external {
        pad.buyFor(address(this), token, quoteIn, 0);
    }
}

/// @notice GangVaultLaunchpad: 2.0 + a vault per curve token, lock / release
///         while locked, the locked amount counted against the 1% cap, releases uncapped.
contract VaultLaunchpadTest is GangFixture {
    uint256 internal constant MAX_PER_WALLET = 10_000_000 ether;
    uint256 internal constant LOCK_AMT = 4_000_000 ether;

    event VaultSet(address indexed vault, bool enabled);
    event VaultBound(address indexed token, address indexed vault);
    event VaultLocked(address indexed token, address indexed vault, address indexed user, uint256 amount);
    event VaultReleased(address indexed token, address indexed vault, address indexed user, uint256 amount);

    GangVaultLaunchpad internal vpad;
    MockLockVault internal vault;
    MockLockVault internal otherVault;
    address internal creator;
    address internal alice;
    address internal bob;

    function _newPad() internal override returns (GangLaunchpad) {
        return new GangVaultLaunchpad(
            owner,
            address(quoteRegistry),
            address(divVault),
            address(bucket),
            address(handler),
            address(tokenDeployer),
            address(wbnb),
            address(pairFactory)
        );
    }

    function setUp() public {
        _deployGang(address(this));
        vpad = GangVaultLaunchpad(address(pad));
        vault = new MockLockVault(vpad);
        otherVault = new MockLockVault(vpad);
        vm.startPrank(owner);
        vpad.setVault(address(vault), true);
        vpad.setVault(address(otherVault), true);
        handler.list(address(vault), "lock vault");
        vm.stopPrank();
        creator = _newAgent();
        alice = _newAgent();
        bob = _newAgent();
    }

    // ---------------------------------------------------------------- helpers
    function _createVault(IGangLaunchpad.TaxConfig memory tax) internal returns (address t) {
        vm.prank(creator);
        t = vpad.createWithVault(
            "Vault", "VLT", "logo", "meta", address(wbnb), address(0), tax, 9 ether, address(vault)
        );
        vault.approvePad(t);
    }

    function _untaxed() internal returns (address) {
        return _createVault(_tax(0, 0, 0, address(0)));
    }

    /// @dev `who` buys until the 1% cap (the pad trims the last buy).
    function _buyToCap(address t, address who) internal {
        vm.prank(who);
        pad.buy(t, 2 ether, 0);
        assertEq(IERC20(t).balanceOf(who) + vpad.lockedOf(t, who), MAX_PER_WALLET, "at the cap");
    }

    function _lock(address t, address who, uint256 amount) internal {
        vm.prank(who);
        IERC20(t).approve(address(vault), amount);
        vm.prank(who, who);
        vault.lock(t, amount);
    }

    function _release(address t, address who, uint256 amount) internal {
        vm.prank(who, who);
        vault.release(t, amount);
    }

    // ---------------------------------------------------------------- admin and create
    function test_setVault_onlyOwner_contractOnly() public {
        address v = address(new MockLockVault(vpad));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        vpad.setVault(v, true);

        vm.prank(owner);
        vm.expectRevert(IGangVaultPad.VaultNotContract.selector);
        vpad.setVault(makeAddr("eoa"), true);

        vm.expectEmit(true, false, false, true, address(pad));
        emit VaultSet(v, true);
        vm.prank(owner);
        vpad.setVault(v, true);
        assertTrue(vpad.isVault(v));
    }

    function test_otherCreates_revert() public {
        vm.startPrank(creator);
        vm.expectRevert(IGangVaultPad.UseVaultCreate.selector);
        pad.create("C", "C", "l", "m", address(wbnb), address(0), _tax(0, 0, 0, address(0)));
        vm.expectRevert(IGangVaultPad.UseVaultCreate.selector);
        pad.createWithGradTarget("C", "C", "l", "m", address(wbnb), address(0), _tax(0, 0, 0, address(0)), 9 ether);
        vm.expectRevert(IGangVaultPad.UseVaultCreate.selector);
        pad.create("F", "F", "l", "m", address(wbnb), address(0), _mintCfg(10 ether, 50, 6_000, 100, 100), 1);
        vm.stopPrank();
    }

    function test_createWithVault_bindsListedVault() public {
        vm.prank(creator);
        vm.expectRevert(IGangVaultPad.NotVault.selector);
        vpad.createWithVault("V", "V", "l", "m", address(wbnb), address(0), _tax(0, 0, 0, address(0)), 9 ether, alice);

        vm.prank(creator);
        address t = vpad.createWithVault(
            "V", "V", "l", "m", address(wbnb), address(0), _tax(0, 0, 0, address(0)), 6 ether, address(vault)
        );
        assertEq(vpad.vaultOf(t), address(vault));
        assertEq(pad.kindOf(t), KIND_CURVE);
        assertEq(pad.gradTargetOf(t), 6 ether);

        // the 2.0 checks still apply (tier, Agent creator)
        vm.prank(creator);
        vm.expectRevert(IGangLaunchpad.BadGradTarget.selector);
        vpad.createWithVault(
            "V", "V", "l", "m", address(wbnb), address(0), _tax(0, 0, 0, address(0)), 7 ether, address(vault)
        );
        vm.prank(makeAddr("notAgent"));
        vm.expectRevert(IGangLaunchpad.NotAgent.selector);
        vpad.createWithVault(
            "V", "V", "l", "m", address(wbnb), address(0), _tax(0, 0, 0, address(0)), 9 ether, address(vault)
        );
    }

    function test_createWithVault_taxRecipientIsVault() public {
        address t = _createVault(_tax(300, 300, 0, address(vault)));
        (,,, address recipient) = pad.taxConfigOf(t);
        assertEq(recipient, address(vault));
    }

    // ---------------------------------------------------------------- lock / release
    function test_lock_movesTokens_booksLocked_curveUntouched() public {
        address t = _untaxed();
        vm.prank(alice);
        pad.buy(t, 1 ether, 0);
        uint256 bal = IERC20(t).balanceOf(alice);
        uint256 sold = _curveSold(t);
        uint256 realQ = _curveRealQuote(t);
        uint256 padBal = IERC20(t).balanceOf(address(pad));

        vm.prank(alice);
        IERC20(t).approve(address(vault), LOCK_AMT);
        vm.expectEmit(true, true, true, true, address(pad));
        emit VaultLocked(t, address(vault), alice, LOCK_AMT);
        vm.prank(alice, alice);
        vault.lock(t, LOCK_AMT);

        assertEq(IERC20(t).balanceOf(alice), bal - LOCK_AMT);
        assertEq(IERC20(t).balanceOf(address(vault)), LOCK_AMT);
        assertEq(vpad.lockedOf(t, alice), LOCK_AMT);
        assertEq(pad.walletRoom(t, alice), MAX_PER_WALLET - bal, "locking does not free room");
        assertEq(_curveSold(t), sold);
        assertEq(_curveRealQuote(t), realQ);
        assertEq(IERC20(t).balanceOf(address(pad)), padBal, "pad passes the tokens through");
        assertEq(IERC20(t).allowance(alice, address(vault)), 0, "alice's allowance to the vault spent");
    }

    function test_capLoop_blocked() public {
        address t = _untaxed();
        _buyToCap(t, alice);
        _lock(t, alice, LOCK_AMT);
        assertEq(pad.walletRoom(t, alice), 0);
        vm.prank(alice);
        vm.expectRevert(IGangLaunchpad.WalletCapReached.selector);
        pad.buy(t, 0.1 ether, 0);
    }

    function test_capCountsLocked_viaRouterEntry() public {
        address t = _untaxed();
        _buyToCap(t, alice);
        _lock(t, alice, LOCK_AMT);
        address r = makeAddr("listedRouter");
        vm.prank(owner);
        pad.setRouter(r, true);
        wbnb.mintUnlimited(r, 1 ether);
        vm.prank(r);
        wbnb.approve(address(pad), type(uint256).max);
        vm.prank(r, alice);
        vm.expectRevert(IGangLaunchpad.WalletCapReached.selector);
        pad.buyFor(alice, t, 0.1 ether, 0);
    }

    function test_ownRelease_restoresRoom() public {
        address t = _untaxed();
        _buyToCap(t, alice);
        _lock(t, alice, LOCK_AMT);
        uint256 back = (LOCK_AMT * 3) / 4;

        vm.expectEmit(true, true, true, true, address(pad));
        emit VaultReleased(t, address(vault), alice, back);
        _release(t, alice, back);

        assertEq(IERC20(t).balanceOf(alice), MAX_PER_WALLET - LOCK_AMT + back);
        assertEq(vpad.lockedOf(t, alice), LOCK_AMT - back);
        assertEq(pad.walletRoom(t, alice), 0, "the part kept still counts until released");
        assertEq(IERC20(t).balanceOf(address(vault)), LOCK_AMT - back, "the rest stays in the vault");
    }

    function test_releaseToOther_uncapped_lockerKeepsBooking() public {
        address t = _untaxed();
        _buyToCap(t, alice);
        _lock(t, alice, LOCK_AMT);
        _buyToCap(t, bob);

        // the vault pays bob (its own business): bob takes alice's tokens, past 1%
        _release(t, bob, LOCK_AMT);
        assertEq(IERC20(t).balanceOf(bob), MAX_PER_WALLET + LOCK_AMT, "release is not capped");
        assertEq(vpad.lockedOf(t, bob), 0);
        assertEq(vpad.lockedOf(t, alice), LOCK_AMT, "alice's booking stays until graduation");
        assertEq(pad.walletRoom(t, bob), 0);
        assertEq(pad.walletRoom(t, alice), 0);

        vm.prank(bob);
        vm.expectRevert(IGangLaunchpad.WalletCapReached.selector);
        pad.buy(t, 0.1 ether, 0);
        vm.prank(alice);
        vm.expectRevert(IGangLaunchpad.WalletCapReached.selector);
        pad.buy(t, 0.1 ether, 0);

        // bob can still sell what he holds back to the curve
        vm.startPrank(bob);
        IERC20(t).approve(address(pad), LOCK_AMT);
        pad.sell(t, LOCK_AMT, 0);
        vm.stopPrank();
    }

    function test_releaseMoreThanLocked_floorsAtZero() public {
        address t = _untaxed();
        _buyToCap(t, alice);
        _lock(t, alice, LOCK_AMT);
        _buyToCap(t, bob);
        _lock(t, bob, LOCK_AMT);
        _release(t, alice, 2 * LOCK_AMT);
        assertEq(vpad.lockedOf(t, alice), 0);
        assertEq(vpad.lockedOf(t, bob), LOCK_AMT);
    }

    // ---------------------------------------------------------------- refusals
    function test_refusals() public {
        address t = _untaxed();
        vm.prank(alice);
        pad.buy(t, 1 ether, 0);
        vm.prank(alice);
        IERC20(t).approve(address(vault), type(uint256).max);
        vm.prank(alice);
        IERC20(t).approve(address(otherVault), type(uint256).max);

        // not this token's vault (another listed vault, or a wallet)
        vm.prank(alice, alice);
        vm.expectRevert(IGangVaultPad.NotVault.selector);
        otherVault.lock(t, 1 ether);
        vm.prank(alice, alice);
        vm.expectRevert(IGangVaultPad.NotVault.selector);
        vpad.vaultLock(t, alice, 1 ether);
        vm.prank(alice, alice);
        vm.expectRevert(IGangVaultPad.NotVault.selector);
        vpad.vaultLock(address(wbnb), alice, 1 ether);

        // user must be the tx sender (a vault can't move someone else's tokens, even with their approval)
        vm.prank(bob, bob);
        vm.expectRevert(IGangLaunchpad.TraderNotOrigin.selector);
        vault.lockFor(t, alice, 1 ether);
        vm.prank(bob, bob);
        vm.expectRevert(IGangLaunchpad.TraderNotOrigin.selector);
        vault.releaseTo(t, alice, 1 ether);
        // ... and so never a contract (the future pair included)
        vm.prank(alice, alice);
        vm.expectRevert(IGangLaunchpad.TraderNotOrigin.selector);
        vault.releaseTo(t, address(otherVault), 1 ether);

        // zero
        vm.prank(alice, alice);
        vm.expectRevert(IGangLaunchpad.ZeroAmount.selector);
        vault.lock(t, 0);

        // allowance
        vm.prank(alice);
        IERC20(t).approve(address(vault), 1 ether);
        vm.prank(alice, alice);
        vm.expectRevert();
        vault.lock(t, 2 ether);
    }

    function test_nonAgent_refused_bothWays() public {
        address t = _untaxed();
        _buyToCap(t, alice);
        _lock(t, alice, LOCK_AMT);
        address plain = makeAddr("plain");
        vm.prank(plain, plain);
        vm.expectRevert(IGangLaunchpad.NotAgent.selector);
        vault.release(t, 1 ether);
        vm.prank(plain, plain);
        vm.expectRevert(IGangLaunchpad.NotAgent.selector);
        vault.lock(t, 1 ether);
    }

    function test_delisted_noLock_releaseOpen() public {
        address t = _untaxed();
        _buyToCap(t, alice);
        _lock(t, alice, LOCK_AMT);
        vm.prank(owner);
        vpad.setVault(address(vault), false);

        vm.prank(alice);
        IERC20(t).approve(address(vault), 1 ether);
        vm.prank(alice, alice);
        vm.expectRevert(IGangVaultPad.VaultDelisted.selector);
        vault.lock(t, 1 ether);

        _release(t, alice, LOCK_AMT);
        assertEq(vpad.lockedOf(t, alice), 0);

        vm.prank(creator);
        vm.expectRevert(IGangVaultPad.NotVault.selector);
        vpad.createWithVault(
            "V", "V", "l", "m", address(wbnb), address(0), _tax(0, 0, 0, address(0)), 9 ether, address(vault)
        );
    }

    function test_vaultCannotMoveTokensItself_whileLocked() public {
        address t = _untaxed();
        _buyToCap(t, alice);
        _lock(t, alice, LOCK_AMT);
        vm.expectRevert(GangToken.TransfersLocked.selector);
        vault.transferOut(t, alice, 1 ether);
    }

    // ---------------------------------------------------------------- audit 2026-11-01 fixes
    /// @dev H-1: an Agent vault buying, releasing uncapped and buying again would sweep the curve into one wallet.
    function test_vaultCannotBuy_evenAsAgent() public {
        address t = _untaxed();
        agents.mint(address(vault), 999_999);
        wbnb.mintUnlimited(address(vault), 10 ether);
        vm.expectRevert(IGangVaultPad.VaultCannotTrade.selector);
        vault.curveBuy(t, address(wbnb), 1 ether);

        vm.prank(owner);
        pad.setAgentGate(false, address(agents)); // gate off: still refused
        vm.expectRevert(IGangVaultPad.VaultCannotTrade.selector);
        vault.curveBuy(t, address(wbnb), 1 ether);

        // another vault-pad token's vault may trade this one like anyone (it is not this token's vault)
        vm.prank(creator);
        address t2 = vpad.createWithVault(
            "B", "B", "l", "m", address(wbnb), address(0), _tax(0, 0, 0, address(0)), 9 ether, address(otherVault)
        );
        vault.curveBuy(t2, address(wbnb), 0.1 ether);
        assertGt(IERC20(t2).balanceOf(address(vault)), 0);
    }

    /// @dev M-1: the vault can't sell what users locked.
    function test_vaultCannotSellLocked() public {
        address t = _untaxed();
        _buyToCap(t, alice);
        _lock(t, alice, LOCK_AMT);
        agents.mint(address(vault), 999_998);
        vm.expectRevert(IGangVaultPad.VaultCannotTrade.selector);
        vault.curveSell(t, LOCK_AMT);
        assertEq(IERC20(t).balanceOf(address(vault)), LOCK_AMT);
    }

    function test_vaultAndRouter_exclusive() public {
        MockLockVault v = new MockLockVault(vpad);
        vm.startPrank(owner);
        pad.setRouter(address(v), true);
        vm.expectRevert(IGangVaultPad.VaultIsRouter.selector);
        vpad.setVault(address(v), true);
        pad.setRouter(address(v), false);
        vpad.setVault(address(v), true);
        vm.expectRevert(IGangVaultPad.VaultIsRouter.selector);
        pad.setRouter(address(v), true);
        pad.setRouter(address(v), false); // disabling is always fine
        // re-review L-1: delisting does not make it router-eligible (tokens and lock allowances stay bound to it)
        vpad.setVault(address(v), false);
        vm.expectRevert(IGangVaultPad.VaultIsRouter.selector);
        pad.setRouter(address(v), true);
        assertTrue(vpad.everVault(address(v)));
        vm.stopPrank();
    }

    /// @dev L-1: a vault that lost its code (EIP-7702 delegation revoked) can still be delisted.
    function test_delist_withoutCode() public {
        MockLockVault v = new MockLockVault(vpad);
        vm.prank(owner);
        vpad.setVault(address(v), true);
        vm.etch(address(v), "");
        vm.prank(owner);
        vpad.setVault(address(v), false);
        assertFalse(vpad.isVault(address(v)));
    }

    /// @dev A vault that is itself tx.origin (EIP-7702) can't lock / release to itself.
    function test_vaultAsOrigin_refused() public {
        address t = _untaxed();
        _buyToCap(t, alice);
        _lock(t, alice, LOCK_AMT);
        agents.mint(address(vault), 999_997);
        vm.prank(address(vault), address(vault));
        vm.expectRevert(IGangVaultPad.NotVault.selector);
        vpad.vaultRelease(t, address(vault), 1 ether);
    }

    // ---------------------------------------------------------------- review 2026-11-01 test gaps
    function test_createWithVault_emitsBound_viaInterface() public {
        vm.recordLogs();
        vm.prank(creator);
        address t = IGangVaultPad(address(pad))
            .createWithVault(
                "V", "V", "l", "m", address(wbnb), address(0), _tax(0, 0, 0, address(0)), 9 ether, address(vault)
            );
        bytes32 sig = keccak256("VaultBound(address,address)");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].topics[0] == sig && address(uint160(uint256(logs[i].topics[1]))) == t) seen = true;
        }
        assertTrue(seen, "VaultBound emitted");
    }

    function test_erc20Quote_lockRelease() public {
        vm.prank(creator);
        address t = vpad.createWithVault(
            "Q", "Q", "l", "m", address(quoteTok), address(0), _tax(0, 0, 0, address(0)), 9 ether, address(vault)
        );
        vault.approvePad(t);
        _buyToCap(t, alice);
        _lock(t, alice, LOCK_AMT);
        assertEq(pad.walletRoom(t, alice), 0);
        _release(t, alice, LOCK_AMT);
        assertEq(pad.walletRoom(t, alice), 0, "back in the wallet: still at the cap");
        assertEq(IERC20(t).balanceOf(alice), MAX_PER_WALLET);
    }

    function test_release_needsVaultAllowanceToPad() public {
        vm.prank(creator);
        address t = vpad.createWithVault(
            "N", "N", "l", "m", address(wbnb), address(0), _tax(0, 0, 0, address(0)), 9 ether, address(vault)
        ); // no vault.approvePad(t)
        _buyToCap(t, alice);
        _lock(t, alice, LOCK_AMT);
        vm.prank(alice, alice);
        vm.expectRevert();
        vault.release(t, 1 ether);
    }

    function test_vaultOfOtherToken_refused() public {
        address t = _untaxed();
        vm.prank(creator);
        address t2 = vpad.createWithVault(
            "B", "B", "l", "m", address(wbnb), address(0), _tax(0, 0, 0, address(0)), 9 ether, address(otherVault)
        );
        _buyToCap(t2, alice);
        vm.prank(alice);
        IERC20(t2).approve(address(vault), type(uint256).max);
        vm.prank(alice, alice);
        vm.expectRevert(IGangVaultPad.NotVault.selector);
        vault.lock(t2, 1 ether); // `vault` is t's vault, not t2's
        assertEq(vpad.vaultOf(t), address(vault));
    }

    function test_gateOff_lockReleaseOpenToAnyOrigin_vaultStillBarred() public {
        address t = _untaxed();
        _buyToCap(t, alice);
        _lock(t, alice, LOCK_AMT);
        vm.prank(owner);
        pad.setAgentGate(false, address(agents));
        address plain = makeAddr("plainWallet");
        _release(t, plain, 1 ether); // the pad's gate is off: anyone may act for themselves, as on the curve
        assertEq(IERC20(t).balanceOf(plain), 1 ether);
        wbnb.mintUnlimited(address(vault), 1 ether);
        vm.expectRevert(IGangVaultPad.VaultCannotTrade.selector);
        vault.curveBuy(t, address(wbnb), 0.1 ether);
    }

    function test_dividendShares_releaseToOther_andAfterGraduation() public {
        address t = _createVault(_tax(300, 300, 5_000, address(vault)));
        _buyToCap(t, alice);
        _lock(t, alice, LOCK_AMT);
        _release(t, bob, LOCK_AMT / 5);
        assertEq(divVault.shares(t, bob), LOCK_AMT / 5);
        assertEq(divVault.shares(t, address(vault)), LOCK_AMT - LOCK_AMT / 5);
        _graduate(t);
        // after graduation the token syncs shares on transfers (the pad's entries are closed)
        vault.transferOut(t, alice, LOCK_AMT / 5);
        assertEq(divVault.shares(t, address(vault)), LOCK_AMT - 2 * (LOCK_AMT / 5));
        assertEq(divVault.shares(t, alice), MAX_PER_WALLET - LOCK_AMT + LOCK_AMT / 5);
    }

    function test_registryPreview_countsLocked() public {
        address t = _untaxed();
        _buyToCap(t, alice);
        _lock(t, alice, LOCK_AMT);
        address[] memory pads = new address[](1);
        pads[0] = address(pad);
        GangPadRegistry reg = GangPadRegistry(GangPadRegistryDeployLib.deploy(owner, pads).proxy);
        (uint256 out,,,) = reg.previewBuy(t, alice, 0.1 ether);
        assertEq(out, 0, "no room left for alice");
        (out,,,) = reg.previewBuy(t, bob, 0.1 ether);
        assertGt(out, 0);
    }

    // ---------------------------------------------------------------- graduation
    function test_graduation_vaultHoldsThenTransfersFreely() public {
        address t = _createVault(_tax(0, 0, 0, address(0)));
        _buyToCap(t, alice);
        _lock(t, alice, LOCK_AMT);
        _graduate(t);

        assertEq(IERC20(t).balanceOf(address(vault)), LOCK_AMT, "locked tokens stay in the vault");
        vm.prank(alice, alice);
        vm.expectRevert(IGangLaunchpad.AlreadyGraduated.selector);
        vault.release(t, 1 ether);
        vm.prank(alice);
        IERC20(t).approve(address(vault), 1 ether);
        vm.prank(alice, alice);
        vm.expectRevert(IGangLaunchpad.AlreadyGraduated.selector);
        vault.lock(t, 1 ether);

        vault.transferOut(t, alice, LOCK_AMT); // unlocked: a plain transfer
        assertEq(IERC20(t).balanceOf(alice), MAX_PER_WALLET);
    }

    // ---------------------------------------------------------------- dividends
    function test_dividendShares_followBalances() public {
        address t = _createVault(_tax(300, 300, 5_000, address(vault)));
        _buyToCap(t, alice);
        _lock(t, alice, LOCK_AMT);
        assertEq(divVault.shares(t, alice), MAX_PER_WALLET - LOCK_AMT);
        assertEq(divVault.shares(t, address(vault)), LOCK_AMT);

        _release(t, alice, LOCK_AMT / 2);
        assertEq(divVault.shares(t, alice), MAX_PER_WALLET - LOCK_AMT / 2);
        assertEq(divVault.shares(t, address(vault)), LOCK_AMT / 2);
    }

    // ---------------------------------------------------------------- fuzz
    /// @dev Any lock / release sequence leaves the curve's books and the pad's token balance alone, and every
    ///      buyer's (balance + locked) within 1% after their own buys.
    function testFuzz_lockRelease_booksAndCap(uint256 seed) public {
        address t = _untaxed();
        address[5] memory users = [alice, bob, creator, _newAgent(), _newAgent()];
        for (uint256 i; i < 5; i++) {
            vm.prank(users[i]);
            pad.buy(t, 0.5 ether, 0);
            vm.prank(users[i]);
            IERC20(t).approve(address(vault), type(uint256).max);
        }
        uint256 sold = _curveSold(t);
        uint256 padBal = IERC20(t).balanceOf(address(pad));

        for (uint256 step; step < 30; step++) {
            seed = uint256(keccak256(abi.encode(seed, step)));
            address u = users[seed % 5];
            uint256 action = (seed >> 8) % 3;
            if (action == 0) {
                uint256 bal = IERC20(t).balanceOf(u);
                if (bal == 0) continue;
                uint256 amt = 1 + ((seed >> 16) % bal);
                vm.prank(u, u);
                vault.lock(t, amt);
            } else if (action == 1) {
                uint256 vb = IERC20(t).balanceOf(address(vault));
                if (vb == 0) continue;
                uint256 amt = 1 + ((seed >> 16) % vb);
                vm.prank(u, u);
                vault.release(t, amt);
            } else {
                if (pad.walletRoom(t, u) == 0) {
                    vm.prank(u);
                    vm.expectRevert(IGangLaunchpad.WalletCapReached.selector);
                    pad.buy(t, 0.3 ether, 0);
                    continue;
                }
                // room > 0 means balance + locked < 1%; a buy never takes it past 1%
                vm.prank(u);
                pad.buy(t, 0.3 ether, 0);
                assertLe(IERC20(t).balanceOf(u) + vpad.lockedOf(t, u), MAX_PER_WALLET, "own buys stay within 1%");
                sold = _curveSold(t);
                padBal = IERC20(t).balanceOf(address(pad));
            }
            assertEq(_curveSold(t), sold, "lock / release never touch the curve");
            assertEq(IERC20(t).balanceOf(address(pad)), padBal, "the pad keeps none of it");
        }
    }
}
