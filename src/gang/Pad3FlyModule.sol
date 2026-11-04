// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IGangLaunchpad} from "./interfaces/IGangLaunchpad.sol";
import {IGangLaunchpad3} from "./interfaces/IGangLaunchpad3.sol";
import {IFlywheelPad} from "../flywheel/interfaces/IFlywheelPad.sol";
import {FlywheelLogic} from "../flywheel/FlywheelLogic.sol";
import {FlywheelPostLogic} from "../flywheel/FlywheelPostLogic.sol";
import {FlywheelOracle} from "../flywheel/FlywheelOracle.sol";
import {Pad3FlyStore} from "./Pad3FlyStore.sol";
import {Pad3VaultStore} from "./Pad3VaultStore.sol";
import {IGangVaultPad} from "./interfaces/IGangVaultPad.sol";

interface IPad3MintRoom {
    function mintRoom() external view returns (uint256);
}

interface IPad3Wbnb {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/// @title Pad3FlyModule — GangLaunchpad 3.0's 铸币飞轮 mode (GangFlywheelPad V2's rules, on the one 3.0 address)
/// @notice Never called directly: Pad3Module's fallback delegatecalls it (itself delegatecalled by the pad's fallback
///         and, for a 铸币飞轮 token, by the pad's and Pad3Module's views / calls shared by name with 打新), so it runs
///         in the proxy's storage, with the proxy's balance and the caller as msg.sender. Every external function and
///         selector of GangFlywheelPad V2 (create / mint / mintFor / mintWithBnb / withdraw / withdrawFor / openEarly /
///         launch / mintPost / mintPostFor / mintPostWithBnb / claimDev and its views, `sales(token)` returning V2's
///         `IFlywheelPad.Sale`), through the same FlywheelLogic / FlywheelPostLogic code, plus the aggregator entry for
///         3.0's own 铸币飞轮 tokens (GangGateway V2's 铸币飞轮 rules, as LegacyRoute applies them to V1 / V2 tokens).
///         The pad's admin (router list, gate, migrator, bridge pools, TWAP window) and the views it shares with V2
///         (`isAgent`, `tokenCount`, `migrator`, …) are the pad's own.
/// @dev STORAGE: slots 0–2 are OZ Ownable / Ownable2Step / ReentrancyGuard (the pad's), then a mirror of GangLaunchpad3's
///      variables in its order (test/gang3/GangLaunchpad3Layout.t.sol checks it slot by slot); the 铸币飞轮 state is
///      in Pad3FlyStore's namespace. Its own three dependencies are immutables: the 铸币飞轮 tax handler (a
///      FlywheelTaxHandler whose launchpad is the 3.0 proxy, bound in the shared vault as the operator of the vault
///      core), V2's MintTokenDeployer (listing 3.0) and the vault core (Pad3FlyVaultCore: the tokens' core in the
///      shared vault, FlywheelLogic's `dividendVault`); quote registry, bucket and WBNB equal the pad's (the deploy /
///      upgrade scripts check them).
///      Routers: `mintFor` / `withdrawFor` / `mintPostFor` take only the routers the owner listed for this mode
///      (`setFlyRouter`), not the pad's router list: code written for the pad's other kinds sizes shares by the pad's
///      `TOKENS_PER_SHARE` (50,000), half a 铸币飞轮 share (audit B M-1).
contract Pad3FlyModule is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant TOTAL_SHARES = FlywheelLogic.TOTAL_SHARES;
    uint256 internal constant TPS = FlywheelLogic.TOKENS_PER_SHARE;
    uint8 internal constant KIND = FlywheelLogic.KIND;
    /// @notice Must equal GangLaunchpad3.TOKEN_VERSION (the scripts and tests check it).
    uint8 public constant TOKEN_VERSION = 1;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAX_FEE_RATE = 500;
    uint8 internal constant STATUS_CURVE = 1;
    uint8 internal constant STATUS_POOL = 2;
    uint8 internal constant STATUS_MINTING = 3;

    event FlyRouterSet(address indexed router, bool enabled);

