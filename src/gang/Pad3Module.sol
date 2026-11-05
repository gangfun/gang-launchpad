// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SharedDividendVault} from "../common/SharedDividendVault.sol";
import {IGangLaunchpad} from "./interfaces/IGangLaunchpad.sol";
import {IGangLaunchpad3} from "./interfaces/IGangLaunchpad3.sol";
import {IGangVaultPad} from "./interfaces/IGangVaultPad.sol";
import {IGangPromote} from "./interfaces/IGangPromote.sol";
import {IGangPadToken, IGangPadHandler} from "./interfaces/IGangPadDeps.sol";
import {PadCommon} from "./PadCommon.sol";
import {CurveLogic3 as CurveLogic} from "./CurveLogic3.sol";
import {FairLogic} from "./FairLogic.sol";
import {Pad3VaultStore} from "./Pad3VaultStore.sol";
import {Pad3FlyStore} from "./Pad3FlyStore.sol";
import {Pad3PromoteStore} from "./Pad3PromoteStore.sol";

/// @title Pad3Module — GangLaunchpad 3.0's second half: the vault mode (GangVaultLaunchpad's rules, on the one 3.0
///        address) and the pad's off-chain views (moved out of the pad for its 24 KB limit)
/// @notice Never called directly: GangLaunchpad3's fallback delegatecalls it for these selectors, so it runs in the
///         proxy's storage, with the proxy's balance and the caller as msg.sender. The same rules as GangVaultLaunchpad:
///         a curve token can be created bound to one listed vault (`createWithVault`, by the wallet the owner named,
///         once per grant), and while the token is on its curve that vault can
///         - `vaultLock`: move `user`'s tokens into itself (the allowance `user` gave the vault), and
///         - `vaultRelease`: move its tokens back to `user` (the allowance the vault gave the pad).
///         `user` is always the wallet that sent the tx and holds an Agent ID. What `user` locked counts against their
///         1% wallet cap (the pad's `_lockedOf`), a release is not capped. A token's own vault never trades it on the
///         curve (the pad's `_checkCurveTrader`), and an address ever listed as a vault never becomes a router (the
///         pad's `setRouter`). Unlike GangVaultLaunchpad, the other creates stay open: 3.0 serves every mode.
///         Also the promoter share's entries (docs/SPEC-PROMOTER-SHARE-2026-11-04.md): the split itself is CurveLogic3's.
/// @dev STORAGE: slots 0–2 are OZ Ownable / Ownable2Step / ReentrancyGuard (the pad's `onlyOwner` and `nonReentrant`
///      act on the proxy's), then a mirror of GangLaunchpad3's variables in its order (only some are used here), which
///      test/gang3/GangLaunchpad3Layout.t.sol checks slot by slot against the pad's layout. Vault state is in
///      Pad3VaultStore's namespace. The dependencies are this module's own immutables, set to the pad's (the deploy
///      and upgrade scripts check they are equal).
interface IWBNBDeposit {
    function deposit() external payable;
}

