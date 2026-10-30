// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IGangPadRegistry} from "../gang/interfaces/IGangPadRegistry.sol";
import {IGangGateway} from "./interfaces/IGangGateway.sol";

/// @dev The slice of a Gang pad (GangLaunchpad and every later generation, which keep these selectors and layouts) the
///      gateway calls. `curves` / `sales` keep the 12- / 14-field layouts GangRouter decodes.
interface IGangGatewayPad {
    function curves(address token)
        external
        view
        returns (
            address creator,
            address quote,
            uint128 realQuote,
            uint128 sold,
            uint128 gradAmt,
            uint128 virtualQuote,
            bool graduated,
            uint16 buyTaxBps,
            uint16 sellTaxBps,
            uint16 dividendBps,
            address pair,
            address refPair
        );
    function sales(address token)
        external
        view
        returns (
            address creator,
            uint64 progressAt,
            uint16 capShares,
            uint16 holdBps,
            address quote,
            uint16 sold,
            bool launched,
            uint16 mintFeeBps,
            uint16 exitFeeBps,
            address gate,
            uint128 sharePrice,
            address pair,
            address refPool,
            uint16 markSold
        );
    function buyFor(address trader, address token, uint256 quoteIn, uint256 minTokensOut)
        external
        returns (uint256 tokensOut);
    function sellFor(address trader, address token, uint256 tokensIn, uint256 minQuoteOut)
        external
        returns (uint256 quoteOut);
    function routers(address router) external view returns (bool);
    function agentGateEnabled() external view returns (bool);
}

interface IWBNBGateway {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/// @title GangGateway — four.meme-style curve entry for aggregators (implementation behind a proxy)
/// @notice A listed router on every Gang pad that lists it (`setRouter`), shaped like four.meme's TokenManager2 /
///         Helper3 so an aggregator's four.meme adapter carries over: the user approves this gateway once on the token,
///         any contract calls `sellToken` / `buyTokenAMAP` (no caller whitelist, no signature), and the pad's own
///         check `trader == tx.origin` (§23) binds every trade to the wallet that sent the tx. A sell's proceeds go to
///         that wallet; the caller can take at most `feeRate` (≤ 5%) of them as its router fee.
///         The pad of a token is the one GangPadRegistry returns (registered AND listing the token), so a look-alike
///         token cannot route funds to a fake pad, and a later pad generation is served once it is registered and
///         lists this gateway. A buy's `amountOut` is what `to`'s token balance grew by: a real, locked Gang token
///         moves only from its own pad, so a registry made to point such a token at another pad cannot fake a fill
///         (minAmount > 0 reverts). A pad wrongly registered (`addPad`) can still fake fills of its OWN tokens: that
///         is up to the Safe's review of `addPad`. The pad holds every reserve and enforces every rule (price, 1% fee, Agent gate, 1%
///         wallet cap, graduation); this contract only moves the caller's own funds in, wraps / unwraps BNB, splits a
///         sell's proceeds and checks the seller's minimum. Tokens never pass through it: a buy's tokens go from the
///         pad to `to`, a sell's from `from` into the pad (GangToken.pullFor, with `from`'s allowance to this
///         gateway, locked tokens only).
///         Deliberate exception to the §23.9 router checklist (items 2 and 3, AUDIT-BRIEF §25): the seller is a
///         parameter, not msg.sender, and `minFunds` is the caller's. A contract the user is tricked into calling can
///         sell the user's approved curve tokens in the user's own tx with no minimum: the proceeds go to the user,
///         minus up to the 5% router fee, but the attacker can also sell its own inventory on the same curve first and
///         buy it back after (same tx, or a bundle around it), so the user's loss is bounded by that inventory, not by
///         5% (audit PoC: 9–54%). Exact approvals (allowance back to 0 after each sell) limit it to an approval not
///         yet used. four.meme's open sell path has the same model; aggregators asked for it.
///         Deployed as the logic of a TransparentUpgradeableProxy whose ProxyAdmin is owned by a 48 h
///         TimelockController run by the platform Safe (as GangRouter, §21): users approve the PROXY, and a new
///         version is public for 48 h before it can run. No owner and no funds here.
/// @dev Anything sent here outside a call (tokens, BNB) stays here: every call settles against its own balance delta.
///      STORAGE LAYOUT (proxy storage). Upgrade rule: a new variable takes its slot from `__gap` (declared right before
///      it) and the gap shrinks by the same number of slots; never reorder, retype or remove a variable, and never
///      change the inheritance list:
///        slot 0      ReentrancyGuard._status  (0 on a fresh proxy = not entered; 1 / 2 afterwards)
///        slot 1      registry
///        slot 2      wbnb
///        slots 3–49  __gap (47 slots)
///      Initializable keeps its flag in its ERC-7201 slot (not in the sequential layout). A new version that needs
///      set-up uses `reinitializer(2)`.
contract GangGateway is IGangGateway, Initializable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 internal constant BPS = 10_000;
    /// @notice Highest router fee a seller can be charged (four.meme's cap): 5%.
    uint256 public constant MAX_FEE_RATE = 500;
    /// @notice The pad's fee on every curve trade (CurveLogic.PROTOCOL_FEE_BPS; GangPadRegistry refuses a pad with
    ///         another one).
    uint256 public constant PROTOCOL_FEE_BPS = 100;
    uint8 internal constant KIND_CURVE = 1;
    uint8 internal constant KIND_FAIR = 2;
    uint8 internal constant STATUS_NONE = 0;
    uint8 internal constant STATUS_CURVE = 1;
    uint8 internal constant STATUS_POOL = 2;
    uint8 internal constant STATUS_MINTING = 3;