    // ---------------------------------------------------------------- mirror of GangLaunchpad3's layout (slot 3 on)
    IGangLaunchpad.Config internal _config;
    mapping(address => address) internal bridgePoolOf;
    mapping(address router => bool) internal routers;
    mapping(address token => uint8) internal kindOf;
    mapping(address token => IGangLaunchpad.Curve) internal curves;
    mapping(address token => IGangLaunchpad.Sale) internal _sales;
    mapping(address token => mapping(address user => IGangLaunchpad.Position)) internal positions;
    mapping(address token => string) internal logoURIOf;
    mapping(address quote => uint256) internal owedFee;
    address[] internal allTokens;
    mapping(address token => uint256) internal creatorFeeOf;
    mapping(address token => uint256) internal gradTargetOf;
    mapping(address token => uint8) internal tokenVersionOf;
    mapping(address caller => bool) internal isCaller;

    // ---------------------------------------------------------------- dependencies
    address internal immutable quoteRegistry;
    address internal immutable platformBucket;
    /// @notice The 铸币飞轮 tax handler of 3.0's 铸币飞轮 tokens (a FlywheelTaxHandler, launchpad = the 3.0 proxy).
    address public immutable flyTaxHandler;
    /// @notice The MintTokenDeployer 3.0's 铸币飞轮 tokens are deployed by (it lists the 3.0 proxy).
    address public immutable flyTokenDeployer;
    /// @notice The vault core 3.0's 铸币飞轮 tokens are registered under (Pad3FlyVaultCore; FlywheelLogic's vault).
    address public immutable flyVaultCore;
    address internal immutable wbnb;

    constructor(
        address quoteRegistry_,
        address platformBucket_,
        address flyTaxHandler_,
        address flyTokenDeployer_,
        address flyVaultCore_,
        address wbnb_
    ) Ownable(address(0xdEaD)) {
        if (
            quoteRegistry_ == address(0) || platformBucket_ == address(0) || flyTaxHandler_ == address(0)
                || flyTokenDeployer_ == address(0) || flyVaultCore_ == address(0) || wbnb_ == address(0)
        ) revert IFlywheelPad.ZeroAddress();
        quoteRegistry = quoteRegistry_;
        platformBucket = platformBucket_;
        flyTaxHandler = flyTaxHandler_;
        flyTokenDeployer = flyTokenDeployer_;
        flyVaultCore = flyVaultCore_;
        wbnb = wbnb_;
    }

    /// @notice List or delist a router for this mode's `mintFor` / `withdrawFor` / `mintPostFor` (none by default): one
    ///         that sizes a 铸币飞轮 share as 100,000 tokens (`shareSizeOf`). Same rules as the pad's `setRouter`.
    function setFlyRouter(address router, bool enabled) external onlyOwner {
        if (router == address(0)) revert IGangLaunchpad.ZeroAddress();
        if (enabled) {
            // a plain contract (not an EIP-7702 wallet), never one ever listed as a vault
            uint256 size = router.code.length;
            if (size == 0 || (size == 23 && bytes3(router.code) == 0xef0100)) revert IGangLaunchpad3.NotAContract();
            if (Pad3VaultStore.layout().everVault[router]) revert IGangVaultPad.VaultIsRouter();
        }
        Pad3FlyStore.layout().routers[router] = enabled;
        emit FlyRouterSet(router, enabled);
    }

    function flyRouters(address router) external view returns (bool) {
        return Pad3FlyStore.layout().routers[router];
    }

    /// @notice This module's dependencies as FlywheelLogic gets them (`dividendVault`: the vault core).
    function flyDeps() external view returns (IGangLaunchpad.Deps memory) {
        return _deps();
    }

    // ---------------------------------------------------------------- create / pre-launch (V2's)
    /// @param text     name, symbol, logoURI (site), metaURI (the token's contractURI, fixed)
    /// @param quote    WBNB (address(0)) or any 18-decimal ERC-20
    /// @param refPool  pool pricing a non-BNB quote (ignored for WBNB or a QuoteRegistry rate)
    /// @param devShares shares the creator mints in the same call (1..min(baseQuota, maxPerTx)); approve the quote first
    function create(
        string[4] calldata text,
        address quote,
        address refPool,
        IFlywheelPad.FlyConfig calldata cfg,
        uint256 devShares
    ) external nonReentrant returns (address token) {
        // never one of the pad's own tokens (curve, 打新, 铸币飞轮): PadCommon's filter checks the 铸币飞轮 token
        // deployer and the vault, not the pad's TokenDeployer (audit A I-1)
        if (kindOf[quote] != 0) revert IGangLaunchpad.QuoteNotAllowed();
        Pad3FlyStore.Layout storage f = Pad3FlyStore.layout();
        token = FlywheelLogic.create(
            _config,
            f.sales,
            f.accounts,
            f.owedDev,
            f.postRulesOf,
            bridgePoolOf,
            _deps(),
            text,
            quote,
            refPool,
            cfg,
            devShares
        );
        // the pad's record of every token (GangLaunchpad3._record)
        kindOf[token] = KIND;
        tokenVersionOf[token] = TOKEN_VERSION;
        emit IGangLaunchpad3.TokenVersionSet(token, TOKEN_VERSION);
        logoURIOf[token] = text[2];
        allTokens.push(token);
    }

