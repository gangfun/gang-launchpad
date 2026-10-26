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
import {DividendVault} from "../launchpad-v2/DividendVault.sol";
import {PlatformFeeBucket} from "../launchpad-v2/PlatformFeeBucket.sol";
import {IMigratorV2} from "../launchpad-v2/interfaces/IMigratorV2.sol";
import {MigratorV2} from "../launchpad-v2/MigratorV2.sol";
import {PoolCheck} from "../launchpad-v2/PoolCheck.sol";
import {FairToken, FairTokenDeployer} from "./FairToken.sol";

/// @title FairMintPad (打新发射 · 铭文式打进度)
/// @notice No bonding curve. Half the supply is sold in 10,000 equal shares at one fixed price; when the last share
///         is minted, the other half plus all principal goes into a Pancake V2 pair (LP to 0xdead), so the opening
///         price equals the mint price. Unfilled at the deadline → everyone refunds principal + fee in full.
///         Mint and withdraw each cost a fee the creator sets at create (1%–5% each, e.g. mint 1% / withdraw 2%),
///         all to PlatformFeeBucket; mint fees are escrowed until launch.
/// @dev Spec: docs/SPEC-FAIR-MINT-2026-10-26.md. NO mainnet broadcast.
///      Each sale snapshots its rules at create (cap, gate, deadline, hold line): owner setters only affect new sales.
///      Escrowed principal / fees have no admin exit — only withdraw, refund, launch and the platform fee.
contract FairMintPad is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 public constant MINT_SUPPLY = 500_000_000 ether;
    uint256 public constant LP_SUPPLY = TOTAL_SUPPLY - MINT_SUPPLY;
    uint256 public constant TOTAL_SHARES = 10_000;
    uint256 public constant TOKENS_PER_SHARE = MINT_SUPPLY / TOTAL_SHARES; // 50_000 tokens
    uint256 public constant BPS = 10_000;
    uint16 public constant MIN_FEE_BPS = 100; // 1%: platform floor
    uint16 public constant MAX_FEE_BPS = 500; // 5%: a higher exit fee would trap minters

    uint256 public constant MIN_RAISE_BNB = 5 ether;
    uint256 public constant MAX_RAISE_BNB = 50 ether;
    /// @dev QuoteRegistry overrides are "15 BNB worth of quote" (V2 graduation target); scaled to the raise.
    uint256 public constant REGISTRY_REF_BNB = 15 ether;
    uint16 public constant MIN_CAP_BPS = 10; // 0.1% of supply → ≥ 500 addresses
    uint16 public constant MAX_CAP_BPS = 50; // 0.5% of supply → ≥ 100 addresses
    uint32 public constant MIN_DURATION = 1 hours;
    uint32 public constant MAX_DURATION = 72 hours;
    uint16 public constant MIN_HOLD_BPS = 3_000;
    uint16 public constant MAX_HOLD_BPS = 8_000;
    /// @dev Vault floor uses `<=`; must stay below 1 share × MIN_HOLD_BPS (15k tokens) or small minters earn nothing.
    uint256 public constant MIN_SHARE_BALANCE = 10_000 ether;
    uint256 public constant MIN_REF_DEPTH_BNB = 1 ether;

    struct MintConfig {
        uint256 raiseBnb; // BNB-equivalent; converted to quote units at create
        uint16 capBps; // per-address cap, share of total supply
        uint32 duration; // seconds until deadline
        uint16 holdBps; // reward line: out for good once balance < baseline × holdBps
        uint16 mintFeeBps; // on top of the principal at mint; refunded in full if the sale fails
        uint16 exitFeeBps; // taken from the principal on withdraw
    }

    struct Sale {
        address creator;
        uint64 deadline;
        uint16 capShares;
        uint16 holdBps;
        address quote;
        uint16 sold;
        bool launched;
        bool failed;
        uint16 mintFeeBps;
        uint16 exitFeeBps;
        address gate; // Agent ID registry snapshot; 0 = ungated
        uint128 sharePrice;
        uint128 escrowedFee;
        address pair;
        address refPool;
    }

    struct Position {
        uint16 shares;
        uint128 feePaid; // escrowed mint fee, refunded in full if the sale fails
    }

    enum Status {
        None,
        Minting,
        Launched,
        Failed
    }

    QuoteRegistry public immutable quoteRegistry;
    DividendVault public immutable dividendVault;
    PlatformFeeBucket public immutable platformBucket;
    address public immutable taxHandler;
    FairTokenDeployer public immutable tokenDeployer;
    address public immutable wbnb;
    address public immutable pairFactory;

    address public v3Factory;
    uint32 public twapWindow = 1800;
    mapping(address => address) public bridgePoolOf;
    IMigratorV2 public migrator;
    IERC721 public agentIdRegistry;
    bool public agentGateEnabled = true;
    /// @notice Stateless entry contracts (e.g. GangRouter) that may mint for a trader they pay for. A router only ever
    ///         spends its own quote: it can't withdraw, refund or claim for anyone (those stay msg.sender-only).
    mapping(address router => bool) public routers;

    mapping(address token => Sale) public sales;
    mapping(address token => mapping(address user => Position)) public positions;
    mapping(address token => string) public logoURIOf;
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
        uint256 deadline,
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
        uint256 refund,
        uint256 fee,
        uint256 userShares,
        uint256 sold
    );
    event Launched(
        address indexed token,
        address indexed pair,
        address quote,
        uint256 tokenAmount,
        uint256 quoteAmount,
        uint256 feeToPlatform
    );
    event Failed(address indexed token, uint256 sold);
    event Refunded(address indexed token, address indexed user, uint256 amount);
    event MigratorSet(address indexed migrator);
    event AgentGateUpdated(bool enabled, address registry);
    event V3FactorySet(address indexed factory);
    event TwapWindowUpdated(uint32 window);
    event BridgePoolSet(address indexed asset, address indexed pool);
    event RouterSet(address indexed router, bool enabled);

    error BadConfig(string reason);
    error UnknownToken();
    error NotMinting();
    error NotFailed();
    error ZeroAmount();
    error BadAmount();
    error Slippage();
    error WalletCapReached();
    error NothingToRefund();
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
        dividendVault = DividendVault(dividendVault_);
        platformBucket = PlatformFeeBucket(platformBucket_);
        taxHandler = taxHandler_;
        tokenDeployer = FairTokenDeployer(tokenDeployer_);
        wbnb = wbnb_;
        pairFactory = pairFactory_;
    }

    // ---------------------------------------------------------------- admin (new sales only)
    function setMigrator(address migrator_) external onlyOwner {
        if (address(migrator) != address(0)) revert MigratorAlreadySet();
        if (migrator_ == address(0)) revert ZeroAddress();
        // one-shot: a migrator bound to another pad would make every launch revert forever
        if (MigratorV2(migrator_).launchpad() != address(this)) revert WrongMigrator();
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
    /// @param quote     WBNB (address(0)) or a QuoteRegistry-enabled 18-decimal ERC20. Fee-on-transfer quotes are also
    ///                  rejected at mint.
    /// @param refPool   Pancake V2 pair / V3 pool pricing `quote`; ignored for WBNB or a QuoteRegistry override.
    /// @param devShares Shares the creator mints in the same call (≥ 1); needs quote approval beforehand.
    function create(
        string calldata name,
        string calldata symbol,
        string calldata logoURI,
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
        if (dividendVault.minimumShareBalance() > MIN_SHARE_BALANCE) revert VaultFloorTooHigh();

        if (quote == address(0)) quote = wbnb;
        _requireQuote(quote);
        (uint256 raiseQuote, address refUsed) = _toQuote(quote, refPool, cfg.raiseBnb);
        uint256 price = raiseQuote / TOTAL_SHARES;
        if (price == 0) revert PriceTooSmall();

        token = tokenDeployer.deploy(name, symbol, taxHandler, logoURI);
        dividendVault.ensureMinimumShareBalance(MIN_SHARE_BALANCE);
        dividendVault.registerToken(token, quote);

        Sale storage s = sales[token];
        s.creator = msg.sender;
        s.deadline = (block.timestamp + cfg.duration).toUint64();
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
            s.deadline,
            cfg.holdBps,
            cfg.mintFeeBps,
            cfg.exitFeeBps
        );
        _mint(token, s, msg.sender, devShares, devShares);
    }

    // ---------------------------------------------------------------- mint / withdraw / refund
    /// @param minShares Revert if the last-fill truncation leaves fewer than this.
    function mint(address token, uint256 shares, uint256 minShares) external nonReentrant returns (uint256 accepted) {
        Sale storage s = _minting(token);
        _requireAgent(s.gate, msg.sender);
        if (shares == 0) revert ZeroAmount();
        accepted = _mint(token, s, msg.sender, shares, minShares);
    }

    /// @notice A listed router mints for `trader`: the router pays (cost + mint fee), the shares, tokens and the fee
    ///         escrow are the trader's (a refund or withdraw pays the trader, never the router). Gate and cap: trader's.
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

    /// @notice Before fill and deadline: get principal − exit fee back. The fee paid at mint is kept by the platform.
    function withdraw(address token, uint256 shares) external nonReentrant returns (uint256 payout) {
        Sale storage s = _minting(token);
        Position storage p = positions[token][msg.sender];
        if (shares == 0 || shares > p.shares) revert BadAmount();

        uint256 principal = shares * s.sharePrice;
        uint256 exitFee = (principal * s.exitFeeBps) / BPS;
        payout = principal - exitFee;
        uint256 mintFee = shares == p.shares ? p.feePaid : (uint256(p.feePaid) * shares) / p.shares;

        p.shares -= shares.toUint16();
        p.feePaid -= mintFee.toUint128();
        s.sold -= shares.toUint16();
        s.escrowedFee -= mintFee.toUint128();

        FairToken(token).reclaim(msg.sender, shares * TOKENS_PER_SHARE);
        dividendVault.setShare(token, msg.sender, uint256(p.shares) * TOKENS_PER_SHARE);
        IERC20(s.quote).safeTransfer(msg.sender, payout);
        _toPlatform(s.quote, mintFee + exitFee);

        emit Withdrawn(token, msg.sender, shares, payout, mintFee + exitFee, p.shares, s.sold);
    }

    /// @notice Deadline passed without a fill: principal + mint fee back in full.
    function refund(address token) external nonReentrant returns (uint256 amount) {
        Sale storage s = sales[token];
        if (s.creator == address(0)) revert UnknownToken();
        if (s.launched || block.timestamp <= s.deadline) revert NotFailed();
        if (!s.failed) {
            s.failed = true;
            emit Failed(token, s.sold);
        }
        Position storage p = positions[token][msg.sender];
        uint256 shares = p.shares;
        if (shares == 0) revert NothingToRefund();

        uint256 fee = p.feePaid;
        amount = shares * s.sharePrice + fee;
        s.escrowedFee -= fee.toUint128();
        p.shares = 0;
        p.feePaid = 0;

        // no dividendVault.setShare: a failed sale never earns rewards, and refunds must not depend on the vault
        FairToken(token).reclaim(msg.sender, shares * TOKENS_PER_SHARE);
        IERC20(s.quote).safeTransfer(msg.sender, amount);
        emit Refunded(token, msg.sender, amount);
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
        if (cfg.capBps < MIN_CAP_BPS || cfg.capBps > MAX_CAP_BPS) return (false, "capBps must be 10-50 (0.1%-0.5%)");
        if (cfg.duration < MIN_DURATION || cfg.duration > MAX_DURATION) return (false, "duration must be 1-72 hours");
        if (cfg.holdBps < MIN_HOLD_BPS || cfg.holdBps > MAX_HOLD_BPS) return (false, "holdBps must be 3000-8000");
        if (cfg.mintFeeBps < MIN_FEE_BPS || cfg.mintFeeBps > MAX_FEE_BPS) {
            return (false, "mintFeeBps must be 100-500 (1%-5%)");
        }
        if (cfg.exitFeeBps < MIN_FEE_BPS || cfg.exitFeeBps > MAX_FEE_BPS) {
            return (false, "exitFeeBps must be 100-500 (1%-5%)");
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

    function status(address token) public view returns (Status) {
        Sale storage s = sales[token];
        if (s.creator == address(0)) return Status.None;
        if (s.launched) return Status.Launched;
        if (s.failed || block.timestamp > s.deadline) return Status.Failed;
        return Status.Minting;
    }

    /// @notice Tokens `user` held at launch (= minted shares × 50k). Reward rule input.
    function baselineOf(address token, address user) external view returns (uint256) {
        return uint256(positions[token][user].shares) * TOKENS_PER_SHARE;
    }

    function holdBpsOf(address token) external view returns (uint16) {
        return sales[token].holdBps;
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

        p.shares += accepted.toUint16();
        p.feePaid += fee.toUint128();
        s.sold += accepted.toUint16();
        s.escrowedFee += fee.toUint128();

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

        uint256 fee = s.escrowedFee;
        s.escrowedFee = 0;
        _toPlatform(quote, fee);
        emit Launched(token, pair, quote, LP_SUPPLY, quoteAmount, fee);
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
        if (s.launched || block.timestamp > s.deadline) revert NotMinting();
    }

    function _currentGate() internal view returns (address) {
        if (!agentGateEnabled) return address(0);
        if (address(agentIdRegistry) == address(0)) revert NotAgent();
        return address(agentIdRegistry);
    }

    /// @dev WBNB, or a QuoteRegistry-enabled 18-decimal quote WITH a fixed rate (graduationAmount > 0): no
    ///      fee-on-transfer / hook / low-decimal quotes (6 decimals would round holder rewards to 0 in DividendVault),
    ///      and no pricing from a creator-picked reference pool, whose spot price one flash swap can move by 1000×
    ///      within the create tx (2026-10-26 internal audit round 2). The multisig keeps the rate current.
    function _requireQuote(address quote) internal view {
        if (quote == wbnb) return;
        if (quoteRegistry.graduationAmount(quote) == 0 || IERC20Metadata(quote).decimals() != 18) {
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
