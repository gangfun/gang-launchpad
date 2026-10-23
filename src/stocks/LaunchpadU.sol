// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {LaunchToken} from "../LaunchToken.sol";
import {TaxLaunchToken} from "./TaxLaunchToken.sol";
import {QuoteRegistry} from "./QuoteRegistry.sol";
import {DividendVault} from "./DividendVault.sol";
import {PlatformFeeBucket} from "./PlatformFeeBucket.sol";
import {IMigratorS, IPairFactoryS} from "./interfaces/IMigratorS.sol";
import {PoolCheck} from "./PoolCheck.sol";
import {PostGradTaxHandler} from "./PostGradTaxHandler.sol";

/// @title LaunchpadU (any-pool + normal/taxed; create-time gradAmt lock ≈15 BNB)
/// @notice BSC mainnet-ready Gang Pair pad. Untaxed bonding: 1%→platform 80/20.
///         Taxed bonding+outer: 50% holders (≥1_000_000 share) + 50% platform (→80% buyback / 20% feeVault).
///         create = BAW Dev allowlist only; bonding buy/sell = Agent gate.
/// @dev No Chapel mocks. TARGET_GRAD_BNB=15e18 spot-locked at create; MIN_RESERVE_WBNB=1e18 ThinWbnb.
contract LaunchpadU is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 public constant CURVE_SUPPLY = 800_000_000 ether;
    /// @dev WBNB reference only (= TARGET_GRAD_BNB/3). Pricing MUST use Curve.virtualQuote, never this for non-WBNB.
    ///      Critical 2026-10-23: global VQ desynced sold-at-grad when gradAmt was spot-scaled.
    uint256 public constant VIRTUAL_QUOTE = 5 ether;
    uint256 public constant VIRTUAL_TOKEN = 1_066_666_666_666_666_666_666_666_667;
    /// @dev Legacy WBNB K (= VIRTUAL_QUOTE * VIRTUAL_TOKEN). Pricing uses per-curve k = virtualQuote * VIRTUAL_TOKEN.
    uint256 public constant K = VIRTUAL_QUOTE * VIRTUAL_TOKEN;
    uint256 public constant MAX_PER_WALLET = 10_000_000 ether;
    uint256 public constant BPS = 10_000;

    /// @dev v4.1-style protocol fee on untaxed path (all → platform bucket → 80/20).
    uint256 public constant PROTOCOL_FEE_BPS = 100;
    /// @dev Taxed path: 0.5% holders + 0.5% platform (= 1% total).
    uint256 public constant DIVIDEND_TAX_BPS = 50;
    uint256 public constant PLATFORM_TAX_BPS = 50;
    /// @dev Lazy-locked holder gate for taxed tokens.
    uint256 public constant TAXED_MIN_SHARE = 1_000_000 ether; // 100万枚 (18 dec)
    /// @dev Gang Pair graduation target in WBNB wei; spot-converted to quote at create and locked.
    uint256 public constant TARGET_GRAD_BNB = 15 ether;
    /// @dev Min WBNB reserve in quote/WBNB pool (dust / thin-pool reject). Prod hard floor = 1e18.
    uint256 public constant MIN_RESERVE_WBNB = 1 ether;
    /// @dev Floor for create-time lockedGrad (Lazy NB #3). Rejects dust before virtualQuote=gradAmt/3.
    uint256 public constant MIN_GRAD_AMT = 1e6;

    /// @dev Curve layout for public `curves(token)` auto-getter.
    ///      **ABI WARNING (2026-10-23):** `virtualQuote` was inserted after `gradAmt`,
    ///      shifting later tuple fields (`graduated`, and for U: `taxed` / `pair` / `refPair`).
    ///      Callers MUST use an updated ABI or named views `gradAmtOf` / `virtualQuoteOf` —
    ///      never stale positional unpack from pre-VQ ABIs.
    struct Curve {
        address creator;
        address quote;
        uint128 realQuote;
        uint128 sold;
        uint128 gradAmt; // locked at create: ≈15 BNB equiv quote, or 15e18 if quote==WBNB
        /// @dev = gradAmt / 3 (floor). Remainder choice: accept wei-level sold-at-grad drift vs CURVE_SUPPLY
        ///      when gradAmt % 3 != 0. WBNB 15e18/3=5e18 exact → sold-at-grad = CURVE_SUPPLY.
        uint128 virtualQuote;
        bool graduated;
        bool taxed;
        address pair; // post-grad pair
        address refPair; // create-time quote/WBNB liquidity pair (when resolved)
    }

    QuoteRegistry public immutable quoteRegistry; // optional: graduationQuoteAmount>0 overrides spot lock
    DividendVault public immutable dividendVault;
    PlatformFeeBucket public immutable platformBucket;
    PostGradTaxHandler public immutable taxHandler;
    address public immutable wbnb;
    address public pairFactory; // Pancake-like factory for getPair
    IMigratorS public migrator;

    IERC721 public agentIdRegistry;
    /// @dev Source default true (Lazy #5). Owner must still setAgentGate(true, registry) to bind registry address.
    bool public agentGateEnabled = true;
    /// @dev Prod: keep true (1% MAX_PER_WALLET). Owner may toggle only if Lazy authorizes.
    bool public walletCapEnabled = true;
    /// @dev Preview fallback only when pair missing/no reserves. Create always locks via spot/TARGET.
    ///      MUST NOT be used as a test-sized pad; default = TARGET_GRAD_BNB for mainnet.
    uint256 public defaultGraduationQuoteAmount = 15 ether;

    /// @notice BAW Dev allowlist for create. Owner sets team BAW wallets post-deploy.
    mapping(address => bool) public isDev;

    /// @notice Prefer named getters over positional `curves()` unpack (see Curve ABI WARNING).
    mapping(address token => Curve) public curves;
    mapping(address token => string) public logoURIOf;
    address[] public allTokens;

    event Created(
        address indexed token,
        address indexed creator,
        string name,
        string symbol,
        string logoURI,
        bool taxed,
        address indexed quote,
        address refPair,
        uint256 gradAmt
    );
    event Buy(
        address indexed token,
        address indexed buyer,
        uint256 quoteIn,
        uint256 taxDividend,
        uint256 taxPlatform,
        uint256 tokensOut,
        uint256 realQuote
    );
    event Sell(
        address indexed token,
        address indexed seller,
        uint256 tokensIn,
        uint256 taxDividend,
        uint256 taxPlatform,
        uint256 quoteOut,
        uint256 realQuote
    );
    /// @notice Emitted at create when per-curve virtualQuote is locked (= floor(gradAmt/3)).
    ///         Indexers: prefer this over extending Created (stack-too-deep on U).
    event VirtualQuoteLocked(address indexed token, uint256 virtualQuote);
    event Graduated(
        address indexed token, address indexed pair, address quote, uint256 tokenAmount, uint256 quoteAmount
    );
    event MigratorSet(address indexed migrator);
    event PairFactorySet(address indexed factory);
    event AgentGateUpdated(bool enabled, address registry);
    event DevUpdated(address indexed account, bool enabled);
    event WalletCapUpdated(bool enabled);
    event DefaultGraduationUpdated(uint256 amount);

    error UnknownToken();
    error AlreadyGraduated();
    error ZeroAmount();
    /// @dev lockedGrad < MIN_GRAD_AMT (1e6)
    error GradAmtTooSmall();
    error Slippage();
    error MigratorNotSet();
    error MigratorAlreadySet();
    error ZeroAddress();
    error NotAgent();
    error NotDev();
    error WalletCapReached();
    error TaxedRequiresPairOrQuote();
    error UntaxedRequiresQuote();

    constructor(
        address owner_,
        address quoteRegistry_,
        address dividendVault_,
        address platformBucket_,
        address taxHandler_,
        address wbnb_,
        address pairFactory_
    ) Ownable(owner_) {
        if (
            quoteRegistry_ == address(0) || dividendVault_ == address(0) || platformBucket_ == address(0)
                || taxHandler_ == address(0) || wbnb_ == address(0)
        ) revert ZeroAddress();
        quoteRegistry = QuoteRegistry(quoteRegistry_);
        dividendVault = DividendVault(dividendVault_);
        platformBucket = PlatformFeeBucket(platformBucket_);
        taxHandler = PostGradTaxHandler(taxHandler_);
        wbnb = wbnb_;
        pairFactory = pairFactory_;
    }

    function setMigrator(address migrator_) external onlyOwner {
        if (address(migrator) != address(0)) revert MigratorAlreadySet();
        if (migrator_ == address(0)) revert ZeroAddress();
        migrator = IMigratorS(migrator_);
        emit MigratorSet(migrator_);
    }

    function setPairFactory(address factory_) external onlyOwner {
        pairFactory = factory_;
        emit PairFactorySet(factory_);
    }

    function setAgentGate(bool enabled, address registry) external onlyOwner {
        agentGateEnabled = enabled;
        agentIdRegistry = IERC721(registry);
        emit AgentGateUpdated(enabled, registry);
    }

    /// @notice Owner marks BAW Dev wallets allowed to create (not any Agent).
    function setDev(address account, bool enabled) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        isDev[account] = enabled;
        emit DevUpdated(account, enabled);
    }

    function setWalletCapEnabled(bool enabled) external onlyOwner {
        walletCapEnabled = enabled;
        emit WalletCapUpdated(enabled);
    }

    function setDefaultGraduationQuoteAmount(uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        defaultGraduationQuoteAmount = amount;
        emit DefaultGraduationUpdated(amount);
    }

    // ---------------------------------------------------------------- create
    /// @param name Display name
    /// @param symbol Ticker
    /// @param logoURI Off-chain / indexer metadata (may be empty)
    /// @param taxed false = v4.1-like untaxed; true = holder-dividend tax path
    /// @param pairOrQuote taxed: Pancake pair CA **or** quote ERC20 (factory.getPair(quote,WBNB) must have reserves);
    ///                    untaxed: quote ERC20 (WBNB or other); address(0) → wbnb
    function create(
        string calldata name,
        string calldata symbol,
        string calldata logoURI,
        bool taxed,
        address pairOrQuote
    ) external returns (address token) {
        if (address(migrator) == address(0)) revert MigratorNotSet();
        _requireDev();

        address quote;
        address refPair;
        uint256 lockedGrad;
        if (taxed) {
            if (pairOrQuote == address(0)) revert TaxedRequiresPairOrQuote();
            if (pairFactory == address(0)) revert ZeroAddress();
            (quote, refPair) = PoolCheck.resolveQuoteIdentity(pairOrQuote, wbnb, pairFactory);
            lockedGrad = _lockGradAmt(quote, refPair);
            dividendVault.ensureMinimumShareBalance(TAXED_MIN_SHARE);
            token = address(new TaxLaunchToken(name, symbol));
            TaxLaunchToken(token).exclude(address(dividendVault), true);
            TaxLaunchToken(token).exclude(address(platformBucket), true);
            dividendVault.registerToken(token, quote);
        } else {
            quote = pairOrQuote == address(0) ? wbnb : pairOrQuote;
            if (quote == address(0)) revert UntaxedRequiresQuote();
            // Untaxed = LaunchToken (no transfer tax hooks). Non-WBNB quote still needs liquid quote/WBNB pair.
            if (quote == wbnb) {
                lockedGrad = TARGET_GRAD_BNB;
            } else {
                if (pairFactory == address(0)) revert ZeroAddress();
                (address qResolved, address pair) = PoolCheck.resolveQuoteIdentity(quote, wbnb, pairFactory);
                if (qResolved != quote) revert UntaxedRequiresQuote();
                refPair = pair;
                lockedGrad = _lockGradAmt(quote, pair);
            }
            token = address(new LaunchToken(name, symbol));
        }

        if (lockedGrad < MIN_GRAD_AMT) revert GradAmtTooSmall();
        _writeCurve(token, quote, lockedGrad, taxed, refPair);
        logoURIOf[token] = logoURI;
        allTokens.push(token);

        emit Created(token, msg.sender, name, symbol, logoURI, taxed, quote, refPair, lockedGrad);
    }

    // ---------------------------------------------------------------- buy
    struct BuyVars {
        uint256 taxDiv;
        uint256 taxPlat;
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
        Curve storage c = _live(token);
        if (quoteIn == 0) revert ZeroAmount();
        _requireAgent();

        BuyVars memory v = _prepBuy(c, token, quoteIn);
        tokensOut = v.tokensOut;
        if (tokensOut < minTokensOut) revert Slippage();

        tokensOut = _execBuy(c, token, quoteIn, minTokensOut, v);
    }

    function _prepBuy(Curve storage c, address token, uint256 quoteIn) internal view returns (BuyVars memory v) {
        uint256 room = walletRoom(token, msg.sender);
        if (walletCapEnabled && room == 0) revert WalletCapReached();

        v.feeBps = c.taxed ? (DIVIDEND_TAX_BPS + PLATFORM_TAX_BPS) : PROTOCOL_FEE_BPS;
        if (c.taxed) {
            v.taxDiv = (quoteIn * DIVIDEND_TAX_BPS) / BPS;
            v.taxPlat = (quoteIn * PLATFORM_TAX_BPS) / BPS;
        } else {
            v.taxDiv = 0;
            v.taxPlat = (quoteIn * PROTOCOL_FEE_BPS) / BPS;
        }
        v.net = quoteIn - v.taxDiv - v.taxPlat;
        v.gradAmt = c.gradAmt;
        uint256 remaining = v.gradAmt - c.realQuote;

        if (v.net > remaining) {
            v.net = remaining;
            _recomputeFee(quoteIn, c.taxed, v);
            if (v.net > remaining) v.net = remaining;
        }

        v.tokensOut = _tokensOut(c, v.net);
        if (walletCapEnabled && v.tokensOut > room) {
            v.tokensOut = room;
            v.net = _quoteInFor(c, room);
            _recomputeFee(quoteIn, c.taxed, v);
        }
    }

    function _recomputeFee(uint256 quoteIn, bool taxed, BuyVars memory v) internal pure {
        uint256 feeBps = taxed ? (DIVIDEND_TAX_BPS + PLATFORM_TAX_BPS) : PROTOCOL_FEE_BPS;
        uint256 spentGross = Math.ceilDiv(v.net * BPS, BPS - feeBps);
        if (spentGross > quoteIn) spentGross = quoteIn;
        if (taxed) {
            v.taxDiv = (spentGross * DIVIDEND_TAX_BPS) / BPS;
            v.taxPlat = (spentGross * PLATFORM_TAX_BPS) / BPS;
        } else {
            v.taxDiv = 0;
            v.taxPlat = (spentGross * PROTOCOL_FEE_BPS) / BPS;
        }
        v.net = spentGross - v.taxDiv - v.taxPlat;
        v.refundGross = quoteIn - spentGross;
    }

    /// @dev Finding 5: credit curve/taxes from measured received (FoT-safe). Reverts if FoT cuts below minTokensOut.
    function _execBuy(Curve storage c, address token, uint256 quoteIn, uint256 minTokensOut, BuyVars memory v)
        internal
        returns (uint256 tokensOut)
    {
        address quoteAddr = c.quote;
        v = _pullQuoteAndPrep(c, token, quoteAddr, quoteIn, minTokensOut, v);

        c.realQuote += v.net.toUint128();
        c.sold += v.tokensOut.toUint128();

        IERC20(token).safeTransfer(msg.sender, v.tokensOut);
        _syncShareAndTax(c, token, quoteAddr, v.taxDiv, v.taxPlat);

        emit Buy(token, msg.sender, v.net, v.taxDiv, v.taxPlat, v.tokensOut, c.realQuote);

        if (v.refundGross > 0) IERC20(quoteAddr).safeTransfer(msg.sender, v.refundGross);
        if (c.realQuote >= v.gradAmt) _graduate(token, c);
        tokensOut = v.tokensOut;
    }

    function _pullQuoteAndPrep(
        Curve storage c,
        address token,
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
        // FoT / deflationary quote: re-prep against actual received. Ops must not whitelist FoT quotes.
        if (received != quoteIn) {
            v = _prepBuy(c, token, received);
            if (v.tokensOut < minTokensOut) revert Slippage();
        }
        return v;
    }

    function _syncShareAndTax(Curve storage c, address token, address quoteAddr, uint256 taxDiv, uint256 taxPlat)
        internal
    {
        IERC20 quote = IERC20(quoteAddr);
        if (c.taxed) {
            dividendVault.setShare(token, msg.sender, IERC20(token).balanceOf(msg.sender));
            if (taxDiv > 0) {
                quote.forceApprove(address(dividendVault), taxDiv);
                dividendVault.depositReward(token, taxDiv);
            }
        }
        if (taxPlat > 0) {
            // 20% of platform slice lands in PlatformFeeBucket.feeVault on collect (Lazy-locked).
            quote.forceApprove(address(platformBucket), taxPlat);
            platformBucket.notifyAccrual(quoteAddr, taxPlat);
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
        _requireAgent();

        uint256 quoteOut = _quoteOut(c, tokensIn);
        uint256 taxDiv;
        uint256 taxPlat;
        if (c.taxed) {
            taxDiv = (quoteOut * DIVIDEND_TAX_BPS) / BPS;
            taxPlat = (quoteOut * PLATFORM_TAX_BPS) / BPS;
        } else {
            taxDiv = 0;
            taxPlat = (quoteOut * PROTOCOL_FEE_BPS) / BPS;
        }
        quoteToUser = quoteOut - taxDiv - taxPlat;
        if (quoteToUser < minQuoteOut) revert Slippage();

        c.realQuote -= quoteOut.toUint128();
        c.sold -= tokensIn.toUint128();

        IERC20(token).safeTransferFrom(msg.sender, address(this), tokensIn);

        address quoteAddr = c.quote;
        _syncShareAndTax(c, token, quoteAddr, taxDiv, taxPlat);
        IERC20(quoteAddr).safeTransfer(msg.sender, quoteToUser);

        emit Sell(token, msg.sender, tokensIn, taxDiv, taxPlat, quoteToUser, c.realQuote);
    }

    // ---------------------------------------------------------------- views
    function isAgent(address account) public view returns (bool) {
        if (!agentGateEnabled) return true;
        // Fail closed when gate ON but registry not bound yet (Lazy #5 default true).
        if (address(agentIdRegistry) == address(0)) return false;
        return agentIdRegistry.balanceOf(account) > 0;
    }

    function _requireAgent() internal view {
        if (agentGateEnabled && !isAgent(msg.sender)) revert NotAgent();
    }

    function _requireDev() internal view {
        if (!isDev[msg.sender]) revert NotDev();
    }

    function walletRoom(address token, address buyer) public view returns (uint256) {
        if (!walletCapEnabled) return type(uint256).max;
        uint256 bal = IERC20(token).balanceOf(buyer);
        return bal >= MAX_PER_WALLET ? 0 : MAX_PER_WALLET - bal;
    }

    function tokenCount() external view returns (uint256) {
        return allTokens.length;
    }

    /// @notice Locked graduation quote amount for a token (0 if unknown).
    function gradAmtOf(address token) external view returns (uint256) {
        return curves[token].gradAmt;
    }

    /// @notice Per-curve virtual quote reserve (= gradAmt / 3 at create). 0 if unknown.
    function virtualQuoteOf(address token) external view returns (uint256) {
        return curves[token].virtualQuote;
    }

    /// @notice Quote still needed to graduate (`gradAmt - realQuote`); 0 if unknown/graduated.
    function graduationRemaining(address token) external view returns (uint256) {
        Curve storage c = curves[token];
        if (c.creator == address(0) || c.graduated) return 0;
        if (c.realQuote >= c.gradAmt) return 0;
        return uint256(c.gradAmt) - uint256(c.realQuote);
    }

    /// @dev Spot preview for a quote at *current* reserves (create will lock this). quote==WBNB → 15e18.
    function graduationAmountOf(address quote) external view returns (uint256) {
        return _previewGradAmt(quote);
    }

    // ---------------------------------------------------------------- internal
    function _lockGradAmt(address quote, address pair) internal view returns (uint256) {
        if (quote == wbnb) return TARGET_GRAD_BNB;
        // OPT5: QuoteRegistry.graduationQuoteAmount > 0 is ops override (bStock etc.); else PoolCheck V2 spot.
        uint256 ov = quoteRegistry.graduationAmount(quote);
        if (ov > 0) return ov;
        if (pair == address(0)) revert PoolCheck.PairEmpty();
        return PoolCheck.spotGradAmt(pair, wbnb, TARGET_GRAD_BNB, MIN_RESERVE_WBNB);
    }

    function _previewGradAmt(address quote) internal view returns (uint256) {
        if (quote == address(0) || quote == wbnb) return TARGET_GRAD_BNB;
        uint256 ov = quoteRegistry.graduationAmount(quote);
        if (ov > 0) return ov;
        if (pairFactory == address(0)) return defaultGraduationQuoteAmount;
        address pair = IPairFactoryS(pairFactory).getPair(quote, wbnb);
        if (pair == address(0) || !PoolCheck.hasReserves(pair)) return defaultGraduationQuoteAmount;
        return PoolCheck.spotGradAmt(pair, wbnb, TARGET_GRAD_BNB, MIN_RESERVE_WBNB);
    }

    function _graduate(address token, Curve storage c) internal {
        c.graduated = true;
        uint256 tokenAmount = TOTAL_SUPPLY - c.sold;
        uint256 quoteAmount = c.realQuote;
        address quote = c.quote;
        c.realQuote = 0;

        if (c.taxed) {
            TaxLaunchToken(token).unlock();
            TaxLaunchToken(token).exclude(address(migrator), true);
            // H2 (2026-10-23): the handler is wired only AFTER the pair exists and `setPair` ran. While
            // `taxHandler == 0` the token does not sync dividend shares, so neither the migrator nor the
            // Pancake pair can ever be written into DividendVault during the migration transfers.
            IERC20(token).safeTransfer(address(migrator), tokenAmount);
            IERC20(quote).safeTransfer(address(migrator), quoteAmount);
            address pair = migrator.migrate(token, quote, tokenAmount, quoteAmount);
            c.pair = pair;
            // Pair NOT excluded — outer 1% applies to pair buys/sells.
            TaxLaunchToken(token).setPair(pair);
            TaxLaunchToken(token).exclude(address(taxHandler), true);
            TaxLaunchToken(token).setTaxHandler(address(taxHandler));
        } else {
            LaunchToken(token).unlock();
            IERC20(token).safeTransfer(address(migrator), tokenAmount);
            IERC20(quote).safeTransfer(address(migrator), quoteAmount);
            address pair = migrator.migrate(token, quote, tokenAmount, quoteAmount);
            c.pair = pair;
            // v4.1: graduation 0 transfer tax — LaunchToken has no tax hooks.
        }
        emit Graduated(token, c.pair, quote, tokenAmount, quoteAmount);
    }

    /// @dev Stores Curve with virtualQuote = floor(lockedGrad / 3). Separate frame avoids stack-too-deep in create.
    function _writeCurve(address token, address quote, uint256 lockedGrad, bool taxed, address refPair) internal {
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
            taxed: taxed,
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