    function mint(address token, uint256 shares, uint256 minShares, address referrer)
        external
        nonReentrant
        returns (uint256 spent)
    {
        Pad3FlyStore.Layout storage f = Pad3FlyStore.layout();
        spent = FlywheelLogic.mint(
            _config, f.sales, f.accounts, f.owedDev, _deps(), msg.sender, token, shares, minShares, referrer, 0
        );
    }

    function mintFor(address trader, address token, uint256 shares, uint256 minShares, address referrer)
        external
        nonReentrant
        returns (uint256 spent)
    {
        _forTrader(trader, token);
        Pad3FlyStore.Layout storage f = Pad3FlyStore.layout();
        spent = FlywheelLogic.mint(
            _config, f.sales, f.accounts, f.owedDev, _deps(), trader, token, shares, minShares, referrer, 0
        );
    }

    function mintWithBnb(address token, uint256 shares, uint256 minShares, address referrer)
        external
        payable
        nonReentrant
        returns (uint256 spent)
    {
        _wrap(token);
        Pad3FlyStore.Layout storage f = Pad3FlyStore.layout();
        spent = FlywheelLogic.mint(
            _config, f.sales, f.accounts, f.owedDev, _deps(), msg.sender, token, shares, minShares, referrer, msg.value
        );
        _refund(spent);
    }

    /// @notice Reached through the pad's `withdraw` for a 铸币飞轮 token (same selector as 打新's).
    function withdraw(address token, uint256 shares, uint256 minPayout) external nonReentrant returns (uint256 payout) {
        Pad3FlyStore.Layout storage f = Pad3FlyStore.layout();
        payout =
            FlywheelLogic.withdraw(f.sales, f.accounts, owedFee, _deps(), msg.sender, false, token, shares, minPayout);
    }

    /// @notice Reached through the pad's `withdrawFor` for a 铸币飞轮 token.
    function withdrawFor(address trader, address token, uint256 shares, uint256 minPayout)
        external
        nonReentrant
        returns (uint256 payout)
    {
        _forTrader(trader, token);
        Pad3FlyStore.Layout storage f = Pad3FlyStore.layout();
        payout = FlywheelLogic.withdraw(f.sales, f.accounts, owedFee, _deps(), trader, true, token, shares, minPayout);
    }

    function openEarly(address token) external nonReentrant {
        Pad3FlyStore.Layout storage f = Pad3FlyStore.layout();
        FlywheelLogic.openEarly(_config, f.sales, f.owedDev, _deps(), token);
    }

    function launch(address token) external nonReentrant {
        Pad3FlyStore.Layout storage f = Pad3FlyStore.layout();
        FlywheelLogic.launch(_config, f.sales, f.owedDev, _deps(), token);
    }

    // ---------------------------------------------------------------- post-launch (V2's)
    function mintPost(address token, uint256 shares, uint256 minTokensOut, uint256 maxSpent, address referrer)
        external
        nonReentrant
        returns (uint256 tokensOut, uint256 spent)
    {
        (tokensOut, spent) = _mintPost(msg.sender, token, shares, minTokensOut, maxSpent, referrer, 0);
    }

    function mintPostFor(
        address trader,
        address token,
        uint256 shares,
        uint256 minTokensOut,
        uint256 maxSpent,
        address referrer
    ) external nonReentrant returns (uint256 tokensOut, uint256 spent) {
        _forTrader(trader, token);
        (tokensOut, spent) = _mintPost(trader, token, shares, minTokensOut, maxSpent, referrer, 0);
    }

