// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PlatformFeeBucket} from "../launchpad-v2/PlatformFeeBucket.sol";
import {PostGradHandlerBase} from "../common/PostGradHandlerBase.sol";
import {IPostGradTaxHandlerV3} from "./interfaces/IPostGradTaxHandlerV3.sol";
import {ITaxHandlerV3, V3_PLATFORM_TAX_BPS} from "./interfaces/ITaxHandlerV3.sol";
import {TaxLaunchTokenV3} from "./TaxLaunchTokenV3.sol";

/// @title TaxHandlerV3 (LaunchpadV3 · everything about the tax)
/// @notice The tax recipients the platform allows, each token's route (quote, recipient, dividend share), the split of
///         every tax payment, and the pool tax after graduation:
///         - Bonding: LaunchpadV3 hands each curve trade's tax over (`distribute`).
///         - Post-grad: the token's transfer hook accrues the tax in tokens (`notifyTax`), the keeper sells it
///           (`process`) and the quote is split the same way.
///         Split: the platform's part (0.5% of the trade's volume, counted per trade since buys and sells may be taxed
///         at different rates) → `dividendBps` of the rest to DividendVault → the remainder to the recipient, in quote.
/// @dev Must be a DividendVault operator and a PlatformFeeBucket operator.
///      Never reverts because of the recipient: the push is a low-level transfer; a failed one is booked as `owedOf`
///      (held here, never sold by `process`) and anyone can `release` it later. Every payment that reaches the
///      recipient emits `TaxPaid`. A dividend leg with zero total shares would strand funds in DividendVault →
///      recipient, else platform. H2: the DEX pair never holds dividend shares.
contract TaxHandlerV3 is ITaxHandlerV3, IPostGradTaxHandlerV3, PostGradHandlerBase {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant PLATFORM_TAX_BPS = V3_PLATFORM_TAX_BPS;

    struct Route {
        address quote;
        address recipient;
        uint16 dividendBps;
    }

    struct Entry {
        bool listed;
        uint64 listedAt;
        string label;
    }

    PlatformFeeBucket public immutable platformBucket;

    address public launchpad;
    mapping(address token => Route) public routeOf;
    /// @notice Quote owed to `token`'s recipient after a failed push.
    mapping(address token => uint256) public owedOf;
    /// @notice Σ owedOf per quote: held here for recipients, so `process` never sells it (a quote can itself be a
    ///         token this handler taxes).
    mapping(address quote => uint256) public owedTotalOf;
    /// @notice Part of `accruedTax` that is the platform's (tokens).
    mapping(address => uint256) public accruedPlatformTax;
    /// @notice Tax recipients the platform allows. Delisting only stops new tokens from choosing one: tokens already
    ///         created keep paying it.
    mapping(address recipient => Entry) public entries;
    address[] internal _all;

    event LaunchpadSet(address indexed launchpad);
    event Listed(address indexed recipient, string label);
    event Delisted(address indexed recipient);
    event RouteRegistered(address indexed token, address quote, address indexed recipient, uint16 dividendBps);
    event TaxDistributed(
        address indexed token, Phase phase, uint256 amount, uint256 toPlatform, uint256 toDividend, uint256 toRecipient
    );
    /// @notice Quote that reached the recipient (a direct push, or a `release` of what was owed).
    event TaxPaid(address indexed token, address indexed recipient, address indexed quote, uint256 amount);
    /// @notice A push that failed; `release(token)` sends it.
    event TaxOwed(address indexed token, address indexed recipient, address indexed quote, uint256 amount);
    event OuterTaxProcessed(
        address indexed token, address indexed quote, uint256 taxTokens, uint256 quoteOut, uint256 platformQuote
    );

    error LaunchpadAlreadySet();
    error OnlyLaunchpad();
    error OnlySource();
    error AlreadyRegistered();
    error UnknownToken();
    error BadDividendBps();
    error BadPlatformAmount();
    error NothingOwed();
    error AlreadyListed();
    error NotListed();

    constructor(address owner_, address dividendVault_, address platformBucket_)
        PostGradHandlerBase(owner_, dividendVault_)
    {
        if (platformBucket_ == address(0)) revert ZeroAddress();
        platformBucket = PlatformFeeBucket(platformBucket_);
    }

    // ---------------------------------------------------------------- admin
    /// @notice One-shot: the LaunchpadV3 that registers routes and pays in the bonding tax.
    function setLaunchpad(address launchpad_) external onlyOwner {
        if (launchpad_ == address(0)) revert ZeroAddress();
        if (launchpad != address(0)) revert LaunchpadAlreadySet();
        launchpad = launchpad_;
        emit LaunchpadSet(launchpad_);
    }

    /// @param label who it is, for the UI (e.g. "Acme treasury")
    function list(address recipient, string calldata label) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        Entry storage e = entries[recipient];
        if (e.listed) revert AlreadyListed();
        if (e.listedAt == 0) _all.push(recipient);
        e.listed = true;
        e.listedAt = uint64(block.timestamp);
        e.label = label;
        emit Listed(recipient, label);
    }

    function delist(address recipient) external onlyOwner {
        if (!entries[recipient].listed) revert NotListed();
        entries[recipient].listed = false;
        emit Delisted(recipient);
    }

    /// @inheritdoc ITaxHandlerV3
    function isListed(address recipient) external view returns (bool) {
        return entries[recipient].listed;
    }

    /// @notice Every address ever listed (delisted ones included; check `isListed`).
    function recipients() external view returns (address[] memory) {
        return _all;
    }

    // ---------------------------------------------------------------- launchpad
    /// @inheritdoc ITaxHandlerV3
    function register(address token, address quote, address recipient, uint16 dividendBps) external {
        if (msg.sender != launchpad) revert OnlyLaunchpad();
        if (token == address(0) || quote == address(0)) revert ZeroAddress();
        if (routeOf[token].quote != address(0)) revert AlreadyRegistered();
        if (dividendBps > BPS || (recipient == address(0) && dividendBps != BPS)) revert BadDividendBps();
        routeOf[token] = Route({quote: quote, recipient: recipient, dividendBps: dividendBps});
        emit RouteRegistered(token, quote, recipient, dividendBps);
    }

    /// @inheritdoc ITaxHandlerV3
    function distribute(address token, uint256 amount, uint256 platformAmount, Phase phase) external nonReentrant {
        if (msg.sender != launchpad) revert OnlySource();
        Route memory r = routeOf[token];
        if (r.quote == address(0)) revert UnknownToken();
        if (platformAmount > amount) revert BadPlatformAmount();
        if (amount == 0) return;

        IERC20 quote = IERC20(r.quote);
        uint256 beforeBal = quote.balanceOf(address(this));
        quote.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = quote.balanceOf(address(this)) - beforeBal;
        // fee-on-transfer quote: every leg shrinks in proportion
        if (received != amount) platformAmount = (platformAmount * received) / amount;

        _payOut(token, r, received, platformAmount, phase);
    }

    /// @inheritdoc ITaxHandlerV3
    /// @dev Reverts while the recipient still cannot receive, so nothing owed is ever lost.
    function release(address token) external nonReentrant returns (uint256 amount) {
        amount = owedOf[token];
        if (amount == 0) revert NothingOwed();
        Route memory r = routeOf[token];
        owedOf[token] = 0;
        owedTotalOf[r.quote] -= amount;
        IERC20(r.quote).safeTransfer(r.recipient, amount);
        emit TaxPaid(token, r.recipient, r.quote, amount);
    }

    /// @inheritdoc ITaxHandlerV3
    function previewSplit(address token, uint256 amount, uint256 platformAmount)
        external
        view
        returns (uint256 toPlatform, uint256 toDividend, uint256 toRecipient)
    {
        Route memory r = routeOf[token];
        if (r.quote == address(0)) revert UnknownToken();
        if (platformAmount > amount) revert BadPlatformAmount();
        return _split(token, r, amount, platformAmount);
    }

    // ---------------------------------------------------------------- token hooks
    /// @inheritdoc IPostGradTaxHandlerV3
    function notifyTax(address token, address from, address to, uint256 taxAmount, uint16 rateBps)
        external
        nonReentrant
    {
        _checkHook(token, taxAmount);
        // only tokens the launchpad registered (write-once route; their rates were checked to 1%–5% at create): anyone
        // can deploy a TaxLaunchTokenV3 pointing at this handler, and it must not accrue here
        if (routeOf[token].quote == address(0)) revert UnknownToken();
        // the token taxed this trade at `rateBps` (its buy or sell tax): the platform's 0.5% of volume is that share,
        // never more than the tax itself
        if (rateBps > 0) {
            uint256 platform = (taxAmount * PLATFORM_TAX_BPS) / rateBps;
            accruedPlatformTax[token] += platform > taxAmount ? taxAmount : platform;
        }
        _accrue(token, from, to, taxAmount);
    }

    /// @inheritdoc IPostGradTaxHandlerV3
    /// @dev Permissionless and never reverts for unknown tokens (runs inside token transfers).
    function syncShares(address token, address from, address to) external {
        if (dividendVault.quoteOf(token) == address(0)) return;
        _syncShare(token, from);
        _syncShare(token, to);
    }

    /// @inheritdoc IPostGradTaxHandlerV3
    function process(address token, uint256 minQuoteOut) external nonReentrant returns (uint256 quoteOut) {
        return _process(token, minQuoteOut);
    }

    // ---------------------------------------------------------------- internal
    function _quoteOf(address token) internal view override returns (address quote) {
        quote = routeOf[token].quote;
        if (quote == address(0)) revert UnknownToken();
    }

    function _sellable(address token) internal view override returns (uint256) {
        return IERC20(token).balanceOf(address(this)) - owedTotalOf[token];
    }

    /// @dev The platform's part of what is sold, scaled down with it when the balance fell short.
    function _takeAccrued(address token, uint256 amount, uint256 accrued)
        internal
        override
        returns (uint256 platformTokens)
    {
        platformTokens = accruedPlatformTax[token];
        if (amount < accrued) platformTokens = (platformTokens * amount) / accrued;
        accruedPlatformTax[token] = 0;
    }

    function _onProceeds(address token, address quote, uint256 amount, uint256 quoteOut, uint256 platformTokens)
        internal
        override
    {
        uint256 platformQuote = (quoteOut * platformTokens) / amount;
        if (quoteOut > 0) _payOut(token, routeOf[token], quoteOut, platformQuote, Phase.PostGrad);
        emit OuterTaxProcessed(token, quote, amount, quoteOut, platformQuote);
    }

    /// @dev `amount` of the route's quote is held here: split it and send each leg.
    function _payOut(address token, Route memory r, uint256 amount, uint256 platformAmount, Phase phase) internal {
        (uint256 toPlatform, uint256 toDividend, uint256 toRecipient) = _split(token, r, amount, platformAmount);
        IERC20 quote = IERC20(r.quote);
        if (toPlatform > 0) {
            quote.forceApprove(address(platformBucket), toPlatform);
            platformBucket.notifyAccrual(r.quote, toPlatform);
        }
        if (toDividend > 0) {
            quote.forceApprove(address(dividendVault), toDividend);
            dividendVault.depositReward(token, toDividend);
        }
        if (toRecipient > 0) {
            if (_tryTransfer(r.quote, r.recipient, toRecipient)) {
                emit TaxPaid(token, r.recipient, r.quote, toRecipient);
            } else {
                owedOf[token] += toRecipient;
                owedTotalOf[r.quote] += toRecipient;
                emit TaxOwed(token, r.recipient, r.quote, toRecipient);
            }
        }
        emit TaxDistributed(token, phase, amount, toPlatform, toDividend, toRecipient);
    }

    function _split(address token, Route memory r, uint256 amount, uint256 platformAmount)
        internal
        view
        returns (uint256 toPlatform, uint256 toDividend, uint256 toRecipient)
    {
        toPlatform = platformAmount;
        uint256 rest = amount - platformAmount;
        toDividend = (rest * r.dividendBps) / BPS;
        toRecipient = rest - toDividend;

        if (toDividend > 0 && dividendVault.totalShares(token) == 0) {
            if (r.recipient != address(0)) toRecipient += toDividend;
            else toPlatform += toDividend;
            toDividend = 0;
        }
    }

    function _syncShare(address token, address user) internal {
        if (user == address(0)) return;
        if (user == address(this)) return;
        address pair = TaxLaunchTokenV3(token).pair();
        if (user == pair) {
            if (dividendVault.shares(token, user) != 0) dividendVault.setShare(token, user, 0);
            return;
        }
        // Audit G-01: setExcluded does not clear shares, so an excluded holder is written to 0 here instead of being
        // skipped (skipping left its old share earning forever)
        if (dividendVault.excluded(user)) {
            if (dividendVault.shares(token, user) != 0) dividendVault.setShare(token, user, 0);
            return;
        }
        dividendVault.setShare(token, user, IERC20(token).balanceOf(user));
    }

    /// @dev OZ 5.1 has no trySafeTransfer. Accepts tokens that return nothing (USDT-style) or `true`.
    function _tryTransfer(address quote, address to, uint256 amount) internal returns (bool) {
        (bool ok, bytes memory ret) = quote.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!ok) return false;
        if (ret.length == 0) return quote.code.length > 0;
        return ret.length >= 32 && abi.decode(ret, (bool));
    }
}