    /// @notice Where a token's pad is looked up. Set once by `initialize`.
    IGangPadRegistry public registry;
    /// @notice WBNB. Set once by `initialize`.
    address public wbnb;
    /// @dev Reserved for appended state in later versions (see the layout above).
    uint256[47] private __gap;

    /// @dev The implementation itself can never be initialized: only a proxy's storage holds a registry.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Run once, by the proxy's constructor (TransparentUpgradeableProxy's `_data`), in the deploy transaction.
    /// @param registry_ GangPadRegistry proxy (mainnet 0x4fF7…4e5C)
    function initialize(address registry_, address wbnb_) external initializer {
        if (registry_ == address(0) || wbnb_ == address(0)) revert NotDeployed();
        registry = IGangPadRegistry(registry_);
        wbnb = wbnb_;
    }

    /// @dev Only WBNB unwrapping sends BNB here. WBNB pays with `transfer` (2300 gas): through the proxy this costs one
    ///      warm implementation-slot read, the delegatecall and one warm `wbnb` read (the call that unwraps read it).
    receive() external payable {
        if (msg.sender != wbnb) revert OnlyWbnb();
    }

    // ---------------------------------------------------------------- views
    /// @inheritdoc IGangGateway
    function getTokenInfo(address token)
        public
        view
        returns (uint8 status, address quote, address pair, uint256 protocolFeeBps, uint256 graduationLeft)
    {
        (address pad, uint8 kind) = registry.lookup(token);
        if (kind == KIND_CURVE) {
            (, address q, uint128 realQuote,, uint128 gradAmt,, bool graduated,,,, address p,) =
                IGangGatewayPad(pad).curves(token);
            quote = _external(q);
            if (graduated) return (STATUS_POOL, quote, p, 0, 0);
            return (STATUS_CURVE, quote, address(0), PROTOCOL_FEE_BPS, gradAmt - realQuote);
        }
        if (kind == KIND_FAIR) {
            (,,,, address q,, bool launched,,,,, address p,,) = IGangGatewayPad(pad).sales(token);
            quote = _external(q);
            if (launched) return (STATUS_POOL, quote, p, protocolFeeBps, 0);
            return (STATUS_MINTING, quote, address(0), protocolFeeBps, 0);
        }
    }

