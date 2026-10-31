// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SharedDividendVault} from "../common/SharedDividendVault.sol";
import {SharedPlatformFeeBucket as PlatformFeeBucket} from "../common/SharedPlatformFeeBucket.sol";
import {IGangLaunchpad} from "./interfaces/IGangLaunchpad.sol";
import {IGangPadHandler, IGangPadToken, IGangTokenDeployer} from "./interfaces/IGangPadDeps.sol";
import {PadCommon} from "./PadCommon.sol";

/// @title FairLogic — GangLaunchpad's 打新 (fair mint) path
/// @notice External library: GangLaunchpad delegatecalls it, so it runs on the pad's storage, balance and msg.sender,
///         and its events come from the pad. FairMintPad's create / mint / withdraw / launch / flushFees, unchanged:
///         half the supply is sold in 10,000 equal shares at one fixed price, both ways; the last share launches the
///         pair. Each sale snapshots its rules at create (cap, gate, fees, hold line): owner setters only affect new
///         sales. Escrowed principal has no admin exit — only withdraw and launch move it.
/// @dev The asymmetries with the curve path are deliberate and kept (MERGE-PLAN §10.1 #3):
///      - gate: the sale's snapshot (`Sale.gate`), not the pad's current setting;
///      - mint fee blocking (`PadCommon.toPlatform`), exit fee non-blocking (`_exitFeeToPlatform` → `owedFee`, R3-2);
///      - mint share write blocking, withdraw share write guarded (`_setShareOnExit`, A-5 63/64 check, R3-3);
///      - VaultFloorTooHigh checked on every create, before anything else.
///      Reentrancy guard, the caller check of `mintFor` / `withdrawFor` (listed router, trader == tx.origin, §23)
///      and the A-2 `mintFor` check stay in the pad's wrappers.
library FairLogic {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    uint256 internal constant MINT_SUPPLY = 500_000_000 ether;
    uint256 internal constant LP_SUPPLY = PadCommon.TOTAL_SUPPLY - MINT_SUPPLY;
    uint256 internal constant TOTAL_SHARES = 10_000;
    uint256 internal constant TOKENS_PER_SHARE = MINT_SUPPLY / TOTAL_SHARES; // 50_000 tokens
    uint16 internal constant MIN_FEE_BPS = 100;
    uint16 internal constant MAX_MINT_FEE_BPS = 300;
    uint16 internal constant MAX_EXIT_FEE_BPS = 200;
    uint256 internal constant STALE_AFTER = 7 days;
    uint256 internal constant STALE_STEP = 10;
    uint256 internal constant MIN_RAISE_BNB = 5 ether;
    uint256 internal constant MAX_RAISE_BNB = 50 ether;
    /// @dev Per-wallet cap, % of TOTAL_SUPPLY: 0.25% (50 shares, ≥ 200 wallets) to 1% (200 shares, ≥ 50 wallets).
    uint16 internal constant MIN_CAP_BPS = 25;
    uint16 internal constant MAX_CAP_BPS = 100;
    /// @dev Hold line, % of the minted baseline: 60%–90%. 1 share × 60% = 30,000 tokens > MIN_SHARE (10,000).
    uint16 internal constant MIN_HOLD_BPS = 6_000;
    uint16 internal constant MAX_HOLD_BPS = 9_000;
    /// @dev 打新 tokens: 1% buy / 1% sell after launch; the handler gives holders HOLDER_SHARE (50%) of it.
    uint16 internal constant TAX_BPS = 100;
    uint16 internal constant HOLDER_SHARE_BPS = 5_000;
    uint8 internal constant KIND = 2;

    // ---------------------------------------------------------------- create
    function create(
        IGangLaunchpad.Config storage c,
        mapping(address => IGangLaunchpad.Sale) storage sales,
        mapping(address => mapping(address => IGangLaunchpad.Position)) storage positions,
        mapping(address => address) storage bridgePoolOf,
        IGangLaunchpad.Deps memory d,
        string calldata name,
        string calldata symbol,
        string calldata logoURI,
        string calldata metaURI,
        address quote,
        address refPool,
        IGangLaunchpad.MintConfig calldata cfg,
        uint256 devShares
    ) external returns (address token) {
        if (c.migrator == address(0)) revert IGangLaunchpad.MigratorNotSet();
        address gate = _currentGate(c);
        _requireAgent(gate, msg.sender);
        (bool ok, string memory reason) = checkConfig(cfg, devShares);
        if (!ok) revert IGangLaunchpad.BadConfig(reason);
        SharedDividendVault vault = SharedDividendVault(d.dividendVault);
        if (vault.minimumShareBalanceOf(address(this)) > PadCommon.MIN_SHARE) {
            revert IGangLaunchpad.VaultFloorTooHigh();
        }

        if (quote == address(0)) quote = d.wbnb;
        PadCommon.requireQuote(d, quote);
        (uint256 raiseQuote, address refUsed) = PadCommon.toQuote(c, bridgePoolOf, d, quote, refPool, cfg.raiseBnb);
        if (raiseQuote > PadCommon.MAX_QUOTE_AMOUNT) revert IGangLaunchpad.QuoteAmountTooLarge();
        uint256 price = raiseQuote / TOTAL_SHARES;
        if (price == 0) revert IGangLaunchpad.PriceTooSmall();

        token = IGangTokenDeployer(d.tokenDeployer).deploy(name, symbol, metaURI, d.taxHandler, TAX_BPS, TAX_BPS, true);
        vault.ensureMinimumShareBalance(PadCommon.MIN_SHARE);
        vault.registerToken(token, quote);
        IGangPadHandler(d.taxHandler).register(token, quote, address(0), HOLDER_SHARE_BPS, KIND);

        IGangLaunchpad.Sale storage s = sales[token];
        s.creator = msg.sender;
        s.capShares = capShares(cfg.capBps).toUint16();
        s.holdBps = cfg.holdBps;
        s.mintFeeBps = cfg.mintFeeBps;
        s.exitFeeBps = cfg.exitFeeBps;
        s.quote = quote;
        s.gate = gate;
        s.sharePrice = price.toUint128();
        s.refPool = refUsed;

        _emitCreated(token, name, symbol, logoURI, quote, refUsed, cfg, price, s.capShares);
        _mint(c, s, positions[token][msg.sender], d, token, msg.sender, devShares, devShares);
    }

    function _emitCreated(
        address token,
        string calldata name,
        string calldata symbol,
        string calldata logoURI,
        address quote,
        address refUsed,
        IGangLaunchpad.MintConfig calldata cfg,
        uint256 price,
        uint256 cap
    ) private {
        emit IGangLaunchpad.Created(
            token,
            msg.sender,
            name,
            symbol,
            logoURI,
            quote,
            refUsed,
            cfg.raiseBnb,
            price,
            cap,
            cfg.holdBps,
            cfg.mintFeeBps,
            cfg.exitFeeBps
        );
    }

    // ---------------------------------------------------------------- mint / withdraw
    /// @dev msg.sender pays (the trader itself, or a router the pad checked); `trader` gets the shares and tokens.
    function mint(
        IGangLaunchpad.Config storage c,
        mapping(address => IGangLaunchpad.Sale) storage sales,
        mapping(address => mapping(address => IGangLaunchpad.Position)) storage positions,
        IGangLaunchpad.Deps memory d,
        address trader,
        address token,
        uint256 shares,
        uint256 minShares
    ) external returns (uint256 accepted) {
        IGangLaunchpad.Sale storage s = minting(sales, token);
        _requireAgent(s.gate, trader);
        if (shares == 0) revert IGangLaunchpad.ZeroAmount();
        accepted = _mint(c, s, positions[token][trader], d, token, trader, shares, minShares);
    }

    /// @dev `trader`'s shares are sold back; the payout goes to msg.sender. Direct `withdraw`: trader = msg.sender,
    ///      `viaCaller` false, the pad `reclaim`s the tokens (no allowance, as before). `withdrawFor`: the pad checked
    ///      the caller (a listed router) and trader == tx.origin, `viaCaller` true, the tokens move with the trader's
    ///      allowance to the caller (`GangToken.pullFor`; the token is locked while the sale is minting). No gate,
    ///      like `withdraw`: it is the only way out of an unfilled sale.
    function withdraw(
        mapping(address => IGangLaunchpad.Sale) storage sales,
        mapping(address => mapping(address => IGangLaunchpad.Position)) storage positions,
        mapping(address => uint256) storage owedFee,
        IGangLaunchpad.Deps memory d,
        address trader,
        bool viaCaller,
        address token,
        uint256 shares,
        uint256 minPayout
    ) external returns (uint256 payout) {
        IGangLaunchpad.Sale storage s = minting(sales, token);
        IGangLaunchpad.Position storage p = positions[token][trader];
        if (shares == 0 || shares > p.shares) revert IGangLaunchpad.BadAmount();

        uint256 exitFee;
        (payout, exitFee) = withdrawQuote(s, shares);
        if (payout < minPayout) revert IGangLaunchpad.Slippage();

        p.shares -= shares.toUint16();
        s.sold -= shares.toUint16();

        if (viaCaller) IGangPadToken(token).pullFor(trader, msg.sender, shares * TOKENS_PER_SHARE);
        else IGangPadToken(token).reclaim(msg.sender, shares * TOKENS_PER_SHARE);
        _setShareOnExit(d, token, trader, uint256(p.shares) * TOKENS_PER_SHARE);
        address quote = s.quote;
        IERC20(quote).safeTransfer(msg.sender, payout);
        _exitFeeToPlatform(owedFee, d, quote, exitFee);

        emit IGangLaunchpad.Withdrawn(token, trader, shares, payout, exitFee, p.shares, s.sold);
    }

    /// @notice Send exit fees the bucket refused on to it, now that it accepts again (blocking). Anyone can call.
    function flushFees(mapping(address => uint256) storage owedFee, IGangLaunchpad.Deps memory d, address quote)
        external
        returns (uint256 amount)
    {
        amount = owedFee[quote];
        if (amount == 0) revert IGangLaunchpad.ZeroAmount();
        owedFee[quote] = 0;
        PadCommon.toPlatform(d, quote, amount);
        emit IGangLaunchpad.FeesFlushed(quote, amount);
    }

    // ---------------------------------------------------------------- views
    /// @notice Raise in quote units and the per-share price `create` would lock. Reverts like `create`.
    function previewCreate(
        IGangLaunchpad.Config storage c,
        mapping(address => address) storage bridgePoolOf,
        IGangLaunchpad.Deps memory d,
        address quote,
        address refPool,
        uint256 raiseBnb
    ) external view returns (uint256 raiseQuote, uint256 sharePrice) {
        if (quote == address(0)) quote = d.wbnb;
        (raiseQuote,) = PadCommon.toQuote(c, bridgePoolOf, d, quote, refPool, raiseBnb);
        if (raiseQuote > PadCommon.MAX_QUOTE_AMOUNT) revert IGangLaunchpad.QuoteAmountTooLarge();
        sharePrice = raiseQuote / TOTAL_SHARES;
    }

    // ---------------------------------------------------------------- internal (also inlined into the pad's views)
    function checkConfig(IGangLaunchpad.MintConfig calldata cfg, uint256 devShares)
        internal
        pure
        returns (bool ok, string memory reason)
    {
        if (cfg.raiseBnb < MIN_RAISE_BNB || cfg.raiseBnb > MAX_RAISE_BNB) {
            return (false, "raiseBnb must be 5-50 BNB");
        }
        if (cfg.capBps < MIN_CAP_BPS || cfg.capBps > MAX_CAP_BPS) return (false, "capBps must be 25-100 (0.25%-1%)");
        if (cfg.holdBps < MIN_HOLD_BPS || cfg.holdBps > MAX_HOLD_BPS) return (false, "holdBps must be 6000-9000");
        if (cfg.mintFeeBps < MIN_FEE_BPS || cfg.mintFeeBps > MAX_MINT_FEE_BPS) {
            return (false, "mintFeeBps must be 100-300 (1%-3%)");
        }
        if (cfg.exitFeeBps < MIN_FEE_BPS || cfg.exitFeeBps > MAX_EXIT_FEE_BPS) {
            return (false, "exitFeeBps must be 100-200 (1%-2%)");
        }
        if (devShares == 0 || devShares > capShares(cfg.capBps)) return (false, "devShares must be 1..cap");
        return (true, "");
    }

    function capShares(uint16 capBps) internal pure returns (uint256) {
        return (uint256(capBps) * PadCommon.TOTAL_SUPPLY) / PadCommon.BPS / TOKENS_PER_SHARE;
    }

    function acceptable(IGangLaunchpad.Sale storage s, uint256 held, uint256 want) internal view returns (uint256) {
        uint256 room = held >= s.capShares ? 0 : s.capShares - held;
        uint256 left = TOTAL_SHARES - s.sold;
        return Math.min(want, Math.min(room, left));
    }

    /// @dev Principal of `shares` at the mint price, less the exit fee in force now.
    function withdrawQuote(IGangLaunchpad.Sale storage s, uint256 shares)
        internal
        view
        returns (uint256 payout, uint256 fee)
    {
        uint256 principal = shares * s.sharePrice;
        fee = (principal * exitFeeBps(s)) / PadCommon.BPS;
        payout = principal - fee;
    }

    function exitFeeBps(IGangLaunchpad.Sale storage s) internal view returns (uint256) {
        return block.timestamp >= uint256(s.progressAt) + STALE_AFTER ? 0 : s.exitFeeBps;
    }

    function minting(mapping(address => IGangLaunchpad.Sale) storage sales, address token)
        internal
        view
        returns (IGangLaunchpad.Sale storage s)
    {
        s = sales[token];
        if (s.creator == address(0)) revert IGangLaunchpad.UnknownToken();
        if (s.launched) revert IGangLaunchpad.NotMinting();
    }

    // ---------------------------------------------------------------- private
    function _mint(
        IGangLaunchpad.Config storage c,
        IGangLaunchpad.Sale storage s,
        IGangLaunchpad.Position storage p,
        IGangLaunchpad.Deps memory d,
        address token,
        address trader,
        uint256 want,
        uint256 minShares
    ) private returns (uint256 accepted) {
        if (p.shares >= s.capShares) revert IGangLaunchpad.WalletCapReached();
        accepted = acceptable(s, p.shares, want);
        if (accepted == 0) revert IGangLaunchpad.ZeroAmount();
        if (accepted < minShares) revert IGangLaunchpad.Slippage();

        address quote = s.quote;
        uint256 cost = accepted * s.sharePrice;
        uint256 fee = (cost * s.mintFeeBps) / PadCommon.BPS;
        PadCommon.pullExact(quote, cost + fee);
        PadCommon.toPlatform(d, quote, fee); // blocking; no refund, so nothing to escrow

        p.shares += accepted.toUint16();
        s.sold += accepted.toUint16();
        // R3-1: only progress restarts the stale clock — the creator's mint, or `sold` up STALE_STEP since the last
        // restart (a 1-share mint or a withdraw-and-remint can't keep the waiver off)
        if (s.progressAt == 0 || s.sold >= uint256(s.markSold) + STALE_STEP) {
            s.progressAt = uint64(block.timestamp);
            s.markSold = s.sold;
        }

        IERC20(token).safeTransfer(trader, accepted * TOKENS_PER_SHARE);
        SharedDividendVault(d.dividendVault).setShare(token, trader, uint256(p.shares) * TOKENS_PER_SHARE);
        emit IGangLaunchpad.Minted(token, trader, accepted, cost, fee, p.shares, s.sold);

        if (s.sold == TOTAL_SHARES) _launch(c, s, token);
    }

    /// @dev The pad holds exactly LP_SUPPLY of the token here (all mint shares are out with minters), and exactly this
    ///      sale's escrow (TOTAL_SHARES × price) leaves — never another sale's or a curve's quote (§5.4).
    function _launch(IGangLaunchpad.Config storage c, IGangLaunchpad.Sale storage s, address token) private {
        s.launched = true;
        address quote = s.quote;
        uint256 quoteAmount = TOTAL_SHARES * s.sharePrice;
        address pair = PadCommon.migrate(c, token, quote, LP_SUPPLY, quoteAmount, true);
        s.pair = pair;
        emit IGangLaunchpad.Launched(token, pair, quote, LP_SUPPLY, quoteAmount);
    }

    /// @dev Withdraw is the only way out of an unfilled sale, so a vault that refuses writes (its owner re-pointed
    ///      it) must not block it: the share is then left as is and corrected by the handler's first sync after launch.
    ///      A caller that starves the call (63/64 rule) to leave a stale share behind is refused instead (A-5).
    function _setShareOnExit(IGangLaunchpad.Deps memory d, address token, address user, uint256 share) private {
        uint256 gasBefore = gasleft();
        try SharedDividendVault(d.dividendVault).setShare(token, user, share) {}
        catch {
            if (gasleft() <= gasBefore / 63) revert IGangLaunchpad.OutOfGas();
            emit IGangLaunchpad.ShareWriteFailed(token, user, share);
        }
    }

    /// @dev Withdraw must not depend on the fee sink either (R3-2): a bucket that refuses the pad (its owner revoked
    ///      it) leaves the fee here as `owedFee`. The payout is the same either way, so starving this call gains the
    ///      caller nothing.
    function _exitFeeToPlatform(
        mapping(address => uint256) storage owedFee,
        IGangLaunchpad.Deps memory d,
        address quote,
        uint256 fee
    ) private {
        if (fee == 0) return;
        IERC20(quote).forceApprove(d.platformBucket, fee);
        try PlatformFeeBucket(d.platformBucket).notifyAccrual(quote, fee) {}
        catch {
            IERC20(quote).forceApprove(d.platformBucket, 0);
            owedFee[quote] += fee;
            emit IGangLaunchpad.FeeOwed(quote, fee);
        }
    }

    /// @dev The gate a new sale snapshots: the pad's registry while the gate is on, 0 (ungated) while it is off.
    function _currentGate(IGangLaunchpad.Config storage c) private view returns (address) {
        if (!c.agentGateEnabled) return address(0);
        address reg = c.agentIdRegistry;
        if (reg == address(0)) revert IGangLaunchpad.NotAgent();
        return reg;
    }

    /// @dev Against the sale's snapshot, not the pad's current setting.
    function _requireAgent(address gate, address account) private view {
        if (gate != address(0) && IERC721(gate).balanceOf(account) == 0) revert IGangLaunchpad.NotAgent();
    }
}