    function mintPostWithBnb(address token, uint256 shares, uint256 minTokensOut, address referrer)
        external
        payable
        nonReentrant
        returns (uint256 tokensOut, uint256 spent)
    {
        _wrap(token);
        // msg.value bounds the spend (BnbShort)
        (tokensOut, spent) = _mintPost(msg.sender, token, shares, minTokensOut, type(uint256).max, referrer, msg.value);
        _refund(spent);
    }

    function _mintPost(
        address trader,
        address token,
        uint256 shares,
        uint256 minTokensOut,
        uint256 maxSpent,
        address referrer,
        uint256 bnbIn
    ) internal returns (uint256 tokensOut, uint256 spent) {
        Pad3FlyStore.Layout storage f = Pad3FlyStore.layout();
        (tokensOut, spent) = FlywheelPostLogic.mintPost(
            f.sales,
            f.accounts,
            f.owedDev,
            f.postRulesOf,
            _deps(),
            trader,
            token,
            shares,
            minTokensOut,
            maxSpent,
            referrer,
            bnbIn
        );
    }

    // ---------------------------------------------------------------- owed (V2's; exit fees: the pad's `flushFees`)
    function claimDev(address token) external nonReentrant returns (uint256 amount) {
        Pad3FlyStore.Layout storage f = Pad3FlyStore.layout();
        amount = f.owedDev[token];
        if (amount == 0) revert IFlywheelPad.NothingOwed();
        f.owedDev[token] = 0;
        IFlywheelPad.Sale storage s = f.sales[token];
        IERC20(s.quote).safeTransfer(s.creator, amount);
        emit IFlywheelPad.DevPaid(token, s.creator, amount);
    }

    // ---------------------------------------------------------------- views (V2's)
    /// @notice V2's `sales(token)` (reached through the pad's `sales` for a 铸币飞轮 token).
    function sales(address token) external view returns (IFlywheelPad.Sale memory) {
        return Pad3FlyStore.layout().sales[token];
    }

    function accounts(address token, address user) external view returns (IFlywheelPad.Account memory) {
        return Pad3FlyStore.layout().accounts[token][user];
    }

    function owedDev(address token) external view returns (uint256) {
        return Pad3FlyStore.layout().owedDev[token];
    }

    function postRulesOf(address token) external view returns (uint16 guardBps, uint32 twapWindow) {
        IFlywheelPad.PostRules memory r = Pad3FlyStore.layout().postRulesOf[token];
        return (r.guardBps, r.twapWindow);
    }

    /// @notice Reached through the pad's `baselineOf` (the 铸币飞轮 handler reads it).
    function baselineOf(address token, address user) external view returns (uint256) {
        return Pad3FlyStore.layout().accounts[token][user].baseline;
    }

    /// @notice Reached through the pad's `holdBpsOf`.
    function holdBpsOf(address token) external view returns (uint16) {
        return Pad3FlyStore.layout().sales[token].holdBps;
    }

    function quotaLeft(address token, address user) external view returns (uint256) {
        Pad3FlyStore.Layout storage f = Pad3FlyStore.layout();
        IFlywheelPad.Sale storage s = f.sales[token];
        IFlywheelPad.Account storage a = f.accounts[token][user];
        uint256 quota = uint256(s.baseQuota) + a.bonus;
        return a.used >= quota ? 0 : quota - a.used;
    }

    function sharePrice(address token, uint256 shares) external view returns (uint256) {
        IFlywheelPad.Sale storage s = Pad3FlyStore.layout().sales[token];
        if (!s.launched) return s.basePrice;
        return (uint256(s.basePrice) * FlywheelPostLogic.tierX100(s, uint256(s.totalShares) + shares)) / 100;
    }

    /// @notice Reached through Pad3Module's `previewMint` for a 铸币飞轮 token.
    function previewMint(address token, address user, uint256 shares)
        public
        view
        returns (uint256 accepted, uint256 cost, uint256 fee)
    {
        Pad3FlyStore.Layout storage f = Pad3FlyStore.layout();
        IFlywheelPad.Sale storage s = f.sales[token];
        if (s.creator == address(0) || s.launched || s.filledAt != 0) return (0, 0, 0);
        if (!_gatePasses(s.gate, user)) return (0, 0, 0);
        accepted = FlywheelLogic._acceptable(s, f.accounts[token][user], shares, TOTAL_SHARES - s.sold);
        cost = accepted * s.basePrice;
        fee = (cost * s.mintFeeBps) / BPS;
    }

