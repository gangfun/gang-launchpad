// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {QuoteRegistry} from "../launchpad-v2/QuoteRegistry.sol";
import {IMigratorV2} from "../launchpad-v2/interfaces/IMigratorV2.sol";
import {PoolCheck} from "../launchpad-v2/PoolCheck.sol";
import {SharedDividendVault} from "../common/SharedDividendVault.sol";
import {SharedPlatformFeeBucket as PlatformFeeBucket} from "../common/SharedPlatformFeeBucket.sol";
import {SharedMigrator} from "../common/SharedMigrator.sol";
import {V3_PLATFORM_TAX_BPS} from "./interfaces/IGangTaxHandler.sol";
import {IGangLaunchpad} from "./interfaces/IGangLaunchpad.sol";
import {IGangPadView} from "./interfaces/IGangPadView.sol";
import {IGangPadHandler} from "./interfaces/IGangPadDeps.sol";
import {PadCommon} from "./PadCommon.sol";
import {CurveLogic3 as CurveLogic} from "./CurveLogic3.sol";
import {LegacyRoute} from "./LegacyRoute.sol";
import {IGangLaunchpad3} from "./interfaces/IGangLaunchpad3.sol";
import {IGangPadRegistry} from "./interfaces/IGangPadRegistry.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FairLogic} from "./FairLogic.sol";

/// @title GangLaunchpad 3.0 — the upgradeable Gang pad: one permanent address for both launch kinds
/// @notice GangLaunchpad 2.0 (bonding curve V3 with the creator's 70% of the 1% fee and graduation tiers, and 打新)
///         behind a TransparentUpgradeableProxy: users, routers and aggregators keep the PROXY address for good, and
///         later features ship as upgrades of this implementation instead of new pads
///         (docs/SPEC-GANG-LAUNCHPAD-3-2026-11-03.md §1). Every external function, getter, constant, event and error
///         of 2.0 keeps its name, selector and layout, so GangPadRegistry, GangGateway, GangRouter, the CLI and
///         indexers read it as they read 2.0.
///         What 3.0 adds: `tokenVersionOf` (the rule set each token was created under, emitted as `TokenVersionSet`;
///         an upgrade never changes the rules of a token already created — the upgrade policy, checked in review).
///         - V3 (kindOf 1): V2 curve / Agent gate (current setting) / 1% wallet cap / graduation at the creator's
///           target (6 / 9 / 12 / 15 BNB raised, default 9); no tax on the curve, only the 1% protocol fee, 70% of it
///           kept for the token's creator (`claimCreatorFee`); buy / sell tax on the Pancake pool after graduation
///           (GangToken → handler).
///         - 打新 (kindOf 2): 10,000 equal shares at one fixed price both ways; the last share launches the pair; each
///           sale snapshots its rules (cap, gate, fees, hold line) at create.
/// @dev Upgrades: the ProxyAdmin (created by the proxy) is owned by the platform Safe, no timelock
///      (SPEC-GANG-LAUNCHPAD-3 §1, §6). The seven dependencies are implementation immutables (as 2.0, same gas per
///      trade): a new implementation is deployed with the same seven (script/UpgradeGangLaunchpad3.s.sol compares
///      them before printing the Safe's upgrade). The reentrancy guard, router list and A-2 router checks are here, in
///      the wrappers, kept apart on purpose: `buyFor` needs the pad's gate on now, `mintFor` needs the sale's
///      snapshot gate set. Funds of one quote are shared by curves and sales on this one address; each path only ever
///      moves its own token's escrow (curve: `realQuote` and `creatorFeeOf`; sale: sold × price; exit fees owed:
///      `owedFee`).
///      STORAGE LAYOUT (proxy storage, locked by test/gang3/GangLaunchpad3Layout.t.sol, struct members included).
///      Upgrade rule: append new variables after the last one; never reorder, retype or remove a variable or a struct
///      member, and never change the inheritance list. Ownable `_owner` (0), Ownable2Step `_pendingOwner` (1), ReentrancyGuard `_status` (2, 0 on a fresh proxy =
///      not entered), then this contract's variables in declaration order from slot 3. Initializable keeps its flag in
///      its ERC-7201 slot. A version that needs set-up uses `reinitializer(n)` through ProxyAdmin.upgradeAndCall.
interface IWBNB3 {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

contract GangLaunchpad3 is IGangLaunchpad, IGangLaunchpad3, IGangPadView, Initializable, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------- shared constants
    uint256 public constant TOTAL_SUPPLY = PadCommon.TOTAL_SUPPLY;
    uint256 public constant BPS = PadCommon.BPS;
    uint256 public constant MIN_REF_DEPTH_BNB = PadCommon.MIN_REF_DEPTH_BNB;
    /// @notice The rule set new tokens are created under (`tokenVersionOf`). 3.0's first rules = 2.0's, version 1.
    uint8 public constant TOKEN_VERSION = 1;
    /// @notice See `initVersion`.
    uint64 internal constant INIT_VERSION = 1;

