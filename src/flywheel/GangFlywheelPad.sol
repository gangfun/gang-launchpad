// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {QuoteRegistry} from "../launchpad-v2/QuoteRegistry.sol";
import {PoolCheck} from "../launchpad-v2/PoolCheck.sol";
import {SharedDividendVault} from "../common/SharedDividendVault.sol";
import {SharedPlatformFeeBucket as PlatformFeeBucket} from "../common/SharedPlatformFeeBucket.sol";
import {SharedMigrator} from "../common/SharedMigrator.sol";
import {IGangLaunchpad} from "../gang/interfaces/IGangLaunchpad.sol";
import {PadCommon} from "../gang/PadCommon.sol";
import {IFlywheelPad} from "./interfaces/IFlywheelPad.sol";
import {IFlywheelPadView} from "./interfaces/IFlywheelPadView.sol";
import {FlywheelLogic} from "./FlywheelLogic.sol";
import {FlywheelPostLogic} from "./FlywheelPostLogic.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {FlywheelOracle} from "./FlywheelOracle.sol";

interface IMintRoom {
    function mintRoom() external view returns (uint256);
}

interface IWBNBLike {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/// @title GangFlywheelPad — 持续打新 (continuous mint): the Agent ID mint format on the Gang launchpad
/// @notice Anyone with an Agent ID can launch a token here. Each wallet gets a quota (the dev's base + invites) shared
///         by the two phases:
///         - before launch: 10,000 shares at one price, sold back at that price (less the exit fee) until the sale is
///           filled or opened early by the dev (≥ 30% sold); the dev's cut is held until launch;
///         - launch (after `launchDelay`, anyone): the pool at the mint price, LP to 0xdead, then a few minutes of
///           launch protection (FlywheelTaxHandler);
///         - after launch (if `postMint`): mints at the tier price per share for tokens at the pool price (V2: the
///           higher of the price now and at the block's start); the money goes into the pool (part of it bought from
///           the pair), less the platform's mint fee and the dev's cut. The dev picks the post-launch guard at create:
///           off, or refuse mints while the pool is 15/20/30% below its TWAP, over a 15- or 30-minute window
///           (`postRulesOf`).
///         Minted tokens earn the holders' part of the pool tax (the handler's holder rule; this pad's `baselineOf`).
///         The pad has no power over a sale once created: no pause, no parameter change, no admin exit for escrow.
/// @dev The two paths live in external libraries (FlywheelLogic, FlywheelPostLogic) run by delegatecall, so the pad
///      stays under EIP-170. Shared contracts: SharedMigrator, SharedDividendVault (this pad's floor: 1,000 tokens),
///      SharedPlatformFeeBucket, QuoteRegistry; its own MintTokenDeployer and FlywheelTaxHandler.
///      Aggregators: the pad is listed in GangPadRegistry (`lookup(token)` → this pad, kind 3), trades through the
///      `…For` entries as a listed router for the wallet that sent the transaction (as GangLaunchpad, AUDIT-BRIEF §23),
///      and quotes with `previewMint` / `previewWithdraw` / `previewMintPost`.
contract GangFlywheelPad is IFlywheelPad, IFlywheelPadView, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant TOTAL_SHARES = FlywheelLogic.TOTAL_SHARES;
    uint256 public constant TOKENS_PER_SHARE = FlywheelLogic.TOKENS_PER_SHARE;
    uint8 public constant KIND = FlywheelLogic.KIND;
    /// @notice GangPadRegistry.addPad checks these against its curve quoter before listing a pad. This pad has no curve
    ///         (`kindOf` is never 1), so the registry never quotes a curve here: they only let it list the pad, so that
    ///         `lookup(token)` finds this pad's tokens (kind 3).
    uint256 public constant VIRTUAL_TOKEN = 1_066_666_666_666_666_666_666_666_667;
    uint256 public constant PROTOCOL_FEE_BPS = 100;

