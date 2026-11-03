// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";
import {GangLaunchpad} from "../../src/gang/GangLaunchpad.sol";
import {GangLaunchpad3} from "../../src/gang/GangLaunchpad3.sol";
import {Pad3Module} from "../../src/gang/Pad3Module.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {IGangVaultPad} from "../../src/gang/interfaces/IGangVaultPad.sol";
import {Pad3VaultStore} from "../../src/gang/Pad3VaultStore.sol";
import {VaultLaunchpadTest, MockLockVault} from "../gang/VaultLaunchpad.t.sol";
import {UpgradeGangLaunchpad3} from "../../script/UpgradeGangLaunchpad3.s.sol";

/// @dev The upgrade script's per-token vault state, exposed.
contract VaultSnapHarness is UpgradeGangLaunchpad3 {
    function vaultState(GangLaunchpad3 p, address t) external view returns (bytes memory) {
        return _vaultState(p, t);
    }

    function servesVaultMode(address proxy) external view returns (bool) {
        return _servesVaultMode(proxy);
    }
}

/// @notice GangLaunchpad 3.0's vault mode (Pad3Module, through the pad's fallback): GangVaultLaunchpad's whole suite
///         re-run on 3.0. One difference on purpose: 3.0 keeps its other creates open, and a token made by them has no
///         vault (so nothing can lock it).
contract Pad3VaultTest is VaultLaunchpadTest {
    function _newPad() internal override returns (GangLaunchpad) {
        return _newPad3();
    }

    function test_otherCreates_revert() public override {
        vm.startPrank(creator);
        address c = pad.create("C", "C", "l", "m", address(wbnb), address(0), _tax(0, 0, 0, address(0)));
        address g =
            pad.createWithGradTarget("C", "C", "l", "m", address(wbnb), address(0), _tax(0, 0, 0, address(0)), 9 ether);
        address f =
            pad.create("F", "F", "l", "m", address(wbnb), address(0), _mintCfg(10 ether, 50, 6_000, 100, 100), 1);
        vm.stopPrank();
        assertEq(vpad.vaultOf(c), address(0));
        assertEq(vpad.vaultOf(g), address(0));
        assertEq(vpad.vaultOf(f), address(0));
        // a listed vault cannot lock a token that is not bound to it
        vm.prank(alice);
        pad.buy(c, 0.1 ether, 0);
        vm.prank(alice);
        IERC20(c).approve(address(vault), 1 ether);
        vm.prank(alice, alice);
        vm.expectRevert(IGangVaultPad.NotVault.selector);
        vault.lock(c, 1 ether);
    }

    /// @dev createWithVault (in the module) records a token exactly as the pad's own createWithGradTarget does, but for
    ///      the vault binding: the same curve, graduation target, kind, rule version, logo, list entry and events.
    function test_createWithVault_sameRecordAsPadCreate() public {
        IGangLaunchpad.TaxConfig memory tax = _tax(200, 300, 5_000, address(0));
        tax.recipient = address(vault);
        vm.recordLogs();
        vm.prank(creator);
        address a = pad.createWithGradTarget("A", "A", "logo", "meta", address(wbnb), address(0), tax, 9 ether);
        bytes32[] memory eventsA = _eventIds(vm.getRecordedLogs());
        _grant(address(vault), creator);
        vm.recordLogs();
        vm.prank(creator);
        address b =
            vpad.createWithVault("A", "A", "logo", "meta", address(wbnb), address(0), tax, 9 ether, address(vault));
        bytes32[] memory eventsB = _eventIds(vm.getRecordedLogs());
        // the same events in the same order, but for the grant used up (first) and the binding (last)
        assertEq(eventsB.length, eventsA.length + 2, "two vault events more");
        assertEq(eventsB[0], VaultCreatorSet.selector);
        assertEq(eventsB[eventsB.length - 1], VaultBound.selector);
        for (uint256 i; i < eventsA.length; i++) {
            assertEq(eventsB[i + 1], eventsA[i], "same event");
        }
        GangLaunchpad3 p = _pad3();
        assertEq(p.allTokens(p.tokenCount() - 1), b);
        assertEq(p.allTokens(p.tokenCount() - 2), a);
        assertEq(p.kindOf(b), p.kindOf(a));
        assertEq(p.tokenVersionOf(b), p.tokenVersionOf(a));
        assertEq(p.gradTargetOf(b), p.gradTargetOf(a));
        assertEq(p.creatorFeeOf(b), p.creatorFeeOf(a));
        assertEq(p.logoURIOf(b), p.logoURIOf(a));
        assertEq(_curveSansPair(b), _curveSansPair(a), "same curve but its pair");
        (, bytes memory taxB) = address(p).staticcall(abi.encodeCall(Pad3Module.taxConfigOf, (b)));
        (, bytes memory taxA) = address(p).staticcall(abi.encodeCall(Pad3Module.taxConfigOf, (a)));
        assertEq(taxB, taxA, "same tax config");
        assertEq(vpad.vaultOf(a), address(0));
        assertEq(vpad.vaultOf(b), address(vault));
    }

    function _eventIds(Vm.Log[] memory logs) internal pure returns (bytes32[] memory ids) {
        ids = new bytes32[](logs.length);
        for (uint256 i; i < logs.length; i++) {
            ids[i] = logs[i].topics[0];
        }
    }

    function _curveSansPair(address t) internal view returns (bytes memory) {
        (
            address c,
            address q,
            uint128 rq,
            uint128 sold,
            uint128 g,
            uint128 vq,
            bool grad,
            uint16 bt,
            uint16 st,
            uint16 db,,
            address rp
        ) = _pad3().curves(t);
        return abi.encode(c, q, rq, sold, g, vq, grad, bt, st, db, rp);
    }

    // ---------------------------------------------------------------- the aggregator entry (3.0 only)
    function _pad3() internal view returns (GangLaunchpad3) {
        return GangLaunchpad3(payable(address(pad)));
    }

    /// @dev The entry's buy counts what `to` locked, as `buy` / `buyFor` do; its quote says so too.
    function test_entryBuy_capCountsLocked() public {
        address t = _untaxed();
        _buyToCap(t, alice);
        _lock(t, alice, LOCK_AMT);
        (,, uint256 amount,,,,,) = _pad3().tryBuy(t, alice, 0, 0.1 ether);
        assertEq(amount, 0, "no quote: at the cap with the locked amount");
        vm.deal(alice, 1 ether);
        vm.prank(alice, alice);
        vm.expectRevert(IGangLaunchpad.WalletCapReached.selector);
        _pad3().buyTokenAMAP{value: 0.1 ether}(t, alice, 0.1 ether, 0);
        // a sell of unlocked tokens makes room again, through the entry, up to the cap with the locked amount
        vm.prank(alice);
        IERC20(t).approve(address(pad), type(uint256).max);
        vm.prank(alice, alice);
        _pad3().sellToken(0, t, alice, 1_000_000 ether, 0, 0, address(0));
        (,, amount,,,,,) = _pad3().tryBuy(t, alice, 0, 0.01 ether);
        assertEq(amount, 1_000_000 ether, "quote trimmed to the room left");
        vm.prank(alice, alice);
        (uint256 out,) = _pad3().buyTokenAMAP{value: 0.01 ether}(t, alice, 0.01 ether, 0);
        assertEq(out, 1_000_000 ether);
        assertEq(IERC20(t).balanceOf(alice) + vpad.lockedOf(t, alice), MAX_PER_WALLET, "back at the cap");
    }

    /// @dev The token's vault never trades it through the entry either (not even as tx.origin), and gets no quote.
    function test_entry_vaultCannotTrade() public {
        address t = _untaxed();
        _buyToCap(t, alice);
        _lock(t, alice, LOCK_AMT);
        (,, uint256 amount,,,,,) = _pad3().tryBuy(t, address(vault), 0, 0.1 ether);
        assertEq(amount, 0, "no quote for the vault");
        (,, amount,,,,,) = _pad3().tryBuy(t, bob, 0, 0.1 ether);
        assertGt(amount, 0, "others still get one");
        vm.deal(address(vault), 1 ether);
        vm.prank(address(vault), address(vault));
        vm.expectRevert(IGangVaultPad.VaultCannotTrade.selector);
        _pad3().buyTokenAMAP{value: 0.1 ether}(t, address(vault), 0.1 ether, 0);
        vm.prank(address(vault));
        IERC20(t).approve(address(pad), LOCK_AMT);
        vm.prank(address(vault), address(vault));
        vm.expectRevert(IGangVaultPad.VaultCannotTrade.selector);
        _pad3().sellToken(0, t, address(vault), 1 ether, 0, 0, address(0));
    }

    /// @dev A holder's unlocked tokens sell through the entry as usual; the locked ones stay in the vault.
    function test_entrySell_unlockedOnly() public {
        address t = _untaxed();
        _buyToCap(t, alice);
        _lock(t, alice, LOCK_AMT);
        uint256 free = IERC20(t).balanceOf(alice);
        vm.prank(alice);
        IERC20(t).approve(address(pad), type(uint256).max);
        vm.prank(alice, alice);
        _pad3().sellToken(0, t, alice, free, 0, 0, address(0));
        assertEq(IERC20(t).balanceOf(alice), 0);
        assertEq(IERC20(t).balanceOf(address(vault)), LOCK_AMT, "the vault keeps the locked");
        assertEq(vpad.lockedOf(t, alice), LOCK_AMT);
    }

    // ---------------------------------------------------------------- the fallback and the module
    function test_fallback_unknownSelectorReverts() public {
        (bool ok,) = address(pad).call(abi.encodeWithSignature("noSuchFunction()"));
        assertFalse(ok);
        (ok,) = address(pad).call{value: 1}(abi.encodeWithSignature("noSuchFunction()"));
        assertFalse(ok);
    }

    /// @dev Value sent with a module call reverts (every module function is non-payable).
    function test_fallback_moduleCallWithValueReverts() public {
        vm.deal(owner, 1 ether);
        vm.prank(owner);
        (bool ok,) = address(pad).call{value: 1}(abi.encodeCall(Pad3Module.setVault, (address(otherVault), false)));
        assertFalse(ok);
        assertTrue(vpad.isVault(address(otherVault)));
    }

    /// @dev The module on its own: its own (empty) storage, owned by no one; nothing to take or set there.
    function test_module_directCallsDoNothing() public {
        Pad3Module m = Pad3Module(_pad3().module());
        assertEq(m.owner(), address(0xdEaD));
        vm.prank(owner);
        vm.expectRevert();
        m.setVault(address(vault), true);
        vm.prank(alice, alice);
        vm.expectRevert(IGangVaultPad.NotVault.selector);
        m.vaultLock(address(1), alice, 1);
        assertFalse(m.isVault(address(vault)));
    }

    // ---------------------------------------------------------------- vault-mode review fixes
    /// @dev The namespace the vault state lives in, pinned: SLOT as ERC-7201 computes it for "gang.pad3.vault", and
    ///      each member at its place (the compiler's storage layout doesn't show namespaces; members are only ever
    ///      appended).
    function test_vaultStore_slotAndMembersPinned() public {
        bytes32 slot = keccak256(abi.encode(uint256(keccak256("gang.pad3.vault")) - 1)) & ~bytes32(uint256(0xff));
        assertEq(Pad3VaultStore.SLOT, slot);
        address t = _untaxed(); // grants and uses up `creator` on `vault`
        _grant(address(otherVault), bob);
        _buyToCap(t, alice);
        _lock(t, alice, LOCK_AMT);
        uint256 base = uint256(slot);
        assertEq(_word(address(vault), base + 0), bytes32(uint256(1)), "isVault");
        assertEq(_word(t, base + 1), bytes32(uint256(uint160(address(vault)))), "vaultOf");
        bytes32 inner = keccak256(abi.encode(t, base + 2));
        assertEq(vm.load(address(pad), keccak256(abi.encode(alice, inner))), bytes32(LOCK_AMT), "lockedOf");
        assertEq(_word(address(vault), base + 3), bytes32(uint256(1)), "everVault");
        assertEq(_word(address(otherVault), base + 4), bytes32(uint256(uint160(bob))), "vaultCreator");
        // a delisted vault tells isVault (0) from everVault (1)
        address gone = address(new MockLockVault(vpad));
        vm.startPrank(owner);
        vpad.setVault(gone, true);
        vpad.setVault(gone, false);
        vm.stopPrank();
        assertEq(_word(gone, base + 0), bytes32(0), "isVault cleared");
        assertEq(_word(gone, base + 3), bytes32(uint256(1)), "everVault kept");
    }

    function _word(address key, uint256 mappingSlot) internal view returns (bytes32) {
        return vm.load(address(pad), keccak256(abi.encode(key, mappingSlot)));
    }

    /// @dev The upgrade script's snapshot reads the vault state: a member moved by an upgrade (here: what a holder
    ///      locked) changes it.
    function test_upgradeSnapshot_seesVaultState() public {
        VaultSnapHarness h = new VaultSnapHarness();
        assertTrue(h.servesVaultMode(address(pad)));
        IGangLaunchpad.TaxConfig memory tax = _tax(0, 0, 0, address(0));
        _grant(address(vault), creator);
        vm.prank(creator);
        address t = vpad.createWithVault("V", "V", "l", "m", address(wbnb), address(0), tax, 9 ether, address(vault));
        vault.approvePad(t);
        _buyToCap(t, creator);
        _lock(t, creator, LOCK_AMT);
        bytes memory before = h.vaultState(_pad3(), t);
        bytes32 inner = keccak256(abi.encode(t, uint256(Pad3VaultStore.SLOT) + 2));
        vm.store(address(pad), keccak256(abi.encode(creator, inner)), bytes32(0));
        assertTrue(keccak256(h.vaultState(_pad3(), t)) != keccak256(before), "a changed lockedOf shows");
    }

    /// @dev A selector of the module that the pad also defines never reaches the module: only the six shared on
    ///      purpose (Ownable2Step's, TOKEN_VERSION) may overlap; anything else would be a module function shadowed.
    function test_moduleSelectors_onlyExpectedOverlap() public view {
        string memory pj = vm.readFile(string.concat(vm.projectRoot(), "/out/GangLaunchpad3.sol/GangLaunchpad3.json"));
        string memory mj = vm.readFile(string.concat(vm.projectRoot(), "/out/Pad3Module.sol/Pad3Module.json"));
        string[] memory padSigs = vm.parseJsonKeys(pj, ".methodIdentifiers");
        string[] memory modSigs = vm.parseJsonKeys(mj, ".methodIdentifiers");
        string[6] memory shared = [
            "TOKEN_VERSION()",
            "acceptOwnership()",
            "owner()",
            "pendingOwner()",
            "renounceOwnership()",
            "transferOwnership(address)"
        ];
        uint256 overlap;
        for (uint256 i; i < modSigs.length; i++) {
            bytes4 sel = bytes4(keccak256(bytes(modSigs[i])));
            for (uint256 j; j < padSigs.length; j++) {
                if (bytes4(keccak256(bytes(padSigs[j]))) != sel) continue;
                overlap++;
                bool ok;
                for (uint256 k; k < 6; k++) {
                    if (keccak256(bytes(modSigs[i])) == keccak256(bytes(shared[k]))) ok = true;
                }
                assertTrue(ok, string.concat("module function shadowed by the pad: ", modSigs[i]));
            }
        }
        assertEq(overlap, 6);
    }

    /// @dev The two tax-config previews, through the pad (the module): a listed recipient passes either; the creator
    ///      itself only `checkTaxConfigFor` it; anyone else neither.
    function test_checkTaxConfig_throughThePad() public view {
        Pad3Module m = Pad3Module(address(pad));
        (bool ok,) = m.checkTaxConfig(_tax(200, 300, 0, address(vault)));
        assertTrue(ok, "listed recipient");
        (ok,) = m.checkTaxConfig(_tax(200, 300, 0, creator));
        assertFalse(ok, "unlisted");
        (ok,) = m.checkTaxConfigFor(creator, _tax(200, 300, 0, creator));
        assertTrue(ok, "the creator itself");
        string memory reason;
        (ok, reason) = m.checkTaxConfigFor(creator, _tax(200, 300, 0, alice));
        assertFalse(ok);
        assertGt(bytes(reason).length, 0);
        (ok,) = m.checkTaxConfig(_tax(0, 0, 0, address(0)));
        assertTrue(ok, "untaxed");
    }

    /// @dev Vault-mode review L-1: an EIP-7702 delegated EOA (23-byte designator) is not a vault.
    function test_setVault_refuses7702Designator() public {
        address eoa = makeAddr("delegated-eoa");
        vm.etch(eoa, abi.encodePacked(hex"ef0100", address(vault)));
        vm.prank(owner);
        vm.expectRevert(IGangVaultPad.VaultNotContract.selector);
        vpad.setVault(eoa, true);
    }

    /// @dev `tryBuy` with no trader (a fresh wallet) still quotes a vault-bound token.
    function test_tryBuy_noTrader_quotesVaultToken() public {
        address t = _untaxed();
        (,, uint256 amount,,,,,) = _pad3().tryBuy(t, address(0), 0, 0.1 ether);
        assertGt(amount, 0);
    }
}
