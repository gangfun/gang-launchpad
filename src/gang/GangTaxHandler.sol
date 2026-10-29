// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SharedPlatformFeeBucket as PlatformFeeBucket} from "../common/SharedPlatformFeeBucket.sol";
import {PostGradHandlerBase} from "../common/PostGradHandlerBase.sol";
import {IGangTaxHandler, V3_PLATFORM_TAX_BPS} from "./interfaces/IGangTaxHandler.sol";
import {IGangPadView} from "./interfaces/IGangPadView.sol";

/// @dev What the handler reads from the tokens it serves.
interface IGangTaxedToken {
    function pair() external view returns (address);
    function locked() external view returns (bool);
    function sellTaxBps() external view returns (uint16);
}

/// @title GangTaxHandler (pool tax after graduation / launch · Curve (V3) and Fair (打新) tokens)
/// @notice One handler for both kinds of launchpad token. A Fair token is modelled as a special route: platform part
///         0, `dividendBps` 5000, no recipient (so the rest is the platform's). Only three things depend on the kind:
///         - the platform's part at tax time: Curve 0.5% of the trade's volume (out of the tax), Fair 0;
///         - the share rule: Curve = balance (pair / excluded → 0); Fair = min(balance, launch baseline), out for good
///           below the hold line (`isOut`);
///         - which `OuterTaxProcessed` is emitted (Curve: 5 fields + `TaxDistributed`; Fair: 6 fields).
///         The tax is accrued in tokens (`notifyTax`); the holders' part is credited to holders right then (tax-time
///         units in the shared dividend vault). It is sold in small chunks — one before every sell into the pair
///         (`swapBack`), or by the keeper when no sells come (`process`) — and each chunk's quote is split: holders'
///         units → vault, platform part → fee bucket, the rest → the Curve recipient (or the platform).
/// @dev The kind is written once by the launchpad (`register`) and is the only thing that tells the kinds apart: both
///      kinds share one vault core, so `vault.launchpadOf(token)` says nothing about the kind (merge plan §4.2, R2-3).
///      Must be the shared dividend vault's operator for the launchpad and a SharedPlatformFeeBucket operator. Never
///      reverts because of a recipient: a failed push is booked as `owedOf` (held here, never sold) and anyone can
///      `release` it. H2: the DEX pair never holds dividend shares.
contract GangTaxHandler is IGangTaxHandler, PostGradHandlerBase {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant PLATFORM_TAX_BPS = V3_PLATFORM_TAX_BPS;
    /// @notice Fair tokens: holders' share of each tax (the rest is the platform's).
    uint256 public constant HOLDER_SHARE_BPS = 5_000;
    uint8 internal constant KIND_CURVE = 1;
    uint8 internal constant KIND_FAIR = 2;
    /// @dev A Fair token's buy and sell tax.
    uint256 internal constant FAIR_TAX_BPS = 100;

    /// @dev `kind` shares the second slot with the recipient and its share: the hooks read one slot for all three.
    struct Route {
        address quote;
        address recipient;
        uint16 dividendBps;
        uint8 kind;
    }

    struct Entry {
        bool listed;
        uint64 listedAt;
        string label;
    }

    PlatformFeeBucket public immutable platformBucket;

    /// @notice The one launchpad that registers routes (and, for Fair tokens, defines baselines).
    address public launchpad;
    mapping(address token => Route) public routeOf;
    /// @notice Quote owed to `token`'s recipient after a failed push.
    mapping(address token => uint256) public owedOf;
    /// @notice Σ owedOf per quote: held here for recipients, so it is never sold (a quote can itself be a token this
    ///         handler taxes).
    mapping(address quote => uint256) public owedTotalOf;
    /// @notice Part of `accruedTax` that is the platform's (tokens; Curve only).
    mapping(address => uint256) public accruedPlatformTax;
    /// @notice Tax recipients the platform allows (Curve). Delisting only stops new tokens from choosing one.
    mapping(address recipient => Entry) public entries;
    address[] internal _all;
    /// @notice Fair tokens: minters out of the reward for good (fell below the hold line once).
    mapping(address token => mapping(address user => bool)) public isOut;

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
    /// @notice Curve chunk sold (V3 layout).
    event OuterTaxProcessed(
        address indexed token, address indexed quote, uint256 taxTokens, uint256 quoteOut, uint256 platformQuote
    );
    /// @notice Fair chunk sold (打新 layout).
    event OuterTaxProcessed(
        address indexed token,
        address indexed quote,
        uint256 taxTokens,
        uint256 quoteOut,
        uint256 toHolders,
        uint256 toPlatform
    );
    event Disqualified(address indexed token, address indexed user, uint256 balance, uint256 baseline);

    error LaunchpadAlreadySet();
    error OnlyLaunchpad();
    error AlreadyRegistered();
    error UnknownToken();
    error BadKind();
    error BadDividendBps();
    error NothingOwed();
    error AlreadyListed();
    error NotListed();

    /// @param dexRouter_ Pancake V2 router `process` sells through (0 = straight into the pair); changes are delayed.
    constructor(address owner_, address dividendVault_, address platformBucket_, address dexRouter_)
        PostGradHandlerBase(owner_, dividendVault_, dexRouter_)
    {
        if (platformBucket_ == address(0)) revert ZeroAddress();
        platformBucket = PlatformFeeBucket(platformBucket_);
    }

    // ---------------------------------------------------------------- admin
    /// @notice One-shot: the launchpad that registers routes.
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

    /// @inheritdoc IGangTaxHandler
    function isListed(address recipient) external view returns (bool) {
        return entries[recipient].listed;
    }

    /// @notice Every address ever listed (delisted ones included; check `isListed`).
    function recipients() external view returns (address[] memory) {
        return _all;
    }

    // ---------------------------------------------------------------- launchpad
    /// @inheritdoc IGangTaxHandler
    function register(address token, address quote, address recipient, uint16 dividendBps, uint8 kind) external {
        if (msg.sender != launchpad) revert OnlyLaunchpad();
        if (token == address(0) || quote == address(0)) revert ZeroAddress();
        if (routeOf[token].kind != 0) revert AlreadyRegistered();
        if (kind == KIND_CURVE) {
            if (dividendBps > BPS || (recipient == address(0) && dividendBps != BPS)) revert BadDividendBps();
        } else if (kind == KIND_FAIR) {
            // the Fair rule is fixed: half to the holders, the rest to the platform
            if (recipient != address(0) || dividendBps != HOLDER_SHARE_BPS) revert BadDividendBps();
        } else {
            revert BadKind();
        }
        routeOf[token] = Route({quote: quote, recipient: recipient, dividendBps: dividendBps, kind: kind});
        emit RouteRegistered(token, quote, recipient, dividendBps);
    }

    /// @inheritdoc IGangTaxHandler
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

    // ---------------------------------------------------------------- token hooks
    /// @inheritdoc IGangTaxHandler
    function notifyTax(address token, address from, address to, uint256 taxAmount, uint256 rateBps)
        external
        nonReentrant
    {
        _checkHook(token, taxAmount);
        // only tokens the launchpad registered (write-once route; audit 4 A-F3 / C-F10, §13.1): anyone can deploy a
        // token pointing at this handler, and it must not accrue here
        Route memory r = routeOf[token];
        if (r.kind == 0) revert UnknownToken();
        // Internal audit 5 C-F7 (A-6): nobody gets a part of its own trade's tax — on a sell the seller's share is
        // synced to what it holds after the sell before the credit (the token already moved the tokens; for a Fair
        // minter this may take it out), and a buyer's share is only written after this call.
        uint256 platform;
        if (r.kind == KIND_CURVE) {
            // the token taxed this trade at `rateBps`: the platform's 0.5% of volume is that share of the tax, never
            // more than the tax itself
            if (rateBps > 0) {
                platform = (taxAmount * PLATFORM_TAX_BPS) / rateBps;
                if (platform > taxAmount) platform = taxAmount;
            }
            if (r.dividendBps > 0 && to == IGangTaxedToken(token).pair()) _syncShare(token, from);
        } else if (to == IGangTaxedToken(token).pair()) {
            _sync(token, from);
        }
        // the holders' share of the rest goes to the holders of this moment; with none, to the recipient (Curve with a
        // recipient) or the platform
        uint256 toHolders = ((taxAmount - platform) * r.dividendBps) / BPS;
        if (r.kind == KIND_CURVE) {
            if (!_creditHolders(token, toHolders) && r.recipient == address(0)) platform += toHolders;
            accruedPlatformTax[token] += platform;
        } else {
            _creditHolders(token, toHolders);
        }
        _accrue(token, from, to, taxAmount);
    }

    /// @inheritdoc IGangTaxHandler
    /// @dev Never reverts for unknown tokens (runs inside token transfers); the share rule follows the registered kind.
    function syncShares(address token, address from, address to) external {
        Route storage r = routeOf[token];
        uint8 kind = r.kind;
        if (kind == KIND_CURVE) {
            // only dividend tokens are in the vault
            if (r.dividendBps == 0) return;
            _syncShare(token, from);
            _syncShare(token, to);
        } else if (kind == KIND_FAIR) {
            // pre-launch shares are written by the pad
            if (IGangTaxedToken(token).locked()) return;
            _sync(token, from);
            _sync(token, to);
        }
    }

    /// @inheritdoc IGangTaxHandler
    function process(address token, uint256 amount, uint256 minQuoteOut)
        external
        nonReentrant
        returns (uint256 quoteOut)
    {
        return _process(token, amount, minQuoteOut);
    }

    /// @inheritdoc IGangTaxHandler
    function swapBack(address token, uint256 sellAmount) external nonReentrant returns (uint256 quoteOut) {
        if (routeOf[token].kind == 0) revert UnknownToken();
        return _swapBack(token, sellAmount);
    }

    /// @notice Fair tokens: reward weight the rule gives `user` right now (0 when out, never minted, or not Fair).
    function eligibleShare(address token, address user) public view returns (uint256) {
        if (routeOf[token].kind != KIND_FAIR || isOut[token][user] || dividendVault.excluded(user)) return 0;
        IGangPadView pad = IGangPadView(launchpad);
        uint256 base = pad.baselineOf(token, user);
        if (base == 0) return 0;
        uint256 bal = IERC20(token).balanceOf(user);
        if (bal * BPS < base * pad.holdBpsOf(token)) return 0;
        return bal < base ? bal : base;
    }

    // ---------------------------------------------------------------- internal
    function _quoteOf(address token) internal view override returns (address quote) {
        quote = routeOf[token].quote;
        if (quote == address(0)) revert UnknownToken();
    }

    function _sellTaxBps(address token) internal view override returns (uint256) {
        if (routeOf[token].kind == KIND_FAIR) return FAIR_TAX_BPS;
        return IGangTaxedToken(token).sellTaxBps();
    }

    function _bucket() internal view override returns (PlatformFeeBucket) {
        return platformBucket;
    }

    /// @dev §15: what is owed to recipients in this token (it can be another token's quote) is never sold.
    function _sellable(address token) internal view override returns (uint256) {
        return IERC20(token).balanceOf(address(this)) - owedTotalOf[token];
    }

    /// @dev The platform's part of the chunk: the same share of it as of what is accrued (all of it on the last chunk),
    ///      never more than what the holders' part leaves. Always 0 for a Fair token (it accrues none).
    function _takeAccrued(address token, uint256 amount, uint256 accrued, uint256 holderUnits)
        internal
        override
        returns (uint256 platformTokens)
    {
        uint256 all = accruedPlatformTax[token];
        if (all == 0) return 0;
        platformTokens = amount == accrued ? all : (all * amount) / accrued;
        if (platformTokens > amount - holderUnits) platformTokens = amount - holderUnits;
        accruedPlatformTax[token] = amount == accrued ? 0 : all - platformTokens;
    }

    /// @dev The holders' quote is already in the vault; the platform gets its tokens' share of the chunk's quote and
    ///      the recipient the rest (the platform when there is none — always for a Fair token).
    function _onProceeds(
        address token,
        address quote,
        uint256 amount,
        uint256 quoteOut,
        uint256 toHolders,
        uint256 platformTokens
    ) internal override {
        Route memory r = routeOf[token];
        uint256 rest = quoteOut - toHolders;
        uint256 toPlatform = (quoteOut * platformTokens) / amount;
        if (toPlatform > rest) toPlatform = rest;
        uint256 toRecipient = rest - toPlatform;
        if (r.recipient == address(0)) (toPlatform, toRecipient) = (rest, 0);
        _send(token, r, toPlatform, toRecipient);
        if (r.kind == KIND_FAIR) {
            emit OuterTaxProcessed(token, quote, amount, quoteOut, toHolders, toPlatform);
        } else {
            emit TaxDistributed(token, Phase.PostGrad, quoteOut, toPlatform, toHolders, toRecipient);
            emit OuterTaxProcessed(token, quote, amount, quoteOut, toPlatform);
        }
    }

    /// @dev The platform's and the recipient's legs (a failed push is booked as owed).
    function _send(address token, Route memory r, uint256 toPlatform, uint256 toRecipient) internal {
        _payPlatform(r.quote, toPlatform);
        if (toRecipient > 0) {
            if (_tryTransfer(r.quote, r.recipient, toRecipient)) {
                emit TaxPaid(token, r.recipient, r.quote, toRecipient);
            } else {
                owedOf[token] += toRecipient;
                owedTotalOf[r.quote] += toRecipient;
                emit TaxOwed(token, r.recipient, r.quote, toRecipient);
            }
        }
    }

    /// @dev Curve share rule: the holder's balance; the pair and excluded holders 0.
    function _syncShare(address token, address user) internal {
        if (user == address(0)) return;
        if (user == address(this)) return;
        address pair = IGangTaxedToken(token).pair();
        // runs inside token transfers: a vault-side failure (e.g. operator revoked, K-7) must not freeze trading, so
        // every write is guarded (ShareWriteFailed; retried by the holder's next sync)
        if (user == pair) {
            if (dividendVault.shares(token, user) != 0) _setShareGuarded(token, user, 0);
            return;
        }
        // Audit G-01: setExcluded does not clear shares, so an excluded holder is written to 0 here instead of being
        // skipped (skipping left its old share earning forever)
        if (dividendVault.excluded(user)) {
            if (dividendVault.shares(token, user) != 0) _setShareGuarded(token, user, 0);
            return;
        }
        _setShareGuarded(token, user, IERC20(token).balanceOf(user));
    }

    /// @dev Fair share rule: min(balance, baseline); below baseline × holdBps the minter is out for good (buying back
    ///      does not restore it). Everyone else (pair, handler, post-launch buyers) has baseline 0 → share 0.
    function _sync(address token, address user) internal {
        if (user == address(0)) return;
        IGangPadView pad = IGangPadView(launchpad);
        uint256 base = pad.baselineOf(token, user);
        uint256 share;
        // base 0 (pair, handler, post-launch buyers, or a minter who sold everything back before launch) targets 0: a
        // share the pad could not clear on that sell-back (its vault write is non-blocking) is zeroed here.
        // Audit G-01: the vault does not clear shares on setExcluded, so an excluded user must target 0 here too.
        if (base != 0 && !isOut[token][user] && !dividendVault.excluded(user)) {
            uint256 bal = IERC20(token).balanceOf(user);
            if (bal * BPS < base * pad.holdBpsOf(token)) {
                isOut[token][user] = true;
                emit Disqualified(token, user, bal, base);
            } else {
                share = bal < base ? bal : base;
            }
        }
        // Out users keep target 0 here, so a zeroing that failed earlier is retried on every later sync.
        // Runs inside token transfers: a vault-side failure (e.g. operator revoked) must not freeze trading.
        if (dividendVault.shares(token, user) != share) _setShareGuarded(token, user, share);
    }

    /// @dev OZ 5.1 has no trySafeTransfer. Accepts tokens that return nothing (USDT-style) or `true`.
    function _tryTransfer(address quote, address to, uint256 amount) internal returns (bool) {
        (bool ok, bytes memory ret) = quote.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!ok) return false;
        if (ret.length == 0) return quote.code.length > 0;
        return ret.length >= 32 && abi.decode(ret, (bool));
    }
}
