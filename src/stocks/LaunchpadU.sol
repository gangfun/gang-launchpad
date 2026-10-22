// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
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
import {IMigratorS} from "./interfaces/IMigratorS.sol";
import {PoolCheck} from "./PoolCheck.sol";

/// @title LaunchpadU (Tip A · any-pool + normal/taxed)
/// @notice Unified create: `taxed=false` ≈ Gang v4.1 (1% protocol → PlatformFeeBucket 80/20 feeVault;
///         graduation 0 transfer tax). `taxed=true` = 1% in-curve (50 bps DividendVault + 50 bps platform);
///         holders need ≥10000e18; platform 20% slice → **platform feeVault** (Lazy-locked).
/// @dev Test / Chapel only. Does NOT touch main Launchpad. Post-grad DEX tax = Tip B (still stub on TaxLaunchToken).
contract LaunchpadU is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 public constant CURVE_SUPPLY = 800_000_000 ether;
    /// @dev Tiny graduation scale for forge / Chapel PoC (same as LaunchpadS).
    uint256 public constant VIRTUAL_QUOTE = 333_333_333_333_333_333;
    uint256 public constant VIRTUAL_TOKEN = 1_066_666_666_666_666_666_666_666_667;
    uint256 public constant K = VIRTUAL_QUOTE * VIRTUAL_TOKEN;
    uint256 public constant MAX_PER_WALLET = 10_000_000 ether;
    uint256 public constant BPS = 10_000;

    /// @dev v4.1-style protocol fee on untaxed path (all → platform bucket → 80/20).
    uint256 public constant PROTOCOL_FEE_BPS = 100;
    /// @dev Taxed path: 0.5% holders + 0.5% platform (= 1% total).
    uint256 public constant DIVIDEND_TAX_BPS = 50;
    uint256 public constant PLATFORM_TAX_BPS = 50;
    /// @dev Lazy-locked holder gate for taxed tokens.
    uint256 public constant TAXED_MIN_SHARE = 10_000 ether;

    struct Curve {
        address creator;
        address quote;
        uint128 realQuote;
        uint128 sold;
        bool graduated;
        bool taxed;
        address pair; // post-grad pair
        address refPair; // create-time liquidity pair (taxed only)
    }

    QuoteRegistry public immutable quoteRegistry; // optional accelerator; not a hard gate for taxed
    DividendVault public immutable dividendVault;
    PlatformFeeBucket public immutable platformBucket;
    address public immutable wbnb;
    address public pairFactory; // Pancake-like factory for getPair
    IMigratorS public migrator;

    IERC721 public agentIdRegistry;
    bool public agentGateEnabled;
    bool public walletCapEnabled = true;
    /// @dev Used when quote is not in QuoteRegistry (any-pool / untaxed default).
    uint256 public defaultGraduationQuoteAmount = 1 ether;

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
        address refPair
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
    event Graduated(address indexed token, address indexed pair, address quote, uint256 tokenAmount, uint256 quoteAmount);
    event MigratorSet(address indexed migrator);
    event PairFactorySet(address indexed factory);
    event AgentGateUpdated(bool enabled, address registry);
    event WalletCapUpdated(bool enabled);
    event DefaultGraduationUpdated(uint256 amount);

    error UnknownToken();
    error AlreadyGraduated();
    error ZeroAmount();
    error Slippage();
    error MigratorNotSet();
    error MigratorAlreadySet();
    error ZeroAddress();
    error NotAgent();
    error WalletCapReached();
    error TaxedRequiresPairOrQuote();
    error UntaxedRequiresQuote();

    constructor(
        address owner_,
        address quoteRegistry_,
        address dividendVault_,
        address platformBucket_,
        address wbnb_,
        address pairFactory_
    ) Ownable(owner_) {
        if (
            quoteRegistry_ == address(0) || dividendVault_ == address(0) || platformBucket_ == address(0)
                || wbnb_ == address(0)
        ) revert ZeroAddress();
        quoteRegistry = QuoteRegistry(quoteRegistry_);
        dividendVault = DividendVault(dividendVault_);
        platformBucket = PlatformFeeBucket(platformBucket_);
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

        address quote;
        address refPair;
        if (taxed) {
            if (pairOrQuote == address(0)) revert TaxedRequiresPairOrQuote();
            if (pairFactory == address(0)) revert ZeroAddress();
            (quote, refPair) = PoolCheck.resolveQuoteAndPair(pairOrQuote, wbnb, pairFactory);
            dividendVault.ensureMinimumShareBalance(TAXED_MIN_SHARE);
            token = address(new TaxLaunchToken(name, symbol));
            TaxLaunchToken(token).exclude(address(dividendVault), true);
            TaxLaunchToken(token).exclude(address(platformBucket), true);
            dividendVault.registerToken(token, quote);
        } else {
            quote = pairOrQuote == address(0) ? wbnb : pairOrQuote;
            if (quote == address(0)) revert UntaxedRequiresQuote();
            // Untaxed = LaunchToken (no transfer tax hooks); registry optional, not required.
            token = address(new LaunchToken(name, symbol));
        }

        curves[token] = Curve({
            creator: msg.sender,
            quote: quote,
            realQuote: 0,
            sold: 0,
            graduated: false,
            taxed: taxed,
            pair: address(0),
            refPair: refPair
        });
        logoURIOf[token] = logoURI;
        allTokens.push(token);

        emit Created(token, msg.sender, name, symbol, logoURI, taxed, quote, refPair);
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
        if (agentGateEnabled && !isAgent(msg.sender)) revert NotAgent();

        BuyVars memory v = _prepBuy(c, token, quoteIn);
        tokensOut = v.tokensOut;
        if (tokensOut < minTokensOut) revert Slippage();

        _execBuy(c, token, quoteIn, v);
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
        v.gradAmt = _graduationAmount(c.quote);
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

    function _execBuy(Curve storage c, address token, uint256 quoteIn, BuyVars memory v) internal {
        address quoteAddr = c.quote;
        IERC20 quote = IERC20(quoteAddr);
        quote.safeTransferFrom(msg.sender, address(this), quoteIn);

        c.realQuote += v.net.toUint128();
        c.sold += v.tokensOut.toUint128();

        IERC20(token).safeTransfer(msg.sender, v.tokensOut);
        _syncShareAndTax(c, token, quoteAddr, v.taxDiv, v.taxPlat);

        emit Buy(token, msg.sender, v.net, v.taxDiv, v.taxPlat, v.tokensOut, c.realQuote);

        if (v.refundGross > 0) quote.safeTransfer(msg.sender, v.refundGross);
        if (c.realQuote >= v.gradAmt) _graduate(token, c);
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
        if (!agentGateEnabled || address(agentIdRegistry) == address(0)) return true;
        return agentIdRegistry.balanceOf(account) > 0;
    }

    function walletRoom(address token, address buyer) public view returns (uint256) {
        if (!walletCapEnabled) return type(uint256).max;
        uint256 bal = IERC20(token).balanceOf(buyer);
        return bal >= MAX_PER_WALLET ? 0 : MAX_PER_WALLET - bal;
    }

    function tokenCount() external view returns (uint256) {
        return allTokens.length;
    }

    function graduationAmountOf(address quote) external view returns (uint256) {
        return _graduationAmount(quote);
    }

    // ---------------------------------------------------------------- internal
    function _graduationAmount(address quote) internal view returns (uint256) {
        if (quoteRegistry.isQuoted(quote)) {
            uint256 g = quoteRegistry.graduationAmount(quote);
            if (g > 0) return g;
        }
        return defaultGraduationQuoteAmount;
    }

    function _graduate(address token, Curve storage c) internal {
        c.graduated = true;
        uint256 tokenAmount = TOTAL_SUPPLY - c.sold;
        uint256 quoteAmount = c.realQuote;
        address quote = c.quote;
        c.realQuote = 0;

        if (c.taxed) {
            TaxLaunchToken(token).unlock();
            IERC20(token).safeTransfer(address(migrator), tokenAmount);
            IERC20(quote).safeTransfer(address(migrator), quoteAmount);
            address pair = migrator.migrate(token, quote, tokenAmount, quoteAmount);
            c.pair = pair;
            TaxLaunchToken(token).setPair(pair);
            // Tip B: wire post-grad 1% DEX tax. TaxLaunchToken transfer tax still stubbed.
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

    function _tokensOut(Curve storage c, uint256 quoteIn) internal view returns (uint256) {
        uint256 qReserve = VIRTUAL_QUOTE + c.realQuote;
        uint256 tReserve = VIRTUAL_TOKEN - c.sold;
        uint256 newT = Math.ceilDiv(K, qReserve + quoteIn);
        return tReserve - newT;
    }

    function _quoteInFor(Curve storage c, uint256 tokensOut) internal view returns (uint256) {
        uint256 qReserve = VIRTUAL_QUOTE + c.realQuote;
        uint256 tReserve = VIRTUAL_TOKEN - c.sold;
        return Math.ceilDiv(K, tReserve - tokensOut) - qReserve;
    }

    function _quoteOut(Curve storage c, uint256 tokensIn) internal view returns (uint256) {
        uint256 qReserve = VIRTUAL_QUOTE + c.realQuote;
        uint256 tReserve = VIRTUAL_TOKEN - c.sold;
        uint256 newQ = Math.ceilDiv(K, tReserve + tokensIn);
        return qReserve - newQ;
    }

    function _live(address token) internal view returns (Curve storage c) {
        c = curves[token];
        if (c.creator == address(0)) revert UnknownToken();
        if (c.graduated) revert AlreadyGraduated();
    }
}