    // ---------------------------------------------------------------- V3 constants
    uint256 public constant CURVE_SUPPLY = CurveLogic.CURVE_SUPPLY;
    uint256 public constant VIRTUAL_TOKEN = CurveLogic.VIRTUAL_TOKEN;
    uint256 public constant MAX_PER_WALLET = CurveLogic.MAX_PER_WALLET;
    /// @dev Bonding fee, all curve tokens: 1%. The only charge on the curve (no tax there).
    uint256 public constant PROTOCOL_FEE_BPS = CurveLogic.PROTOCOL_FEE_BPS;
    /// @dev The creator's part of PROTOCOL_FEE_BPS (70% → `creatorFeeOf`); the rest (30%) → PlatformFeeBucket.
    uint256 public constant CREATOR_FEE_SHARE_BPS = CurveLogic.CREATOR_FEE_SHARE_BPS;
    /// @dev Platform's part of every taxed pool trade (after graduation), as a share of the trade's volume; out of the
    ///      tax. Applied by the handler; kept here for readers (CLI / indexer).
    uint256 public constant PLATFORM_TAX_BPS = V3_PLATFORM_TAX_BPS;
    uint16 public constant MIN_TAX_BPS = CurveLogic.MIN_TAX_BPS;
    uint16 public constant MAX_TAX_BPS = CurveLogic.MAX_TAX_BPS;
    /// @dev Holders need balance strictly > 10_000 tokens for dividend shares (V2 parity). = MIN_SHARE_BALANCE.
    uint256 public constant TAXED_MIN_SHARE = PadCommon.MIN_SHARE;
    /// @dev The graduation target `create` takes when the creator picks none (BNB raised); `createWithGradTarget`
    ///      picks one of GRAD_BNB_TIERS. Each token's own target: `gradTargetOf`, in its quote: `gradAmtOf`.
    uint256 public constant TARGET_GRAD_BNB = CurveLogic.DEFAULT_GRAD_BNB;
    uint256 public constant MIN_GRAD_AMT = CurveLogic.MIN_GRAD_AMT;
    /// @dev Largest graduation amount / 打新 raise in quote units (a Pancake pair's reserves are uint112).
    uint256 public constant MAX_QUOTE_AMOUNT = PadCommon.MAX_QUOTE_AMOUNT;

    // ---------------------------------------------------------------- 打新 constants
    uint256 public constant MINT_SUPPLY = FairLogic.MINT_SUPPLY;
    uint256 public constant LP_SUPPLY = FairLogic.LP_SUPPLY;
    uint256 public constant TOTAL_SHARES = FairLogic.TOTAL_SHARES;
    uint256 public constant TOKENS_PER_SHARE = FairLogic.TOKENS_PER_SHARE; // 50_000 tokens
    uint16 public constant MIN_FEE_BPS = FairLogic.MIN_FEE_BPS; // 1%: platform floor, mint and exit
    uint16 public constant MAX_MINT_FEE_BPS = FairLogic.MAX_MINT_FEE_BPS; // 3%: never refunded, so kept low
    uint16 public constant MAX_EXIT_FEE_BPS = FairLogic.MAX_EXIT_FEE_BPS; // 2%: withdraw is the only way out
    /// @notice No progress for this long → withdraw costs no exit fee (only the mint fee paid is lost).
    uint256 public constant STALE_AFTER = FairLogic.STALE_AFTER;
    /// @notice Shares sold must rise this far above the last restart to restart the stale clock (0.1% of the shares).
    uint256 public constant STALE_STEP = FairLogic.STALE_STEP;
    uint256 public constant MIN_RAISE_BNB = FairLogic.MIN_RAISE_BNB;
    uint256 public constant MAX_RAISE_BNB = FairLogic.MAX_RAISE_BNB;
    /// @dev QuoteRegistry overrides are "15 BNB worth of quote" (V2 graduation target); scaled to the raise.
    uint256 public constant REGISTRY_REF_BNB = PadCommon.REF_BNB;
    uint16 public constant MIN_CAP_BPS = FairLogic.MIN_CAP_BPS; // 0.25% of supply → ≥ 200 addresses
    uint16 public constant MAX_CAP_BPS = FairLogic.MAX_CAP_BPS; // 1% of supply → ≥ 50 addresses
    uint16 public constant MIN_HOLD_BPS = FairLogic.MIN_HOLD_BPS;
    uint16 public constant MAX_HOLD_BPS = FairLogic.MAX_HOLD_BPS;
    /// @dev Vault floor uses `<=`; must stay below 1 share × MIN_HOLD_BPS (30k tokens). = TAXED_MIN_SHARE.
    uint256 public constant MIN_SHARE_BALANCE = PadCommon.MIN_SHARE;

    uint8 internal constant KIND_CURVE = CurveLogic.KIND;
    uint8 internal constant KIND_FAIR = FairLogic.KIND;

    // ---------------------------------------------------------------- aggregator entry constants (GangGateway's)
    /// @notice Highest router fee a seller can be charged on `sellToken` (four.meme's cap): 5%.
    uint256 public constant MAX_FEE_RATE = 500;
    uint8 internal constant STATUS_CURVE = 1;
    uint8 internal constant STATUS_POOL = 2;
    uint8 internal constant STATUS_MINTING = 3;

    // ---------------------------------------------------------------- immutables
    QuoteRegistry public immutable quoteRegistry;
    SharedDividendVault public immutable dividendVault;
    PlatformFeeBucket public immutable platformBucket;
    /// @notice The one post-grad tax handler of both kinds: recipient whitelist, routes, pool tax.
    address public immutable taxHandler;
    address public immutable tokenDeployer;
    address public immutable wbnb;
    /// @notice GangPadRegistry (proxy): where the aggregator entry finds the pad of a token that is not this pad's.
    IGangPadRegistry public immutable padRegistry;

    // ---------------------------------------------------------------- storage
    Config internal _config;
    mapping(address => address) public bridgePoolOf;
    /// @notice Entry contracts (GangRouter, listed aggregators) that may buy / mint (paying themselves) and sell /
    ///         withdraw (with the trader's token allowance to them) for a trader — only the wallet that sent the tx
    ///         (`trader == tx.origin`, AUDIT-BRIEF §23). Claims stay msg.sender-only.
    mapping(address router => bool) public routers;
    /// @inheritdoc IGangPadView
    mapping(address token => uint8) public kindOf;
    mapping(address token => Curve) public curves;
    mapping(address token => Sale) public sales;
    mapping(address token => mapping(address user => Position)) public positions;
    mapping(address token => string) public logoURIOf;
    /// @notice 打新 exit fees the bucket refused; anyone can `flushFees` them once it accepts.
    mapping(address quote => uint256) public owedFee;
    /// @notice Every token of the pad, both kinds (see `kindOf`).
    address[] public allTokens;
    /// @notice Curve tokens: the creator's part of the 1% fee, in the token's quote, not claimed yet.
    mapping(address token => uint256) public creatorFeeOf;
    /// @notice The graduation target the creator picked, in BNB raised (0 = not a curve token of this pad).
    mapping(address token => uint256) public gradTargetOf;
    /// @notice The rule set `token` was created under (TOKEN_VERSION at its create; 0 = not a token of this pad).
    ///         Fixed for good: an upgrade adds rules for new tokens only.
    mapping(address token => uint8) public tokenVersionOf;
    /// @notice Contracts allowed to call `sellToken` for a seller other than themselves (aggregators' contracts,
    ///         listed by the owner after review; GangGateway's `isCaller`).
    mapping(address caller => bool) public isCaller;

