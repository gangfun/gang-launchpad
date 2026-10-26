// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {LaunchTokenV3} from "./LaunchTokenV3.sol";
import {QuoteRegistry} from "../launchpad-v2/QuoteRegistry.sol";
import {DividendVault} from "../launchpad-v2/DividendVault.sol";
import {PlatformFeeBucket} from "../launchpad-v2/PlatformFeeBucket.sol";
import {IMigratorV2} from "../launchpad-v2/interfaces/IMigratorV2.sol";
import {MigratorV2} from "../launchpad-v2/MigratorV2.sol";
import {PoolCheck} from "../launchpad-v2/PoolCheck.sol";
import {TaxLaunchTokenV3, TaxTokenDeployerV3} from "./TaxLaunchTokenV3.sol";
import {TaxRouterV3} from "./TaxRouterV3.sol";
import {RecipientRegistry} from "./RecipientRegistry.sol";
import {ILaunchpadV3} from "./interfaces/ILaunchpadV3.sol";
import {ITaxRouter, V3_PLATFORM_TAX_BPS} from "./interfaces/ITaxRouter.sol";

/// @title LaunchpadV3 (tax recipient)
/// @notice V2 curve / BAW gate / walletCap 1% / ≈15 BNB graduation, unchanged. The `bool taxed` switch becomes a
///         TaxConfig: a buy tax and a sell tax (1%–5% each, immutable, charged on the curve and on the pool), a holder
///         dividend share, and a platform-listed tax recipient. Every tax payment is split by TaxRouterV3: 0.5% of
///         the trade's volume to the platform, then the dividend share, the rest to the recipient in quote.
///         Bonding protocol fee (1% → PlatformFeeBucket) is unchanged and charged on top of the tax.
/// @dev Spec: docs/SPEC-V3-TAX-RECIPIENT-2026-10-26.md. NO mainnet broadcast from this branch.
contract LaunchpadV3 is ILaunchpadV3, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 public constant CURVE_SUPPLY = 800_000_000 ether;
    uint256 public constant VIRTUAL_TOKEN = 1_066_666_666_666_666_666_666_666_667;
    uint256 public constant MAX_PER_WALLET = 10_000_000 ether; // 1% of TOTAL_SUPPLY
    uint256 public constant BPS = 10_000;

    /// @dev Bonding fee, all tokens: 1% → PlatformFeeBucket. The token's tax is charged on top.
    uint256 public constant PROTOCOL_FEE_BPS = 100;
    /// @dev Platform's part of every taxed trade (curve and pool), as a share of the trade's volume; out of the tax.
    uint256 public constant PLATFORM_TAX_BPS = V3_PLATFORM_TAX_BPS;
    uint16 public constant MIN_TAX_BPS = 100;
    uint16 public constant MAX_TAX_BPS = 500;
    /// @dev Holders need balance strictly > 10_000 tokens for dividend shares (V2 parity).
    uint256 public constant TAXED_MIN_SHARE = 10_000 ether;
    uint256 public constant TARGET_GRAD_BNB = 15 ether;
    uint256 public constant MIN_REF_DEPTH_BNB = 1 ether;
    uint256 public constant MIN_GRAD_AMT = 1e6;

    struct Curve {
        address creator;
        address quote;
        uint128 realQuote;
        uint128 sold;
        uint128 gradAmt;
        uint128 virtualQuote;
        bool graduated;
        uint16 buyTaxBps;
        uint16 sellTaxBps;
        uint16 dividendBps;
        address pair;
        address refPair;
    }

    QuoteRegistry public immutable quoteRegistry;
    DividendVault public immutable dividendVault;
    PlatformFeeBucket public immutable platformBucket;
    address public immutable taxHandler;
    TaxRouterV3 public immutable router;
    RecipientRegistry public immutable recipientRegistry;
    TaxTokenDeployerV3 public immutable taxTokenDeployer;
    address public immutable wbnb;
    address public pairFactory;
    address public v3Factory;
    uint32 public twapWindow = 1800;
    mapping(address => address) public bridgePoolOf;
    IMigratorV2 public migrator;

    IERC721 public agentIdRegistry;
    bool public agentGateEnabled = true;
    bool public walletCapEnabled = true;
    /// @notice Stateless entry contracts (e.g. GangRouter) that may buy for a trader they pay for. A router only ever
    ///         spends its own quote; sells stay msg.sender-only (tokens are locked to the pad before graduation).
    mapping(address router => bool) public routers;

    mapping(address token => Curve) public curves;
    mapping(address token => string) public logoURIOf;
    address[] public allTokens;

    event Buy(
        address indexed token,
        address indexed buyer,
        uint256 quoteIn,
        uint256 protocolFee,
        uint256 tax,
        uint256 tokensOut,
        uint256 realQuote
    );
    event Sell(
        address indexed token,
        address indexed seller,
        uint256 tokensIn,
        uint256 protocolFee,
        uint256 tax,
        uint256 quoteOut,
        uint256 realQuote
    );
    event VirtualQuoteLocked(address indexed token, uint256 virtualQuote);
    event Graduated(
        address indexed token, address indexed pair, address quote, uint256 tokenAmount, uint256 quoteAmount
    );
    event MigratorSet(address indexed migrator);
    event PairFactorySet(address indexed factory);
    event AgentGateUpdated(bool enabled, address registry);
    event WalletCapUpdated(bool enabled);
    event V3FactorySet(address indexed factory);
    event TwapWindowUpdated(uint32 window);
    event BridgePoolSet(address indexed asset, address indexed pool);
    event RouterSet(address indexed router, bool enabled);

    error UnknownToken();
    error AlreadyGraduated();
    error ZeroAmount();
    error GradAmtTooSmall();
    error Slippage();
    error MigratorNotSet();
    error MigratorAlreadySet();
    error ZeroAddress();
    error NotAgent();
    error WalletCapReached();
    error RefPoolRequired();
    error NoBridgePool();
    error BridgeNotWbnb();
    error BadTaxConfig(string reason);
    error OnlyRouter();
    error QuoteNotAllowed();
    error WrongMigrator();
    error RouterNeedsGate();

    constructor(
        address owner_,
        address quoteRegistry_,
        address dividendVault_,
        address platformBucket_,
        address taxHandler_,
        address router_,
        address recipientRegistry_,
        address taxTokenDeployer_,
        address wbnb_,
        address pairFactory_
    ) Ownable(owner_) {
        if (
            quoteRegistry_ == address(0) || dividendVault_ == address(0) || platformBucket_ == address(0)
                || taxHandler_ == address(0) || router_ == address(0) || recipientRegistry_ == address(0)
                || taxTokenDeployer_ == address(0) || wbnb_ == address(0)
        ) revert ZeroAddress();
        quoteRegistry = QuoteRegistry(quoteRegistry_);
        dividendVault = DividendVault(dividendVault_);
        platformBucket = PlatformFeeBucket(platformBucket_);
        taxHandler = taxHandler_;
        router = TaxRouterV3(router_);
        recipientRegistry = RecipientRegistry(recipientRegistry_);
        taxTokenDeployer = TaxTokenDeployerV3(taxTokenDeployer_);
        wbnb = wbnb_;
        pairFactory = pairFactory_;
    }

    function setMigrator(address migrator_) external onlyOwner {
        if (address(migrator) != address(0)) revert MigratorAlreadySet();
        if (migrator_ == address(0)) revert ZeroAddress();
        // one-shot: a migrator bound to another pad would make every graduation revert forever
        if (MigratorV2(migrator_).launchpad() != address(this)) revert WrongMigrator();
        migrator = IMigratorV2(migrator_);
        emit MigratorSet(migrator_);
    }

    function setPairFactory(address factory_) external onlyOwner {
        pairFactory = factory_;
        emit PairFactorySet(factory_);
    }

    function setRouter(address router_, bool enabled) external onlyOwner {
        if (router_ == address(0)) revert ZeroAddress();
        routers[router_] = enabled;
        emit RouterSet(router_, enabled);
    }

    function setAgentGate(bool enabled, address registry) external onlyOwner {
        agentGateEnabled = enabled;
        agentIdRegistry = IERC721(registry);
        emit AgentGateUpdated(enabled, registry);
    }

    function setWalletCapEnabled(bool enabled) external onlyOwner {
        walletCapEnabled = enabled;
        emit WalletCapUpdated(enabled);
    }

    function setV3Factory(address factory_) external onlyOwner {
        v3Factory = factory_;
        emit V3FactorySet(factory_);
    }

    function setTwapWindow(uint32 window) external onlyOwner {
        twapWindow = window;
        emit TwapWindowUpdated(window);
    }

    function setBridgePool(address asset, address pool) external onlyOwner {
        if (asset == address(0) || asset == wbnb) revert ZeroAddress();
        if (pool != address(0)) {
            PoolCheck.PoolInfo memory info = PoolCheck.inspect(_cfg(), pool);
            if (PoolCheck.counterOf(info, asset) != wbnb) revert BridgeNotWbnb();
        }
        bridgePoolOf[asset] = pool;
        emit BridgePoolSet(asset, pool);
    }

    function _cfg() internal view returns (PoolCheck.Cfg memory) {
        return PoolCheck.Cfg({wbnb: wbnb, v2Factory: pairFactory, v3Factory: v3Factory, twapWindow: twapWindow});
    }

    // ---------------------------------------------------------------- create
    /// @inheritdoc ILaunchpadV3
    function create(
        string calldata name,
        string calldata symbol,
        string calldata logoURI,
        string calldata metaURI,
        address quote,
        address refPool,
        TaxConfig calldata tax
    ) external returns (address token) {
        if (address(migrator) == address(0)) revert MigratorNotSet();
        _requireAgent(msg.sender);
        string memory reason = _checkTax(tax);
        if (bytes(reason).length != 0) revert BadTaxConfig(reason);

        if (quote == address(0)) quote = wbnb;
        _requireQuote(quote);
        (uint256 lockedGrad, address refUsed) = _lockGradAmt(quote, refPool);
        if (lockedGrad < MIN_GRAD_AMT) revert GradAmtTooSmall();

        if (tax.buyTaxBps == 0) {
            token = address(new LaunchTokenV3(name, symbol, metaURI));
        } else {
            token = _createTaxed(name, symbol, metaURI, quote, tax);
        }

        _writeCurve(token, quote, lockedGrad, tax, refUsed);
        logoURIOf[token] = logoURI;
        allTokens.push(token);

        emit Created(token, msg.sender, name, symbol, logoURI, quote, refUsed, lockedGrad);
        emit TaxConfigured(token, tax.buyTaxBps, tax.sellTaxBps, tax.dividendBps, tax.recipient);
    }

    function _createTaxed(
        string calldata name,
        string calldata symbol,
        string calldata uri,
        address quote,
        TaxConfig calldata tax
    ) internal returns (address token) {
        token = taxTokenDeployer.deploy(name, symbol, tax.buyTaxBps, tax.sellTaxBps, taxHandler, uri);
        if (tax.dividendBps > 0) {
            dividendVault.ensureMinimumShareBalance(TAXED_MIN_SHARE);
            dividendVault.registerToken(token, quote);
        }
        router.register(token, quote, tax.recipient, tax.dividendBps);
    }

    /// @inheritdoc ILaunchpadV3
    function checkTaxConfig(TaxConfig calldata tax) external view returns (bool ok, string memory reason) {
        reason = _checkTax(tax);
        ok = bytes(reason).length == 0;
    }

    /// @inheritdoc ILaunchpadV3
    function taxConfigOf(address token)
        external
        view
        returns (uint16 buyTaxBps, uint16 sellTaxBps, uint16 dividendBps, address recipient)
    {
        Curve storage c = curves[token];
        (, recipient,) = router.routeOf(token);
        return (c.buyTaxBps, c.sellTaxBps, c.dividendBps, recipient);
    }

    /// @dev Empty string = valid.
    function _checkTax(TaxConfig calldata tax) internal view returns (string memory) {
        if (tax.buyTaxBps == 0 && tax.sellTaxBps == 0) {
            if (tax.dividendBps != 0 || tax.recipient != address(0)) {
                return "untaxed: dividendBps / recipient must be empty";
            }
            return "";
        }
        if (
            tax.buyTaxBps < MIN_TAX_BPS || tax.buyTaxBps > MAX_TAX_BPS || tax.sellTaxBps < MIN_TAX_BPS
                || tax.sellTaxBps > MAX_TAX_BPS
        ) return "buyTaxBps and sellTaxBps must each be 100-500 (1%-5%)";
        if (tax.dividendBps > BPS) return "dividendBps > 10000";
        if (tax.recipient == address(0)) {
            if (tax.dividendBps != BPS) return "no recipient: dividendBps must be 10000";
            return "";
        }
        if (!recipientRegistry.isListed(tax.recipient)) return "recipient not listed";
        return "";
    }

    // ---------------------------------------------------------------- buy
    struct BuyVars {
        uint256 protocolFee;
        uint256 tax;
        uint256 platformTax;
        uint256 net;
        uint256 refundGross;
        uint256 gradAmt;
        uint256 tokensOut;
        uint256 feeBps;
    }

    function buy(address token, uint256 quoteIn, uint256 minTokensOut)
        external
        nonReentrant
        returns (uint256 tokensOut)
    {
        tokensOut = _buy(msg.sender, token, quoteIn, minTokensOut);
    }

    /// @notice A listed router buys for `trader`: the router pays and gets any refund (cap / graduation truncation);
    ///         the tokens, the dividend share, the gate and the wallet cap are the trader's.
    function buyFor(address trader, address token, uint256 quoteIn, uint256 minTokensOut)
        external
        nonReentrant
        returns (uint256 tokensOut)
    {
        if (!routers[msg.sender]) revert OnlyRouter();
        // ungated, a router could name any trader — e.g. the future pair, seeding it before graduation
        if (!agentGateEnabled) revert RouterNeedsGate();
        tokensOut = _buy(trader, token, quoteIn, minTokensOut);
    }

    /// @dev msg.sender pays (the trader itself, or a router); `trader` receives.
    function _buy(address trader, address token, uint256 quoteIn, uint256 minTokensOut)
        internal
        returns (uint256 tokensOut)
    {
        Curve storage c = _live(token);
        if (quoteIn == 0) revert ZeroAmount();
        _requireAgent(trader);

        BuyVars memory v = _prepBuy(c, token, trader, quoteIn);
        tokensOut = v.tokensOut;
        if (tokensOut < minTokensOut) revert Slippage();

        tokensOut = _execBuy(c, token, trader, quoteIn, minTokensOut, v);
    }

    function _prepBuy(Curve storage c, address token, address trader, uint256 quoteIn)
        internal
        view
        returns (BuyVars memory v)
    {
        uint256 room = walletRoom(token, trader);
        if (walletCapEnabled && room == 0) revert WalletCapReached();

        v.feeBps = _feeBps(c);
        _applyFees(quoteIn, v);
        v.gradAmt = c.gradAmt;
        uint256 remaining = v.gradAmt - c.realQuote;

        if (v.net > remaining) {
            v.net = remaining;
            _recomputeFee(quoteIn, v);
            if (v.net > remaining) v.net = remaining;
        }

        v.tokensOut = _tokensOut(c, v.net);
        if (walletCapEnabled && v.tokensOut > room) {
            v.tokensOut = room;
            v.net = _quoteInFor(c, room);
            _recomputeFee(quoteIn, v);
        }
    }

    function _feeBps(Curve storage c) internal view returns (uint256) {
        return PROTOCOL_FEE_BPS + c.buyTaxBps;
    }

    function _applyFees(uint256 gross, BuyVars memory v) internal pure {
        v.protocolFee = (gross * PROTOCOL_FEE_BPS) / BPS;
        v.tax = (gross * v.feeBps) / BPS - v.protocolFee;
        v.platformTax = _platformPart(gross, v.tax);
        v.net = gross - v.protocolFee - v.tax;
    }

    /// @dev Platform's 0.5% of `volume`, out of `tax` (never more than the tax itself; untaxed → 0).
    function _platformPart(uint256 volume, uint256 tax) internal pure returns (uint256 p) {
        if (tax == 0) return 0;
        p = (volume * PLATFORM_TAX_BPS) / BPS;
        if (p > tax) p = tax;
    }

    function _recomputeFee(uint256 quoteIn, BuyVars memory v) internal pure {
        uint256 spentGross = Math.ceilDiv(v.net * BPS, BPS - v.feeBps);
        if (spentGross > quoteIn) spentGross = quoteIn;
        _applyFees(spentGross, v);
        v.refundGross = quoteIn - spentGross;
    }

    function _execBuy(
        Curve storage c,
        address token,
        address trader,
        uint256 quoteIn,
        uint256 minTokensOut,
        BuyVars memory v
    ) internal returns (uint256 tokensOut) {
        address quoteAddr = c.quote;
        v = _pullQuoteAndPrep(c, token, trader, quoteAddr, quoteIn, minTokensOut, v);

        c.realQuote += v.net.toUint128();
        c.sold += v.tokensOut.toUint128();

        IERC20(token).safeTransfer(trader, v.tokensOut);
        _syncShareAndTax(c, token, trader, quoteAddr, v.protocolFee, v.tax, v.platformTax, false);

        emit Buy(token, trader, v.net, v.protocolFee, v.tax, v.tokensOut, c.realQuote);

        if (v.refundGross > 0) IERC20(quoteAddr).safeTransfer(msg.sender, v.refundGross);
        if (c.realQuote >= v.gradAmt) _graduate(token, c);
        tokensOut = v.tokensOut;
    }

    function _pullQuoteAndPrep(
        Curve storage c,
        address token,
        address trader,
        address quoteAddr,
        uint256 quoteIn,
        uint256 minTokensOut,
        BuyVars memory v
    ) internal returns (BuyVars memory) {
        IERC20 quote = IERC20(quoteAddr);
        uint256 beforeBal = quote.balanceOf(address(this));
        quote.safeTransferFrom(msg.sender, address(this), quoteIn);
        uint256 received = quote.balanceOf(address(this)) - beforeBal;
        if (received == 0) revert ZeroAmount();
        if (received != quoteIn) {
            v = _prepBuy(c, token, trader, received);
            if (v.tokensOut < minTokensOut) revert Slippage();
        }
        return v;
    }

    /// @dev A buy's tax is distributed BEFORE the buyer's share grows: it rewards holders as of before this trade
    ///      (a first buy with no eligible holders rolls the dividend leg to the recipient / platform). A sell syncs the
    ///      seller's (now smaller) share FIRST, so the seller earns nothing of its own tax on what it just sold.
    function _syncShareAndTax(
        Curve storage c,
        address token,
        address account,
        address quoteAddr,
        uint256 protocolFee,
        uint256 tax,
        uint256 platformTax,
        bool shareFirst
    ) internal {
        IERC20 quote = IERC20(quoteAddr);
        bool dividends = c.dividendBps > 0;
        if (dividends && shareFirst) dividendVault.setShare(token, account, IERC20(token).balanceOf(account));
        if (tax > 0) {
            quote.forceApprove(address(router), tax);
            router.distribute(token, tax, platformTax, ITaxRouter.Phase.Bonding);
        }
        if (dividends && !shareFirst) dividendVault.setShare(token, account, IERC20(token).balanceOf(account));
        if (protocolFee > 0) {
            quote.forceApprove(address(platformBucket), protocolFee);
            platformBucket.notifyAccrual(quoteAddr, protocolFee);
        }
    }

    // ---------------------------------------------------------------- sell
    function sell(address token, uint256 tokensIn, uint256 minQuoteOut)
        external
        nonReentrant
        returns (uint256 quoteToUser)
    {
        Curve storage c = _live(token);
        if (tokensIn == 0) revert ZeroAmount();
        _requireAgent(msg.sender);

        uint256 quoteOut = _quoteOut(c, tokensIn);
        uint256 protocolFee = (quoteOut * PROTOCOL_FEE_BPS) / BPS;
        uint256 tax = (quoteOut * c.sellTaxBps) / BPS;
        uint256 platformTax = _platformPart(quoteOut, tax);
        quoteToUser = quoteOut - protocolFee - tax;
        if (quoteToUser < minQuoteOut) revert Slippage();

        c.realQuote -= quoteOut.toUint128();
        c.sold -= tokensIn.toUint128();

        IERC20(token).safeTransferFrom(msg.sender, address(this), tokensIn);

        address quoteAddr = c.quote;
        _syncShareAndTax(c, token, msg.sender, quoteAddr, protocolFee, tax, platformTax, true);
        IERC20(quoteAddr).safeTransfer(msg.sender, quoteToUser);

        emit Sell(token, msg.sender, tokensIn, protocolFee, tax, quoteToUser, c.realQuote);
    }

    // ---------------------------------------------------------------- views
    function isAgent(address account) public view returns (bool) {
        if (!agentGateEnabled) return true;
        if (address(agentIdRegistry) == address(0)) return false;
        return agentIdRegistry.balanceOf(account) > 0;
    }

    /// @dev WBNB, or a QuoteRegistry-enabled 18-decimal quote WITH a fixed rate (graduationAmount > 0): no
    ///      fee-on-transfer / hook / low-decimal quotes (6 decimals would round holder dividends to 0 in DividendVault),
    ///      and no pricing from a creator-picked reference pool, whose spot price one flash swap can move by 1000×
    ///      within the create tx (2026-10-26 internal audit round 2). The multisig keeps the rate current.
    function _requireQuote(address quote) internal view {
        if (quote == wbnb) return;
        if (quoteRegistry.graduationAmount(quote) == 0 || IERC20Metadata(quote).decimals() != 18) {
            revert QuoteNotAllowed();
        }
    }

    function _requireAgent(address account) internal view {
        if (agentGateEnabled && !isAgent(account)) revert NotAgent();
    }

    function walletRoom(address token, address buyer) public view returns (uint256) {
        if (!walletCapEnabled) return type(uint256).max;
        uint256 bal = IERC20(token).balanceOf(buyer);
        return bal >= MAX_PER_WALLET ? 0 : MAX_PER_WALLET - bal;
    }

    function tokenCount() external view returns (uint256) {
        return allTokens.length;
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

    function graduationAmountOf(address quote, address refPool) external view returns (uint256) {
        if (quote == address(0)) quote = wbnb;
        (uint256 g,) = _lockGradAmt(quote, refPool);
        return g;
    }

    // ---------------------------------------------------------------- internal
    /// @dev Same as LaunchpadV2._lockGradAmt.
    function _lockGradAmt(address quote, address refPool) internal view returns (uint256 gradAmt, address refUsed) {
        if (quote == wbnb) return (TARGET_GRAD_BNB, address(0));

        PoolCheck.Cfg memory cfg = _cfg();
        uint256 ov = quoteRegistry.graduationAmount(quote);
        if (ov > 0) {
            if (refPool != address(0)) PoolCheck.counterOf(PoolCheck.inspect(cfg, refPool), quote);
            return (ov, refPool);
        }

        if (refPool == address(0)) revert RefPoolRequired();
        PoolCheck.PoolInfo memory info = PoolCheck.inspect(cfg, refPool);
        address counter = PoolCheck.counterOf(info, quote);

        uint256 targetCounter;
        if (counter == wbnb) {
            targetCounter = TARGET_GRAD_BNB;
        } else {
            address bridge = bridgePoolOf[counter];
            if (bridge == address(0)) revert NoBridgePool();
            PoolCheck.PoolInfo memory bInfo = PoolCheck.inspect(cfg, bridge);
            if (PoolCheck.counterOf(bInfo, counter) != wbnb) revert BridgeNotWbnb();
            targetCounter = PoolCheck.convert(cfg, bInfo, bridge, counter, TARGET_GRAD_BNB);
        }

        uint256 minDepth = Math.mulDiv(targetCounter, MIN_REF_DEPTH_BNB, TARGET_GRAD_BNB);
        if (PoolCheck.depthOf(info, refPool, counter) < minDepth) revert PoolCheck.ThinReferencePool();

        gradAmt = PoolCheck.convert(cfg, info, refPool, quote, targetCounter);
        if (gradAmt == 0) revert PoolCheck.GradAmtZero();
        refUsed = refPool;
    }

    function _graduate(address token, Curve storage c) internal {
        c.graduated = true;
        uint256 tokenAmount = TOTAL_SUPPLY - c.sold;
        uint256 quoteAmount = c.realQuote;
        address quote = c.quote;
        c.realQuote = 0;

        if (c.buyTaxBps > 0) {
            // one-shot on the token: unlock + exclude the migrator, then the pair (tax and share syncing start)
            TaxLaunchTokenV3(token).unlock(address(migrator));
            IERC20(token).safeTransfer(address(migrator), tokenAmount);
            IERC20(quote).safeTransfer(address(migrator), quoteAmount);
            address pair = migrator.migrate(token, quote, tokenAmount, quoteAmount);
            c.pair = pair;
            TaxLaunchTokenV3(token).setPair(pair);
        } else {
            LaunchTokenV3(token).unlock();
            IERC20(token).safeTransfer(address(migrator), tokenAmount);
            IERC20(quote).safeTransfer(address(migrator), quoteAmount);
            c.pair = migrator.migrate(token, quote, tokenAmount, quoteAmount);
        }
        emit Graduated(token, c.pair, quote, tokenAmount, quoteAmount);
    }

    function _writeCurve(address token, address quote, uint256 lockedGrad, TaxConfig calldata tax, address refPair)
        internal
    {
        uint256 vq = lockedGrad / 3;
        if (vq == 0) revert ZeroAmount();
        curves[token] = Curve({
            creator: msg.sender,
            quote: quote,
            realQuote: 0,
            sold: 0,
            gradAmt: lockedGrad.toUint128(),
            virtualQuote: vq.toUint128(),
            graduated: false,
            buyTaxBps: tax.buyTaxBps,
            sellTaxBps: tax.sellTaxBps,
            dividendBps: tax.dividendBps,
            pair: address(0),
            refPair: refPair
        });
        emit VirtualQuoteLocked(token, vq);
    }

    function _tokensOut(Curve storage c, uint256 quoteIn) internal view returns (uint256) {
        uint256 vq = c.virtualQuote;
        uint256 k = vq * VIRTUAL_TOKEN;
        uint256 qReserve = vq + c.realQuote;
        uint256 tReserve = VIRTUAL_TOKEN - c.sold;
        uint256 newT = Math.ceilDiv(k, qReserve + quoteIn);
        return tReserve - newT;
    }

    function _quoteInFor(Curve storage c, uint256 tokensOut) internal view returns (uint256) {
        uint256 vq = c.virtualQuote;
        uint256 k = vq * VIRTUAL_TOKEN;
        uint256 qReserve = vq + c.realQuote;
        uint256 tReserve = VIRTUAL_TOKEN - c.sold;
        return Math.ceilDiv(k, tReserve - tokensOut) - qReserve;
    }

    function _quoteOut(Curve storage c, uint256 tokensIn) internal view returns (uint256) {
        uint256 vq = c.virtualQuote;
        uint256 k = vq * VIRTUAL_TOKEN;
        uint256 qReserve = vq + c.realQuote;
        uint256 tReserve = VIRTUAL_TOKEN - c.sold;
        uint256 newQ = Math.ceilDiv(k, tReserve + tokensIn);
        return qReserve - newQ;
    }

    function _live(address token) internal view returns (Curve storage c) {
        c = curves[token];
        if (c.creator == address(0)) revert UnknownToken();
        if (c.graduated) revert AlreadyGraduated();
    }
}
