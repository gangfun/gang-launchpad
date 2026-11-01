// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {GangTestnetRefs as T} from "../config/GangDeployRefs.sol";
import {SharedDividendVault} from "../src/common/SharedDividendVault.sol";
import {IGangPad} from "../src/gang/interfaces/IGangPad.sol";
import {IGangLaunchpad} from "../src/gang/interfaces/IGangLaunchpad.sol";
import {IGangVaultPad} from "../src/gang/interfaces/IGangVaultPad.sol";
import {IGangTaxHandlerOps} from "../src/gang/interfaces/IGangTaxHandlerOps.sol";
import {GangTaxHandler} from "./GangContracts.sol";

interface IGangRouterBnbV {
    function v3BuyBNB(address token, uint256 minTokensOut, uint256 deadline) external payable returns (uint256);
}

interface IMintableQuoteV {
    function mintUnlimited(address to, uint256 amount) external;
}

/// @title TestnetLockVault — a stand-in lock vault for testnet acceptance (NEVER for mainnet)
/// @notice Locks and releases for whoever calls it, as the pad expects of a vault: the user is `msg.sender`
///         and must be `tx.origin`. It keeps no per-user books (anyone can release anything it holds): it only drives
///         the pad's two entries. After graduation `vaultRelease` reverts `AlreadyGraduated`; it then pays with a
///         plain transfer, as a vault must.
contract TestnetLockVault {
    IGangVaultPad public immutable pad;

    error NotOrigin();

    constructor(IGangVaultPad pad_) {
        pad = pad_;
    }

    /// @dev Once per token: `vaultRelease` spends this allowance.
    function approvePad(address token) external {
        IERC20(token).approve(address(pad), type(uint256).max);
    }

    function lock(address token, uint256 amount) external {
        if (msg.sender != tx.origin) revert NotOrigin();
        pad.vaultLock(token, msg.sender, amount);
    }

    function release(address token, uint256 amount) external {
        if (msg.sender != tx.origin) revert NotOrigin();
        try pad.vaultRelease(token, msg.sender, amount) {}
        catch (bytes memory reason) {
            if (reason.length < 4 || bytes4(reason) != IGangLaunchpad.AlreadyGraduated.selector) {
                assembly ("memory-safe") {
                    revert(add(reason, 32), mload(reason))
                }
            }
            if (!IERC20(token).transfer(msg.sender, amount)) revert();
        }
    }
}

