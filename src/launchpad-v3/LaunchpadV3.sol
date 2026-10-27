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
import {SharedDividendVault} from "../common/SharedDividendVault.sol";
import {SharedPlatformFeeBucket as PlatformFeeBucket} from "../common/SharedPlatformFeeBucket.sol";
import {IMigratorV2} from "../launchpad-v2/interfaces/IMigratorV2.sol";
import {SharedMigrator} from "../common/SharedMigrator.sol";
import {TokenDeployer} from "../common/TokenDeployer.sol";
import {PoolCheck} from "../launchpad-v2/PoolCheck.sol";
import {TaxLaunchTokenV3} from "./TaxLaunchTokenV3.sol";
import {GangTaxHandler} from "../gang/GangTaxHandler.sol";
import {ILaunchpadV3} from "./interfaces/ILaunchpadV3.sol";
import {V3_PLATFORM_TAX_BPS} from "../gang/interfaces/IGangTaxHandler.sol";

/// @title LaunchpadV3 (tax recipient)
/// @notice V2 curve / BAW gate / walletCap 1% / ≈15 BNB graduation, unchanged. The `bool taxed` switch becomes a
///         TaxConfig: a buy tax and a sell tax (1%–5% each, immutable), a holder dividend share, and a platform-listed
///         tax recipient. The tax is charged only on the Pancake pool after graduation (TaxLaunchTokenV3 →
///         TaxHandlerV3: 0.5% of the trade's volume to the platform, then the dividend share, the rest to the
///         recipient in quote). On the curve every token, taxed or not, pays only the 1% protocol fee
///         (→ PlatformFeeBucket), as on V2; dividend shares are still kept in sync so the pool tax finds them.
/// @dev Spec: docs/SPEC-V3-TAX-RECIPIENT-2026-10-26.md (§19: no curve tax, 2026-10-27).
contract LaunchpadV3 is ILaunchpadV3, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 public constant CURVE_SUPPLY = 800_000_000 ether;
    uint256 public constant VIRTUAL_TOKEN = 1_066_666_666_666_666_666_666_666_667;
    uint256 public constant MAX_PER_WALLET = 10_000_000 ether; // 1% of TOTAL_SUPPLY
    uint256 public constant BPS = 10_000;

    /// @dev Bonding fee, all tokens: 1% → PlatformFeeBucket. The only charge on the curve (no tax there).
    uint256 public constant PROTOCOL_FEE_BPS = 100;
    /// @dev Platform's part of every taxed pool trade (after graduation), as a share of the trade's volume; out of the
    ///      tax. Applied by TaxHandlerV3; kept here for readers (CLI / indexer).
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
    SharedDividendVault public immutable dividendVault;
    PlatformFeeBucket public immutable platformBucket;
    /// @notice Recipient whitelist, each token's route and split, and the pool tax after graduation.
    GangTaxHandler public immutable taxHandler;
    TokenDeployer public immutable tokenDeployer;
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
    error FeeOnTransferQuote();
    error WrongMigrator();
    error RouterNeedsGate();
    error VaultFloorTooHigh();

    constructor(
        address owner_,
        address quoteRegistry_,
        address dividendVault_,
        address platformBucket_,
        address taxHandler_,
        address tokenDeployer_,
        address wbnb_,
        address pairFactory_
    ) Ownable(owner_) {
        if (
            quoteRegistry_ == address(0) || dividendVault_ == address(0) || platformBucket_ == address(0)
                || taxHandler_ == address(0) || tokenDeployer_ == address(0) || wbnb_ == address(0)
        ) revert ZeroAddress();
        quoteRegistry = QuoteRegistry(quoteRegistry_);
        dividendVault = SharedDividendVault(dividendVault_);
        platformBucket = PlatformFeeBucket(platformBucket_);
        taxHandler = GangTaxHandler(taxHandler_);
        tokenDeployer = TokenDeployer(tokenDeployer_);
        wbnb = wbnb_;
        pairFactory = pairFactory_;
    }

    function setMigrator(address migrator_) external onlyOwner {
        if (address(migrator) != address(0)) revert MigratorAlreadySet();
        if (migrator_ == address(0)) revert ZeroAddress();
        // one-shot: a migrator that does not list this core would make every graduation revert forever
        if (!SharedMigrator(migrator_).launchpads(address(this))) revert WrongMigrator();
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
            token = tokenDeployer.deployPlain(name, symbol, metaURI);
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
        token = tokenDeployer.deployTax(name, symbol, tax.buyTaxBps, tax.sellTaxBps, address(taxHandler), uri);
        if (tax.dividendBps > 0) {
            // internal audit 5 C-F4 (as FairMintPad): a floor the vault owner raised above TAXED_MIN_SHARE would leave
            // the new token with no shareholders and send the holders' part of its tax elsewhere
            if (dividendVault.minimumShareBalanceOf(address(this)) > TAXED_MIN_SHARE) revert VaultFloorTooHigh();
            dividendVault.ensureMinimumShareBalance(TAXED_MIN_SHARE);
            dividendVault.registerToken(token, quote);
        }
        taxHandler.register(token, quote, tax.recipient, tax.dividendBps, 1);
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
        (, recipient,,) = taxHandler.routeOf(token);
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
        if (!taxHandler.isListed(tax.recipient)) return "recipient not listed";
        return "";
    }

    // ---------------------------------------------------------------- buy
    struct BuyVars {
        uint256 protocolFee;
        uint256 net;
        uint256 refundGross;
        uint256 gradAmt;
        uint256 tokensOut;
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

        tokensOut = _execBuy(c, token, trader, quoteIn, v);
    }

    function _prepBuy(Curve storage c, address token, address trader, uint256 quoteIn)
        internal
        view
        returns (BuyVars memory v)
    {
        uint256 room = walletRoom(token, trader);
        if (walletCapEnabled && room == 0) revert WalletCapReached();

        _applyFee(quoteIn, v);
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

    /// @dev The curve's only charge: 1% of the gross (no tax on the curve, 2026-10-27).
    function _applyFee(uint256 gross, BuyVars memory v) internal pure {
        v.protocolFee = (gross * PROTOCOL_FEE_BPS) / BPS;
        v.net = gross - v.protocolFee;
    }

    function _recomputeFee(uint256 quoteIn, BuyVars memory v) internal pure {
        uint256 spentGross = Math.ceilDiv(v.net * BPS, BPS - PROTOCOL_FEE_BPS);
        if (spentGross > quoteIn) spentGross = quoteIn;
        _applyFee(spentGross, v);
        v.refundGross = quoteIn - spentGross;
    }

    function _execBuy(Curve storage c, address token, address trader, uint256 quoteIn, BuyVars memory v)
        internal
        returns (uint256 tokensOut)
    {
        address quoteAddr = c.quote;
        _pullExact(quoteAddr, quoteIn);

        c.realQuote += v.net.toUint128();
        c.sold += v.tokensOut.toUint128();

        IERC20(token).safeTransfer(trader, v.tokensOut);
        _syncShareAndFee(c, token, trader, quoteAddr, v.protocolFee);

        // `tax` stays in the event (ABI unchanged for indexers): always 0, the curve charges none
        emit Buy(token, trader, v.net, v.protocolFee, 0, v.tokensOut, c.realQuote);

        if (v.refundGross > 0) IERC20(quoteAddr).safeTransfer(msg.sender, v.refundGross);
        if (c.realQuote >= v.gradAmt) _graduate(token, c);
        tokensOut = v.tokensOut;
    }

    /// @dev Audit 4 (A-F1 / B-F2 / C-F1/F2): a fee-on-transfer quote can't graduate (the migrator forwards the
    ///      nominal amount) and under-funds the shared vault / bucket for every token on that quote: refused on the
    ///      first pull (as FairMintPad._pullExact).
    function _pullExact(address quoteAddr, uint256 amount) internal {
        IERC20 quote = IERC20(quoteAddr);
        uint256 beforeBal = quote.balanceOf(address(this));
        quote.safeTransferFrom(msg.sender, address(this), amount);
        if (quote.balanceOf(address(this)) - beforeBal != amount) revert FeeOnTransferQuote();
    }

    /// @dev No tax on the curve: the trade pays only `protocolFee` (→ PlatformFeeBucket). A dividend token's share
    ///      still follows the trader's balance (as V2's taxed track), so the pool tax after graduation is credited
    ///      to the right holders; nothing is paid to holders or to the recipient here.
    function _syncShareAndFee(Curve storage c, address token, address account, address quoteAddr, uint256 protocolFee)
        internal
    {
        if (c.dividendBps > 0) dividendVault.setShare(token, account, IERC20(token).balanceOf(account));
        if (protocolFee > 0) {
            IERC20(quoteAddr).forceApprove(address(platformBucket), protocolFee);
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
        quoteToUser = quoteOut - protocolFee;
        if (quoteToUser < minQuoteOut) revert Slippage();

        c.realQuote -= quoteOut.toUint128();
        c.sold -= tokensIn.toUint128();

        IERC20(token).safeTransferFrom(msg.sender, address(this), tokensIn);

        address quoteAddr = c.quote;
        _syncShareAndFee(c, token, msg.sender, quoteAddr, protocolFee);
        IERC20(quoteAddr).safeTransfer(msg.sender, quoteToUser);

        // `tax` stays in the event (ABI unchanged for indexers): always 0, the curve charges none
        emit Sell(token, msg.sender, tokensIn, protocolFee, 0, quoteToUser, c.realQuote);
    }

    // ---------------------------------------------------------------- views
    function isAgent(address account) public view returns (bool) {
        if (!agentGateEnabled) return true;
        if (address(agentIdRegistry) == address(0)) return false;
        return agentIdRegistry.balanceOf(account) > 0;
    }

    /// @dev WBNB, or any 18-decimal ERC-20 (6 decimals would round holder dividends to 0 in the shared vault), priced
    ///      like LaunchpadV2: a QuoteRegistry fixed rate when set, else the creator's reference pool (_lockGradAmt).
    ///      2026-10-27 product decision: keep V2's reference-pool pricing (users are used to it), accepting internal
    ///      audit R2-1 again: a Pancake V2 pair (reserves) or a V3 pool without TWAP history is read at spot.
    ///      A fee-on-transfer quote is refused at its first pull (FeeOnTransferQuote, audit 4).
    function _requireQuote(address quote) internal view {
        if (quote == wbnb) return;
        // low-level: a high-level call to an address without code reverts outside any try/catch
        (bool ok, bytes memory ret) = quote.staticcall(abi.encodeWithSelector(IERC20Metadata.decimals.selector));
        if (!ok || ret.length < 32 || abi.decode(ret, (uint256)) != 18) revert QuoteNotAllowed();
        // audit 4 (C-F3 / C-F4 / B-F1 / A-F2): never a token of this platform — a locked sibling pulled as a quote moves
        // past its wallet cap and lock; a dividend token held by the vault / bucket / a new pair earns rewards no one
        // can claim. TokenDeployer records every token of both cores; the vault also knows registered ones.
        if (tokenDeployer.isLaunchToken(quote) || dividendVault.launchpadOf(quote) != address(0)) {
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
