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
import {QuoteRegistry} from "../launchpad-v2/QuoteRegistry.sol";
import {SharedDividendVault} from "../common/SharedDividendVault.sol";
import {SharedPlatformFeeBucket as PlatformFeeBucket} from "../common/SharedPlatformFeeBucket.sol";
import {IMigratorV2} from "../launchpad-v2/interfaces/IMigratorV2.sol";
import {SharedMigrator} from "../common/SharedMigrator.sol";
import {TokenDeployer} from "../common/TokenDeployer.sol";
import {PoolCheck} from "../launchpad-v2/PoolCheck.sol";
import {FairToken} from "./FairToken.sol";
import {IGangTaxHandler} from "../gang/interfaces/IGangTaxHandler.sol";
import {IGangPadView} from "../gang/interfaces/IGangPadView.sol";

/// @title FairMintPad (打新发射 · 铭文式打进度)
/// @notice No bonding curve: half the supply is sold in 10,000 equal shares at one fixed price, both ways — mint buys
///         shares at it, withdraw sells them back to the pad at it. When the last share is minted, the other half
///         plus all principal goes into a Pancake V2 pair (LP to 0xdead), so the opening price equals the mint price.
///         There is no deadline and no refund: a sale stays open until it fills, and a minter leaves by withdrawing.
///         Mint fee (1%–3%) is paid to PlatformFeeBucket at mint; exit fee (1%–2%) is taken on withdraw, and waived once
///         a sale has made no progress for STALE_AFTER (7 days), so a stalled sale can be left at the price paid.
///         Progress = shares sold reaching STALE_STEP above where the clock last restarted, so a 1-share mint (or a
///         withdraw-and-remint) can't keep the waiver off: holding the shares that restart it is what it costs.
///         Tokens stay locked until launch: they only move between the pad and minters (no P2P sale before launch).
/// @dev Spec: docs/SPEC-FAIR-MINT-2026-10-26.md. NO mainnet broadcast.
///      Each sale snapshots its rules at create (cap, gate, fees, hold line): owner setters only affect new sales.
///      Escrowed principal has no admin exit — only withdraw and launch move it.
contract FairMintPad is IGangPadView, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 public constant MINT_SUPPLY = 500_000_000 ether;
    uint256 public constant LP_SUPPLY = TOTAL_SUPPLY - MINT_SUPPLY;
    uint256 public constant TOTAL_SHARES = 10_000;
    uint256 public constant TOKENS_PER_SHARE = MINT_SUPPLY / TOTAL_SHARES; // 50_000 tokens
    uint256 public constant BPS = 10_000;
    uint16 public constant MIN_FEE_BPS = 100; // 1%: platform floor, mint and exit
    uint16 public constant MAX_MINT_FEE_BPS = 300; // 3%: never refunded (there is no refund), so kept low
    uint16 public constant MAX_EXIT_FEE_BPS = 200; // 2%: withdraw is the only way out of an unfilled sale
    /// @notice No progress for this long → withdraw costs no exit fee (only the mint fee paid is lost).
    uint256 public constant STALE_AFTER = 7 days;
    /// @notice Shares sold must rise this far above the last restart to restart the stale clock (0.1% of the shares).
    uint256 public constant STALE_STEP = 10;

    uint256 public constant MIN_RAISE_BNB = 5 ether;
    uint256 public constant MAX_RAISE_BNB = 50 ether;
    /// @dev QuoteRegistry overrides are "15 BNB worth of quote" (V2 graduation target); scaled to the raise.
    uint256 public constant REGISTRY_REF_BNB = 15 ether;
    uint16 public constant MIN_CAP_BPS = 25; // 0.25% of supply → ≥ 200 addresses (no deadline: keep the bar reachable)
    uint16 public constant MAX_CAP_BPS = 50; // 0.5% of supply → ≥ 100 addresses
    uint16 public constant MIN_HOLD_BPS = 3_000;
    uint16 public constant MAX_HOLD_BPS = 8_000;
    /// @dev Vault floor uses `<=`; must stay below 1 share × MIN_HOLD_BPS (15k tokens) or small minters earn nothing.
    uint256 public constant MIN_SHARE_BALANCE = 10_000 ether;
    uint256 public constant MIN_REF_DEPTH_BNB = 1 ether;

    struct MintConfig {
        uint256 raiseBnb; // BNB-equivalent; converted to quote units at create
        uint16 capBps; // per-address cap, share of total supply
        uint16 holdBps; // reward line: out for good once balance < baseline × holdBps
        uint16 mintFeeBps; // on top of the principal at mint, to the platform at once
        uint16 exitFeeBps; // taken from the principal on withdraw (waived once the sale is stale)
    }

    struct Sale {
        address creator;
        uint64 progressAt; // stale clock: the creator's mint, then each mint that lifts `sold` to markSold + STALE_STEP
        uint16 capShares;
        uint16 holdBps;
        address quote;
        uint16 sold;
        bool launched;
        uint16 mintFeeBps;
        uint16 exitFeeBps;
        address gate; // Agent ID registry snapshot; 0 = ungated
        uint128 sharePrice;
        address pair;
        address refPool;
        uint16 markSold; // `sold` when the stale clock last restarted
    }

    struct Position {
        uint16 shares;
    }

    enum Status {
        None,
        Minting,
        Launched
    }

    QuoteRegistry public immutable quoteRegistry;
    SharedDividendVault public immutable dividendVault;
    PlatformFeeBucket public immutable platformBucket;
    address public immutable taxHandler;
    TokenDeployer public immutable tokenDeployer;
    address public immutable wbnb;
    address public immutable pairFactory;

    address public v3Factory;
    uint32 public twapWindow = 1800;
    mapping(address => address) public bridgePoolOf;
    IMigratorV2 public migrator;
    IERC721 public agentIdRegistry;
    bool public agentGateEnabled = true;
    /// @notice Stateless entry contracts (e.g. GangRouter) that may mint for a trader they pay for. A router only ever
    ///         spends its own quote: it can't withdraw or claim for anyone (those stay msg.sender-only).
    mapping(address router => bool) public routers;

    mapping(address token => Sale) public sales;
    mapping(address token => mapping(address user => Position)) public positions;
    mapping(address token => string) public logoURIOf;
    /// @notice Exit fees the bucket refused (see `_exitFeeToPlatform`); anyone can `flushFees` them once it accepts.
    mapping(address quote => uint256) public owedFee;
    address[] public allTokens;

    event Created(
        address indexed token,
        address indexed creator,
        string name,
        string symbol,
        string logoURI,
        address indexed quote,
        address refPool,
        uint256 raiseBnb,
        uint256 sharePrice,
        uint256 capShares,
        uint256 holdBps,
        uint256 mintFeeBps,
        uint256 exitFeeBps
    );
    event Minted(
        address indexed token,
        address indexed user,
        uint256 shares,
        uint256 cost,
        uint256 fee,
        uint256 userShares,
        uint256 sold
    );
    event Withdrawn(
        address indexed token,
        address indexed user,
        uint256 shares,
        uint256 payout,
        uint256 fee,
        uint256 userShares,
        uint256 sold
    );
    event Launched(
        address indexed token, address indexed pair, address quote, uint256 tokenAmount, uint256 quoteAmount
    );
    /// @notice The vault refused the exit's share write: `user` keeps its old share until someone `syncShares` it.
    event ShareWriteFailed(address indexed token, address indexed user, uint256 share);
    event FeeOwed(address indexed quote, uint256 amount);
    event FeesFlushed(address indexed quote, uint256 amount);
    event MigratorSet(address indexed migrator);
    event AgentGateUpdated(bool enabled, address registry);
    event V3FactorySet(address indexed factory);
    event TwapWindowUpdated(uint32 window);
    event BridgePoolSet(address indexed asset, address indexed pool);
    event RouterSet(address indexed router, bool enabled);

    error BadConfig(string reason);
    error UnknownToken();
    error NotMinting();
    error ZeroAmount();
    error BadAmount();
    error Slippage();
    error WalletCapReached();
    error NotAgent();
    error MigratorNotSet();
    error MigratorAlreadySet();
    error ZeroAddress();
    error RefPoolRequired();
    error NoBridgePool();
    error BridgeNotWbnb();
    error PriceTooSmall();
    error FeeOnTransferQuote();
    error VaultFloorTooHigh();
    error OnlyRouter();
    error QuoteNotAllowed();
    error WrongMigrator();
    error RouterNeedsGate();
    error OutOfGas();

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
        tokenDeployer = TokenDeployer(tokenDeployer_);
        wbnb = wbnb_;
        pairFactory = pairFactory_;
    }

    // ---------------------------------------------------------------- admin (new sales only)
    function setMigrator(address migrator_) external onlyOwner {
        if (address(migrator) != address(0)) revert MigratorAlreadySet();
        if (migrator_ == address(0)) revert ZeroAddress();
        // one-shot: a migrator that does not list this core would make every launch revert forever
        if (!SharedMigrator(migrator_).launchpads(address(this))) revert WrongMigrator();
        migrator = IMigratorV2(migrator_);
        emit MigratorSet(migrator_);
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

    function setV3Factory(address factory_) external onlyOwner {
        v3Factory = factory_;
        emit V3FactorySet(factory_);
    }

    function setTwapWindow(uint32 window) external onlyOwner {
        twapWindow = window;
        emit TwapWindowUpdated(window);
    }

    /// @notice Canonical `asset`/WBNB pool used to express `asset` in BNB. pool = 0 removes it.
    function setBridgePool(address asset, address pool) external onlyOwner {
        if (asset == address(0) || asset == wbnb) revert ZeroAddress();
        if (pool != address(0)) {
            PoolCheck.PoolInfo memory info = PoolCheck.inspect(_cfg(), pool);
            if (PoolCheck.counterOf(info, asset) != wbnb) revert BridgeNotWbnb();
        }
        bridgePoolOf[asset] = pool;
        emit BridgePoolSet(asset, pool);
    }

    // ---------------------------------------------------------------- create
    /// @param logoURI   Logo image URI: kept in `logoURIOf` and emitted in `Created` (what the site shows).
    /// @param metaURI   Metadata JSON URI (name, symbol, description, image, links): the token's `contractURI()` /
    ///                  `metaURI()`, fixed for good. Not checked on-chain; the CLI builds and uploads it.
    /// @param quote     WBNB (address(0)) or any 18-decimal ERC20. Fee-on-transfer quotes are rejected at the dev's
    ///                  mint (same tx).
    /// @param refPool   Pancake V2 pair / V3 pool pricing `quote`; ignored for WBNB or a QuoteRegistry override.
    /// @param devShares Shares the creator mints in the same call (≥ 1); needs quote approval beforehand.
    function create(
        string calldata name,
        string calldata symbol,
        string calldata logoURI,
        string calldata metaURI,
        address quote,
        address refPool,
        MintConfig calldata cfg,
        uint256 devShares
    ) external nonReentrant returns (address token) {
        if (address(migrator) == address(0)) revert MigratorNotSet();
        address gate = _currentGate();
        _requireAgent(gate, msg.sender);
        (bool ok, string memory reason) = checkConfig(cfg, devShares);
        if (!ok) revert BadConfig(reason);
        if (dividendVault.minimumShareBalanceOf(address(this)) > MIN_SHARE_BALANCE) revert VaultFloorTooHigh();

        if (quote == address(0)) quote = wbnb;
        _requireQuote(quote);
        (uint256 raiseQuote, address refUsed) = _toQuote(quote, refPool, cfg.raiseBnb);
        uint256 price = raiseQuote / TOTAL_SHARES;
        if (price == 0) revert PriceTooSmall();

        token = tokenDeployer.deployFair(name, symbol, taxHandler, metaURI);
        dividendVault.ensureMinimumShareBalance(MIN_SHARE_BALANCE);
        dividendVault.registerToken(token, quote);
        IGangTaxHandler(taxHandler).register(token, quote, address(0), 5000, 2);

        Sale storage s = sales[token];
        s.creator = msg.sender;
        s.capShares = _capShares(cfg.capBps).toUint16();
        s.holdBps = cfg.holdBps;
        s.mintFeeBps = cfg.mintFeeBps;
        s.exitFeeBps = cfg.exitFeeBps;
        s.quote = quote;
        s.gate = gate;
        s.sharePrice = price.toUint128();
        s.refPool = refUsed;
        logoURIOf[token] = logoURI;
        allTokens.push(token);

        emit Created(
            token,
            msg.sender,
            name,
            symbol,
            logoURI,
            quote,
            refUsed,
            cfg.raiseBnb,
            price,
            s.capShares,
            cfg.holdBps,
            cfg.mintFeeBps,
            cfg.exitFeeBps
        );
        _mint(token, s, msg.sender, devShares, devShares);
    }

    // ---------------------------------------------------------------- mint / withdraw
    /// @param minShares Revert if the last-fill truncation leaves fewer than this.
    function mint(address token, uint256 shares, uint256 minShares) external nonReentrant returns (uint256 accepted) {
        Sale storage s = _minting(token);
        _requireAgent(s.gate, msg.sender);
        if (shares == 0) revert ZeroAmount();
        accepted = _mint(token, s, msg.sender, shares, minShares);
    }

    /// @notice A listed router mints for `trader`: the router pays (cost + mint fee), the shares and tokens are the
    ///         trader's (a later withdraw pays the trader, never the router). Gate and cap: the trader's.
    function mintFor(address trader, address token, uint256 shares, uint256 minShares)
        external
        nonReentrant
        returns (uint256 accepted)
    {
        if (!routers[msg.sender]) revert OnlyRouter();
        Sale storage s = _minting(token);
        // ungated, a router could name any trader — e.g. the future pair, seeding it before launch to take the LP
        if (s.gate == address(0)) revert RouterNeedsGate();
        _requireAgent(s.gate, trader);
        if (shares == 0) revert ZeroAmount();
        accepted = _mint(token, s, trader, shares, minShares);
    }

    /// @notice Before the sale fills: sell `shares` back to the pad at the mint price, minus the exit fee (none once
    ///         the sale is stale). The mint fee paid is the platform's and is not returned.
    /// @param minPayout Reverts (Slippage) below this: a mint landing first can restart the stale clock and bring the
    ///        exit fee back (flow review F3). Use `previewWithdraw` for the expected payout.
    function withdraw(address token, uint256 shares, uint256 minPayout) external nonReentrant returns (uint256 payout) {
        Sale storage s = _minting(token);
        Position storage p = positions[token][msg.sender];
        if (shares == 0 || shares > p.shares) revert BadAmount();

        uint256 exitFee;
        (payout, exitFee) = _withdrawQuote(s, shares);
        if (payout < minPayout) revert Slippage();

        p.shares -= shares.toUint16();
        s.sold -= shares.toUint16();

        FairToken(token).reclaim(msg.sender, shares * TOKENS_PER_SHARE);
        _setShareOnExit(token, msg.sender, uint256(p.shares) * TOKENS_PER_SHARE);
        IERC20(s.quote).safeTransfer(msg.sender, payout);
        _exitFeeToPlatform(s.quote, exitFee);

        emit Withdrawn(token, msg.sender, shares, payout, exitFee, p.shares, s.sold);
    }

    /// @notice Send exit fees the bucket refused on to it, now that it accepts again. Anyone can call.
    function flushFees(address quote) external nonReentrant returns (uint256 amount) {
        amount = owedFee[quote];
        if (amount == 0) revert ZeroAmount();
        owedFee[quote] = 0;
        _toPlatform(quote, amount);
        emit FeesFlushed(quote, amount);
    }

    // ---------------------------------------------------------------- views
    function checkConfig(MintConfig calldata cfg, uint256 devShares)
        public
        pure
        returns (bool ok, string memory reason)
    {
        if (cfg.raiseBnb < MIN_RAISE_BNB || cfg.raiseBnb > MAX_RAISE_BNB) {
            return (false, "raiseBnb must be 5-50 BNB");
        }
        if (cfg.capBps < MIN_CAP_BPS || cfg.capBps > MAX_CAP_BPS) return (false, "capBps must be 25-50 (0.25%-0.5%)");
        if (cfg.holdBps < MIN_HOLD_BPS || cfg.holdBps > MAX_HOLD_BPS) return (false, "holdBps must be 3000-8000");
        if (cfg.mintFeeBps < MIN_FEE_BPS || cfg.mintFeeBps > MAX_MINT_FEE_BPS) {
            return (false, "mintFeeBps must be 100-300 (1%-3%)");
        }
        if (cfg.exitFeeBps < MIN_FEE_BPS || cfg.exitFeeBps > MAX_EXIT_FEE_BPS) {
            return (false, "exitFeeBps must be 100-200 (1%-2%)");
        }
        if (devShares == 0 || devShares > _capShares(cfg.capBps)) return (false, "devShares must be 1..cap");
        return (true, "");
    }

    /// @notice Raise in quote units and the per-share price `create` would lock. Reverts like `create`.
    function previewCreate(address quote, address refPool, uint256 raiseBnb)
        external
        view
        returns (uint256 raiseQuote, uint256 sharePrice)
    {
        if (quote == address(0)) quote = wbnb;
        (raiseQuote,) = _toQuote(quote, refPool, raiseBnb);
        sharePrice = raiseQuote / TOTAL_SHARES;
    }

    /// @notice What `mint(token, shares, 0)` by `user` would accept and cost right now (cost excludes fee).
    function previewMint(address token, address user, uint256 shares)
        external
        view
        returns (uint256 accepted, uint256 cost, uint256 fee)
    {
        Sale storage s = sales[token];
        if (status(token) != Status.Minting) return (0, 0, 0);
        accepted = _acceptable(s, positions[token][user].shares, shares);
        cost = accepted * s.sharePrice;
        fee = (cost * s.mintFeeBps) / BPS;
    }

    /// @notice What `withdraw(token, shares)` by `user` would pay out and charge right now (0, 0 if it would revert).
    function previewWithdraw(address token, address user, uint256 shares)
        external
        view
        returns (uint256 payout, uint256 fee)
    {
        Sale storage s = sales[token];
        if (status(token) != Status.Minting || shares == 0 || shares > positions[token][user].shares) return (0, 0);
        return _withdrawQuote(s, shares);
    }

    /// @notice The exit fee a withdraw pays now: the sale's own, or 0 once it has made no progress for STALE_AFTER.
    function exitFeeBpsOf(address token) external view returns (uint256) {
        return _exitFeeBps(sales[token]);
    }

    function status(address token) public view returns (Status) {
        Sale storage s = sales[token];
        if (s.creator == address(0)) return Status.None;
        if (s.launched) return Status.Launched;
        return Status.Minting;
    }

    /// @notice Tokens `user` held at launch (= minted shares × 50k). Reward rule input.
    function baselineOf(address token, address user) external view returns (uint256) {
        return uint256(positions[token][user].shares) * TOKENS_PER_SHARE;
    }

    function holdBpsOf(address token) external view returns (uint16) {
        return sales[token].holdBps;
    }

    /// @notice IGangPadView: every token of this pad is a Fair (2) token.
    function kindOf(address token) external view returns (uint8) {
        return sales[token].creator == address(0) ? 0 : 2;
    }

    function isAgent(address account) external view returns (bool) {
        if (!agentGateEnabled) return true;
        address gate = address(agentIdRegistry);
        return gate != address(0) && IERC721(gate).balanceOf(account) > 0;
    }

    function tokenCount() external view returns (uint256) {
        return allTokens.length;
    }

    // ---------------------------------------------------------------- internal
    /// @dev msg.sender pays (the trader itself, or a router); `trader` gets the shares and tokens.
    function _mint(address token, Sale storage s, address trader, uint256 want, uint256 minShares)
        internal
        returns (uint256 accepted)
    {
        Position storage p = positions[token][trader];
        if (p.shares >= s.capShares) revert WalletCapReached();
        accepted = _acceptable(s, p.shares, want);
        if (accepted == 0) revert ZeroAmount();
        if (accepted < minShares) revert Slippage();

        uint256 cost = accepted * s.sharePrice;
        uint256 fee = (cost * s.mintFeeBps) / BPS;
        _pullExact(s.quote, cost + fee);
        _toPlatform(s.quote, fee); // no refund, so nothing to escrow

        p.shares += accepted.toUint16();
        s.sold += accepted.toUint16();
        // only progress restarts the stale clock: the creator's mint, or `sold` up STALE_STEP since the last restart
        if (s.progressAt == 0 || s.sold >= uint256(s.markSold) + STALE_STEP) {
            s.progressAt = uint64(block.timestamp);
            s.markSold = s.sold;
        }

        IERC20(token).safeTransfer(trader, accepted * TOKENS_PER_SHARE);
        dividendVault.setShare(token, trader, uint256(p.shares) * TOKENS_PER_SHARE);
        emit Minted(token, trader, accepted, cost, fee, p.shares, s.sold);

        if (s.sold == TOTAL_SHARES) _launch(token, s);
    }

    function _acceptable(Sale storage s, uint256 held, uint256 want) internal view returns (uint256) {
        uint256 room = held >= s.capShares ? 0 : s.capShares - held;
        uint256 left = TOTAL_SHARES - s.sold;
        return Math.min(want, Math.min(room, left));
    }

    /// @dev Pad holds exactly LP_SUPPLY of the token here (all mint shares are out with minters).
    function _launch(address token, Sale storage s) internal {
        s.launched = true;
        FairToken t = FairToken(token);
        address quote = s.quote;
        uint256 quoteAmount = TOTAL_SHARES * s.sharePrice;

        // one-shot on the token: unlock + exclude the migrator, then the pair (tax and reward syncing start)
        t.unlock(address(migrator));
        IERC20(token).safeTransfer(address(migrator), LP_SUPPLY);
        IERC20(quote).safeTransfer(address(migrator), quoteAmount);
        address pair = migrator.migrate(token, quote, LP_SUPPLY, quoteAmount);
        s.pair = pair;
        t.setPair(pair);
        emit Launched(token, pair, quote, LP_SUPPLY, quoteAmount);
    }

    /// @dev Principal of `shares` at the mint price, less the exit fee in force now.
    function _withdrawQuote(Sale storage s, uint256 shares) internal view returns (uint256 payout, uint256 fee) {
        uint256 principal = shares * s.sharePrice;
        fee = (principal * _exitFeeBps(s)) / BPS;
        payout = principal - fee;
    }

    /// @dev Withdraw is the only way out of an unfilled sale, so a vault that refuses writes (its owner re-pointed
    ///      it) must not block it: the share is then left as is and corrected by the handler's first sync after launch.
    ///      A caller that starves the call (63/64 rule) to leave a stale share behind is refused instead.
    function _setShareOnExit(address token, address user, uint256 share) internal {
        uint256 gasBefore = gasleft();
        try dividendVault.setShare(token, user, share) {}
        catch {
            if (gasleft() <= gasBefore / 63) revert OutOfGas();
            emit ShareWriteFailed(token, user, share);
        }
    }

    /// @dev Withdraw must not depend on the fee sink either: a bucket that refuses the pad (its owner revoked it) leaves
    ///      the fee here as `owedFee`. The payout is the same either way, so starving this call gains the caller nothing.
    function _exitFeeToPlatform(address quote, uint256 fee) internal {
        if (fee == 0) return;
        IERC20(quote).forceApprove(address(platformBucket), fee);
        try platformBucket.notifyAccrual(quote, fee) {}
        catch {
            IERC20(quote).forceApprove(address(platformBucket), 0);
            owedFee[quote] += fee;
            emit FeeOwed(quote, fee);
        }
    }

    function _exitFeeBps(Sale storage s) internal view returns (uint256) {
        return block.timestamp >= uint256(s.progressAt) + STALE_AFTER ? 0 : s.exitFeeBps;
    }

    function _toPlatform(address quote, uint256 amount) internal {
        if (amount == 0) return;
        IERC20(quote).forceApprove(address(platformBucket), amount);
        platformBucket.notifyAccrual(quote, amount);
    }

    function _pullExact(address quote, uint256 amount) internal {
        uint256 before = IERC20(quote).balanceOf(address(this));
        IERC20(quote).safeTransferFrom(msg.sender, address(this), amount);
        if (IERC20(quote).balanceOf(address(this)) - before != amount) revert FeeOnTransferQuote();
    }

    function _minting(address token) internal view returns (Sale storage s) {
        s = sales[token];
        if (s.creator == address(0)) revert UnknownToken();
        if (s.launched) revert NotMinting();
    }

    function _currentGate() internal view returns (address) {
        if (!agentGateEnabled) return address(0);
        if (address(agentIdRegistry) == address(0)) revert NotAgent();
        return address(agentIdRegistry);
    }

    /// @dev WBNB, or any 18-decimal ERC-20 (6 decimals would round holder rewards to 0 in the shared vault), priced like
    ///      LaunchpadV2: a QuoteRegistry fixed rate when set, else the creator's reference pool (_toQuote).
    ///      2026-10-27 product decision: keep V2's reference-pool pricing (users are used to it), accepting internal
    ///      audit R2-1 again: a Pancake V2 pair (reserves) or a V3 pool without TWAP history is read at spot.
    ///      Fee-on-transfer quotes still fail at the first pull (_pullExact).
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

    function _requireAgent(address gate, address account) internal view {
        if (gate != address(0) && IERC721(gate).balanceOf(account) == 0) revert NotAgent();
    }

    function _capShares(uint16 capBps) internal pure returns (uint256) {
        return (uint256(capBps) * TOTAL_SUPPLY) / BPS / TOKENS_PER_SHARE;
    }

    function _cfg() internal view returns (PoolCheck.Cfg memory) {
        return PoolCheck.Cfg({wbnb: wbnb, v2Factory: pairFactory, v3Factory: v3Factory, twapWindow: twapWindow});
    }

    /// @dev `bnbAmount` in quote units. Same pricing rules as LaunchpadV2._lockGradAmt with the target = the raise:
    ///      WBNB → as is; QuoteRegistry override (quoted for 15 BNB) → scaled; else the dev's reference pool, bridged
    ///      through bridgePoolOf when its other side is not WBNB, with a ≥ 1 BNB depth floor.
    function _toQuote(address quote, address refPool, uint256 bnbAmount)
        internal
        view
        returns (uint256 amount, address refUsed)
    {
        if (quote == wbnb) return (bnbAmount, address(0));

        PoolCheck.Cfg memory cfg = _cfg();
        uint256 ov = quoteRegistry.graduationAmount(quote);
        if (ov > 0) {
            if (refPool != address(0)) PoolCheck.counterOf(PoolCheck.inspect(cfg, refPool), quote);
            return (Math.mulDiv(ov, bnbAmount, REGISTRY_REF_BNB), refPool);
        }

        if (refPool == address(0)) revert RefPoolRequired();
        PoolCheck.PoolInfo memory info = PoolCheck.inspect(cfg, refPool);
        address counter = PoolCheck.counterOf(info, quote);

        uint256 targetCounter;
        if (counter == wbnb) {
            targetCounter = bnbAmount;
        } else {
            address bridge = bridgePoolOf[counter];
            if (bridge == address(0)) revert NoBridgePool();
            PoolCheck.PoolInfo memory bInfo = PoolCheck.inspect(cfg, bridge);
            if (PoolCheck.counterOf(bInfo, counter) != wbnb) revert BridgeNotWbnb();
            targetCounter = PoolCheck.convert(cfg, bInfo, bridge, counter, bnbAmount);
        }

        uint256 minDepth = Math.mulDiv(targetCounter, MIN_REF_DEPTH_BNB, bnbAmount);
        if (PoolCheck.depthOf(info, refPool, counter) < minDepth) revert PoolCheck.ThinReferencePool();

        amount = PoolCheck.convert(cfg, info, refPool, quote, targetCounter);
        if (amount == 0) revert PoolCheck.GradAmtZero();
        refUsed = refPool;
    }
}