    /// @notice The seven dependencies are fixed in the implementation's code (as 2.0's immutables); the proxy's state
    ///         starts with `initialize`. The implementation itself can never be initialized.
    /// @custom:oz-upgrades-unsafe-allow constructor state-variable-immutable
    constructor(
        address quoteRegistry_,
        address dividendVault_,
        address platformBucket_,
        address taxHandler_,
        address tokenDeployer_,
        address wbnb_,
        address padRegistry_
    ) Ownable(address(0xdEaD)) {
        if (
            quoteRegistry_ == address(0) || dividendVault_ == address(0) || platformBucket_ == address(0)
                || taxHandler_ == address(0) || tokenDeployer_ == address(0) || wbnb_ == address(0)
                || padRegistry_ == address(0)
        ) revert ZeroAddress();
        padRegistry = IGangPadRegistry(padRegistry_);
        quoteRegistry = QuoteRegistry(quoteRegistry_);
        dividendVault = SharedDividendVault(dividendVault_);
        platformBucket = PlatformFeeBucket(platformBucket_);
        taxHandler = taxHandler_;
        tokenDeployer = tokenDeployer_;
        wbnb = wbnb_;
        _disableInitializers();
    }

    /// @notice Run once, by the proxy's constructor (TransparentUpgradeableProxy's `_data`), in the deploy transaction:
    ///         the pad's owner and 2.0's starting settings (TWAP 30 min, Agent gate and wallet cap on).
    function initialize(address owner_, address pairFactory_) external initializer {
        if (owner_ == address(0) || pairFactory_ == address(0)) revert ZeroAddress();
        _transferOwnership(owner_);
        _config.pairFactory = pairFactory_;
        _config.twapWindow = 1800;
        _config.agentGateEnabled = true;
        _config.walletCapEnabled = true;
    }

    /// @notice The initialized version this implementation leaves the proxy at: INIT_VERSION (1: `initialize`). A
    ///         later version sets INIT_VERSION = n and uses it for BOTH its `reinitializer(INIT_VERSION)` and this view
    ///         (one constant, so the two cannot drift apart); script/UpgradeGangLaunchpad3.s.sol then requires the
    ///         set-up call in the same `upgradeAndCall` (a reinitializer left for later could be called by anyone).
    function initVersion() external pure virtual returns (uint64) {
        return INIT_VERSION;
    }

    // ---------------------------------------------------------------- admin (new tokens / trades only)
    /// @notice One-shot. Last step of the deploy: `create` needs a migrator, so the pad opens only once everything
    ///         else is wired (A-1).
    /// @notice Disabled (audit 3C L-2): without an owner no router or caller could ever be delisted. Hand over with
    ///         `transferOwnership` + `acceptOwnership` instead.
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    function setMigrator(address migrator_) external onlyOwner {
        if (_config.migrator != address(0)) revert MigratorAlreadySet();
        if (migrator_ == address(0)) revert ZeroAddress();
        // one-shot: a migrator that does not list this pad would make every graduation / launch revert forever (A-7)
        if (!SharedMigrator(migrator_).launchpads(address(this))) revert WrongMigrator();
        _config.migrator = migrator_;
        emit MigratorSet(migrator_);
    }

    /// @notice Pancake V2 factory used to price reference pools (only affects tokens created from now on).
    function setPairFactory(address factory_) external onlyOwner {
        _config.pairFactory = factory_;
        emit PairFactorySet(factory_);
    }

    function setRouter(address router_, bool enabled) external onlyOwner {
        if (router_ == address(0)) revert ZeroAddress();
        routers[router_] = enabled;
        emit RouterSet(router_, enabled);
    }

    /// @notice V3 trades check the gate as set now; a 打新 sale keeps the gate it was created with.
    function setAgentGate(bool enabled, address registry) external onlyOwner {
        _config.agentGateEnabled = enabled;
        _config.agentIdRegistry = registry;
        emit AgentGateUpdated(enabled, registry);
    }

    /// @notice V3 1% wallet cap (打新 has its own per-sale cap).
    function setWalletCapEnabled(bool enabled) external onlyOwner {
        _config.walletCapEnabled = enabled;
        emit WalletCapUpdated(enabled);
    }

    function setV3Factory(address factory_) external onlyOwner {
        _config.v3Factory = factory_;
        emit V3FactorySet(factory_);
    }

    function setTwapWindow(uint32 window) external onlyOwner {
        _config.twapWindow = window;
        emit TwapWindowUpdated(window);
    }

    /// @notice Canonical `asset`/WBNB pool used to express `asset` in BNB. pool = 0 removes it.
    function setBridgePool(address asset, address pool) external onlyOwner {
        if (asset == address(0) || asset == wbnb) revert ZeroAddress();
        if (pool != address(0)) {
            PoolCheck.PoolInfo memory info = PoolCheck.inspect(PadCommon.poolCfg(_config, wbnb), pool);
            if (PoolCheck.counterOf(info, asset) != wbnb) revert BridgeNotWbnb();
        }
        bridgePoolOf[asset] = pool;
        emit BridgePoolSet(asset, pool);
    }

