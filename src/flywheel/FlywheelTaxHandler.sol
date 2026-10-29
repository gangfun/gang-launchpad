// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SharedPlatformFeeBucket as PlatformFeeBucket} from "../common/SharedPlatformFeeBucket.sol";
import {PostGradHandlerBase} from "../common/PostGradHandlerBase.sol";
import {IUniswapV2PairLite} from "../launchpad-v2/interfaces/IUniswapV2PairLite.sol";
import {IFlywheelPadView} from "./interfaces/IFlywheelPadView.sol";

/// @dev What the handler reads from the tokens it serves.
interface IFlywheelToken {
    function pair() external view returns (address);
    function locked() external view returns (bool);
    function sellTaxBps() external view returns (uint16);
}

interface IPairCumulative {
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
}

/// @title FlywheelTaxHandler (pool tax, launch protection and price oracle of continuous-mint tokens)
/// @notice The handler of every GangMintToken of one pad (`launchpad`, set once). Four jobs:
///         - **Tax split.** Of each pool tax, the first 1% of the trade (`BASE_TAX_BPS`) is split holders 50% /
///           platform 25% / dev 25%; a sell tax above 1% goes entirely to holders. The holders' part is credited at tax
///           time (shared dividend vault units); the rest accrues here in tokens and is sold in chunks
///           (PostGradHandlerBase). Each chunk's quote: holders → vault, platform → fee bucket, the rest → the token's
///           creator (a failed push is owed, `release`). With no qualifying holder, the holders' part is the platform's.
///         - **Holder rule.** Share = min(balance, baseline) where the baseline is what the wallet minted (the pad's
///           `baselineOf`); below baseline × hold line the wallet is out, and buying back does not restore it. Minting
///           again does: the pad resets the baseline and calls `requalify`.
///         - **Launch protection.** Until `protectionOf.until`, a buy from the pair must go to an Agent ID holder (the
///           sale's gate) and each wallet's total buys in the window stay within the cap (counted per wallet, not by
///           balance, so moving tokens out does not reopen it).
///         - **Price oracle.** Every pool trade (and every pad call to `observe`) records the price at the block's first
///           touch (`blockStartPrice`) and, at most every OBS_GRANULARITY, an observation of the pair's cumulative
///           price. `twap` is the average over at least TWAP_WINDOW; within the first window after launch the time
///           before launch counts at the launch price.
/// @dev Must be the shared dividend vault's operator for its pad and a SharedPlatformFeeBucket operator. Runs inside token
///      transfers: never reverts because of a recipient or the vault; the protection checks are the only reverts a
///      trade can get from here (besides the base's flash-swap refusal).
contract FlywheelTaxHandler is PostGradHandlerBase {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    /// @notice The part of each trade's tax split three ways: the first 1% of the trade.
    uint256 public constant BASE_TAX_BPS = 100;
    /// @notice Holders' and platform's shares of that part (the creator gets the rest, 25%).
    uint256 public constant HOLDER_BPS = 5_000;
    uint256 public constant PLATFORM_BPS = 2_500;
    uint32 public constant TWAP_WINDOW = 30 minutes;
    uint32 public constant OBS_GRANULARITY = 5 minutes;
    uint256 internal constant OBS_SLOTS = 8;

    struct Route {
        address quote;
        address recipient;
    }

    struct Protection {
        uint64 until;
        address gate;
        uint256 cap;
    }

    struct Observation {
        uint32 timestamp;
        uint256 cumulative;
    }

    /// @dev Launch time / price (the TWAP's fill-in for the first window) and the ring's newest slot.
    struct Oracle {
        uint32 launchedAt;
        uint8 last;
        uint224 launchPrice;
        uint256 launchCumulative;
    }

    /// @dev Price (UQ112x112, quote per token) at the first touch of `blockNumber`.
    struct BlockRef {
        uint32 blockNumber;
        uint224 price;
    }

    PlatformFeeBucket public immutable platformBucket;

    /// @notice The one pad that registers tokens and defines baselines.
    address public launchpad;
    mapping(address token => Route) public routeOf;
    /// @notice Quote owed to `token`'s creator after a failed push.
    mapping(address token => uint256) public owedOf;
    /// @notice Σ owedOf per quote: held here for creators, never sold (a quote can itself be a token taxed here).
    mapping(address quote => uint256) public owedTotalOf;
    /// @notice Part of `accruedTax` that is the platform's (tokens).
    mapping(address token => uint256) public accruedPlatformTax;
    /// @notice Minters below their hold line (until they mint again).
    mapping(address token => mapping(address user => bool)) public isOut;
    mapping(address token => Protection) public protectionOf;
    /// @notice Gross tokens each wallet bought from the pair during the launch protection.
    mapping(address token => mapping(address user => uint256)) public boughtInWindow;
    mapping(address token => Oracle) public oracleOf;
    mapping(address token => BlockRef) public blockRefOf;
    mapping(address token => Observation[OBS_SLOTS]) internal _obs;

    event LaunchpadSet(address indexed launchpad);
    event RouteRegistered(address indexed token, address quote, address indexed recipient);
    event Launched(address indexed token, uint256 protectedUntil, address gate, uint256 cap, uint256 launchPrice);
    event Requalified(address indexed token, address indexed user);
    event Disqualified(address indexed token, address indexed user, uint256 balance, uint256 baseline);
    event TaxDistributed(
        address indexed token, uint256 taxTokens, uint256 quoteOut, uint256 toHolders, uint256 toPlatform, uint256 toDev
    );
    event TaxPaid(address indexed token, address indexed recipient, address indexed quote, uint256 amount);
    event TaxOwed(address indexed token, address indexed recipient, address indexed quote, uint256 amount);

    error LaunchpadAlreadySet();
    error OnlyLaunchpad();
    error AlreadyRegistered();
    error UnknownToken();
    error NothingOwed();
    error NotLaunched();
    error ProtectionNotAgent();
    error ProtectionCapExceeded();

    /// @param dexRouter_ Pancake V2 router `process` sells through (0 = straight into the pair); changes are delayed.
    constructor(address owner_, address dividendVault_, address platformBucket_, address dexRouter_)
        PostGradHandlerBase(owner_, dividendVault_, dexRouter_)
    {
        if (platformBucket_ == address(0)) revert ZeroAddress();
        platformBucket = PlatformFeeBucket(platformBucket_);
    }

    modifier onlyLaunchpad() {
        if (msg.sender != launchpad) revert OnlyLaunchpad();
        _;
    }

    // ---------------------------------------------------------------- admin
    /// @notice One-shot: the pad this handler serves.
    function setLaunchpad(address launchpad_) external onlyOwner {
        if (launchpad_ == address(0)) revert ZeroAddress();
        if (launchpad != address(0)) revert LaunchpadAlreadySet();
        launchpad = launchpad_;
        emit LaunchpadSet(launchpad_);
    }

    // ---------------------------------------------------------------- pad
    /// @notice At create, once per token: its quote and the creator who gets the dev's part of the tax.
    function register(address token, address quote, address recipient) external onlyLaunchpad {
        if (token == address(0) || quote == address(0) || recipient == address(0)) revert ZeroAddress();
        if (routeOf[token].quote != address(0)) revert AlreadyRegistered();
        routeOf[token] = Route({quote: quote, recipient: recipient});
        emit RouteRegistered(token, quote, recipient);
    }

    /// @notice At launch, once the pair is seeded and set on the token: the launch protection (`gate` 0 = no Agent ID
    ///         check) and the oracle's start (the launch price fills the first window).
    function onLaunch(address token, uint64 protectedUntil, address gate, uint256 cap) external onlyLaunchpad {
        if (routeOf[token].quote == address(0)) revert UnknownToken();
        if (oracleOf[token].launchedAt != 0) revert AlreadyRegistered();
        address pair = IFlywheelToken(token).pair();
        if (pair == address(0)) revert NoPair();
        protectionOf[token] = Protection({until: protectedUntil, gate: gate, cap: cap});
        uint224 price = _spot(pair, token);
        uint256 cum = _cumulative(pair, token);
        oracleOf[token] =
            Oracle({launchedAt: uint32(block.timestamp), last: 0, launchPrice: price, launchCumulative: cum});
        _obs[token][0] = Observation({timestamp: uint32(block.timestamp), cumulative: cum});
        blockRefOf[token] = BlockRef({blockNumber: uint32(block.number), price: price});
        emit Launched(token, protectedUntil, gate, cap, price);
    }

    /// @notice A wallet that was out minted again: it qualifies from its new baseline (the pad has reset it).
    function requalify(address token, address user) external onlyLaunchpad {
        if (isOut[token][user]) {
            isOut[token][user] = false;
            emit Requalified(token, user);
        }
    }

    // ---------------------------------------------------------------- oracle
    /// @notice Record the block's first-touch price and, when due, an observation. Anyone (the pad calls it on mints).
    function observe(address token) external {
        if (oracleOf[token].launchedAt == 0) revert NotLaunched();
        _touch(token, IFlywheelToken(token).pair());
    }

    /// @notice Pair price now, UQ112x112 quote per token.
    function spotPrice(address token) public view returns (uint256) {
        address pair = IFlywheelToken(token).pair();
        if (pair == address(0)) revert NoPair();
        return _spot(pair, token);
    }

    /// @notice Price at this block's first touch (the spot price if nothing touched the pair yet this block).
    function blockStartPrice(address token) public view returns (uint256) {
        BlockRef memory b = blockRefOf[token];
        if (b.blockNumber == uint32(block.number)) return b.price;
        return spotPrice(token);
    }

    /// @notice Average price over at least the last TWAP_WINDOW (UQ112x112). Within the first window after launch, the
    ///         time before launch counts at the launch price.
    function twap(address token) public view returns (uint256) {
        Oracle memory o = oracleOf[token];
        if (o.launchedAt == 0) revert NotLaunched();
        address pair = IFlywheelToken(token).pair();
        uint256 nowCum = _cumulative(pair, token);
        uint32 now32 = uint32(block.timestamp);
        uint32 age = now32 - o.launchedAt;
        unchecked {
            if (age < TWAP_WINDOW) {
                return (uint256(o.launchPrice) * (TWAP_WINDOW - age) + (nowCum - o.launchCumulative)) / TWAP_WINDOW;
            }
            // the newest observation at least a window old: the ring holds OBS_SLOTS ≥ OBS_GRANULARITY apart, so once
            // the launch observation is overwritten the oldest one is ≥ 35 minutes old — there always is one
            uint32 target = now32 - TWAP_WINDOW;
            Observation memory best = Observation({timestamp: o.launchedAt, cumulative: o.launchCumulative});
            Observation[OBS_SLOTS] storage ring = _obs[token];
            for (uint256 i; i < OBS_SLOTS; i++) {
                Observation memory ob = ring[i];
                if (ob.timestamp != 0 && ob.timestamp <= target && ob.timestamp > best.timestamp) best = ob;
            }
            return (nowCum - best.cumulative) / (now32 - best.timestamp);
        }
    }

    /// @notice Spot, block-start and TWAP prices in one call (UQ112x112).
    function prices(address token) external view returns (uint256 spot, uint256 blockStart, uint256 average) {
        return (spotPrice(token), blockStartPrice(token), twap(token));
    }

    function observation(address token, uint256 i) external view returns (uint32 timestamp, uint256 cumulative) {
        Observation memory ob = _obs[token][i];
        return (ob.timestamp, ob.cumulative);
    }

    // ---------------------------------------------------------------- creator payouts
    /// @notice Push the quote owed to `token`'s creator (a direct transfer that failed). Anyone; reverts while it
    ///         still cannot receive.
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
    /// @notice The token's hook after taking a pool tax (`taxAmount` already sent here, at `rateBps` of the trade).
    function notifyTax(address token, address from, address to, uint256 taxAmount, uint256 rateBps)
        external
        nonReentrant
    {
        _checkHook(token, taxAmount);
        Route memory r = routeOf[token];
        if (r.quote == address(0)) revert UnknownToken();
        address pair = IFlywheelToken(token).pair();
        if (from == pair) _protect(token, to, taxAmount, rateBps);
        _touch(token, pair);
        // internal audit 5 C-F7 (A-6): a seller is synced to what it holds after the sell before the credit, so it
        // gets no part of its own trade's tax (and a buyer's share is only written after this call)
        if (to == pair) _sync(token, from);

        uint256 base = rateBps > BASE_TAX_BPS ? (taxAmount * BASE_TAX_BPS) / rateBps : taxAmount;
        uint256 toHolders = taxAmount - base + (base * HOLDER_BPS) / BPS;
        uint256 platform = (base * PLATFORM_BPS) / BPS;
        if (!_creditHolders(token, toHolders)) platform += toHolders;
        accruedPlatformTax[token] += platform;
        _accrue(token, from, to, taxAmount);
    }

    /// @notice The token's hook on every transfer once its pair is set. Never reverts for unknown tokens.
    function syncShares(address token, address from, address to) external {
        if (routeOf[token].quote == address(0)) return;
        // pre-launch shares are written by the pad
        if (IFlywheelToken(token).locked()) return;
        _sync(token, from);
        _sync(token, to);
    }

    /// @dev Only the token, when a taxed sell of `sellAmount` goes into its pair: sells one chunk of accrued tax first.
    function swapBack(address token, uint256 sellAmount) external nonReentrant returns (uint256 quoteOut) {
        if (routeOf[token].quote == address(0)) revert UnknownToken();
        if (msg.sender != token) revert OnlyToken();
        // the block's first-touch price before the chunk moves it
        _touch(token, IFlywheelToken(token).pair());
        return _swapBack(token, sellAmount);
    }

    /// @dev Keeper/owner only: sells `amount` (≤ `maxChunk(token)`) with a mandatory off-chain `minQuoteOut`.
    function process(address token, uint256 amount, uint256 minQuoteOut)
        external
        nonReentrant
        returns (uint256 quoteOut)
    {
        // the block's first-touch price before the chunk moves it (internal audit C-L1)
        if (routeOf[token].quote != address(0)) _touch(token, IFlywheelToken(token).pair());
        return _process(token, amount, minQuoteOut);
    }

    /// @notice Reward weight `user` has right now (0 when out, never minted, or excluded).
    function eligibleShare(address token, address user) public view returns (uint256) {
        if (routeOf[token].quote == address(0) || isOut[token][user] || dividendVault.excluded(user)) return 0;
        IFlywheelPadView pad = IFlywheelPadView(launchpad);
        uint256 base = pad.baselineOf(token, user);
        if (base == 0) return 0;
        uint256 bal = IERC20(token).balanceOf(user);
        if (bal * BPS < base * pad.holdBpsOf(token)) return 0;
        return bal < base ? bal : base;
    }

    // ---------------------------------------------------------------- internal: protection / oracle
    /// @dev A buy during the launch protection: Agent ID receiver, within its cap (gross tokens taken from the pair).
    function _protect(address token, address to, uint256 taxAmount, uint256 rateBps) internal {
        Protection memory p = protectionOf[token];
        if (block.timestamp >= p.until) return;
        if (p.gate != address(0) && IERC721(p.gate).balanceOf(to) == 0) revert ProtectionNotAgent();
        uint256 bought = boughtInWindow[token][to] + (taxAmount * BPS) / rateBps;
        if (bought > p.cap) revert ProtectionCapExceeded();
        boughtInWindow[token][to] = bought;
    }

    /// @dev The block's first-touch price, and an observation when the newest is OBS_GRANULARITY old. Inside a pool
    ///      trade the pair's reserves are still the pre-trade ones.
    function _touch(address token, address pair) internal {
        Oracle storage o = oracleOf[token];
        if (o.launchedAt == 0) return;
        uint224 price = _spot(pair, token);
        BlockRef storage b = blockRefOf[token];
        if (b.blockNumber != uint32(block.number)) {
            b.blockNumber = uint32(block.number);
            b.price = price;
        }
        uint8 last = o.last;
        if (block.timestamp >= uint256(_obs[token][last].timestamp) + OBS_GRANULARITY) {
            uint8 next = uint8((uint256(last) + 1) % OBS_SLOTS);
            _obs[token][next] = Observation({timestamp: uint32(block.timestamp), cumulative: _cumulative(pair, token)});
            o.last = next;
        }
    }

    /// @dev Pair price, UQ112x112 quote per token (0 for an empty token side).
    function _spot(address pair, address token) internal view returns (uint224) {
        (uint256 rT, uint256 rQ) = _reserves(pair, token);
        if (rT == 0) return 0;
        return uint224((rQ << 112) / rT);
    }

    /// @dev The pair's cumulative quote-per-token price as of now (Uniswap V2 oracle library: the stored value plus
    ///      the current price over the time since the pair's last update). Wraps like the pair's own counter.
    function _cumulative(address pair, address token) internal view returns (uint256 cum) {
        bool tokenIs0 = IUniswapV2PairLite(pair).token0() == token;
        cum = tokenIs0 ? IPairCumulative(pair).price0CumulativeLast() : IPairCumulative(pair).price1CumulativeLast();
        (,, uint32 last) = IUniswapV2PairLite(pair).getReserves();
        unchecked {
            uint32 elapsed = uint32(block.timestamp) - last;
            if (elapsed > 0) cum += uint256(_spot(pair, token)) * elapsed;
        }
    }

    // ---------------------------------------------------------------- internal: shares / proceeds
    function _quoteOf(address token) internal view override returns (address quote) {
        quote = routeOf[token].quote;
        if (quote == address(0)) revert UnknownToken();
    }

    function _sellTaxBps(address token) internal view override returns (uint256) {
        return IFlywheelToken(token).sellTaxBps();
    }

    function _bucket() internal view override returns (PlatformFeeBucket) {
        return platformBucket;
    }

    /// @dev What is owed to creators in this token (it can be another token's quote) is never sold.
    function _sellable(address token) internal view override returns (uint256) {
        return IERC20(token).balanceOf(address(this)) - owedTotalOf[token];
    }

    /// @dev The platform's part of the chunk: the same share of it as of what is accrued (all of it on the last chunk),
    ///      never more than what the holders' part leaves.
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

    /// @dev Holders' quote is already in the vault; the platform gets its tokens' share of the chunk's quote and the
    ///      creator the rest.
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
        uint256 toDev = rest - toPlatform;
        _payPlatform(quote, toPlatform);
        if (toDev > 0) {
            if (_tryTransfer(quote, r.recipient, toDev)) {
                emit TaxPaid(token, r.recipient, quote, toDev);
            } else {
                owedOf[token] += toDev;
                owedTotalOf[quote] += toDev;
                emit TaxOwed(token, r.recipient, quote, toDev);
            }
        }
        emit TaxDistributed(token, amount, quoteOut, toHolders, toPlatform, toDev);
    }

    /// @dev Share = min(balance, baseline); below baseline × hold line the wallet is out until it mints again. Everyone
    ///      else (pair, pad, handler, pool buyers) has baseline 0 → share 0. Runs inside token transfers: vault-side
    ///      failures never freeze trading (`_setShareGuarded`).
    function _sync(address token, address user) internal {
        if (user == address(0)) return;
        IFlywheelPadView pad = IFlywheelPadView(launchpad);
        uint256 base = pad.baselineOf(token, user);
        uint256 share;
        if (base != 0 && !isOut[token][user] && !dividendVault.excluded(user)) {
            uint256 bal = IERC20(token).balanceOf(user);
            if (bal * BPS < base * pad.holdBpsOf(token)) {
                isOut[token][user] = true;
                emit Disqualified(token, user, bal, base);
            } else {
                share = bal < base ? bal : base;
            }
        }
        if (dividendVault.shares(token, user) != share) _setShareGuarded(token, user, share);
    }

    /// @dev Accepts tokens that return nothing (USDT-style) or `true`.
    function _tryTransfer(address quote, address to, uint256 amount) internal returns (bool) {
        (bool ok, bytes memory ret) = quote.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!ok) return false;
        if (ret.length == 0) return quote.code.length > 0;
        return ret.length >= 32 && abi.decode(ret, (bool));
    }
}
