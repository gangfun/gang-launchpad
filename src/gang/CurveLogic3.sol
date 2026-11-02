// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SharedDividendVault} from "../common/SharedDividendVault.sol";
import {IGangLaunchpad} from "./interfaces/IGangLaunchpad.sol";
import {IGangLaunchpad3} from "./interfaces/IGangLaunchpad3.sol";
import {IGangPadHandler, IGangPadToken, IGangTokenDeployer} from "./interfaces/IGangPadDeps.sol";
import {PadCommon} from "./PadCommon.sol";

/// @title CurveLogic3 — GangLaunchpad 3.0's bonding-curve path: CurveLogic (2.0) with the entries 3.0's own
///        aggregator interface needs, the curve's math and rules unchanged
/// @notice External library, delegatecalled by GangLaunchpad3 (runs on the pad's storage, balance and msg.sender;
///         events come from the pad). Same create / buy / sell / graduation / creator fee as CurveLogic, line for
///         line, with four additions (SPEC-GANG-PAD-3 §18.2):
///         1. `buy(..., prepaid)`: the pad already holds `quoteIn` (native BNB it wrapped, or quote it pulled itself),
///            so the exact pull from msg.sender is skipped;
///         2. `sell(..., pull, payTo)`: whose allowance moves the tokens (PULL_CALLER: msg.sender's own, as 2.0's
///            `sell`; PULL_ROUTER: the trader's to the calling router, as 2.0's `sellFor`; PULL_PAD: the trader's to
///            the pad, 3.0's four.meme-style `sellToken`) and who receives the quote (`payTo`);
///         3. `quoteBuy` / `quoteSell`: views of what a buy / sell would do now (the aggregator quotes);
///         4. `TradeV1` on every trade, with the creator's part of the fee and the price after the trade.
/// @dev The reentrancy guard and every caller check (listed router, trader == tx.origin, the A-2 gate, a pull from
///      the trader only for the wallet that sent the tx) stay in the pad's wrappers. Not callable directly.
library CurveLogic3 {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    uint256 internal constant CURVE_SUPPLY = 800_000_000 ether;
    uint256 internal constant VIRTUAL_TOKEN = 1_066_666_666_666_666_666_666_666_667;
    uint256 internal constant MAX_PER_WALLET = 10_000_000 ether; // 1% of TOTAL_SUPPLY
    uint256 internal constant PROTOCOL_FEE_BPS = 100;
    /// @dev The creator's part of the protocol fee (70%, as pons); the rest (30%) is the platform's.
    uint256 internal constant CREATOR_FEE_SHARE_BPS = 7_000;
    uint16 internal constant MIN_TAX_BPS = 100;
    uint16 internal constant MAX_TAX_BPS = 500;
    uint256 internal constant MIN_GRAD_AMT = 1e6;
    /// @dev Graduation targets a creator may pick, in BNB raised: 6 / 9 / 12 / 15 (MIN to MAX in STEPs; graduation
    ///      market cap = 5x the raise: curve shape fixed, virtual quote = target / 3). 2.0 default 9 BNB (1.0: always
    ///      15). The one definition: `isGradTier` and the pad's GRAD_BNB_TIERS both read it.
    uint256 internal constant MIN_GRAD_BNB = 6 ether;
    uint256 internal constant MAX_GRAD_BNB = 15 ether;
    uint256 internal constant GRAD_BNB_STEP = 3 ether;
    uint256 internal constant DEFAULT_GRAD_BNB = 9 ether;
    uint8 internal constant KIND = 1;
    /// @dev `sell`'s `pull`: msg.sender's tokens with its allowance to the pad (2.0 `sell`).
    uint8 internal constant PULL_CALLER = 0;
    /// @dev the trader's tokens with its allowance to msg.sender, a listed router (`GangToken.pullFor`, 2.0 `sellFor`).
    uint8 internal constant PULL_ROUTER = 1;
    /// @dev the trader's tokens with its allowance to the pad (3.0 `sellToken`; the pad checked trader == tx.origin).
    uint8 internal constant PULL_PAD = 2;

    struct BuyVars {
        uint256 protocolFee;
        uint256 net;
        uint256 refundGross;
        uint256 gradAmt;
        uint256 tokensOut;
    }

    // ---------------------------------------------------------------- create
    function create(
        IGangLaunchpad.Config storage c,
        mapping(address => IGangLaunchpad.Curve) storage curves,
        mapping(address => address) storage bridgePoolOf,
        IGangLaunchpad.Deps memory d,
        string calldata name,
        string calldata symbol,
        string calldata logoURI,
        string calldata metaURI,
        address quote,
        address refPool,
        IGangLaunchpad.TaxConfig calldata tax,
        uint256 gradBnb
    ) external returns (address token) {
        if (c.migrator == address(0)) revert IGangLaunchpad.MigratorNotSet();
        if (!isGradTier(gradBnb)) revert IGangLaunchpad.BadGradTarget();
        _requireAgent(c, msg.sender);
        string memory reason = checkTax(d, msg.sender, tax);
        if (bytes(reason).length != 0) revert IGangLaunchpad.BadTaxConfig(reason);

        if (quote == address(0)) quote = d.wbnb;
        PadCommon.requireQuote(d, quote);
        (uint256 lockedGrad, address refUsed) = PadCommon.toQuote(c, bridgePoolOf, d, quote, refPool, gradBnb);
        if (lockedGrad < MIN_GRAD_AMT) revert IGangLaunchpad.GradAmtTooSmall();
        if (lockedGrad > PadCommon.MAX_QUOTE_AMOUNT) revert IGangLaunchpad.QuoteAmountTooLarge();

        if (tax.buyTaxBps == 0) {
            token = IGangTokenDeployer(d.tokenDeployer).deploy(name, symbol, metaURI, address(0), 0, 0, false);
        } else {
            token = _createTaxed(d, name, symbol, metaURI, quote, tax);
        }

        _writeCurve(curves[token], token, quote, lockedGrad, tax, refUsed);

        emit IGangLaunchpad.Created(token, msg.sender, name, symbol, logoURI, quote, refUsed, lockedGrad);
        emit IGangLaunchpad.TaxConfigured(token, tax.buyTaxBps, tax.sellTaxBps, tax.dividendBps, tax.recipient);
        emit IGangLaunchpad.GradTargetSet(token, gradBnb);
    }

    /// @dev 6 / 9 / 12 / 15 BNB (GRAD_BNB_TIERS).
    function isGradTier(uint256 gradBnb) internal pure returns (bool) {
        return gradBnb >= MIN_GRAD_BNB && gradBnb <= MAX_GRAD_BNB && (gradBnb - MIN_GRAD_BNB) % GRAD_BNB_STEP == 0;
    }

    function _createTaxed(
        IGangLaunchpad.Deps memory d,
        string calldata name,
        string calldata symbol,
        string calldata uri,
        address quote,
        IGangLaunchpad.TaxConfig calldata tax
    ) private returns (address token) {
        token = IGangTokenDeployer(d.tokenDeployer)
            .deploy(name, symbol, uri, d.taxHandler, tax.buyTaxBps, tax.sellTaxBps, false);
        if (tax.dividendBps > 0) {
            SharedDividendVault vault = SharedDividendVault(d.dividendVault);
            // internal audit 5 C-F4: a floor the vault owner raised above TAXED_MIN_SHARE would leave the new token with
            // no shareholders and send the holders' part of its tax elsewhere. Checked only for a dividend token, after
            // the token is deployed (打新 checks it on every create, before anything else).
            if (vault.minimumShareBalanceOf(address(this)) > PadCommon.MIN_SHARE) {
                revert IGangLaunchpad.VaultFloorTooHigh();
            }
            vault.ensureMinimumShareBalance(PadCommon.MIN_SHARE);
            vault.registerToken(token, quote);
        }
        IGangPadHandler(d.taxHandler).register(token, quote, tax.recipient, tax.dividendBps, KIND);
    }

    /// @dev Empty string = valid. The recipient is the creator itself (no listing needed) or a whitelisted address
    ///      (2026-10-27, AUDIT-BRIEF §22). `creator` = 0 means "unknown": only the whitelist counts (the pad's old
    ///      `checkTaxConfig(tax)`); a zero recipient never matches it, the branch above handles that case.
    function checkTax(IGangLaunchpad.Deps memory d, address creator, IGangLaunchpad.TaxConfig calldata tax)
        public
        view
        returns (string memory)
    {
        if (tax.buyTaxBps == 0 && tax.sellTaxBps == 0) {
            if (tax.dividendBps != 0 || tax.recipient != address(0)) {
                return "untaxed: dividendBps / recipient must be empty";
            }
            return "";
        }
        if (
            tax.buyTaxBps < MIN_TAX_BPS || tax.buyTaxBps > MAX_TAX_BPS || tax.sellTaxBps < MIN_TAX_BPS
                || tax.sellTaxBps > MAX_TAX_BPS
        ) return "buyTaxBps and sellTaxBps must each be 100-500 (1%-5%)";
        if (tax.dividendBps > PadCommon.BPS) return "dividendBps > 10000";
        if (tax.recipient == address(0)) {
            if (tax.dividendBps != PadCommon.BPS) return "no recipient: dividendBps must be 10000";
            return "";
        }
        if (tax.recipient != creator && !IGangPadHandler(d.taxHandler).isListed(tax.recipient)) {
            return "recipient not listed";
        }
        return "";
    }

    function _writeCurve(
        IGangLaunchpad.Curve storage cv,
        address token,
        address quote,
        uint256 lockedGrad,
        IGangLaunchpad.TaxConfig calldata tax,
        address refPair
    ) private {
        uint256 vq = lockedGrad / 3;
        if (vq == 0) revert IGangLaunchpad.ZeroAmount();
        cv.creator = msg.sender;
        cv.quote = quote;
        cv.gradAmt = lockedGrad.toUint128();
        cv.virtualQuote = vq.toUint128();
        cv.buyTaxBps = tax.buyTaxBps;
        cv.sellTaxBps = tax.sellTaxBps;
        cv.dividendBps = tax.dividendBps;
        cv.refPair = refPair;
        emit IGangLaunchpad.VirtualQuoteLocked(token, vq);
    }

    // ---------------------------------------------------------------- buy
    /// @dev msg.sender pays (the trader itself, or a router the pad checked); `trader` receives the tokens and any
    ///      refund of the cut (in the quote ERC-20, §23). `locked`: what `trader` holds in the token's vault (vault
    ///      pad, SPEC-VAULT-LOCK §3.5), counted against the 1% cap like the wallet balance; 0 on a plain pad.
    function buy(
        IGangLaunchpad.Config storage c,
        mapping(address => IGangLaunchpad.Curve) storage curves,
        mapping(address => uint256) storage creatorFeeOf,
        IGangLaunchpad.Deps memory d,
        address trader,
        address token,
        uint256 quoteIn,
        uint256 minTokensOut,
        uint256 locked,
        bool prepaid
    ) external returns (uint256 tokensOut) {
        IGangLaunchpad.Curve storage cv = _live(curves, token);
        if (quoteIn == 0) revert IGangLaunchpad.ZeroAmount();
        _requireAgent(c, trader);

        BuyVars memory v = _prepBuy(c, cv, token, trader, quoteIn, locked);
        if (v.tokensOut < minTokensOut) revert IGangLaunchpad.Slippage();

        tokensOut = _execBuy(c, cv, creatorFeeOf, d, token, trader, quoteIn, v, prepaid);
    }

    function _prepBuy(
        IGangLaunchpad.Config storage c,
        IGangLaunchpad.Curve storage cv,
        address token,
        address trader,
        uint256 quoteIn,
        uint256 locked
    ) private view returns (BuyVars memory v) {
        bool capped = c.walletCapEnabled;
        uint256 room = walletRoom(capped, token, trader, locked);
        if (capped && room == 0) revert IGangLaunchpad.WalletCapReached();

        _applyFee(quoteIn, v);
        v.gradAmt = cv.gradAmt;
        uint256 remaining = v.gradAmt - cv.realQuote;

        if (v.net > remaining) {
            v.net = remaining;
            _recomputeFee(quoteIn, v);
            if (v.net > remaining) v.net = remaining;
        }

        v.tokensOut = _tokensOut(cv, v.net);
        if (capped && v.tokensOut > room) {
            v.tokensOut = room;
            v.net = _quoteInFor(cv, room);
            _recomputeFee(quoteIn, v);
        }
    }

    /// @dev The curve's only charge: 1% of the gross (no tax on the curve, 2026-10-27), split by `_syncShareAndFee`.
    function _applyFee(uint256 gross, BuyVars memory v) private pure {
        v.protocolFee = (gross * PROTOCOL_FEE_BPS) / PadCommon.BPS;
        v.net = gross - v.protocolFee;
    }

    function _recomputeFee(uint256 quoteIn, BuyVars memory v) private pure {
        uint256 spentGross = Math.ceilDiv(v.net * PadCommon.BPS, PadCommon.BPS - PROTOCOL_FEE_BPS);
        if (spentGross > quoteIn) spentGross = quoteIn;
        _applyFee(spentGross, v);
        v.refundGross = quoteIn - spentGross;
    }

    function _execBuy(
        IGangLaunchpad.Config storage c,
        IGangLaunchpad.Curve storage cv,
        mapping(address => uint256) storage creatorFeeOf,
        IGangLaunchpad.Deps memory d,
        address token,
        address trader,
        uint256 quoteIn,
        BuyVars memory v,
        bool prepaid
    ) private returns (uint256 tokensOut) {
        address quoteAddr = cv.quote;
        if (!prepaid) PadCommon.pullExact(quoteAddr, quoteIn);

        cv.realQuote += v.net.toUint128();
        cv.sold += v.tokensOut.toUint128();

        IERC20(token).safeTransfer(trader, v.tokensOut);
        uint256 creatorFee = _syncShareAndFee(cv, creatorFeeOf, d, token, trader, quoteAddr, v.protocolFee);

        // `tax` stays in the event (ABI unchanged for indexers): always 0, the curve charges none
        emit IGangLaunchpad.Buy(token, trader, v.net, v.protocolFee, 0, v.tokensOut, cv.realQuote);
        emit IGangLaunchpad3.TradeV1(
            token,
            trader,
            true,
            v.net + v.protocolFee,
            v.tokensOut,
            v.protocolFee,
            creatorFee,
            _price(cv),
            cv.realQuote,
            cv.sold
        );

        // §23: the cut (cap / graduation) goes back to the trader, not the caller — aggregators assume exact-in and
        // may not forward or sweep a leftover. Direct `buy`: trader = msg.sender, as before.
        if (v.refundGross > 0) IERC20(quoteAddr).safeTransfer(trader, v.refundGross);
        if (cv.realQuote >= v.gradAmt) _graduate(c, token, cv);
        tokensOut = v.tokensOut;
    }

    /// @dev No tax on the curve: the trade pays only `protocolFee`. The creator's 70% stays on the pad in
    ///      `creatorFeeOf[token]` (pull: a creator that can't receive never blocks a trade); the platform's 30% goes to
    ///      the PlatformFeeBucket (blocking). A dividend token's share still follows the trader's balance (blocking
    ///      write, as V2's taxed track), so the pool tax after graduation is credited to the right holders; nothing is
    ///      paid to holders or to the tax recipient here.
    function _syncShareAndFee(
        IGangLaunchpad.Curve storage cv,
        mapping(address => uint256) storage creatorFeeOf,
        IGangLaunchpad.Deps memory d,
        address token,
        address account,
        address quoteAddr,
        uint256 protocolFee
    ) private returns (uint256 creatorFee) {
        if (cv.dividendBps > 0) {
            SharedDividendVault(d.dividendVault).setShare(token, account, IERC20(token).balanceOf(account));
        }
        creatorFee = (protocolFee * CREATOR_FEE_SHARE_BPS) / PadCommon.BPS;
        if (creatorFee > 0) {
            creatorFeeOf[token] += creatorFee;
            emit IGangLaunchpad.CreatorFeeAccrued(token, cv.creator, creatorFee);
        }
        PadCommon.toPlatform(d, quoteAddr, protocolFee - creatorFee);
    }

    /// @dev Pays `token`'s creator everything kept for it, in the curve's quote, to `to`. Before or after graduation.
    function claimCreatorFee(
        mapping(address => IGangLaunchpad.Curve) storage curves,
        mapping(address => uint256) storage creatorFeeOf,
        address token,
        address to
    ) external returns (uint256 amount) {
        IGangLaunchpad.Curve storage cv = curves[token];
        if (cv.creator == address(0)) revert IGangLaunchpad.UnknownToken();
        if (msg.sender != cv.creator) revert IGangLaunchpad.NotCreator();
        if (to == address(0) || to == address(this)) revert IGangLaunchpad.ZeroAddress();
        amount = creatorFeeOf[token];
        if (amount == 0) revert IGangLaunchpad.ZeroAmount();
        creatorFeeOf[token] = 0;
        IERC20(cv.quote).safeTransfer(to, amount);
        emit IGangLaunchpad.CreatorFeeClaimed(token, msg.sender, to, amount);
    }

    // ---------------------------------------------------------------- sell
    /// @dev `trader` sells `tokensIn`; the tokens move as `pull` says (PULL_CALLER / PULL_ROUTER / PULL_PAD, the pad
    ///      checked the caller for the last two) and the quote, after the 1% fee, goes to `payTo`.
    function sell(
        IGangLaunchpad.Config storage c,
        mapping(address => IGangLaunchpad.Curve) storage curves,
        mapping(address => uint256) storage creatorFeeOf,
        IGangLaunchpad.Deps memory d,
        address trader,
        uint8 pull,
        address token,
        uint256 tokensIn,
        uint256 minQuoteOut,
        address payTo
    ) external returns (uint256 quoteToUser) {
        IGangLaunchpad.Curve storage cv = _live(curves, token);
        if (tokensIn == 0) revert IGangLaunchpad.ZeroAmount();
        _requireAgent(c, trader);

        uint256 quoteOut = _quoteOut(cv, tokensIn);
        uint256 protocolFee = (quoteOut * PROTOCOL_FEE_BPS) / PadCommon.BPS;
        quoteToUser = quoteOut - protocolFee;
        if (quoteToUser < minQuoteOut) revert IGangLaunchpad.Slippage();

        cv.realQuote -= quoteOut.toUint128();
        cv.sold -= tokensIn.toUint128();

        if (pull == PULL_ROUTER) IGangPadToken(token).pullFor(trader, msg.sender, tokensIn);
        else if (pull == PULL_PAD) IERC20(token).safeTransferFrom(trader, address(this), tokensIn);
        else IERC20(token).safeTransferFrom(msg.sender, address(this), tokensIn);

        address quoteAddr = cv.quote;
        uint256 creatorFee = _syncShareAndFee(cv, creatorFeeOf, d, token, trader, quoteAddr, protocolFee);
        if (payTo != address(this)) IERC20(quoteAddr).safeTransfer(payTo, quoteToUser);

        // `tax` stays in the event (ABI unchanged for indexers): always 0, the curve charges none
        emit IGangLaunchpad.Sell(token, trader, tokensIn, protocolFee, 0, quoteToUser, cv.realQuote);
        emit IGangLaunchpad3.TradeV1(
            token, trader, false, quoteOut, tokensIn, protocolFee, creatorFee, _price(cv), cv.realQuote, cv.sold
        );
    }

    // ---------------------------------------------------------------- quotes (3.0)
    /// @notice What `buy(trader, token, quoteIn)` would do now: tokens out, quote kept (fee included), the fee, and
    ///         the refund of a cap / graduation cut; all 0 when it would revert (not a live curve token, quoteIn 0, the
    ///         gate refuses `trader`, the wallet cap is reached). `trader` = address(0): a fresh wallet, no gate check.
    function quoteBuy(
        IGangLaunchpad.Config storage c,
        mapping(address => IGangLaunchpad.Curve) storage curves,
        address token,
        address trader,
        uint256 quoteIn
    ) external view returns (uint256 tokensOut, uint256 spent, uint256 fee, uint256 refund) {
        IGangLaunchpad.Curve storage cv = curves[token];
        if (cv.creator == address(0) || cv.graduated || quoteIn == 0) return (0, 0, 0, 0);
        if (trader != address(0) && c.agentGateEnabled && !PadCommon.isAgent(c, trader)) return (0, 0, 0, 0);
        if (c.walletCapEnabled && walletRoom(true, token, trader, 0) == 0) return (0, 0, 0, 0);
        BuyVars memory v = _prepBuy(c, cv, token, trader, quoteIn, 0);
        return (v.tokensOut, quoteIn - v.refundGross, v.protocolFee, v.refundGross);
    }

    /// @notice What selling `tokensIn` pays now (after the 1% fee) and that fee; 0, 0 when it would revert (not a
    ///         live curve token, 0, more than the curve sold). The seller's balance, allowance and gate are not
    ///         checked.
    function quoteSell(mapping(address => IGangLaunchpad.Curve) storage curves, address token, uint256 tokensIn)
        external
        view
        returns (uint256 funds, uint256 fee)
    {
        IGangLaunchpad.Curve storage cv = curves[token];
        if (cv.creator == address(0) || cv.graduated || tokensIn == 0 || tokensIn > cv.sold) return (0, 0);
        uint256 quoteOut = _quoteOut(cv, tokensIn);
        fee = (quoteOut * PROTOCOL_FEE_BPS) / PadCommon.BPS;
        funds = quoteOut - fee;
    }

    // ---------------------------------------------------------------- views
    /// @notice What `create` would lock as the graduation amount for `quote` (0 = WBNB), `refPool` and the target
    ///         `gradBnb` (one of GRAD_BNB_TIERS).
    function graduationAmountOf(
        IGangLaunchpad.Config storage c,
        mapping(address => address) storage bridgePoolOf,
        IGangLaunchpad.Deps memory d,
        address quote,
        address refPool,
        uint256 gradBnb
    ) external view returns (uint256 g) {
        if (!isGradTier(gradBnb)) revert IGangLaunchpad.BadGradTarget();
        if (quote == address(0)) quote = d.wbnb;
        (g,) = PadCommon.toQuote(c, bridgePoolOf, d, quote, refPool, gradBnb);
        if (g > PadCommon.MAX_QUOTE_AMOUNT) revert IGangLaunchpad.QuoteAmountTooLarge();
    }

    /// @dev Room left under the 1% wallet cap (max when the cap is off): the wallet balance plus `locked` (what the
    ///      buyer holds in the token's vault on a vault pad; 0 elsewhere). Internal: also inlined into the pad's view.
    function walletRoom(bool capped, address token, address buyer, uint256 locked) internal view returns (uint256) {
        if (!capped) return type(uint256).max;
        uint256 held = IERC20(token).balanceOf(buyer) + locked;
        return held >= MAX_PER_WALLET ? 0 : MAX_PER_WALLET - held;
    }

    // ---------------------------------------------------------------- internal
    function _requireAgent(IGangLaunchpad.Config storage c, address account) private view {
        if (c.agentGateEnabled && !PadCommon.isAgent(c, account)) revert IGangLaunchpad.NotAgent();
    }

    function _graduate(IGangLaunchpad.Config storage c, address token, IGangLaunchpad.Curve storage cv) private {
        cv.graduated = true;
        uint256 tokenAmount = PadCommon.TOTAL_SUPPLY - cv.sold;
        uint256 quoteAmount = cv.realQuote;
        address quote = cv.quote;
        cv.realQuote = 0;

        // taxed: unlock, migrate, then setPair (tax and share syncing start); untaxed: never setPair (Untaxed)
        cv.pair = PadCommon.migrate(c, token, quote, tokenAmount, quoteAmount, cv.buyTaxBps > 0);
        emit IGangLaunchpad.Graduated(token, cv.pair, quote, tokenAmount, quoteAmount);
    }

    /// @dev The curve's marginal price: quote wei per 1e18 token wei (virtual + real quote over the virtual tokens left).
    function _price(IGangLaunchpad.Curve storage cv) private view returns (uint256) {
        return ((uint256(cv.virtualQuote) + cv.realQuote) * 1e18) / (VIRTUAL_TOKEN - cv.sold);
    }

    function _tokensOut(IGangLaunchpad.Curve storage cv, uint256 quoteIn) private view returns (uint256) {
        uint256 vq = cv.virtualQuote;
        uint256 k = vq * VIRTUAL_TOKEN;
        uint256 qReserve = vq + cv.realQuote;
        uint256 tReserve = VIRTUAL_TOKEN - cv.sold;
        uint256 newT = Math.ceilDiv(k, qReserve + quoteIn);
        return tReserve - newT;
    }

    function _quoteInFor(IGangLaunchpad.Curve storage cv, uint256 tokensOut) private view returns (uint256) {
        uint256 vq = cv.virtualQuote;
        uint256 k = vq * VIRTUAL_TOKEN;
        uint256 qReserve = vq + cv.realQuote;
        uint256 tReserve = VIRTUAL_TOKEN - cv.sold;
        return Math.ceilDiv(k, tReserve - tokensOut) - qReserve;
    }

    function _quoteOut(IGangLaunchpad.Curve storage cv, uint256 tokensIn) private view returns (uint256) {
        uint256 vq = cv.virtualQuote;
        uint256 k = vq * VIRTUAL_TOKEN;
        uint256 qReserve = vq + cv.realQuote;
        uint256 tReserve = VIRTUAL_TOKEN - cv.sold;
        uint256 newQ = Math.ceilDiv(k, tReserve + tokensIn);
        return qReserve - newQ;
    }

    function _live(mapping(address => IGangLaunchpad.Curve) storage curves, address token)
        private
        view
        returns (IGangLaunchpad.Curve storage cv)
    {
        cv = curves[token];
        if (cv.creator == address(0)) revert IGangLaunchpad.UnknownToken();
        if (cv.graduated) revert IGangLaunchpad.AlreadyGraduated();
    }
}