    /// @inheritdoc IGangGateway
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
        if (amount != 0) revert AmountNotSupported();
        tokenManager = address(this);
        uint8 status;
        (status, quote,,,) = getTokenInfo(token);
        if (status != STATUS_CURVE || !_buyOpen(token)) return (tokenManager, quote, 0, 0, 0, 0, 0, 0);
        (estimatedAmount, estimatedCost, estimatedFee,) = registry.previewBuy(token, trader, funds);
        if (estimatedAmount == 0) return (tokenManager, quote, 0, 0, 0, 0, 0, 0);
        if (quote == address(0)) amountMsgValue = funds;
        else amountApproval = funds;
        amountFunds = estimatedCost;
    }

    /// @inheritdoc IGangGateway
    function trySell(address token, uint256 amount)
        external
        view
        returns (address tokenManager, address quote, uint256 funds, uint256 fee)
    {
        tokenManager = address(this);
        uint8 status;
        (status, quote,,,) = getTokenInfo(token);
        if (status != STATUS_CURVE || !_listedOn(token)) return (tokenManager, quote, 0, 0);
        (funds, fee) = registry.previewSell(token, address(0), amount);
    }

    // ---------------------------------------------------------------- trades
    /// @inheritdoc IGangGateway
    function buyTokenAMAP(address token, address to, uint256 funds, uint256 minAmount)
        external
        payable
        nonReentrant
        returns (uint256 amountOut, uint256 fundsUsed)
    {
        (IGangGatewayPad pad, IERC20 quote) = _curve(token);
        if (address(quote) == wbnb) {
            if (msg.value != funds) revert BadMsgValue();
            IWBNBGateway(address(quote)).deposit{value: funds}();
        } else {
            if (msg.value != 0) revert BadMsgValue();
            // a fee-on-transfer quote arrives short and the pad's exact pull of `funds` fails (the pad refuses those)
            quote.safeTransferFrom(msg.sender, address(this), funds);
        }
        // every registered pad pulls exactly `funds` (PadCommon.pullExact) and refunds a cut straight to `to` (§23):
        // this approval ends at 0 and nothing stays here. A pad generation that did otherwise would leave the rest here
        // and overstate fundsUsed — check that before registering it. `to`'s quote balance grows by the refund only
        // (`to` is tx.origin: never this gateway, never the pad)
        uint256 toBefore = quote.balanceOf(to);
        uint256 tokensBefore = IERC20(token).balanceOf(to);
        quote.forceApprove(address(pad), funds);
        pad.buyFor(to, token, funds, minAmount);
        // what `to` received, not what the pad says: a locked token moves only from its own pad (audit L-2)
        amountOut = IERC20(token).balanceOf(to) - tokensBefore;
        if (amountOut < minAmount) revert Slippage();
        fundsUsed = funds - (quote.balanceOf(to) - toBefore);
        emit GatewayBuy(token, to, msg.sender, fundsUsed, amountOut);
    }

    /// @inheritdoc IGangGateway
    function sellToken(
        uint256,
        address token,
        address from,
        uint256 amount,
        uint256 minFunds,
        uint256 feeRate,
        address feeRecipient
    ) external nonReentrant returns (uint256 fundsToSeller) {
        if (feeRate > MAX_FEE_RATE) revert FeeRateTooHigh();
        (IGangGatewayPad pad, IERC20 quote) = _curve(token);
        uint256 base = quote.balanceOf(address(this));
        // the minimum is checked on what `from` ends up with (after the router fee), so the pad's is 0
        pad.sellFor(from, token, amount, 0);
        uint256 funds = quote.balanceOf(address(this)) - base;
        uint256 fee = (funds * feeRate) / BPS;
        fundsToSeller = funds - fee;
        if (fundsToSeller < minFunds) revert Slippage();
        if (fee > 0 && feeRecipient == address(0)) revert ZeroFeeRecipient();

        if (address(quote) == wbnb) {
            IWBNBGateway(address(quote)).withdraw(funds);
            _sendBnb(feeRecipient, fee);
            _sendBnb(from, fundsToSeller);
        } else {
            if (fee > 0) quote.safeTransfer(feeRecipient, fee);
            quote.safeTransfer(from, fundsToSeller);
        }
        emit GatewaySell(token, from, msg.sender, amount, funds, fundsToSeller, fee, feeRecipient);
    }

    // ---------------------------------------------------------------- internal
    /// @dev The registered pad of a live curve token and its quote; NotCurveToken for anything else (not a Gang token,
    ///      a look-alike, a 打新 token, graduated).
    function _curve(address token) internal view returns (IGangGatewayPad pad, IERC20 quote) {
        (address p, uint8 kind) = registry.lookup(token);
        if (kind != KIND_CURVE) revert NotCurveToken();
        pad = IGangGatewayPad(p);
        (, address q,,,,, bool graduated,,,,,) = pad.curves(token);
        if (graduated) revert NotCurveToken();
        quote = IERC20(q);
    }

    /// @dev The token's pad lists this gateway (else every trade reverts OnlyRouter). Called after getTokenInfo found a
    ///      curve, so the lookup cannot fail.
    function _listedOn(address token) internal view returns (bool) {
        (address pad,) = registry.lookup(token);
        return IGangGatewayPad(pad).routers(address(this));
    }

    /// @dev `_listedOn` and the gate on (the pad's buyFor reverts RouterNeedsGate without it).
    function _buyOpen(address token) internal view returns (bool) {
        (address pad,) = registry.lookup(token);
        IGangGatewayPad p = IGangGatewayPad(pad);
        return p.routers(address(this)) && p.agentGateEnabled();
    }

    /// @dev The quote as four.meme reports it: address(0) for WBNB (native BNB in and out here).
    function _external(address quote) internal view returns (address) {
        return quote == wbnb ? address(0) : quote;
    }

    function _sendBnb(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert BnbTransferFailed();
    }
}