    // ---------------------------------------------------------------- V3 (curve)
    /// @param logoURI Logo image URI: kept in `logoURIOf` and emitted in `Created` (what the site shows).
    /// @param metaURI Metadata JSON URI: the token's `contractURI()` / `metaURI()`, fixed for good.
    function create(
        string calldata name,
        string calldata symbol,
        string calldata logoURI,
        string calldata metaURI,
        address quote,
        address refPool,
        TaxConfig calldata tax
    ) external nonReentrant returns (address token) {
        token = _createCurve(name, symbol, logoURI, metaURI, quote, refPool, tax, TARGET_GRAD_BNB);
    }

    /// @notice `create` with the graduation target picked by the creator: `gradBnb` one of GRAD_BNB_TIERS (BNB raised,
    ///         converted to the quote as `create` does).
    function createWithGradTarget(
        string calldata name,
        string calldata symbol,
        string calldata logoURI,
        string calldata metaURI,
        address quote,
        address refPool,
        TaxConfig calldata tax,
        uint256 gradBnb
    ) external nonReentrant returns (address token) {
        token = _createCurve(name, symbol, logoURI, metaURI, quote, refPool, tax, gradBnb);
    }

    function _createCurve(
        string calldata name,
        string calldata symbol,
        string calldata logoURI,
        string calldata metaURI,
        address quote,
        address refPool,
        TaxConfig calldata tax,
        uint256 gradBnb
    ) internal returns (address token) {
        token = CurveLogic.create(
            _config, curves, bridgePoolOf, _deps(), name, symbol, logoURI, metaURI, quote, refPool, tax, gradBnb
        );
        gradTargetOf[token] = gradBnb;
        _record(token, logoURI, KIND_CURVE);
    }

    function buy(address token, uint256 quoteIn, uint256 minTokensOut)
        external
        nonReentrant
        returns (uint256 tokensOut)
    {
        _checkCurveTrader(token, msg.sender);
        tokensOut = CurveLogic.buy(
            _config,
            curves,
            creatorFeeOf,
            _deps(),
            msg.sender,
            token,
            quoteIn,
            minTokensOut,
            _lockedOf(token, msg.sender),
            false
        );
    }

    /// @notice A listed router (GangRouter, a listed aggregator) buys for `trader`, who must be the wallet that sent
    ///         the tx (`trader == tx.origin`, §23). The router pays `quoteIn`; the refund of any cap / graduation cut
    ///         goes to the TRADER (quote ERC-20, never to the router); the tokens, the dividend share, the gate and the
    ///         wallet cap are the trader's, exactly as a direct `buy`.
    ///         Reverts OnlyRouter (caller not listed) / TraderNotOrigin.
    function buyFor(address trader, address token, uint256 quoteIn, uint256 minTokensOut)
        external
        nonReentrant
        returns (uint256 tokensOut)
    {
        _forTrader(trader);
        // A-2 (V3): the pad's gate must be on now — ungated, a router could name any trader (e.g. the future pair,
        // seeding it before graduation). Kept as is; the origin binding (§23) now also rules that case out.
        if (!_config.agentGateEnabled) revert RouterNeedsGate();
        _checkCurveTrader(token, trader);
        tokensOut = CurveLogic.buy(
            _config,
            curves,
            creatorFeeOf,
            _deps(),
            trader,
            token,
            quoteIn,
            minTokensOut,
            _lockedOf(token, trader),
            false
        );
    }

    function sell(address token, uint256 tokensIn, uint256 minQuoteOut)
        external
        nonReentrant
        returns (uint256 quoteToUser)
    {
        _checkCurveTrader(token, msg.sender);
        quoteToUser = CurveLogic.sell(
            _config,
            curves,
            creatorFeeOf,
            _deps(),
            msg.sender,
            CurveLogic.PULL_CALLER,
            token,
            tokensIn,
            minQuoteOut,
            msg.sender
        );
    }

    /// @notice A listed router sells `trader`'s tokens, `trader` being the wallet that sent the tx (§23). The tokens
    ///         are pulled from `trader` into the pad with the allowance `trader` gave the ROUTER (`approve(router, …)`
    ///         on the token, as for any DEX router); the quote goes to the router. Gate: the trader's; the dividend
    ///         share and the `Sell` event are the trader's. Reverts OnlyRouter / TraderNotOrigin.
    /// @return quoteOut Quote paid to the caller (after the 1% protocol fee).
    function sellFor(address trader, address token, uint256 tokensIn, uint256 minQuoteOut)
        external
        nonReentrant
        returns (uint256 quoteOut)
    {
        _forTrader(trader);
        _checkCurveTrader(token, trader);
        quoteOut = CurveLogic.sell(
            _config,
            curves,
            creatorFeeOf,
            _deps(),
            trader,
            CurveLogic.PULL_ROUTER,
            token,
            tokensIn,
            minQuoteOut,
            msg.sender
        );
    }

    /// @notice The creator of curve token `token` takes its part of the 1% fee (`creatorFeeOf`), in the token's quote,
    ///         to `to`. Before or after graduation; only the creator, directly (no router). Reverts NotCreator /
    ///         ZeroAmount (nothing kept) / ZeroAddress (`to` is 0 or the pad).
    function claimCreatorFee(address token, address to) external nonReentrant returns (uint256 amount) {
        amount = CurveLogic.claimCreatorFee(curves, creatorFeeOf, token, to);
    }

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