    QuoteRegistry public immutable quoteRegistry;
    SharedDividendVault public immutable dividendVault;
    PlatformFeeBucket public immutable platformBucket;
    address public immutable taxHandler;
    address public immutable tokenDeployer;
    address public immutable wbnb;

    IGangLaunchpad.Config internal _config;
    mapping(address => address) public bridgePoolOf;
    /// @notice Entry contracts (GangRouter, listed aggregators) that may mint (paying) and sell back (with the trader's
    ///         token allowance to them) for the wallet that sent the transaction.
    mapping(address router => bool) public routers;
    mapping(address token => uint8) public kindOf;
    mapping(address token => Sale) internal _sales;
    mapping(address token => mapping(address user => Account)) public accounts;
    mapping(address token => string) public logoURIOf;
    /// @notice Exit fees the bucket refused; anyone can `flushFees` them once it accepts.
    mapping(address quote => uint256) public owedFee;
    /// @notice Dev cuts the creator could not receive; anyone can `claimDev`.
    mapping(address token => uint256) public owedDev;
    address[] public allTokens;
    /// @notice Each sale's post-launch guard and TWAP window (V2; fixed at create). Not in `Sale`, whose getter
    ///         indexers decode as it was.
    mapping(address token => PostRules) public postRulesOf;

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
                || pairFactory_ == address(0)
        ) revert ZeroAddress();
        quoteRegistry = QuoteRegistry(quoteRegistry_);
        dividendVault = SharedDividendVault(dividendVault_);
        platformBucket = PlatformFeeBucket(platformBucket_);
        taxHandler = taxHandler_;
        tokenDeployer = tokenDeployer_;
        wbnb = wbnb_;
        _config.pairFactory = pairFactory_;
        _config.twapWindow = 1800;
        _config.agentGateEnabled = true;
    }

    /// @dev Only WBNB unwraps (BNB refunds).
    receive() external payable {
        if (msg.sender != wbnb) revert ZeroAddress();
    }

    // ---------------------------------------------------------------- admin (new sales only)
    /// @notice One-shot, last step of the deploy: `create` needs a migrator that lists this pad.
    function setMigrator(address migrator_) external onlyOwner {
        if (_config.migrator != address(0)) revert MigratorAlreadySet();
        if (migrator_ == address(0)) revert ZeroAddress();
        if (!SharedMigrator(migrator_).launchpads(address(this))) revert WrongMigrator();
        _config.migrator = migrator_;
        emit MigratorSet(migrator_);
    }

    /// @notice The Agent ID gate new sales snapshot (a sale keeps the gate it was created with).
    function setAgentGate(bool enabled, address registry) external onlyOwner {
        _config.agentGateEnabled = enabled;
        _config.agentIdRegistry = registry;
        emit AgentGateUpdated(enabled, registry);
    }

    /// @notice Pancake V2 factory used to price reference pools of non-BNB quotes.
    function setPairFactory(address factory_) external onlyOwner {
        _config.pairFactory = factory_;
        emit PairFactorySet(factory_);
    }

    function setV3Factory(address factory_) external onlyOwner {
        _config.v3Factory = factory_;
        emit V3FactorySet(factory_);
    }

    /// @notice The TWAP window used when pricing a non-BNB quote's reference pool at create (PoolCheck). Not a sale's
    ///         post-launch TWAP window: each sale fixes its own at create (`postRulesOf`).
    function setTwapWindow(uint32 window) external onlyOwner {
        _config.twapWindow = window;
        emit TwapWindowUpdated(window);
    }

    function setRouter(address router_, bool enabled) external onlyOwner {
        if (router_ == address(0)) revert ZeroAddress();
        routers[router_] = enabled;
        emit RouterSet(router_, enabled);
    }

    /// @notice Canonical `asset`/WBNB pool used to express `asset` in BNB. pool = 0 removes it.
    function setBridgePool(address asset, address pool) external onlyOwner {
        if (asset == address(0) || asset == wbnb) revert ZeroAddress();
        if (pool != address(0)) {
            PoolCheck.PoolInfo memory info = PoolCheck.inspect(PadCommon.poolCfg(_config, wbnb), pool);
            if (PoolCheck.counterOf(info, asset) != wbnb) revert IGangLaunchpad.BridgeNotWbnb();
        }
        bridgePoolOf[asset] = pool;
        emit BridgePoolSet(asset, pool);
    }

    // ---------------------------------------------------------------- create / pre-launch
    /// @param text     name, symbol, logoURI (site), metaURI (the token's contractURI, fixed)
    /// @param quote    WBNB (address(0)) or any 18-decimal ERC-20
    /// @param refPool  pool pricing a non-BNB quote (ignored for WBNB or a QuoteRegistry rate)
    /// @param devShares shares the creator mints in the same call (1..min(baseQuota, maxPerTx)); approve the quote first
    function create(string[4] calldata text, address quote, address refPool, FlyConfig calldata cfg, uint256 devShares)
        external
        nonReentrant
        returns (address token)
    {
        token = FlywheelLogic.create(
            _config, _sales, accounts, owedDev, postRulesOf, bridgePoolOf, _deps(), text, quote, refPool, cfg, devShares
        );
        kindOf[token] = KIND;
        logoURIOf[token] = text[2];
        allTokens.push(token);
    }

    /// @notice Pre-launch mint, paid in the sale's quote (approved to the pad).
    /// @param minShares revert if the quota, per-mint cap or the last shares leave fewer than this
    function mint(address token, uint256 shares, uint256 minShares, address referrer)
        external
        nonReentrant
        returns (uint256 spent)
    {
        spent = FlywheelLogic.mint(
            _config, _sales, accounts, owedDev, _deps(), msg.sender, token, shares, minShares, referrer, 0
        );
    }

    /// @notice A listed router mints for `trader`, the wallet that sent the transaction; the router pays (approve the
    ///         exact `previewMint` cost + fee). Shares, tokens, gate and quota are the trader's.
    function mintFor(address trader, address token, uint256 shares, uint256 minShares, address referrer)
        external
        nonReentrant
        returns (uint256 spent)
    {
        _forTrader(trader, token);
        spent = FlywheelLogic.mint(
            _config, _sales, accounts, owedDev, _deps(), trader, token, shares, minShares, referrer, 0
        );
    }

    /// @notice Pre-launch mint of a WBNB sale paid in BNB; what is not spent comes back.
    function mintWithBnb(address token, uint256 shares, uint256 minShares, address referrer)
        external
        payable
        nonReentrant
        returns (uint256 spent)
    {
        _wrap(token);
        spent = FlywheelLogic.mint(
            _config, _sales, accounts, owedDev, _deps(), msg.sender, token, shares, minShares, referrer, msg.value
        );
        _refund(spent);
    }

    /// @notice Before the sale fills (or opens early): sell `shares` back at the mint price, less the exit fee.
    function withdraw(address token, uint256 shares, uint256 minPayout) external nonReentrant returns (uint256 payout) {
        payout = FlywheelLogic.withdraw(_sales, accounts, owedFee, _deps(), msg.sender, false, token, shares, minPayout);
    }

    /// @notice A listed router sells back `trader`'s shares (the wallet that sent the transaction): the tokens move with
    ///         the allowance the trader gave the router, the payout goes to the router.
    function withdrawFor(address trader, address token, uint256 shares, uint256 minPayout)
        external
        nonReentrant
        returns (uint256 payout)
    {
        _forTrader(trader, token);
        payout = FlywheelLogic.withdraw(_sales, accounts, owedFee, _deps(), trader, true, token, shares, minPayout);
    }

    /// @notice The creator opens the pool before the sale fills, once at least 30% of the shares are sold.
    function openEarly(address token) external nonReentrant {
        FlywheelLogic.openEarly(_config, _sales, owedDev, _deps(), token);
    }

    /// @notice Anyone, `launchDelay` after the sale filled or opened early.
    function launch(address token) external nonReentrant {
        FlywheelLogic.launch(_config, _sales, owedDev, _deps(), token);
    }

    // ---------------------------------------------------------------- post-launch
    /// @notice Post-launch mint, paid in the sale's quote (approved to the pad).
    /// @param minTokensOut revert below this (the price can move before the transaction lands)
    function mintPost(address token, uint256 shares, uint256 minTokensOut, uint256 maxSpent, address referrer)
        external
        nonReentrant
        returns (uint256 tokensOut, uint256 spent)
    {
        (tokensOut, spent) = FlywheelPostLogic.mintPost(
            _sales,
            accounts,
            owedDev,
            postRulesOf,
            _deps(),
            msg.sender,
            token,
            shares,
            minTokensOut,
            maxSpent,
            referrer,
            0
        );
    }

    /// @notice A listed router mints after launch for `trader`, the wallet that sent the transaction; the router pays,
    ///         the tokens are the trader's.
    function mintPostFor(
        address trader,
        address token,
        uint256 shares,
        uint256 minTokensOut,
        uint256 maxSpent,
        address referrer
    ) external nonReentrant returns (uint256 tokensOut, uint256 spent) {
        _forTrader(trader, token);
        (tokensOut, spent) = FlywheelPostLogic.mintPost(
            _sales, accounts, owedDev, postRulesOf, _deps(), trader, token, shares, minTokensOut, maxSpent, referrer, 0
        );
    }

    /// @notice Post-launch mint of a WBNB sale paid in BNB; what is not spent comes back.
    function mintPostWithBnb(address token, uint256 shares, uint256 minTokensOut, address referrer)
        external
        payable
        nonReentrant
        returns (uint256 tokensOut, uint256 spent)
    {
        _wrap(token);
        // msg.value bounds the spend (BnbShort)
        (tokensOut, spent) = FlywheelPostLogic.mintPost(
            _sales,
            accounts,
            owedDev,
            postRulesOf,
            _deps(),
            msg.sender,
            token,
            shares,
            minTokensOut,
            type(uint256).max,
            referrer,
            msg.value
        );
        _refund(spent);
    }

    // ---------------------------------------------------------------- owed
    /// @notice Send exit fees the bucket refused on to it. Anyone.
    function flushFees(address quote) external nonReentrant returns (uint256 amount) {
        amount = owedFee[quote];
        if (amount == 0) revert ZeroAmount();
        owedFee[quote] = 0;
        PadCommon.toPlatform(_deps(), quote, amount);
        emit FeesFlushed(quote, amount);
    }

    /// @notice Push a dev cut the creator could not receive. Anyone; reverts while it still can't.
    function claimDev(address token) external nonReentrant returns (uint256 amount) {
        amount = owedDev[token];
        if (amount == 0) revert NothingOwed();
        owedDev[token] = 0;
        Sale storage s = _sales[token];
        IERC20(s.quote).safeTransfer(s.creator, amount);
        emit DevPaid(token, s.creator, amount);
    }

    // ---------------------------------------------------------------- views
    function sales(address token) external view returns (Sale memory) {
        return _sales[token];
    }

    /// @inheritdoc IFlywheelPadView
    function baselineOf(address token, address user) external view returns (uint256) {
        return accounts[token][user].baseline;
    }

    /// @inheritdoc IFlywheelPadView
    function holdBpsOf(address token) external view returns (uint16) {
        return _sales[token].holdBps;
    }

    /// @notice Shares `user` may still mint (quota left), ignoring the per-mint cap and pre-launch shares left.
    function quotaLeft(address token, address user) external view returns (uint256) {
        Sale storage s = _sales[token];
        Account storage a = accounts[token][user];
        uint256 quota = uint256(s.baseQuota) + a.bonus;
        return a.used >= quota ? 0 : quota - a.used;
    }

    /// @notice Price per share (quote) of a post-launch mint of `shares` now; the pre-launch price before launch.
    function sharePrice(address token, uint256 shares) external view returns (uint256) {
        Sale storage s = _sales[token];
        if (!s.launched) return s.basePrice;
        return (uint256(s.basePrice) * FlywheelPostLogic.tierX100(s, uint256(s.totalShares) + shares)) / 100;
    }

    /// @notice What `mint(token, shares, 0, …)` by `user` would accept and cost now (cost excludes the fee); zeros when
    ///         the sale no longer takes pre-launch mints.
    function previewMint(address token, address user, uint256 shares)
        external
        view
        returns (uint256 accepted, uint256 cost, uint256 fee)
    {
        Sale storage s = _sales[token];
        if (s.creator == address(0) || s.launched || s.filledAt != 0) return (0, 0, 0);
        if (!_gatePasses(s.gate, user)) return (0, 0, 0);
        accepted = FlywheelLogic._acceptable(s, accounts[token][user], shares, TOTAL_SHARES - s.sold);
        cost = accepted * s.basePrice;
        fee = (cost * s.mintFeeBps) / 10_000;
    }

    /// @notice What `withdraw(token, shares, 0)` by `user` would pay out and charge now (zeros if it would revert).
    function previewWithdraw(address token, address user, uint256 shares)
        external
        view
        returns (uint256 payout, uint256 fee)
    {
        Sale storage s = _sales[token];
        if (!FlywheelLogic.withdrawable(s)) return (0, 0);
        if (shares == 0 || shares > accounts[token][user].preShares) return (0, 0);
        uint256 principal = shares * s.basePrice;
        fee = (principal * FlywheelLogic.exitFeeBps(s)) / 10_000;
        payout = principal - fee;
    }

    /// @notice What `mintPost(token, shares, 0, …)` by `user` would accept, cost (price and fee) and deliver if sent
    ///         now (the same pricing code the mint runs); `ok` false when it would be refused (not launched / minting
    ///         off / no Agent ID / no quota / the sale's guard: price more than `guardBps` below its TWAP / a price
    ///         more than 10% above the pool / the wallet's pace / the supply cap, checked against exactly what the mint
    ///         would newly mint).
    function previewMintPost(address token, address user, uint256 shares)
        external
        view
        returns (uint256 accepted, uint256 paid, uint256 fee, uint256 tokensOut, bool ok)
    {
        Sale storage s = _sales[token];
        if (!s.launched || !s.postMint || !_gatePasses(s.gate, user)) return (0, 0, 0, 0, false);
        Account storage a = accounts[token][user];
        accepted = FlywheelLogic._acceptable(s, a, shares, type(uint256).max);
        if (accepted == 0) return (0, 0, 0, 0, false);
        paid = (accepted * s.basePrice * FlywheelPostLogic.tierX100(s, uint256(s.totalShares) + accepted)) / 100;
        fee = (paid * s.mintFeeBps) / 10_000;
        FlywheelPostLogic.Pricing memory p = FlywheelPostLogic.pricing(taxHandler, token, s.pair, postRulesOf[token]);
        tokensOut = Math.mulDiv(paid, 1 << 112, p.price);
        if (p.belowAverage || p.abovePool) return (accepted, paid, fee, tokensOut, false);
        if ((FlywheelPostLogic.recentSpent(a) + paid) * 10_000 > p.rQ * FlywheelPostLogic.PACE_POOL_BPS) {
            return (accepted, paid, fee, tokensOut, false);
        }
        // the supply cap, exactly (audit V2 B-1): what the mint would newly mint, as `mintPost` computes it
        uint256 net = paid - (user == s.creator ? 0 : (paid * s.devCutBps) / 10_000);
        uint256 minted = FlywheelPostLogic.newlyMinted(p, s.pair, token, s.quote, s.buyBps, net, tokensOut);
        ok = minted <= IMintRoom(token).mintRoom();
    }

    /// @notice The exit fee a sell-back pays now (0 once the sale has been stale for 7 days).
    function exitFeeBpsOf(address token) external view returns (uint256) {
        return FlywheelLogic.exitFeeBps(_sales[token]);
    }

    /// @notice Every reason `create` would refuse `cfg` now (with the Agent ID gate as currently set).
    function checkConfig(FlyConfig calldata cfg, uint256 devShares) external view returns (bool ok, string memory) {
        string memory reason = FlywheelLogic.checkConfig(cfg, devShares);
        if (bytes(reason).length == 0 && !_config.agentGateEnabled) {
            if (cfg.devCutBps != 0) reason = "devCutBps must be 0 when ungated";
            else if (cfg.postMint) reason = "postMint needs the Agent ID gate";
        }
        return (bytes(reason).length == 0, reason);
    }

    /// @notice The prices mints are priced and checked with (UQ112x112, quote per token): spot, this block's start
    ///         (a mint pays the higher of the two), and the TWAP over the sale's window (the guard compares spot with
    ///         it). `high` is the handler's recent high of block-start prices (decaying 0.5% a minute), for information
    ///         only: V2 neither prices nor refuses mints with it.
    function prices(address token)
        external
        view
        returns (uint256 spot, uint256 blockStart, uint256 high, uint256 average)
    {
        address pair = _sales[token].pair;
        if (pair == address(0)) revert NotLaunched();
        spot = FlywheelOracle.spotOf(pair, token);
        blockStart = FlywheelOracle.blockStart(taxHandler, token, spot);
        high = FlywheelOracle.recentHigh(taxHandler, token);
        average = FlywheelOracle.twap(taxHandler, token, pair, postRulesOf[token].twapWindow);
    }

    function isAgent(address account) external view returns (bool) {
        return PadCommon.isAgent(_config, account);
    }

    function tokenCount() external view returns (uint256) {
        return allTokens.length;
    }

    function migrator() external view returns (address) {
        return _config.migrator;
    }

    function pairFactory() external view returns (address) {
        return _config.pairFactory;
    }

    function v3Factory() external view returns (address) {
        return _config.v3Factory;
    }

    function agentIdRegistry() external view returns (IERC721) {
        return IERC721(_config.agentIdRegistry);
    }

    function agentGateEnabled() external view returns (bool) {
        return _config.agentGateEnabled;
    }

    /// @notice The reference-pool pricing window (`setTwapWindow`), not a sale's TWAP window (`postRulesOf`).
    function twapWindow() external view returns (uint32) {
        return _config.twapWindow;
    }

    // ---------------------------------------------------------------- internal
    function _gatePasses(address gate, address user) internal view returns (bool) {
        return gate == address(0) || IERC721(gate).balanceOf(user) > 0;
    }

    /// @dev Who may act for `trader` (§23): a listed router, for the wallet that sent the transaction, on a gated sale
    ///      (ungated, a router could still only name tx.origin, but the gate check mirrors GangLaunchpad's A-2).
    function _forTrader(address trader, address token) internal view {
        if (!routers[msg.sender]) revert OnlyRouter();
        if (trader != tx.origin) revert TraderNotOrigin();
        if (_sales[token].gate == address(0)) revert RouterNeedsGate();
    }

    function _deps() internal view returns (IGangLaunchpad.Deps memory) {
        return IGangLaunchpad.Deps({
            quoteRegistry: address(quoteRegistry),
            dividendVault: address(dividendVault),
            platformBucket: address(platformBucket),
            taxHandler: taxHandler,
            tokenDeployer: tokenDeployer,
            wbnb: wbnb
        });
    }

    /// @dev BNB payments: only for WBNB sales; the whole `msg.value` is wrapped and the libraries spend from it.
    function _wrap(address token) internal {
        if (_sales[token].quote != wbnb) revert BnbNotQuote();
        if (msg.value == 0) revert ZeroAmount();
        IWBNBLike(wbnb).deposit{value: msg.value}();
    }

    function _refund(uint256 spent) internal {
        uint256 back = msg.value - spent;
        if (back == 0) return;
        IWBNBLike(wbnb).withdraw(back);
        (bool ok,) = msg.sender.call{value: back}("");
        if (!ok) {
            // a caller that can't take BNB gets the change as WBNB
            IWBNBLike(wbnb).deposit{value: back}();
            IERC20(wbnb).safeTransfer(msg.sender, back);
        }
    }
}