    /// @notice Reached through Pad3Module's `previewWithdraw` for a 铸币飞轮 token.
    function previewWithdraw(address token, address user, uint256 shares)
        external
        view
        returns (uint256 payout, uint256 fee)
    {
        Pad3FlyStore.Layout storage f = Pad3FlyStore.layout();
        IFlywheelPad.Sale storage s = f.sales[token];
        if (!FlywheelLogic.withdrawable(s)) return (0, 0);
        if (shares == 0 || shares > f.accounts[token][user].preShares) return (0, 0);
        uint256 principal = shares * s.basePrice;
        fee = (principal * FlywheelLogic.exitFeeBps(s)) / BPS;
        payout = principal - fee;
    }

    function previewMintPost(address token, address user, uint256 shares)
        public
        view
        returns (uint256 accepted, uint256 paid, uint256 fee, uint256 tokensOut, bool ok)
    {
        Pad3FlyStore.Layout storage f = Pad3FlyStore.layout();
        IFlywheelPad.Sale storage s = f.sales[token];
        if (!s.launched || !s.postMint || !_gatePasses(s.gate, user)) return (0, 0, 0, 0, false);
        IFlywheelPad.Account storage a = f.accounts[token][user];
        accepted = FlywheelLogic._acceptable(s, a, shares, type(uint256).max);
        if (accepted == 0) return (0, 0, 0, 0, false);
        paid = (accepted * s.basePrice * FlywheelPostLogic.tierX100(s, uint256(s.totalShares) + accepted)) / 100;
        fee = (paid * s.mintFeeBps) / BPS;
        FlywheelPostLogic.Pricing memory p =
            FlywheelPostLogic.pricing(flyTaxHandler, token, s.pair, f.postRulesOf[token]);
        tokensOut = Math.mulDiv(paid, 1 << 112, p.price);
        if (p.belowAverage || p.abovePool) return (accepted, paid, fee, tokensOut, false);
        if ((FlywheelPostLogic.recentSpent(a) + paid) * BPS > p.rQ * FlywheelPostLogic.PACE_POOL_BPS) {
            return (accepted, paid, fee, tokensOut, false);
        }
        uint256 net = paid - (user == s.creator ? 0 : (paid * s.devCutBps) / BPS);
        uint256 minted = FlywheelPostLogic.newlyMinted(p, s.pair, token, s.quote, s.buyBps, net, tokensOut);
        ok = minted <= IPad3MintRoom(token).mintRoom();
    }

    /// @notice Reached through Pad3Module's `exitFeeBpsOf` for a 铸币飞轮 token.
    function exitFeeBpsOf(address token) external view returns (uint256) {
        return FlywheelLogic.exitFeeBps(Pad3FlyStore.layout().sales[token]);
    }

    /// @notice V2's `checkConfig(FlyConfig, devShares)` (a different selector from 打新's).
    function checkConfig(IFlywheelPad.FlyConfig calldata cfg, uint256 devShares)
        external
        view
        returns (bool ok, string memory)
    {
        string memory reason = FlywheelLogic.checkConfig(cfg, devShares);
        if (bytes(reason).length == 0 && !_config.agentGateEnabled) {
            if (cfg.devCutBps != 0) reason = "devCutBps must be 0 when ungated";
            else if (cfg.postMint) reason = "postMint needs the Agent ID gate";
        }
        return (bytes(reason).length == 0, reason);
    }

    function prices(address token)
        external
        view
        returns (uint256 spot, uint256 blockStart, uint256 high, uint256 average)
    {
        Pad3FlyStore.Layout storage f = Pad3FlyStore.layout();
        address pair = f.sales[token].pair;
        if (pair == address(0)) revert IFlywheelPad.NotLaunched();
        spot = FlywheelOracle.spotOf(pair, token);
        blockStart = FlywheelOracle.blockStart(flyTaxHandler, token, spot);
        high = FlywheelOracle.recentHigh(flyTaxHandler, token);
        average = FlywheelOracle.twap(flyTaxHandler, token, pair, f.postRulesOf[token].twapWindow);
    }