contract Pad3Module is IGangLaunchpad, IGangLaunchpad3, IGangVaultPad, IGangPromote, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint8 internal constant KIND_CURVE = CurveLogic.KIND;
    uint8 internal constant KIND_FLY = 3;
    /// @notice Must equal GangLaunchpad3.TOKEN_VERSION (the scripts and tests check it).
    uint8 public constant TOKEN_VERSION = 1;
    /// @notice The most of the creator's fee a promoter can get. A promoter thus earns at most 0.35% of a trade that pays
    ///         1%: trading under your own link always costs more than it earns.
    uint16 public constant MAX_PROMOTE_BPS = 5_000;
    uint32 public constant MIN_PROMOTE_WINDOW = 7 days;
    uint32 public constant MAX_PROMOTE_WINDOW = 90 days;

    // ---------------------------------------------------------------- mirror of GangLaunchpad3's layout (slot 3 on)
    Config internal _config;
    mapping(address => address) internal bridgePoolOf;
    mapping(address router => bool) internal routers;
    mapping(address token => uint8) internal kindOf;
    mapping(address token => Curve) internal curves;
    mapping(address token => Sale) internal _sales;
    mapping(address token => mapping(address user => Position)) internal positions;
    mapping(address token => string) internal logoURIOf;
    mapping(address quote => uint256) internal owedFee;
    address[] internal allTokens;
    mapping(address token => uint256) internal creatorFeeOf;
    mapping(address token => uint256) internal gradTargetOf;
    mapping(address token => uint8) internal tokenVersionOf;
    mapping(address caller => bool) internal isCaller;

    // ---------------------------------------------------------------- the pad's dependencies (this module's copy)
    address internal immutable quoteRegistry;
    address internal immutable dividendVault;
    address internal immutable platformBucket;
    address internal immutable taxHandler;
    address internal immutable tokenDeployer;
    address internal immutable wbnb;
    /// @notice 3.0's 铸币飞轮 module (Pad3FlyModule): every selector this module does not define runs there,
    ///         delegatecalled (the pad's call, still in the proxy's storage). The last link: it has no fallback.
    address public immutable flyModule;

    constructor(
        address quoteRegistry_,
        address dividendVault_,
        address platformBucket_,
        address taxHandler_,
        address tokenDeployer_,
        address wbnb_,
        address flyModule_
    ) Ownable(address(0xdEaD)) {
        if (
            quoteRegistry_ == address(0) || dividendVault_ == address(0) || platformBucket_ == address(0)
                || taxHandler_ == address(0) || tokenDeployer_ == address(0) || wbnb_ == address(0)
                || flyModule_ == address(0)
        ) revert ZeroAddress();
        flyModule = flyModule_;
        quoteRegistry = quoteRegistry_;
        dividendVault = dividendVault_;
        platformBucket = platformBucket_;
        taxHandler = taxHandler_;
        tokenDeployer = tokenDeployer_;
        wbnb = wbnb_;
    }

    /// @notice Selectors not defined here (the 铸币飞轮 mode): Pad3FlyModule's.
    fallback() external payable {
        _toFly();
    }

    /// @dev This call, as it came, delegatecalled to the 铸币飞轮 module (never comes back).
    function _toFly() internal {
        address m = flyModule;
        // memory-safe: execution ends here (return / revert), no Solidity code reads memory after it
        assembly ("memory-safe") {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), m, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch ok
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    /// @dev `_toFly` from a view (the 铸币飞轮 module's function is a view too).
    function _toFlyView() internal view {
        function() internal f = _toFly;
        function() internal view v;
        assembly ("memory-safe") {
            v := f
        }
        v();
    }

    /// @dev Views shared by 打新 and 铸币飞轮 by name: a 铸币飞轮 token's are the 铸币飞轮 module's (V2's).
    modifier flyToModuleView(address token) {
        if (kindOf[token] == KIND_FLY) _toFlyView();
        _;
    }

    /// @notice Tokens a whole share holds for `token`: 50,000 for 3.0's 打新, 100,000 for its 铸币飞轮, 0 otherwise
    ///         (curves; an older pad's token: its pad's `TOKENS_PER_SHARE`). Sells of share tokens through the entry
    ///         take whole shares only.
    function shareSizeOf(address token) external view returns (uint256) {
        uint8 kind = kindOf[token];
        if (kind == FairLogic.KIND) return FairLogic.TOKENS_PER_SHARE;
        if (kind == KIND_FLY) return FLY_TOKENS_PER_SHARE;
        return 0;
    }

    /// @dev FlywheelLogic.TOKENS_PER_SHARE (Pad3FlyModule checks it equals)
    uint256 internal constant FLY_TOKENS_PER_SHARE = 100_000 ether;

    /// @notice This module's dependencies (through the pad: the module's own; the scripts compare them with the pad's).
    function moduleDeps() external view returns (Deps memory) {
        return _deps();
    }

    // ---------------------------------------------------------------- admin
    /// @notice List / delist a vault. Delisting stops new tokens from binding it and stops new locks; releases from it
    ///         stay open, so tokens are never stuck in it. A vault must be a contract when listed (not an EIP-7702
    ///         delegated EOA, as the pad's routers and callers) and never a router; delisting also drops the vault's
    ///         creator grant.
    function setVault(address vault, bool enabled) external onlyOwner {
        Pad3VaultStore.Layout storage v = Pad3VaultStore.layout();
        if (enabled) {
            if (!_isPlainContract(vault)) revert VaultNotContract();
            // neither router list of the pad (re-review I-2: the 铸币飞轮 one too)
            if (routers[vault] || Pad3FlyStore.layout().routers[vault]) revert VaultIsRouter();
            v.everVault[vault] = true;
        } else if (v.vaultCreator[vault] != address(0)) {
            delete v.vaultCreator[vault];
            emit VaultCreatorSet(vault, address(0));
        }
        v.isVault[vault] = enabled;
        emit VaultSet(vault, enabled);
    }

    /// @notice Name the wallet that may create the next token bound to `vault` (a listed vault; 0 revokes).
    function setVaultCreator(address vault, address creator) external onlyOwner {
        Pad3VaultStore.Layout storage v = Pad3VaultStore.layout();
        if (creator != address(0) && !v.isVault[vault]) revert NotVault();
        v.vaultCreator[vault] = creator;
        emit VaultCreatorSet(vault, creator);
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
        Pad3VaultStore.Layout storage v = Pad3VaultStore.layout();
        if (!v.isVault[vault]) revert NotVault();
        if (msg.sender != v.vaultCreator[vault]) revert NotVaultCreator();
        delete v.vaultCreator[vault];
        emit VaultCreatorSet(vault, address(0));
        token = _createCurve(name, symbol, logoURI, metaURI, quote, refPool, tax, gradBnb);
        v.vaultOf[token] = vault;
        emit VaultBound(token, vault);
    }

    /// @inheritdoc IGangPromote
    function createWithPromote(
        string calldata name,
        string calldata symbol,
        string calldata logoURI,
        string calldata metaURI,
        address quote,
        address refPool,
        TaxConfig calldata tax,
        uint256 gradBnb,
        uint16 shareBps,
        uint32 window
    ) external nonReentrant returns (address token) {
        if (shareBps == 0 || shareBps > MAX_PROMOTE_BPS || window < MIN_PROMOTE_WINDOW || window > MAX_PROMOTE_WINDOW) revert BadPromoteTerms();
        token = _createCurve(name, symbol, logoURI, metaURI, quote, refPool, tax, gradBnb);
        Pad3PromoteStore.layout().termsOf[token] = Pad3PromoteStore.Terms(shareBps, window);
        emit PromoteSet(token, shareBps, window);
    }

    /// @dev GangLaunchpad3._createCurve, line for line (test/gang3/Pad3Vault.t.sol compares the records)
    function _createCurve(
        string calldata name,
        string calldata symbol,
        string calldata logoURI,
        string calldata metaURI,
        address quote,
        address refPool,
        TaxConfig calldata tax,
        uint256 gradBnb
    ) private returns (address token) {
        token = CurveLogic.create(
            _config, curves, bridgePoolOf, _deps(), name, symbol, logoURI, metaURI, quote, refPool, tax, gradBnb
        );
        gradTargetOf[token] = gradBnb;
        kindOf[token] = KIND_CURVE;
        tokenVersionOf[token] = TOKEN_VERSION;
        emit TokenVersionSet(token, TOKEN_VERSION);
        logoURIOf[token] = logoURI;
        allTokens.push(token);
    }

    // ---------------------------------------------------------------- promoter share
    /// @inheritdoc IGangPromote
    /// @dev GangLaunchpad3.buyTokenAMAP's curve branch, with the binding first so the first trade already pays. Sent by
    ///      the wallet itself: a binding is for good and takes part of the creator's fee, so no contract (one a wallet was
    ///      talked into calling, or an open route of a listed one) ever names a promoter for it (audit L-1).
    function buyWithPromoter(address token, uint256 funds, uint256 minAmount, address promoter)
        external
        payable
        nonReentrant
        returns (uint256 amountOut, uint256 fundsUsed)
    {
        address to = msg.sender;
        if (to != tx.origin) revert TraderNotOrigin();
        if (kindOf[token] != KIND_CURVE) revert NotCurveToken();
        Curve storage cv = curves[token];
        if (cv.graduated) revert NotCurveToken();
        if (!_config.agentGateEnabled) revert RouterNeedsGate();
        Pad3VaultStore.Layout storage v = Pad3VaultStore.layout();
        if (to == v.vaultOf[token]) revert VaultCannotTrade();
        IERC20 quote = IERC20(cv.quote);
        _payIn(address(quote), funds);
        if (_bindable(token, to, promoter)) {
            Pad3PromoteStore.layout().bindingOf[token][to] =
                Pad3PromoteStore.Binding(promoter, uint40(block.timestamp), true);
            emit PromoterBound(token, to, promoter);
        }
        uint256 toBefore = quote.balanceOf(to);
        amountOut = CurveLogic.buy(
            _config, curves, creatorFeeOf, _deps(), to, token, funds, minAmount, v.lockedOf[token][to], true
        );
        fundsUsed = funds - (quote.balanceOf(to) - toBefore);
        emit GatewayBuy(token, to, msg.sender, fundsUsed, amountOut);
    }

    /// @inheritdoc IGangPromote
    function claimPromoterFee(address token, address to) external nonReentrant returns (uint256 amount) {
        if (to == address(0) || to == address(this)) revert ZeroAddress();
        Pad3PromoteStore.Layout storage l = Pad3PromoteStore.layout();
        amount = l.feeOf[token][msg.sender];
        if (amount == 0) revert ZeroAmount();
        l.feeOf[token][msg.sender] = 0;
        IERC20(curves[token].quote).safeTransfer(to, amount);
        emit PromoterFeeClaimed(token, msg.sender, to, amount);
    }

    /// @inheritdoc IGangPromote
    function promoteOf(address token) external view returns (uint16 shareBps, uint32 window) {
        Pad3PromoteStore.Terms memory t = Pad3PromoteStore.layout().termsOf[token];
        return (t.shareBps, t.window);
    }

    /// @inheritdoc IGangPromote
    function bindingOf(address token, address wallet)
        external
        view
        returns (address promoter, uint40 boundAt, bool traded)
    {
        Pad3PromoteStore.Binding memory b = Pad3PromoteStore.layout().bindingOf[token][wallet];
        return (b.promoter, b.boundAt, b.traded);
    }

    /// @inheritdoc IGangPromote
    function promoterFeeOf(address token, address promoter) external view returns (uint256) {
        return Pad3PromoteStore.layout().feeOf[token][promoter];
    }

    /// @inheritdoc IGangPromote
    function canBind(address token, address wallet, address promoter) external view returns (bool) {
        return wallet != address(0) && _config.agentGateEnabled && !curves[token].graduated
            && PadCommon.isAgent(_config, wallet) && _bindable(token, wallet, promoter);
    }

    /// @dev Bindings are for good, so this is the only way in: never a wallet that has traded the token, never the
    ///      wallet itself or the creator as its promoter, and the promoter holds an Agent ID (the gate, when it's on).
    function _bindable(address token, address wallet, address promoter) private view returns (bool) {
        Pad3PromoteStore.Layout storage l = Pad3PromoteStore.layout();
        return l.termsOf[token].shareBps != 0 && !l.bindingOf[token][wallet].traded && promoter != address(0)
            && promoter != wallet && promoter != curves[token].creator && PadCommon.isAgent(_config, promoter);
    }

    /// @dev GangLaunchpad3._payIn: `funds` of `quote` into the pad, as WBNB from msg.value (== funds), else pulled exactly
    ///      from msg.sender (a fee-on-transfer quote arrives short: FeeOnTransferQuote).
    function _payIn(address quote, uint256 funds) private {
        if (quote == wbnb) {
            if (msg.value != funds) revert BadMsgValue();
            IWBNBDeposit(wbnb).deposit{value: funds}();
        } else {
            if (msg.value != 0) revert BadMsgValue();
            PadCommon.pullExact(quote, funds);
        }
    }

    // ---------------------------------------------------------------- vault entries
    /// @notice The vault moves `amount` of `user`'s tokens into itself, spending the allowance `user` gave the vault.
    ///         Before graduation only; `user` = tx.origin, an Agent; the vault still listed. Books `lockedOf`.
    function vaultLock(address token, address user, uint256 amount) external nonReentrant {
        uint16 dividendBps = _vaultEntry(token, user, amount);
        Pad3VaultStore.Layout storage v = Pad3VaultStore.layout();
        if (!v.isVault[msg.sender]) revert VaultDelisted();

        IGangPadToken(token).pullFor(user, msg.sender, amount); // user → pad
        IERC20(token).safeTransfer(msg.sender, amount); // pad → vault
        v.lockedOf[token][user] += amount;

        _syncShares(token, dividendBps, user);
        emit VaultLocked(token, msg.sender, user, amount);
    }

    /// @notice The vault moves `amount` of its tokens to `user`, spending the allowance the vault gave the pad.
    ///         Before graduation only; `user` = tx.origin, an Agent; not capped at 1%. Listed or not (never stuck).
    function vaultRelease(address token, address user, uint256 amount) external nonReentrant {
        uint16 dividendBps = _vaultEntry(token, user, amount);
        Pad3VaultStore.Layout storage v = Pad3VaultStore.layout();

        IERC20(token).safeTransferFrom(msg.sender, user, amount); // vault → user (msg.sender to the token = the pad)
        uint256 locked = v.lockedOf[token][user];
        v.lockedOf[token][user] = amount >= locked ? 0 : locked - amount;

        _syncShares(token, dividendBps, user);
        emit VaultReleased(token, msg.sender, user, amount);
    }

    // ---------------------------------------------------------------- views
    function isVault(address vault) external view returns (bool) {
        return Pad3VaultStore.layout().isVault[vault];
    }

    function vaultOf(address token) external view returns (address) {
        return Pad3VaultStore.layout().vaultOf[token];
    }

    function lockedOf(address token, address user) external view returns (uint256) {
        return Pad3VaultStore.layout().lockedOf[token][user];
    }

    function everVault(address vault) external view returns (bool) {
        return Pad3VaultStore.layout().everVault[vault];
    }

    function vaultCreator(address vault) external view returns (address) {
        return Pad3VaultStore.layout().vaultCreator[vault];
    }

    // ---------------------------------------------------------------- the pad's off-chain views (moved here for size)
    // GangLaunchpad3's own, line for line (only off-chain readers use them: CLI preflight, previews, the deploy
    // scripts' probes); the pad reaches them through its fallback at the same selectors.

    /// @notice CLI preflight: every TaxConfig check `create` would revert on, without reverting. The creator is not
    ///         known here, so the recipient must be whitelisted; use `checkTaxConfigFor` when the creator itself is the
    ///         recipient.
    function checkTaxConfig(TaxConfig calldata tax) external view returns (bool ok, string memory reason) {
        reason = CurveLogic.checkTax(_deps(), address(0), tax);
        ok = bytes(reason).length == 0;
    }

    /// @notice `checkTaxConfig` as `create` by `creator` sees it: the recipient may be `creator` itself (no listing
    ///         needed) or a whitelisted address.
    function checkTaxConfigFor(address creator, TaxConfig calldata tax)
        external
        view
        returns (bool ok, string memory reason)
    {
        reason = CurveLogic.checkTax(_deps(), creator, tax);
        ok = bytes(reason).length == 0;
    }

    function taxConfigOf(address token)
        external
        view
        returns (uint16 buyTaxBps, uint16 sellTaxBps, uint16 dividendBps, address recipient)
    {
        Curve storage c = curves[token];
        (, recipient) = IGangPadHandler(taxHandler).routeOf(token);
        return (c.buyTaxBps, c.sellTaxBps, c.dividendBps, recipient);
    }

    function gradAmtOf(address token) external view returns (uint256) {
        return curves[token].gradAmt;
    }

    function graduationRemaining(address token) external view returns (uint256) {
        Curve storage c = curves[token];
        if (c.creator == address(0) || c.graduated) return 0;
        if (c.realQuote >= c.gradAmt) return 0;
        return uint256(c.gradAmt) - uint256(c.realQuote);
    }

    /// @notice What `create` would lock as the graduation amount (CurveLogic.DEFAULT_GRAD_BNB in `quote`).
    function graduationAmountOf(address quote, address refPool) external view returns (uint256) {
        return
            CurveLogic.graduationAmountOf(_config, bridgePoolOf, _deps(), quote, refPool, CurveLogic.DEFAULT_GRAD_BNB);
    }

    /// @notice What `createWithGradTarget` would lock for `gradBnb`; reverts BadGradTarget off GRAD_BNB_TIERS.
    function graduationAmountFor(address quote, address refPool, uint256 gradBnb) external view returns (uint256) {
        return CurveLogic.graduationAmountOf(_config, bridgePoolOf, _deps(), quote, refPool, gradBnb);
    }

    /// @notice The graduation targets a creator may pick, in BNB raised.
    function GRAD_BNB_TIERS() external pure returns (uint256[4] memory t) {
        for (uint256 i; i < 4; i++) {
            t[i] = CurveLogic.MIN_GRAD_BNB + i * CurveLogic.GRAD_BNB_STEP;
        }
    }

    function checkConfig(MintConfig calldata cfg, uint256 devShares)
        external
        pure
        returns (bool ok, string memory reason)
    {
        return FairLogic.checkConfig(cfg, devShares);
    }

    /// @notice Raise in quote units and the per-share price `create` would lock. Reverts like `create`.
    function previewCreate(address quote, address refPool, uint256 raiseBnb)
        external
        view
        returns (uint256 raiseQuote, uint256 sharePrice)
    {
        return FairLogic.previewCreate(_config, bridgePoolOf, _deps(), quote, refPool, raiseBnb);
    }

    /// @notice What `mint(token, shares, 0)` by `user` would accept and cost right now (cost excludes fee).
    function previewMint(address token, address user, uint256 shares)
        external
        view
        flyToModuleView(token)
        returns (uint256 accepted, uint256 cost, uint256 fee)
    {
        Sale storage s = _sales[token];
        if (_status(token) != Status.Minting) return (0, 0, 0);
        accepted = FairLogic.acceptable(s, positions[token][user].shares, shares);
        cost = accepted * s.sharePrice;
        fee = (cost * s.mintFeeBps) / PadCommon.BPS;
    }

    /// @notice What `withdraw(token, shares)` by `user` would pay out and charge right now (0, 0 if it would revert).
    function previewWithdraw(address token, address user, uint256 shares)
        external
        view
        flyToModuleView(token)
        returns (uint256 payout, uint256 fee)
    {
        if (_status(token) != Status.Minting || shares == 0 || shares > positions[token][user].shares) {
            return (0, 0);
        }
        return FairLogic.withdrawQuote(_sales[token], shares);
    }

    /// @notice The exit fee a withdraw pays now: the sale's own, or 0 once it has made no progress for STALE_AFTER.
    function exitFeeBpsOf(address token) external view flyToModuleView(token) returns (uint256) {
        return FairLogic.exitFeeBps(_sales[token]);
    }

    // ---------------------------------------------------------------- internal
    /// @dev GangLaunchpad3._isPlainContract: code, and not the 23-byte EIP-7702 delegation designator.
    function _isPlainContract(address a) internal view returns (bool) {
        uint256 size = a.code.length;
        if (size == 0) return false;
        if (size != 23) return true;
        return bytes3(a.code) != 0xef0100;
    }

    function _status(address token) internal view returns (Status) {
        Sale storage s = _sales[token];
        if (s.creator == address(0)) return Status.None;
        if (s.launched) return Status.Launched;
        return Status.Minting;
    }

    /// @dev Shared checks: the caller is `token`'s vault (so `token` is a vault-bound curve token of this pad), the
    ///      curve is live (the token still locked), `amount` > 0, `user` sent the tx and is an Agent.
    function _vaultEntry(address token, address user, uint256 amount) private view returns (uint16 dividendBps) {
        if (msg.sender != Pad3VaultStore.layout().vaultOf[token] || msg.sender == address(0)) revert NotVault();
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
        SharedDividendVault vault = SharedDividendVault(dividendVault);
        vault.setShare(token, user, IERC20(token).balanceOf(user));
        vault.setShare(token, msg.sender, IERC20(token).balanceOf(msg.sender));
    }

    function _deps() internal view returns (Deps memory) {
        return Deps({
            quoteRegistry: quoteRegistry,
            dividendVault: dividendVault,
            platformBucket: platformBucket,
            taxHandler: taxHandler,
            tokenDeployer: tokenDeployer,
            wbnb: wbnb
        });
    }
}
