// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {TaxLaunchToken} from "./TaxLaunchToken.sol";
import {QuoteRegistry} from "./QuoteRegistry.sol";
import {DividendVault} from "./DividendVault.sol";
import {PlatformFeeBucket} from "./PlatformFeeBucket.sol";
import {IMigratorS} from "./interfaces/IMigratorS.sol";

/// @title LaunchpadS (Stocks track)
/// @notice ERC20-quote bonding curve. 1% tax = 0.5% DividendVault + 0.5% PlatformFeeBucket.
/// @dev Parallel to main Launchpad; NEVER writes main accruedFees. Test params use tiny graduation.
contract LaunchpadS is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 public constant CURVE_SUPPLY = 800_000_000 ether;
    /// @dev Scaled for ~1e18 graduation (test). Mainnet would re-calibrate.
    uint256 public constant VIRTUAL_QUOTE = 333_333_333_333_333_333; // ~1/3 of 1e18
    uint256 public constant VIRTUAL_TOKEN = 1_066_666_666_666_666_666_666_666_667;
    uint256 public constant K = VIRTUAL_QUOTE * VIRTUAL_TOKEN;
    uint256 public constant MAX_PER_WALLET = 10_000_000 ether; // 1%; tests may disable via flag
    uint256 public constant DIVIDEND_TAX_BPS = 50; // 0.5%
    uint256 public constant PLATFORM_TAX_BPS = 50; // 0.5%
    uint256 public constant BPS = 10_000;

    struct Curve {
        address creator;
        address quote;
        uint128 realQuote;
        uint128 sold;
        bool graduated;
        address pair;
    }

    QuoteRegistry public immutable quoteRegistry;
    DividendVault public immutable dividendVault;
    PlatformFeeBucket public immutable platformBucket;
    IMigratorS public migrator;

    /// @notice Optional Agent ID registry. address(0) or agentGateEnabled=false → skip gate (tests).
    IERC721 public agentIdRegistry;
    bool public agentGateEnabled;
    bool public walletCapEnabled = true;

    mapping(address token => Curve) public curves;
    address[] public allTokens;

    event Created(address indexed token, address indexed creator, string name, string symbol, address indexed quote);
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
    event AgentGateUpdated(bool enabled, address registry);
    event WalletCapUpdated(bool enabled);

    error UnknownToken();
    error AlreadyGraduated();
    error ZeroAmount();
    error Slippage();
    error MigratorNotSet();
    error MigratorAlreadySet();
    error ZeroAddress();
    error QuoteNotAllowed();
    error NotAgent();
    error WalletCapReached();

    constructor(
        address owner_,
        address quoteRegistry_,
        address dividendVault_,
        address platformBucket_
    ) Ownable(owner_) {
        if (
            quoteRegistry_ == address(0) || dividendVault_ == address(0) || platformBucket_ == address(0)
        ) revert ZeroAddress();
        quoteRegistry = QuoteRegistry(quoteRegistry_);
        dividendVault = DividendVault(dividendVault_);
        platformBucket = PlatformFeeBucket(platformBucket_);
    }

    function setMigrator(address migrator_) external onlyOwner {
        if (address(migrator) != address(0)) revert MigratorAlreadySet();
        if (migrator_ == address(0)) revert ZeroAddress();
        migrator = IMigratorS(migrator_);
        emit MigratorSet(migrator_);
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

    // ---------------------------------------------------------------- create
    function create(string calldata name, string calldata symbol, address quoteToken)
        external
        returns (address token)
    {
        if (address(migrator) == address(0)) revert MigratorNotSet();
        if (!quoteRegistry.isQuoted(quoteToken)) revert QuoteNotAllowed();

        token = address(new TaxLaunchToken(name, symbol));
        curves[token] = Curve({
            creator: msg.sender,
            quote: quoteToken,
            realQuote: 0,
            sold: 0,
            graduated: false,
            pair: address(0)
        });
        allTokens.push(token);

        TaxLaunchToken(token).exclude(address(dividendVault), true);
        TaxLaunchToken(token).exclude(address(platformBucket), true);
        dividendVault.registerToken(token, quoteToken);

        emit Created(token, msg.sender, name, symbol, quoteToken);
    }

    // ---------------------------------------------------------------- buy
    struct BuyVars {
        uint256 taxDiv;
        uint256 taxPlat;
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

        v.taxDiv = (quoteIn * DIVIDEND_TAX_BPS) / BPS;
        v.taxPlat = (quoteIn * PLATFORM_TAX_BPS) / BPS;
        v.net = quoteIn - v.taxDiv - v.taxPlat;
        v.gradAmt = quoteRegistry.graduationAmount(c.quote);
        uint256 remaining = v.gradAmt - c.realQuote;

        if (v.net > remaining) {
            v.net = remaining;
            _recomputeTax(quoteIn, v);
            if (v.net > remaining) v.net = remaining;
        }

        v.tokensOut = _tokensOut(c, v.net);
        if (walletCapEnabled && v.tokensOut > room) {
            v.tokensOut = room;
            v.net = _quoteInFor(c, room);
            _recomputeTax(quoteIn, v);
        }
    }

    function _recomputeTax(uint256 quoteIn, BuyVars memory v) internal pure {
        uint256 spentGross = Math.ceilDiv(v.net * BPS, BPS - DIVIDEND_TAX_BPS - PLATFORM_TAX_BPS);
        if (spentGross > quoteIn) spentGross = quoteIn;
        v.taxDiv = (spentGross * DIVIDEND_TAX_BPS) / BPS;
        v.taxPlat = (spentGross * PLATFORM_TAX_BPS) / BPS;
        v.net = spentGross - v.taxDiv - v.taxPlat;
        v.refundGross = quoteIn - spentGross;
    }

    function _execBuy(Curve storage c, address token, uint256 quoteIn, BuyVars memory v) internal {
        address quoteAddr = c.quote;
        IERC20 quote = IERC20(quoteAddr);
        // Pull full gross; refund unused after tax + curve fill.
        quote.safeTransferFrom(msg.sender, address(this), quoteIn);

        c.realQuote += v.net.toUint128();
        c.sold += v.tokensOut.toUint128();

        IERC20(token).safeTransfer(msg.sender, v.tokensOut);
        _syncShareAndTax(token, quoteAddr, v.taxDiv, v.taxPlat);

        emit Buy(token, msg.sender, v.net, v.taxDiv, v.taxPlat, v.tokensOut, c.realQuote);

        if (v.refundGross > 0) quote.safeTransfer(msg.sender, v.refundGross);
        if (c.realQuote >= v.gradAmt) _graduate(token, c);
    }

    function _syncShareAndTax(address token, address quoteAddr, uint256 taxDiv, uint256 taxPlat) internal {
        dividendVault.setShare(token, msg.sender, IERC20(token).balanceOf(msg.sender));
        IERC20 quote = IERC20(quoteAddr);
        if (taxDiv > 0) {
            quote.forceApprove(address(dividendVault), taxDiv);
            dividendVault.depositReward(token, taxDiv);
        }
        if (taxPlat > 0) {
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
        uint256 taxDiv = (quoteOut * DIVIDEND_TAX_BPS) / BPS;
        uint256 taxPlat = (quoteOut * PLATFORM_TAX_BPS) / BPS;
        quoteToUser = quoteOut - taxDiv - taxPlat;
        if (quoteToUser < minQuoteOut) revert Slippage();

        c.realQuote -= quoteOut.toUint128();
        c.sold -= tokensIn.toUint128();

        IERC20(token).safeTransferFrom(msg.sender, address(this), tokensIn);

        address quoteAddr = c.quote;
        _syncShareAndTax(token, quoteAddr, taxDiv, taxPlat);
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

    // ---------------------------------------------------------------- internal curve
    function _graduate(address token, Curve storage c) internal {
        c.graduated = true;
        uint256 tokenAmount = TOTAL_SUPPLY - c.sold;
        uint256 quoteAmount = c.realQuote;
        address quote = c.quote;
        c.realQuote = 0;

        TaxLaunchToken(token).unlock();
        IERC20(token).safeTransfer(address(migrator), tokenAmount);
        IERC20(quote).safeTransfer(address(migrator), quoteAmount);
        address pair = migrator.migrate(token, quote, tokenAmount, quoteAmount);
        c.pair = pair;
        TaxLaunchToken(token).setPair(pair);
        emit Graduated(token, pair, quote, tokenAmount, quoteAmount);
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