    // ---------------------------------------------------------------- aggregator entry for 3.0's 铸币飞轮 tokens
    // Reached through the pad's entry functions for a kind-3 token (before their guards run). GangGateway V2's
    // 铸币飞轮 rules, as LegacyRoute applies them to V1 / V2 tokens, here on 3.0's own: before launch a buy mints whole
    // shares (at the base price plus the mint fee) and a sell sells whole shares back; after launch, a sale with
    // post-launch minting mints through the entry (status 2: the pool also trades it), any other is not traded here.
    // An ungated sale is not traded here (status 3; A-2).

    function getTokenInfo(address token)
        public
        view
        returns (uint8 status, address quote, address pair, uint256 protocolFeeBps, uint256 graduationLeft)
    {
        IFlywheelPad.Sale storage s = Pad3FlyStore.layout().sales[token];
        quote = s.quote == wbnb ? address(0) : s.quote;
        if (s.launched) return (STATUS_POOL, quote, s.pair, 0, 0);
        if (s.gate == address(0)) return (STATUS_MINTING, quote, address(0), 0, 0);
        return (STATUS_CURVE, quote, address(0), s.mintFeeBps, (TOTAL_SHARES - s.sold) * s.basePrice);
    }

    /// @notice As the pad's `tryBuy`; a 铸币飞轮 quote needs the trader (quota, invites): 0s for address(0).
    function tryBuy(address token, address trader, uint256 amount, uint256 funds)
        external
        view
        returns (
            address tokenManager,
            address quote,
            uint256 estimatedAmount,
            uint256 estimatedCost,
            uint256 estimatedFee,
            uint256 amountMsgValue,
            uint256 amountApproval,
            uint256 amountFunds
        )
    {
        if (amount != 0) revert IGangLaunchpad3.AmountNotSupported();
        tokenManager = address(this);
        (, quote,,,) = getTokenInfo(token);
        (, estimatedAmount, estimatedCost, estimatedFee) = _quote(token, trader, funds);
        if (estimatedAmount == 0) return (tokenManager, quote, 0, 0, 0, 0, 0, 0);
        // whole shares: send exactly their cost
        if (quote == address(0)) amountMsgValue = estimatedCost;
        else amountApproval = estimatedCost;
        amountFunds = estimatedCost;
    }

    function trySell(address token, uint256 amount)
        external
        view
        returns (address tokenManager, address quote, uint256 funds, uint256 fee)
    {
        tokenManager = address(this);
        (, quote,,,) = getTokenInfo(token);
        IFlywheelPad.Sale storage s = Pad3FlyStore.layout().sales[token];
        uint256 shares = _wholeShares(amount);
        if (shares == 0 || shares > s.sold || s.gate == address(0) || !FlywheelLogic.withdrawable(s)) {
            return (tokenManager, quote, 0, 0);
        }
        uint256 principal = shares * s.basePrice;
        fee = (principal * FlywheelLogic.exitFeeBps(s)) / BPS;
        funds = principal - fee;
    }

    function buyTokenAMAP(address token, address to, uint256 funds, uint256 minAmount)
        external
        payable
        nonReentrant
        returns (uint256 amountOut, uint256 fundsUsed)
    {
        if (to != tx.origin) revert IGangLaunchpad.TraderNotOrigin();
        Pad3FlyStore.Layout storage f = Pad3FlyStore.layout();
        IFlywheelPad.Sale storage s = f.sales[token];
        if (s.launched && !s.postMint) revert IGangLaunchpad3.NotCurveToken();
        if (s.gate == address(0)) revert IGangLaunchpad.RouterNeedsGate();
        IERC20 quote = IERC20(s.quote);
        _payIn(address(quote), funds);
        uint256 before = IERC20(token).balanceOf(to);
        if (!s.launched) {
            uint256 shares = _sharesFor(s, funds);
            if (shares == 0) revert IGangLaunchpad3.FundsTooLow();
            fundsUsed = FlywheelLogic.mint(
                _config,
                f.sales,
                f.accounts,
                f.owedDev,
                _deps(),
                to,
                token,
                shares,
                Math.ceilDiv(minAmount, TPS),
                address(0),
                funds
            );
        } else {
            (uint256 shares,,,, bool affordable) = _postMintQuote(s, token, to, funds);
            if (!affordable) revert IGangLaunchpad3.FundsTooLow();
            (, fundsUsed) = _mintPost(to, token, shares == 0 ? 1 : shares, minAmount, funds, address(0), funds);
        }
        if (funds > fundsUsed) quote.safeTransfer(to, funds - fundsUsed);
        // what `to` received (the token is locked: it moves only from the pad)
        amountOut = IERC20(token).balanceOf(to) - before;
        if (amountOut < minAmount) revert IGangLaunchpad.Slippage();
        emit IGangLaunchpad3.GatewayBuy(token, to, msg.sender, fundsUsed, amountOut);
    }