    function walletRoom(address token, address buyer) external view returns (uint256) {
        return CurveLogic.walletRoom(_config.walletCapEnabled, token, buyer, _lockedOf(token, buyer));
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

    /// @notice What `create` would lock as the graduation amount (TARGET_GRAD_BNB in `quote`).
    function graduationAmountOf(address quote, address refPool) external view returns (uint256) {
        return CurveLogic.graduationAmountOf(_config, bridgePoolOf, _deps(), quote, refPool, TARGET_GRAD_BNB);
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

    // ---------------------------------------------------------------- 打新
    /// @param logoURI   Logo image URI: kept in `logoURIOf` and emitted in `Created` (what the site shows).
    /// @param metaURI   Metadata JSON URI: the token's `contractURI()` / `metaURI()`, fixed for good.
    /// @param quote     WBNB (address(0)) or any 18-decimal ERC20. Fee-on-transfer quotes are rejected at the dev's
    ///                  mint (same tx).
    /// @param refPool   Pancake V2 pair / V3 pool pricing `quote`; ignored for WBNB or a QuoteRegistry override.
    /// @param devShares Shares the creator mints in the same call (≥ 1); needs quote approval beforehand.
    function create(
        string calldata name,
        string calldata symbol,
        string calldata logoURI,
        string calldata metaURI,
        address quote,
        address refPool,
        MintConfig calldata cfg,
        uint256 devShares
    ) external nonReentrant returns (address token) {
        token = FairLogic.create(
            _config,
            sales,
            positions,
            bridgePoolOf,
            _deps(),
            name,
            symbol,
            logoURI,
            metaURI,
            quote,
            refPool,
            cfg,
            devShares
        );
        _record(token, logoURI, KIND_FAIR);
    }

    /// @param minShares Revert if the last-fill truncation leaves fewer than this.
    function mint(address token, uint256 shares, uint256 minShares) external nonReentrant returns (uint256 accepted) {
        accepted = FairLogic.mint(_config, sales, positions, _deps(), msg.sender, token, shares, minShares);
    }

    /// @notice A listed router mints for `trader`, the wallet that sent the tx (§23). The router pays cost + mint fee,
    ///         pulled exactly: there is no refund, so the router approves exactly `previewMint(token, trader, n)`'s
    ///         cost + fee. The shares and tokens are the trader's (a later `withdraw` pays the trader; `withdrawFor`
    ///         pays the router that calls it). Gate and cap: the trader's. Reverts OnlyRouter / TraderNotOrigin.
    function mintFor(address trader, address token, uint256 shares, uint256 minShares)
        external
        nonReentrant
        returns (uint256 accepted)
    {
        _forTrader(trader);
        // A-2 (打新): the sale's own snapshot gate must be set — ungated, a router could name any trader (e.g. the
        // future pair, seeding it before launch to take the LP). Kept as is; the origin binding (§23) also stops that.
        if (FairLogic.minting(sales, token).gate == address(0)) revert RouterNeedsGate();
        accepted = FairLogic.mint(_config, sales, positions, _deps(), trader, token, shares, minShares);
    }

    /// @notice Before the sale fills: sell `shares` back to the pad at the mint price, minus the exit fee (none once
    ///         the sale is stale). The mint fee paid is the platform's and is not returned.
    /// @param minPayout Reverts (Slippage) below this: a mint landing first can restart the stale clock and bring the
    ///        exit fee back (flow review F3). Use `previewWithdraw` for the expected payout.
    function withdraw(address token, uint256 shares, uint256 minPayout) external nonReentrant returns (uint256 payout) {
        payout = FairLogic.withdraw(sales, positions, owedFee, _deps(), msg.sender, false, token, shares, minPayout);
    }

    /// @notice A listed router withdraws `trader`'s shares, `trader` being the wallet that sent the tx (§23). The
    ///         tokens (shares × TOKENS_PER_SHARE) are pulled from `trader` with the allowance `trader` gave the ROUTER
    ///         on the token; the payout goes to the router; the position, the dividend share and the `Withdrawn` event
    ///         are the trader's. No gate, as `withdraw` (the only way out). Reverts OnlyRouter / TraderNotOrigin.
    function withdrawFor(address trader, address token, uint256 shares, uint256 minPayout)
        external
        nonReentrant
        returns (uint256 payout)
    {
        _forTrader(trader);
        payout = FairLogic.withdraw(sales, positions, owedFee, _deps(), trader, true, token, shares, minPayout);
    }

    /// @notice Send exit fees the bucket refused on to it, now that it accepts again. Anyone can call.
    function flushFees(address quote) external nonReentrant returns (uint256 amount) {
        amount = FairLogic.flushFees(owedFee, _deps(), quote);
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
        returns (uint256 accepted, uint256 cost, uint256 fee)
    {
        Sale storage s = sales[token];
        if (status(token) != Status.Minting) return (0, 0, 0);
        accepted = FairLogic.acceptable(s, positions[token][user].shares, shares);
        cost = accepted * s.sharePrice;
        fee = (cost * s.mintFeeBps) / BPS;
    }

    /// @notice What `withdraw(token, shares)` by `user` would pay out and charge right now (0, 0 if it would revert).
    function previewWithdraw(address token, address user, uint256 shares)
        external
        view
        returns (uint256 payout, uint256 fee)
    {
        if (status(token) != Status.Minting || shares == 0 || shares > positions[token][user].shares) {
            return (0, 0);
        }
        return FairLogic.withdrawQuote(sales[token], shares);
    }

    /// @notice The exit fee a withdraw pays now: the sale's own, or 0 once it has made no progress for STALE_AFTER.
    function exitFeeBpsOf(address token) external view returns (uint256) {
        return FairLogic.exitFeeBps(sales[token]);
    }

    function status(address token) public view returns (Status) {
        Sale storage s = sales[token];
        if (s.creator == address(0)) return Status.None;
        if (s.launched) return Status.Launched;
        return Status.Minting;
    }

    /// @inheritdoc IGangPadView
    /// @dev Read by the handler on every pool trade of a 打新 token: plain storage, no library call.
    function baselineOf(address token, address user) external view returns (uint256) {
        return uint256(positions[token][user].shares) * TOKENS_PER_SHARE;
    }

    /// @inheritdoc IGangPadView
    function holdBpsOf(address token) external view returns (uint16) {
        return sales[token].holdBps;
    }

    // ---------------------------------------------------------------- aggregator entry (four.meme-shaped)
    /// @notice GangGateway's entry, built into the pad (SPEC-GANG-LAUNCHPAD-3 §2, §3): what an aggregator's four.meme
    ///         adapter calls for this pad's curve tokens AND, forwarded with this pad as their listed router, the
    ///         tokens of the other pads GangPadRegistry trusts (1.0, 2.0, the vault pad, 铸币飞轮 V1 / V2;
    ///         LegacyRoute). The user approves THIS address once; the aggregator's contract calls it with no
    ///         signature; buys are open to any caller, sells take the seller itself or a listed caller (`isCaller`,
    ///         Gateway audit M-1); the buyer / seller is always the wallet that sent the tx.
    /// @notice Owner: whitelist (or delist) a contract that may call `sellToken` for a seller other than itself, and
    ///         that may call the pay-to `sellToken` with itself as `to` (the Gateway's listing review, AUDIT-BRIEF
    ///         §25.10, plus for pay-to: the seller is its own msg.sender, and what it receives is spent on that
    ///         seller's route within the same call — no open sweep, no path that spends "the contract's balance" for
    ///         anyone). Contracts only (NotAContract).
    function setCaller(address caller, bool allowed) external onlyOwner {
        // contracts only (Gateway audit L-2): a listed EOA could later delegate to any code with EIP-7702
        if (allowed && !_isPlainContract(caller)) revert NotAContract();
        isCaller[caller] = allowed;
        emit CallerSet(caller, allowed);
    }

    /// @notice Only WBNB unwrapping sends BNB here (a `sellToken` of a BNB-quoted token). WBNB pays with `transfer`
    ///         (2300 gas): the proxy's delegatecall and this check read no cold storage (`wbnb` is an immutable).
    receive() external payable {
        if (msg.sender != wbnb) revert OnlyWbnb();
    }

    /// @notice GangGateway's getTokenInfo: status 0 = not a Gang token; 1 = on its curve (or a 铸币飞轮 sale before
    ///         launch); 2 = graduated / launched (`pair`); 3 = a 打新 sale still minting (not traded here). The quote as
    ///         address(0) for WBNB (native BNB in and out here). `protocolFeeBps`: 100 on a curve (铸币飞轮: the mint
    ///         fee); `graduationLeft`: quote the curve still needs (铸币飞轮: the price of the shares left).
    function getTokenInfo(address token)
        public
        view
        returns (uint8 status, address quote, address pair, uint256 protocolFeeBps, uint256 graduationLeft)
    {
        uint8 kind = kindOf[token];
        if (kind == KIND_CURVE) {
            Curve storage cv = curves[token];
            quote = _external(cv.quote);
            if (cv.graduated) return (STATUS_POOL, quote, cv.pair, 0, 0);
            return (STATUS_CURVE, quote, address(0), PROTOCOL_FEE_BPS, uint256(cv.gradAmt) - cv.realQuote);
        }
        if (kind == KIND_FAIR) {
            Sale storage s = sales[token];
            quote = _external(s.quote);
            if (s.launched) return (STATUS_POOL, quote, s.pair, 0, 0);
            return (STATUS_MINTING, quote, address(0), 0, 0);
        }
        (status, quote, pair, protocolFeeBps, graduationLeft) = LegacyRoute.info(padRegistry, token);
        quote = _external(quote);
    }

    /// @notice Helper3.tryBuy's layout with the trader added (GangGateway's): what `buyTokenAMAP(token, trader,
    ///         funds, 0)` would do now, all 0 when it would revert. Buys by funds only (`amount` must be 0).
    ///         `trader` = address(0): a fresh wallet, no gate check (curve tokens; 铸币飞轮 quotes need the trader).
    function tryBuy(address token, address trader, uint256 amount, uint256 funds)
        external
        view
        returns (
            address tokenManager,
            address quote,
            uint256 estimatedAmount,
            uint256 estimatedCost,
            uint256 estimatedFee,
            uint256 amountMsgValue,
            uint256 amountApproval,
            uint256 amountFunds
        )
    {
        if (amount != 0) revert AmountNotSupported();
        tokenManager = address(this);
        uint8 kind = kindOf[token];
        if (kind != 0) {
            (, quote,,,) = getTokenInfo(token);
            // as GangGateway on a pad with the gate off (A-2): no buy quote, no buy (sells still work)
            if (kind == KIND_CURVE && _config.agentGateEnabled) {
                (estimatedAmount, estimatedCost, estimatedFee,) =
                    CurveLogic.quoteBuy(_config, curves, token, trader, funds, _lockedOf(token, trader));
            }
        } else {
            (quote, estimatedAmount, estimatedCost, estimatedFee) =
                LegacyRoute.tryBuy(padRegistry, token, trader, funds);
            quote = _external(quote);
        }
        if (estimatedAmount == 0) return (tokenManager, quote, 0, 0, 0, 0, 0, 0);
        if (quote == address(0)) amountMsgValue = funds;
        else amountApproval = funds;
        amountFunds = estimatedCost;
    }

    /// @notice Helper3.trySell's layout (GangGateway's): what selling `amount` pays now after the pad's 1% fee (before
    ///         a router fee) and that fee; 0, 0 when the sell would revert. Treat funds == 0 as "do not sell".
    function trySell(address token, uint256 amount)
        external
        view
        returns (address tokenManager, address quote, uint256 funds, uint256 fee)
    {
        tokenManager = address(this);
        uint8 kind = kindOf[token];
        if (kind != 0) {
            (, quote,,,) = getTokenInfo(token);
            if (kind == KIND_CURVE) (funds, fee) = CurveLogic.quoteSell(curves, token, amount);
        } else {
            (quote, funds, fee) = LegacyRoute.trySell(padRegistry, token, amount);
            quote = _external(quote);
        }
    }

    /// @notice Buy with `funds` of the quote; tokens go to `to`, the wallet that sent the tx (TraderNotOrigin). BNB-quoted:
    ///         msg.value == funds (native BNB). ERC-20-quoted: msg.value == 0, `funds` pulled from msg.sender. A cap /
    ///         graduation cut (or a 铸币飞轮 mint's unspent part) goes back to `to` in the quote ERC-20 (WBNB for a
    ///         BNB-quoted token). The Agent gate and the wallet cap are `to`'s.
    /// @return amountOut tokens `to` received, at least `minAmount`
    /// @return fundsUsed funds the pad kept
    function buyTokenAMAP(address token, address to, uint256 funds, uint256 minAmount)
        external
        payable
        nonReentrant
        returns (uint256 amountOut, uint256 fundsUsed)
    {
        if (to != tx.origin) revert TraderNotOrigin();
        uint8 kind = kindOf[token];
        if (kind == KIND_CURVE) {
            Curve storage cv = curves[token];
            if (cv.graduated) revert NotCurveToken();
            // the same rule as `buyFor` (A-2) and as GangGateway on any pad: the entry buys only with the gate on
            if (!_config.agentGateEnabled) revert RouterNeedsGate();
            // the same hooks as `buy` / `buyFor` (no-ops in this version; a later rule set must not be skipped here)
            _checkCurveTrader(token, to);
            IERC20 quote = IERC20(cv.quote);
            _payIn(address(quote), funds);
            uint256 toBefore = quote.balanceOf(to);
            amountOut = CurveLogic.buy(
                _config, curves, creatorFeeOf, _deps(), to, token, funds, minAmount, _lockedOf(token, to), true
            );
            fundsUsed = funds - (quote.balanceOf(to) - toBefore);
        } else if (kind != 0) {
            revert NotCurveToken();
        } else {
            IERC20 quote = IERC20(LegacyRoute.quoteOf(padRegistry, token));
            uint256 escrow = quote.balanceOf(address(this));
            _payIn(address(quote), funds);
            (amountOut, fundsUsed) = LegacyRoute.buy(padRegistry, token, to, funds, minAmount);
            if (quote.balanceOf(address(this)) != escrow) revert EscrowMoved();
        }
        emit GatewayBuy(token, to, msg.sender, fundsUsed, amountOut);
    }

    /// @notice four.meme's sell with a router fee (TokenManager2.sellToken / GangGateway's), for the seller itself
    ///         (`from == msg.sender`) or a listed caller (`isCaller`, else NotWhitelisted); `from` is the wallet that
    ///         sent the tx (TraderNotOrigin). Sells `amount` of `from`'s tokens with the allowance `from` gave THIS address
    ///         on the token. Of what the curve pays (after its 1% fee), `feeRate` / 10000 goes to `feeRecipient` and
    ///         the rest to `from`: native BNB for a BNB-quoted token, else the quote ERC-20.
    /// @param origin ignored (four.meme's reserved field; pass 0)
    /// @param minFunds the least `from` must end up with, after the pad's fee AND the router fee
    /// @param feeRate router fee in basis points, at most 500 (5%)
    function sellToken(
        uint256 origin,
        address token,
        address from,
        uint256 amount,
        uint256 minFunds,
        uint256 feeRate,
        address feeRecipient
    ) external nonReentrant returns (uint256 fundsToSeller) {
        origin; // four.meme's reserved field
        _entryCaller(from);
        if (feeRate > MAX_FEE_RATE) revert FeeRateTooHigh();
        (IERC20 quote, uint256 funds, uint256 base, bool forwarded) = _entrySell(token, from, amount);
        uint256 fee = (funds * feeRate) / BPS;
        fundsToSeller = funds - fee;
        if (fundsToSeller < minFunds) revert Slippage();
        // the pad itself, or WBNB (its payable fallback books the BNB fee as the pad's WBNB): outside every book
        if (fee > 0 && (feeRecipient == address(0) || feeRecipient == address(this) || feeRecipient == wbnb)) {
            revert ZeroFeeRecipient();
        }

        if (address(quote) == wbnb) {
            IWBNB3(wbnb).withdraw(funds);
            _sendBnb(feeRecipient, fee);
            _sendBnb(from, fundsToSeller);
        } else {
            if (fee > 0) quote.safeTransfer(feeRecipient, fee);
            quote.safeTransfer(from, fundsToSeller);
        }
        if (forwarded && quote.balanceOf(address(this)) != base) revert EscrowMoved();
        emit GatewaySell(token, from, msg.sender, amount, funds, fundsToSeller, fee, feeRecipient);
    }

    /// @notice four.meme's pay-to sell (TokenManager2.sellToken(origin, token, from, to, amount, minFunds), same
    ///         selector) for multi-hop routes: sells `amount` of `from`'s tokens — with the allowance `from` gave THIS
    ///         address, the tokens never pass through `to` (before graduation they move only by the pad) — and pays
    ///         everything the curve (or the older pad) pays after its 1% fee to `to`, which goes on with the next hop.
    ///         Native BNB for a BNB-quoted token, else the quote ERC-20. No router fee here (four.meme's has none
    ///         either): the aggregator takes its own on a later hop. `to` must be the CALLER itself and a listed
    ///         aggregator contract (`isCaller`), else RecipientNotListed (pay-to review M: four.meme lets any caller
    ///         name a listed `to`; here a seller's direct call, or a call by one listed contract, can never park the
    ///         proceeds on another listed contract whose balance someone else could spend). The seller is the wallet
    ///         that sent the tx (TraderNotOrigin).
    /// @param origin ignored (four.meme's reserved field; pass 0)
    /// @param minFunds the least `to` must receive, after the pad's fee (net, as the other `sellToken`)
    /// @return funds what `to` received
    function sellToken(uint256 origin, address token, address from, address to, uint256 amount, uint256 minFunds)
        external
        nonReentrant
        returns (uint256 funds)
    {
        origin; // four.meme's reserved field
        if (to != msg.sender || !isCaller[to] || to == address(this) || to == wbnb) revert RecipientNotListed();
        _entryCaller(from);
        IERC20 quote;
        uint256 base;
        bool forwarded;
        (quote, funds, base, forwarded) = _entrySell(token, from, amount);
        if (funds < minFunds) revert Slippage();
        if (address(quote) == wbnb) {
            IWBNB3(wbnb).withdraw(funds);
            _sendBnb(to, funds);
        } else {
            quote.safeTransfer(to, funds);
        }
        if (forwarded && quote.balanceOf(address(this)) != base) revert EscrowMoved();
        emit GatewaySellTo(token, from, to, msg.sender, amount, funds);
    }

    /// @dev Both entry sells: the seller itself or a listed caller (Gateway audit M-1), the seller = tx.origin (§23).
    function _entryCaller(address from) internal view {
        if (from != msg.sender && !isCaller[msg.sender]) revert NotWhitelisted();
        if (from != tx.origin) revert TraderNotOrigin();
    }

    /// @dev Both entry sells: `amount` of `from`'s tokens sold into the pad (own curve, PULL_PAD) or forwarded to their
    ///      older pad (LegacyRoute); the proceeds after the curve's 1% fee are on the pad, to be paid out by the caller.
    ///      `base`: the pad's own balance of `quote` before a forwarded sell (escrow check).
    function _entrySell(address token, address from, uint256 amount)
        internal
        returns (IERC20 quote, uint256 funds, uint256 base, bool forwarded)
    {
        uint8 kind = kindOf[token];
        if (kind == KIND_CURVE) {
            Curve storage cv = curves[token];
            if (cv.graduated) revert NotCurveToken();
            _checkCurveTrader(token, from);
            quote = IERC20(cv.quote);
            funds = CurveLogic.sell(
                _config, curves, creatorFeeOf, _deps(), from, CurveLogic.PULL_PAD, token, amount, 0, address(this)
            );
        } else if (kind != 0) {
            revert NotCurveToken();
        } else {
            (quote, funds, base) = LegacyRoute.sell(padRegistry, token, from, amount);
            forwarded = true;
        }
    }

    // ---------------------------------------------------------------- shared views
    function isAgent(address account) external view returns (bool) {
        return PadCommon.isAgent(_config, account);
    }

    function tokenCount() external view returns (uint256) {
        return allTokens.length;
    }

    function pairFactory() external view returns (address) {
        return _config.pairFactory;
    }

    function v3Factory() external view returns (address) {
        return _config.v3Factory;
    }

    function twapWindow() external view returns (uint32) {
        return _config.twapWindow;
    }

    function migrator() external view returns (IMigratorV2) {
        return IMigratorV2(_config.migrator);
    }

    function agentIdRegistry() external view returns (IERC721) {
        return IERC721(_config.agentIdRegistry);
    }

    function agentGateEnabled() external view returns (bool) {
        return _config.agentGateEnabled;
    }

    function walletCapEnabled() external view returns (bool) {
        return _config.walletCapEnabled;
    }

    // ---------------------------------------------------------------- internal
    /// @dev `funds` of `quote` into the pad for this trade: WBNB from msg.value (== funds), else pulled exactly from
    ///      msg.sender (a fee-on-transfer quote arrives short: FeeOnTransferQuote).
    function _payIn(address quote, uint256 funds) internal {
        if (quote == wbnb) {
            if (msg.value != funds) revert BadMsgValue();
            IWBNB3(wbnb).deposit{value: funds}();
        } else {
            if (msg.value != 0) revert BadMsgValue();
            uint256 before = IERC20(quote).balanceOf(address(this));
            IERC20(quote).safeTransferFrom(msg.sender, address(this), funds);
            if (IERC20(quote).balanceOf(address(this)) - before != funds) revert FeeOnTransferQuote();
        }
    }

    /// @dev The quote as four.meme reports it: address(0) for WBNB.
    function _external(address quote) internal view returns (address) {
        return quote == wbnb ? address(0) : quote;
    }

    /// @dev Has code, and that code is not an EIP-7702 delegation designator (0xef0100 ‖ address, 23 bytes).
    function _isPlainContract(address a) internal view returns (bool) {
        uint256 size = a.code.length;
        if (size == 0) return false;
        if (size != 23) return true;
        return bytes3(a.code) != 0xef0100;
    }

    function _sendBnb(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert BnbTransferFailed();
    }

    /// @dev Who may act for `trader` (§23): only a listed router (OnlyRouter), and only for the wallet that sent the
    ///      tx (TraderNotOrigin). The whitelist keeps unknown contracts out; the origin binding keeps a listed router
    ///      from being used to fill someone else's cap or to seed the future pair (it is a contract, never tx.origin).
    function _forTrader(address trader) internal view {
        if (!routers[msg.sender]) revert OnlyRouter();
        if (trader != tx.origin) revert TraderNotOrigin();
    }

    function _deps() internal view returns (Deps memory) {
        return Deps({
            quoteRegistry: address(quoteRegistry),
            dividendVault: address(dividendVault),
            platformBucket: address(platformBucket),
            taxHandler: taxHandler,
            tokenDeployer: tokenDeployer,
            wbnb: wbnb
        });
    }

    /// @dev Who may trade `token` on the curve beyond the usual checks. Anyone on this pad; kept as 2.0's hook point for a
    ///      later rule set. A version that makes it refuse someone must make `tryBuy` quote 0 for them too (review 3).
    function _checkCurveTrader(address, address) internal pure {}

    /// @dev What `user` holds in `token`'s vault, counted against the 1% wallet cap with the wallet balance. None on
    ///      this pad; the vault pad (GangVaultLaunchpad, SPEC-VAULT-LOCK §3.5) books it.
    function _lockedOf(address, address) internal pure returns (uint256) {
        return 0;
    }

    /// @dev Both kinds: the kind is written once, here, and never changes.
    function _record(address token, string calldata logoURI, uint8 kind) internal {
        kindOf[token] = kind;
        tokenVersionOf[token] = TOKEN_VERSION;
        emit TokenVersionSet(token, TOKEN_VERSION);
        logoURIOf[token] = logoURI;
        allTokens.push(token);
    }
}