/// @title GangVaultLaunchpadTestnetAcceptance — GangVaultLaunchpad's lock / release end to end on BSC testnet
/// @notice With the deploy wallet (an Agent ID holder, owner of the vault pad and its handler), each step checked in
///         the simulation forge runs before it broadcasts:
///         0. the vault: TEST_VAULT, or a new TestnetLockVault; listed on the pad and on the handler (tax recipient).
///         A. a taxed WBNB token (3% / 3%, no dividend, the vault its recipient, 9 BNB) from `createWithVault`; buy
///            0.002 BNB through the vault pad's router; lock half into the vault (booked as `lockedOf`, the buy room
///            down by it); release most of it (back to the wallet, the rest stays in the vault); sell what came back.
///         B. a taxed test-quote token with dividends (3% / 3%, 40%, the vault its recipient, 6 BNB): buy, lock half,
///            release most of it (the dividend shares follow balances each time); then, with the wallet cap off for the run,
///            buy to graduation through the live migrator; the vault pays the rest back after graduation with a plain
///            transfer (`vaultRelease` closed), the token now syncing shares itself.
/// @dev TESTNET ONLY. Env: DEPLOYER_PRIVATE_KEY, GANG_VAULT_PAD, GANG_VAULT_ROUTER, TEST_QUOTE (default the testnet
///      one), TEST_VAULT (optional). Run with `--tc GangVaultLaunchpadTestnetAcceptance`.
///      The wallet cap is turned off and on in separate transactions: if the graduating buy fails on chain (forge
///      stops), the cap stays off; a re-run turns it back on first, else
///      `cast send <pad> "setWalletCapEnabled(bool)" true`.
contract GangVaultLaunchpadTestnetAcceptance is Script {
    uint256 internal constant MAX_PER_WALLET = 10_000_000 ether;

    error WrongChain(uint256 chainId);
    error Check(string what);

    struct Ctx {
        uint256 pk;
        address me;
        IGangPad pad;
        IGangVaultPad vpad;
        TestnetLockVault vault;
    }

    function run() external {
        if (block.chainid != 97) revert WrongChain(block.chainid);
        Ctx memory x;
        x.pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        x.me = vm.addr(x.pk);
        x.pad = IGangPad(vm.envAddress("GANG_VAULT_PAD"));
        x.vpad = IGangVaultPad(address(x.pad));
        address router = vm.envAddress("GANG_VAULT_ROUTER");
        address testQuote = vm.envOr("TEST_QUOTE", T.TEST_QUOTE);
        if (x.vpad.vaultOf(address(0)) != address(0)) revert Check("not a vault pad");
        if (!x.pad.routers(router)) revert Check("router not listed");
        if (Ownable(address(x.pad)).owner() != x.me) revert Check("deploy wallet is not the pad owner");
        if (Ownable(x.pad.taxHandler()).owner() != x.me) revert Check("deploy wallet is not the handler owner");
        if (!x.pad.isAgent(x.me)) revert Check("deploy wallet holds no Agent ID");
        if (x.pad.migrator() == address(0)) revert Check("pad not open");

        address v = vm.envOr("TEST_VAULT", address(0));
        if (v != address(0) && address(TestnetLockVault(v).pad()) != address(x.vpad)) {
            revert Check("TEST_VAULT is not a TestnetLockVault of this pad");
        }
        vm.startBroadcast(x.pk);
        if (!x.pad.walletCapEnabled()) x.pad.setWalletCapEnabled(true); // an earlier run stopped mid-way
        x.vault = v == address(0) ? new TestnetLockVault(x.vpad) : TestnetLockVault(v);
        if (!x.vpad.isVault(address(x.vault))) x.vpad.setVault(address(x.vault), true);
        GangTaxHandler h = GangTaxHandler(x.pad.taxHandler());
        if (!h.isListed(address(x.vault))) IGangTaxHandlerOps(address(h)).list(address(x.vault), "testnet lock vault");
        vm.stopBroadcast();
        console.log("vault", address(x.vault));

        _wbnbToken(x, router);
        _dividendToken(x, testQuote);
        console.log("acceptance ok");
    }

    function _tax(uint16 dividendBps, address recipient) internal pure returns (IGangLaunchpad.TaxConfig memory) {
        return
            IGangLaunchpad.TaxConfig({buyTaxBps: 300, sellTaxBps: 300, dividendBps: dividendBps, recipient: recipient});
    }

    function _create(Ctx memory x, string memory sym, address quote, uint16 divBps, uint256 gradBnb)
        internal
        returns (address t)
    {
        vm.startBroadcast(x.pk);
        x.vpad.setVaultCreator(address(x.vault), x.me); // only the named wallet binds a token to the vault, once
        t = x.vpad
            .createWithVault(
                string.concat("Vault ", sym),
                sym,
                "",
                "",
                quote,
                address(0),
                _tax(divBps, address(x.vault)),
                gradBnb,
                address(x.vault)
            );
        x.vault.approvePad(t);
        vm.stopBroadcast();
        if (x.vpad.vaultOf(t) != address(x.vault)) revert Check("vaultOf");
        // single use: the grant is cleared, and `createWithVault` only takes msg.sender == vaultCreator (never 0)
        if (x.vpad.vaultCreator(address(x.vault)) != address(0)) revert Check("grant not used up");
        if (x.pad.gradTargetOf(t) != gradBnb) revert Check("grad target");
    }

    /// @dev Lock `amount` of the wallet's `t` into the vault; checks the books and the buy room.
    function _lock(Ctx memory x, address t, uint256 amount) internal {
        uint256 bal0 = IERC20(t).balanceOf(x.me);
        uint256 vb0 = IERC20(t).balanceOf(address(x.vault));
        uint256 l0 = x.vpad.lockedOf(t, x.me);
        vm.startBroadcast(x.pk);
        IERC20(t).approve(address(x.vault), amount);
        x.vault.lock(t, amount);
        vm.stopBroadcast();
        if (IERC20(t).balanceOf(x.me) != bal0 - amount) revert Check("lock: wallet");
        if (IERC20(t).balanceOf(address(x.vault)) != vb0 + amount) revert Check("lock: vault");
        if (x.vpad.lockedOf(t, x.me) != l0 + amount) revert Check("lock: lockedOf");
        _checkRoom(x, t);
    }

    /// @dev Release `amount` from the vault to the wallet (before graduation): uncapped, `lockedOf` down by it.
    function _release(Ctx memory x, address t, uint256 amount) internal {
        uint256 bal0 = IERC20(t).balanceOf(x.me);
        uint256 vb0 = IERC20(t).balanceOf(address(x.vault));
        uint256 l0 = x.vpad.lockedOf(t, x.me);
        vm.startBroadcast(x.pk);
        x.vault.release(t, amount);
        vm.stopBroadcast();
        if (IERC20(t).balanceOf(x.me) != bal0 + amount) revert Check("release: wallet");
        if (IERC20(t).balanceOf(address(x.vault)) != vb0 - amount) revert Check("release: vault");
        if (x.vpad.lockedOf(t, x.me) != (amount >= l0 ? 0 : l0 - amount)) revert Check("release: lockedOf");
        _checkRoom(x, t);
    }

    /// @dev The 1% room counts what the wallet holds and what it has locked.
    function _checkRoom(Ctx memory x, address t) internal view {
        uint256 held = IERC20(t).balanceOf(x.me) + x.vpad.lockedOf(t, x.me);
        uint256 room = held >= MAX_PER_WALLET ? 0 : MAX_PER_WALLET - held;
        if (x.pad.walletRoom(t, x.me) != room) revert Check("walletRoom = 1% - balance - locked");
    }

    /// @dev A dividend token's shares follow balances (the vault's included).
    function _checkShares(Ctx memory x, address t) internal view {
        SharedDividendVault dv = SharedDividendVault(x.pad.dividendVault());
        uint256 floor = dv.tokenMinimumShareBalance(t);
        address[2] memory who = [x.me, address(x.vault)];
        for (uint256 i; i < 2; i++) {
            uint256 b = IERC20(t).balanceOf(who[i]);
            if (dv.shares(t, who[i]) != (b > floor ? b : 0)) revert Check("dividend share = balance");
        }
    }

    function _wbnbToken(Ctx memory x, address router) internal {
        address t = _create(x, "VLA", x.pad.wbnb(), 0, 9 ether);
        console.log("A token", t);

        vm.startBroadcast(x.pk);
        IGangRouterBnbV(router).v3BuyBNB{value: 0.002 ether}(t, 0, block.timestamp + 600);
        vm.stopBroadcast();
        uint256 bought = IERC20(t).balanceOf(x.me);
        if (bought == 0) revert Check("A buy");
        _checkRoom(x, t);

        uint256 locked = bought / 2;
        _lock(x, t, locked);
        uint256 back = (locked * 3) / 4;
        _release(x, t, back);
        if (IERC20(t).balanceOf(address(x.vault)) != locked - back) revert Check("A: the rest stays in the vault");

        uint256 bal = IERC20(t).balanceOf(x.me);
        vm.startBroadcast(x.pk);
        IERC20(t).approve(address(x.pad), back);
        uint256 out = x.pad.sell(t, back, 0);
        vm.stopBroadcast();
        if (out == 0 || IERC20(t).balanceOf(x.me) != bal - back) revert Check("A: released tokens sell");
        console.log("A locked / released / sold", locked, back);
    }

    function _dividendToken(Ctx memory x, address testQuote) internal {
        address t = _create(x, "VLB", testQuote, 4_000, 6 ether);
        console.log("B token", t);
        uint256 grad = x.pad.gradAmtOf(t);

        vm.startBroadcast(x.pk);
        IMintableQuoteV(testQuote).mintUnlimited(x.me, grad * 2);
        IERC20(testQuote).approve(address(x.pad), type(uint256).max);
        x.pad.buy(t, grad / 50, 0);
        vm.stopBroadcast();
        uint256 bought = IERC20(t).balanceOf(x.me);
        if (bought == 0) revert Check("B buy");
        _checkShares(x, t);

        uint256 locked = bought / 2;
        _lock(x, t, locked);
        _checkShares(x, t);
        uint256 back = (locked * 3) / 4;
        _release(x, t, back);
        _checkShares(x, t);

        vm.startBroadcast(x.pk);
        x.pad.setWalletCapEnabled(false);
        x.pad.buy(t, (grad * 3) / 2, 0); // past the graduation amount: the cut comes back
        x.pad.setWalletCapEnabled(true);
        vm.stopBroadcast();
        (,,,,,, bool graduated,,,, address pair,) = x.pad.curves(t);
        if (!graduated || pair == address(0)) revert Check("B graduated");
        if (!x.pad.walletCapEnabled()) revert Check("wallet cap back on");
        console.log("B graduated, pair", pair);

        uint256 rest = IERC20(t).balanceOf(address(x.vault));
        uint256 bal = IERC20(t).balanceOf(x.me);
        vm.startBroadcast(x.pk);
        x.vault.release(t, rest); // vaultRelease is closed: the vault's plain transfer
        vm.stopBroadcast();
        if (IERC20(t).balanceOf(x.me) != bal + rest || IERC20(t).balanceOf(address(x.vault)) != 0) {
            revert Check("B: paid back after graduation");
        }
        _checkShares(x, t);
        console.log("B paid back after graduation", rest);
    }
}