    function sellToken(
        uint256 origin,
        address token,
        address from,
        uint256 amount,
        uint256 minFunds,
        uint256 feeRate,
        address feeRecipient
    ) external nonReentrant returns (uint256 fundsToSeller) {
        origin;
        _entryCaller(from);
        if (feeRate > MAX_FEE_RATE) revert IGangLaunchpad3.FeeRateTooHigh();
        (address quote, uint256 funds) = _entrySell(token, from, amount);
        uint256 fee = (funds * feeRate) / BPS;
        fundsToSeller = funds - fee;
        if (fundsToSeller < minFunds) revert IGangLaunchpad.Slippage();
        if (fee > 0 && (feeRecipient == address(0) || feeRecipient == address(this) || feeRecipient == wbnb)) {
            revert IGangLaunchpad3.ZeroFeeRecipient();
        }
        if (quote == wbnb) {
            IPad3Wbnb(wbnb).withdraw(funds);
            _sendBnb(feeRecipient, fee);
            _sendBnb(from, fundsToSeller);
        } else {
            if (fee > 0) IERC20(quote).safeTransfer(feeRecipient, fee);
            IERC20(quote).safeTransfer(from, fundsToSeller);
        }
        emit IGangLaunchpad3.GatewaySell(token, from, msg.sender, amount, funds, fundsToSeller, fee, feeRecipient);
    }

    function sellToken(uint256 origin, address token, address from, address to, uint256 amount, uint256 minFunds)
        external
        nonReentrant
        returns (uint256 funds)
    {
        origin;
        if (to != msg.sender || !isCaller[to] || to == address(this) || to == wbnb) {
            revert IGangLaunchpad3.RecipientNotListed();
        }
        _entryCaller(from);
        address quote;
        (quote, funds) = _entrySell(token, from, amount);
        if (funds < minFunds) revert IGangLaunchpad.Slippage();
        if (quote == wbnb) {
            IPad3Wbnb(wbnb).withdraw(funds);
            _sendBnb(to, funds);
        } else {
            IERC20(quote).safeTransfer(to, funds);
        }
        emit IGangLaunchpad3.GatewaySellTo(token, from, to, msg.sender, amount, funds);
    }

    // ---------------------------------------------------------------- internal: entry
    function _entryCaller(address from) internal view {
        if (from != msg.sender && !isCaller[msg.sender]) revert IGangLaunchpad3.NotWhitelisted();
        if (from != tx.origin) revert IGangLaunchpad.TraderNotOrigin();
    }

    /// @dev Whole shares of `from` back before launch, with `from`'s allowance to the pad; the payout stays here.
    function _entrySell(address token, address from, uint256 amount) internal returns (address quote, uint256 funds) {
        Pad3FlyStore.Layout storage f = Pad3FlyStore.layout();
        IFlywheelPad.Sale storage s = f.sales[token];
        if (s.launched) revert IGangLaunchpad3.NotCurveToken();
        if (s.gate == address(0)) revert IGangLaunchpad.RouterNeedsGate();
        uint256 shares = _wholeShares(amount);
        if (shares == 0) revert IGangLaunchpad3.NotWholeShares();
        quote = s.quote;
        funds = FlywheelLogic.entryWithdraw(f.sales, f.accounts, owedFee, _deps(), from, token, shares);
    }

    /// @dev (shares, tokens out, cost incl. fee, fee) a buy of `funds` gets now: before launch the most whole shares
    ///      at the base price; after launch (post-launch minting on) the largest mint `previewMintPost` accepts.
    function _quote(address token, address trader, uint256 funds)
        internal
        view
        returns (uint256 shares, uint256 amountOut, uint256 cost, uint256 fee)
    {
        IFlywheelPad.Sale storage s = Pad3FlyStore.layout().sales[token];
        if (trader == address(0) || s.creator == address(0) || s.gate == address(0)) return (0, 0, 0, 0);
        if (!s.launched) {
            uint256 want = _sharesFor(s, funds);
            if (want == 0) return (0, 0, 0, 0);
            uint256 price;
            (shares, price, fee) = previewMint(token, trader, want);
            if (shares == 0) return (0, 0, 0, 0);
            return (shares, shares * TPS, price + fee, fee);
        }
        if (!s.postMint) return (0, 0, 0, 0);
        (shares, amountOut, cost, fee,) = _postMintQuote(s, token, trader, funds);
    }

