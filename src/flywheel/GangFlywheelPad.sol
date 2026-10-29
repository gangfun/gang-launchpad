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
///         - after launch (if `postMint`): mints at the tier price per share for tokens at the pool price; the money
///           goes into the pool (part of it bought from the pair), less the platform's mint fee and the dev's cut.
///         Minted tokens earn the holders' part of the pool tax (the handler's holder rule; this pad's `baselineOf`).
///         The pad has no power over a sale once created: no pause, no parameter change, no admin exit for escrow.
/// @dev The two paths live in external libraries (FlywheelLogic, FlywheelPostLogic) run by delegatecall, so the pad
///      stays under EIP-170. Shared contracts: SharedMigrator, SharedDividendVault (this pad's floor: 1,000 tokens),
///      SharedPlatformFeeBucket, QuoteRegistry; its own MintTokenDeployer and FlywheelTaxHandler.
contract GangFlywheelPad is IFlywheelPad, IFlywheelPadView, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant TOTAL_SHARES = FlywheelLogic.TOTAL_SHARES;
    uint256 public constant TOKENS_PER_SHARE = FlywheelLogic.TOKENS_PER_SHARE;
    uint8 public constant KIND = FlywheelLogic.KIND;

    QuoteRegistry public immutable quoteRegistry;
    SharedDividendVault public immutable dividendVault;
    PlatformFeeBucket public immutable platformBucket;
    address public immutable taxHandler;
    address public immutable tokenDeployer;
    address public immutable wbnb;

    IGangLaunchpad.Config internal _config;
    mapping(address => address) public bridgePoolOf;
    mapping(address token => uint8) public kindOf;
    mapping(address token => Sale) internal _sales;
    mapping(address token => mapping(address user => Account)) public accounts;
    mapping(address token => string) public logoURIOf;
    /// @notice Exit fees the bucket refused; anyone can `flushFees` them once it accepts.
    mapping(address quote => uint256) public owedFee;
    /// @notice Dev cuts the creator could not receive; anyone can `claimDev`.
    mapping(address token => uint256) public owedDev;
    address[] public allTokens;

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

    function setTwapWindow(uint32 window) external onlyOwner {
        _config.twapWindow = window;
        emit TwapWindowUpdated(window);
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
    function create(
        string[4] calldata text,
        address quote,
        address refPool,
        FlyConfig calldata cfg,
        uint256 devShares
    ) external nonReentrant returns (address token) {
        token = FlywheelLogic.create(
            _config, _sales, accounts, owedDev, bridgePoolOf, _deps(), text, quote, refPool, cfg, devShares
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
        spent = FlywheelLogic.mint(_config, _sales, accounts, owedDev, _deps(), token, shares, minShares, referrer, 0);
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
            _config, _sales, accounts, owedDev, _deps(), token, shares, minShares, referrer, msg.value
        );
        _refund(spent);
    }

    /// @notice Before the sale fills (or opens early): sell `shares` back at the mint price, less the exit fee.
    function withdraw(address token, uint256 shares, uint256 minPayout) external nonReentrant returns (uint256 payout) {
        payout = FlywheelLogic.withdraw(_sales, accounts, owedFee, _deps(), token, shares, minPayout);
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
    function mintPost(address token, uint256 shares, uint256 minTokensOut, address referrer)
        external
        nonReentrant
        returns (uint256 tokensOut, uint256 spent)
    {
        (tokensOut, spent) =
            FlywheelPostLogic.mintPost(_sales, accounts, owedDev, _deps(), token, shares, minTokensOut, referrer, 0);
    }

    /// @notice Post-launch mint of a WBNB sale paid in BNB; what is not spent comes back.
    function mintPostWithBnb(address token, uint256 shares, uint256 minTokensOut, address referrer)
        external
        payable
        nonReentrant
        returns (uint256 tokensOut, uint256 spent)
    {
        _wrap(token);
        (tokensOut, spent) = FlywheelPostLogic.mintPost(
            _sales, accounts, owedDev, _deps(), token, shares, minTokensOut, referrer, msg.value
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

    /// @notice The exit fee a sell-back pays now (0 once the sale has been stale for 7 days).
    function exitFeeBpsOf(address token) external view returns (uint256) {
        return FlywheelLogic.exitFeeBps(_sales[token]);
    }

    function checkConfig(FlyConfig calldata cfg, uint256 devShares) external pure returns (bool ok, string memory) {
        string memory reason = FlywheelLogic.checkConfig(cfg, devShares);
        return (bytes(reason).length == 0, reason);
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

    function agentIdRegistry() external view returns (IERC721) {
        return IERC721(_config.agentIdRegistry);
    }

    function agentGateEnabled() external view returns (bool) {
        return _config.agentGateEnabled;
    }

    // ---------------------------------------------------------------- internal
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
