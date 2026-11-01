// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SharedDividendVault} from "../common/SharedDividendVault.sol";
import {IGangPadToken} from "./interfaces/IGangPadDeps.sol";
import {IGangVaultPad} from "./interfaces/IGangVaultPad.sol";
import {GangLaunchpad} from "./GangLaunchpad.sol";
import {PadCommon} from "./PadCommon.sol";

/// @title GangVaultLaunchpad — GangLaunchpad 2.0 with a vault per curve token (SPEC-VAULT-LOCK-2026-11-01)
/// @notice Everything of GangLaunchpad 2.0 (curve, 1% fee with the creator's 70%, graduation tiers, router entries,
///         graduation), plus: each token is created bound to one listed vault contract (`createWithVault`, fixed for
///         good), and while the token is locked (before graduation) that vault can
///         - `vaultLock`: move `user`'s tokens into the vault (the allowance `user` gave the vault), and
///         - `vaultRelease`: move tokens from the vault back to `user` (the allowance the vault gave this pad).
///         Only the wallet the owner names for a vault (`setVaultCreator`) can create a token bound to it, once per
///         grant, so nobody else can attach a token to someone's vault.
///         `user` is always the wallet that sent the tx and holds an Agent ID. What `user` locked counts against their
///         1% wallet cap (`lockedOf`, `walletRoom`); a release is not capped (a wallet past 1% just cannot buy).
///         GangToken is unchanged: both moves are transfers the pad makes (`pullFor`, from the pad, or
///         `msg.sender == launchpad`). The other creates (`create`, `createWithGradTarget`, 打新) revert here.
/// @dev The rules hold whatever the vault's code does (spec §4.3): the vault can only move the tx sender's tokens
///      with the sender's own allowance, and its own tokens to the tx sender, who must be an Agent; never to another
///      contract (the future pair can never be tx.origin). The curve's books (`sold`, `realQuote`, `creatorFeeOf`) are
///      never touched here. After graduation the token is unlocked and both entries revert (plain transfers work).
contract GangVaultLaunchpad is GangLaunchpad, IGangVaultPad {
    using SafeERC20 for IERC20;

    /// @inheritdoc IGangVaultPad
    mapping(address vault => bool) public isVault;
    /// @inheritdoc IGangVaultPad
    mapping(address token => address) public vaultOf;
    /// @inheritdoc IGangVaultPad
    mapping(address token => mapping(address user => uint256)) public lockedOf;
    /// @notice Ever listed as a vault (never cleared): such an address can never become a router, since tokens stay
    ///         bound to it and users' lock allowances to it stay live after a delisting (re-review 2026-11-01 L-1).
    mapping(address vault => bool) public everVault;
    /// @inheritdoc IGangVaultPad
    /// @dev Single use: `createWithVault` clears it, so each grant binds one token (the owner can grant again).
    mapping(address vault => address) public vaultCreator;

    constructor(
        address owner_,
        address quoteRegistry_,
        address dividendVault_,
        address platformBucket_,
        address taxHandler_,
        address tokenDeployer_,
        address wbnb_,
        address pairFactory_
    )
        GangLaunchpad(
            owner_, quoteRegistry_, dividendVault_, platformBucket_, taxHandler_, tokenDeployer_, wbnb_, pairFactory_
        )
    {}

    // ---------------------------------------------------------------- admin
    /// @notice List / delist a vault. Delisting stops new tokens from binding it and stops new locks; releases from it
    ///         stay open, so tokens are never stuck in it.
    ///         A vault must be a contract when listed (not checked on delisting, so it can always be delisted) and never a
    ///         router (one allowance would then serve both: `sellFor` could spend what a user approved for a lock).
    ///         Delisting also drops the vault's creator grant, so a later re-listing never revives a forgotten one.
    function setVault(address vault, bool enabled) external onlyOwner {
        if (enabled) {
            if (vault.code.length == 0) revert VaultNotContract();
            if (routers[vault]) revert VaultIsRouter();
            everVault[vault] = true;
        } else if (vaultCreator[vault] != address(0)) {
            delete vaultCreator[vault];
            emit VaultCreatorSet(vault, address(0));
        }
        isVault[vault] = enabled;
        emit VaultSet(vault, enabled);
    }

    /// @notice Name the wallet that may create the next token bound to `vault` (a listed vault; 0 revokes), so a vault
    ///         binds only the token its own project creates: without this, any Agent could attach a new token to it.
    function setVaultCreator(address vault, address creator) external onlyOwner {
        if (creator != address(0) && !isVault[vault]) revert NotVault();
        vaultCreator[vault] = creator;
        emit VaultCreatorSet(vault, creator);
    }

    /// @notice As GangLaunchpad's, but an address ever listed as a vault can't become a router, even once delisted
    ///         (see `setVault`, `everVault`).
    function setRouter(address router_, bool enabled) external override onlyOwner {
        if (router_ == address(0)) revert ZeroAddress();
        if (enabled && everVault[router_]) revert VaultIsRouter();
        routers[router_] = enabled;
        emit RouterSet(router_, enabled);
    }

    // ---------------------------------------------------------------- create
    /// @notice `createWithGradTarget` with the token bound to `vault` (listed) for good. Only by
    ///         `vaultCreator[vault]`, which this clears (one token per grant).
    function createWithVault(
        string calldata name,
        string calldata symbol,
        string calldata logoURI,
        string calldata metaURI,
        address quote,
        address refPool,
        TaxConfig calldata tax,
        uint256 gradBnb,
        address vault
    ) external nonReentrant returns (address token) {
        if (!isVault[vault]) revert NotVault();
        if (msg.sender != vaultCreator[vault]) revert NotVaultCreator();
        delete vaultCreator[vault];
        emit VaultCreatorSet(vault, address(0));
        token = _createCurve(name, symbol, logoURI, metaURI, quote, refPool, tax, gradBnb);
        vaultOf[token] = vault;
        emit VaultBound(token, vault);
    }

    function create(
        string calldata,
        string calldata,
        string calldata,
        string calldata,
        address,
        address,
        TaxConfig calldata
    ) external pure override returns (address) {
        revert UseVaultCreate();
    }

    function createWithGradTarget(
        string calldata,
        string calldata,
        string calldata,
        string calldata,
        address,
        address,
        TaxConfig calldata,
        uint256
    ) external pure override returns (address) {
        revert UseVaultCreate();
    }

    function create(
        string calldata,
        string calldata,
        string calldata,
        string calldata,
        address,
        address,
        MintConfig calldata,
        uint256
    ) external pure override returns (address) {
        revert UseVaultCreate();
    }

    // ---------------------------------------------------------------- vault entries
    /// @notice The vault moves `amount` of `user`'s tokens into itself, spending the allowance `user` gave the vault.
    ///         Before graduation only; `user` = tx.origin, an Agent; the vault still listed. Books `lockedOf`.
    function vaultLock(address token, address user, uint256 amount) external nonReentrant {
        uint16 dividendBps = _vaultEntry(token, user, amount);
        if (!isVault[msg.sender]) revert VaultDelisted();

        IGangPadToken(token).pullFor(user, msg.sender, amount); // user → pad
        IERC20(token).safeTransfer(msg.sender, amount); // pad → vault
        lockedOf[token][user] += amount;

        _syncShares(token, dividendBps, user);
        emit VaultLocked(token, msg.sender, user, amount);
    }

    /// @notice The vault moves `amount` of its tokens to `user`, spending the allowance the vault gave this pad.
    ///         Before graduation only; `user` = tx.origin, an Agent; not capped at 1%. Listed or not (never stuck).
    ///         `lockedOf[token][user]` goes down by up to `amount`.
    function vaultRelease(address token, address user, uint256 amount) external nonReentrant {
        uint16 dividendBps = _vaultEntry(token, user, amount);

        IERC20(token).safeTransferFrom(msg.sender, user, amount); // vault → user (msg.sender to the token = pad)
        uint256 locked = lockedOf[token][user];
        lockedOf[token][user] = amount >= locked ? 0 : locked - amount;

        _syncShares(token, dividendBps, user);
        emit VaultReleased(token, msg.sender, user, amount);
    }

    // ---------------------------------------------------------------- internal
    /// @dev Shared checks: the caller is `token`'s vault (so `token` is a curve token of this pad), the curve is live
    ///      (the token still locked), `amount` > 0, `user` sent the tx and is an Agent.
    function _vaultEntry(address token, address user, uint256 amount) private view returns (uint16 dividendBps) {
        if (msg.sender != vaultOf[token] || msg.sender == address(0)) revert NotVault();
        Curve storage cv = curves[token];
        if (cv.graduated) revert AlreadyGraduated();
        if (amount == 0) revert ZeroAmount();
        if (user != tx.origin) revert TraderNotOrigin();
        if (user == msg.sender) revert NotVault(); // a vault that is tx.origin (EIP-7702) can't lock / release to itself
        if (!PadCommon.isAgent(_config, user)) revert NotAgent();
        dividendBps = cv.dividendBps;
    }

    /// @dev A dividend token's shares follow balances (the pad writes them before graduation): the user's and the
    ///      vault's.
    function _syncShares(address token, uint16 dividendBps, address user) private {
        if (dividendBps == 0) return;
        SharedDividendVault vault = dividendVault;
        vault.setShare(token, user, IERC20(token).balanceOf(user));
        vault.setShare(token, msg.sender, IERC20(token).balanceOf(msg.sender));
    }

    /// @dev The token's own vault never trades it on the curve (audit 2026-11-01 H-1 / M-1): its tokens can then only
    ///      come from `vaultLock`, each one booked against the locker's 1%, and only leave through `vaultRelease`.
    function _checkCurveTrader(address token, address trader) internal view override {
        if (trader == vaultOf[token]) revert VaultCannotTrade();
    }

    function _lockedOf(address token, address user) internal view override returns (uint256) {
        return lockedOf[token][user];
    }
}