    /// @dev LegacyRoute's `_postMint`, on this pad's own sale.
    function _postMintQuote(IFlywheelPad.Sale storage s, address token, address trader, uint256 funds)
        internal
        view
        returns (uint256 shares, uint256 amountOut, uint256 cost, uint256 fee, bool affordable)
    {
        uint256 want = _sharesFor(s, funds);
        if (want > s.maxPerTx) want = s.maxPerTx;
        while (want != 0) {
            (uint256 accepted, uint256 paid, uint256 mintFee, uint256 out, bool ok) =
                previewMintPost(token, trader, want);
            if (accepted == 0) return (0, 0, 0, 0, true);
            if (paid + mintFee <= funds) {
                if (ok) return (accepted, out, paid + mintFee, mintFee, true);
                affordable = true;
            }
            want = accepted - 1;
        }
    }

    function _sharesFor(IFlywheelPad.Sale storage s, uint256 funds) internal view returns (uint256 n) {
        if (funds > type(uint128).max) funds = type(uint128).max;
        uint256 unit = s.basePrice;
        n = (funds * BPS) / (unit * (BPS + s.mintFeeBps));
        uint256 c = (n + 1) * unit;
        if (c + (c * s.mintFeeBps) / BPS <= funds) n++;
    }

    function _wholeShares(uint256 amount) internal pure returns (uint256) {
        if (amount == 0 || amount % TPS != 0) return 0;
        return amount / TPS;
    }

    function _payIn(address quote, uint256 funds) internal {
        if (quote == wbnb) {
            if (msg.value != funds) revert IGangLaunchpad3.BadMsgValue();
            IPad3Wbnb(wbnb).deposit{value: funds}();
        } else {
            if (msg.value != 0) revert IGangLaunchpad3.BadMsgValue();
            uint256 before = IERC20(quote).balanceOf(address(this));
            IERC20(quote).safeTransferFrom(msg.sender, address(this), funds);
            if (IERC20(quote).balanceOf(address(this)) - before != funds) revert IGangLaunchpad.FeeOnTransferQuote();
        }
    }

    function _sendBnb(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert IGangLaunchpad3.BnbTransferFailed();
    }

    // ---------------------------------------------------------------- internal (V2's)
    function _gatePasses(address gate, address user) internal view returns (bool) {
        return gate == address(0) || IERC721(gate).balanceOf(user) > 0;
    }

    function _forTrader(address trader, address token) internal view {
        if (!Pad3FlyStore.layout().routers[msg.sender]) revert IGangLaunchpad.OnlyRouter();
        if (trader != tx.origin) revert IGangLaunchpad.TraderNotOrigin();
        if (Pad3FlyStore.layout().sales[token].gate == address(0)) revert IGangLaunchpad.RouterNeedsGate();
    }

    function _deps() internal view returns (IGangLaunchpad.Deps memory) {
        return IGangLaunchpad.Deps({
            quoteRegistry: quoteRegistry,
            dividendVault: flyVaultCore,
            platformBucket: platformBucket,
            taxHandler: flyTaxHandler,
            tokenDeployer: flyTokenDeployer,
            wbnb: wbnb
        });
    }

    function _wrap(address token) internal {
        if (Pad3FlyStore.layout().sales[token].quote != wbnb) revert IFlywheelPad.BnbNotQuote();
        if (msg.value == 0) revert IFlywheelPad.ZeroAmount();
        IPad3Wbnb(wbnb).deposit{value: msg.value}();
    }

    function _refund(uint256 spent) internal {
        uint256 back = msg.value - spent;
        if (back == 0) return;
        IPad3Wbnb(wbnb).withdraw(back);
        (bool ok,) = msg.sender.call{value: back}("");
        if (!ok) {
            IPad3Wbnb(wbnb).deposit{value: back}();
            IERC20(wbnb).safeTransfer(msg.sender, back);
        }
    }
}
