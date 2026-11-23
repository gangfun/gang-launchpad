// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IGangPadRegistry} from "../gang/interfaces/IGangPadRegistry.sol";
import {IFlywheelPad} from "../flywheel/interfaces/IFlywheelPad.sol";
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

/// @dev The slice of GangFlywheelPad (铸币飞轮, kind 3; V1 and V2 keep these selectors, the `Sale` layout and the share
///      constants) the gateway calls.
interface IGangGatewayFlywheel {
    function sales(address token) external view returns (IFlywheelPad.Sale memory);
    function TOTAL_SHARES() external view returns (uint256);
    function TOKENS_PER_SHARE() external view returns (uint256);
    function exitFeeBpsOf(address token) external view returns (uint256);
    function previewMint(address token, address user, uint256 shares)
        external
        view
        returns (uint256 accepted, uint256 cost, uint256 fee);
    function previewMintPost(address token, address user, uint256 shares)
        external
        view
        returns (uint256 accepted, uint256 paid, uint256 fee, uint256 tokensOut, bool ok);
    function mintFor(address trader, address token, uint256 shares, uint256 minShares, address referrer)
        external
        returns (uint256 spent);
    function withdrawFor(address trader, address token, uint256 shares, uint256 minPayout)
        external
        returns (uint256 payout);
    function mintPostFor(
        address trader,
        address token,
        uint256 shares,
        uint256 minTokensOut,
        uint256 maxSpent,
        address referrer
    ) external returns (uint256 tokensOut, uint256 spent);
    function routers(address router) external view returns (bool);
}

interface IWBNBGateway {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/// @title GangGateway — four.meme-style curve entry for aggregators (implementation behind a proxy)
/// @notice A listed router on every Gang pad that lists it (`setRouter`), shaped like four.meme's TokenManager2 /
///         Helper3 so an aggregator's four.meme adapter carries over (once its contract is whitelisted for sells): the
///         user approves this gateway once on the token, the aggregator's contract calls `sellToken` / `buyTokenAMAP`
///         (no signature), and the pad's own check `trader == tx.origin` (§23) binds every trade to the wallet that
///         sent the tx. A sell's proceeds go to that wallet; the caller can take at most `feeRate` (≤ 5%) of them as
///         its router fee.
///         Sells: only the seller itself (an EOA calling directly, `from == msg.sender`) or a caller the owner (the
///         Safe) whitelisted (`isCaller`: an aggregator's contract that calls this gateway). A contract the user is
///         merely tricked into calling cannot sell for the user (NotWhitelisted) — without this, it could sell the
///         user's approved curve tokens at a price it moved itself in the same tx (audit M-1, AUDIT-BRIEF §25).
///         Listing a caller is a security decision like `setRouter` (§23.9): `from` must be the user that called the
///         aggregator (its router's msg.sender), never tx.origin or a free parameter of an open entry. Buys stay open
///         to any caller: they spend the caller's own funds and the tokens can only go to tx.origin.
///         The pad of a token is the one GangPadRegistry returns (registered AND listing the token), so a look-alike
///         token cannot route funds to a fake pad, and a later pad generation is served once it is registered and
///         lists this gateway. A buy's `amountOut` is what `to`'s token balance grew by: a real, locked Gang token
///         moves only from its own pad, so a registry made to point such a token at another pad cannot fake a fill
///         (minAmount > 0 reverts). A pad wrongly registered (`addPad`) can still fake fills of its OWN tokens: that is
///         up to the Safe's review of `addPad`. The pad holds every reserve and enforces every rule (price, 1% fee,
///         Agent gate, 1% wallet cap, graduation); this contract only moves the caller's own funds in, wraps / unwraps
///         BNB, splits a sell's proceeds and checks the seller's minimum. Tokens never pass through it: a buy's tokens
///         go from the pad to `to`, a sell's from `from` into the pad (GangToken.pullFor, with `from`'s allowance to
///         this gateway, locked tokens only).
///         铸币飞轮 tokens (GangFlywheelPad, registry kind 3; V2 of this gateway, AUDIT-BRIEF §26) trade through the same
///         five functions: before launch a buy mints whole shares (`mintFor`, at the sale's share price plus its mint
///         fee) and a sell sells whole shares back (`withdrawFor`, at the share price less the exit fee); after launch
///         a buy mints at the post-launch tier price (`mintPostFor`, sales with post-launch minting only, under the
///         pad's guards) and the token's sells go to its PancakeSwap pair (status 2). The pad pulls exactly what it
///         spends from this gateway; the rest of `funds` goes back to `to` in the quote ERC-20 (WBNB for BNB), as the
///         curve's cut refunds do.
///         Deployed as the logic of a TransparentUpgradeableProxy whose ProxyAdmin is owned by a 48 h
///         TimelockController run by the platform Safe (as GangRouter, §21): users approve the PROXY, and a new
///         version is public for 48 h before it can run. The `owner` (mainnet: the Safe, no timelock) manages the
///         sell-caller whitelist only, but a listing takes effect at once and lets that caller sell for its users with
///         their existing approvals to this gateway: as weighty as an upgrade, without the 48 h (accepted to keep it
///         simple, AUDIT-BRIEF §25.10); a delisting is immediate too. No funds here.
/// @dev Anything sent here outside a call (tokens, BNB) stays here: every call settles against its own balance delta.
///      STORAGE LAYOUT (proxy storage). Upgrade rule: a new variable takes its slot from `__gap` (declared right before
///      it) and the gap shrinks by the same number of slots; never reorder, retype or remove a variable, and never
///      change the inheritance list:
///        slot 0      ReentrancyGuard._status  (0 on a fresh proxy = not entered; 1 / 2 afterwards)
///        slot 1      registry
///        slot 2      wbnb
///        slot 3      owner
///        slot 4      pendingOwner
///        slot 5      isCaller
///        slots 6–49  __gap (44 slots)
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
    uint8 internal constant KIND_FLY = 3;
    /// @dev FlywheelLogic.LAUNCH_GRACE (V1 = V2): a filled sale that has not launched this long after its launch time
    ///      takes sell-backs again.
    uint256 internal constant FLY_LAUNCH_GRACE = 7 days;
    uint8 internal constant STATUS_NONE = 0;
    uint8 internal constant STATUS_CURVE = 1;
    uint8 internal constant STATUS_POOL = 2;
    uint8 internal constant STATUS_MINTING = 3;

    /// @notice Where a token's pad is looked up. Set once by `initialize`.
    IGangPadRegistry public registry;
    /// @notice WBNB. Set once by `initialize`.
    address public wbnb;
    /// @notice Manages the sell-caller whitelist (mainnet: the platform Safe). Two-step hand-over.
    address public owner;
    address public pendingOwner;
    /// @notice Contracts allowed to call `sellToken` for a seller other than themselves (aggregators' contracts).
    mapping(address caller => bool) public isCaller;
    /// @dev Reserved for appended state in later versions (see the layout above).
    uint256[44] private __gap;

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    /// @dev The implementation itself can never be initialized: only a proxy's storage holds a registry.
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Run once, by the proxy's constructor (TransparentUpgradeableProxy's `_data`), in the deploy transaction.
    /// @param registry_ GangPadRegistry proxy (mainnet 0x4fF7…4e5C)
    /// @param owner_ manages the sell-caller whitelist (mainnet: the platform Safe)
    function initialize(address registry_, address wbnb_, address owner_) external initializer {
        if (registry_ == address(0) || wbnb_ == address(0) || owner_ == address(0)) revert NotDeployed();
        registry = IGangPadRegistry(registry_);
        wbnb = wbnb_;
        owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
    }

    // ---------------------------------------------------------------- owner
    /// @inheritdoc IGangGateway
    function setCaller(address caller, bool allowed) external onlyOwner {
        // contracts only (audit L-2): a listed EOA could later delegate to any code with EIP-7702 and relay for anyone
        if (allowed && !_isPlainContract(caller)) revert NotAContract();
        isCaller[caller] = allowed;
        emit CallerSet(caller, allowed);
    }

    /// @notice Step 1 of a hand-over; `newOwner` must call `acceptOwnership`. address(0) cancels a pending one.
    function transferOwnership(address newOwner) external onlyOwner {
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
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
            if (launched) return (STATUS_POOL, quote, p, 0, 0);
            return (STATUS_MINTING, quote, address(0), 0, 0);
        }
        if (kind == KIND_FLY) {
            IGangGatewayFlywheel f = IGangGatewayFlywheel(pad);
            IFlywheelPad.Sale memory s = f.sales(token);
            quote = _external(s.quote);
            if (s.launched) return (STATUS_POOL, quote, s.pair, 0, 0);
            return (STATUS_CURVE, quote, address(0), s.mintFeeBps, (f.TOTAL_SHARES() - s.sold) * s.basePrice);
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
        (address pad, uint8 kind) = registry.lookup(token);
        if (kind == KIND_FLY) {
            (, estimatedAmount, estimatedCost, estimatedFee) =
                _flyQuote(IGangGatewayFlywheel(pad), token, trader, funds);
        } else if (status == STATUS_CURVE && _buyOpen(token)) {
            (estimatedAmount, estimatedCost, estimatedFee,) = registry.previewBuy(token, trader, funds);
        }
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
        (address pad, uint8 kind) = registry.lookup(token);
        if (kind == KIND_FLY) {
            IGangGatewayFlywheel f = IGangGatewayFlywheel(pad);
            IFlywheelPad.Sale memory s = f.sales(token);
            uint256 shares = _wholeShares(f, amount);
            // withdrawFor needs a gated sale (RouterNeedsGate); no more shares than minters hold
            if (shares == 0 || shares > s.sold || s.gate == address(0) || !_withdrawable(s)) {
                return (tokenManager, quote, 0, 0);
            }
            uint256 principal = shares * s.basePrice;
            fee = (principal * f.exitFeeBpsOf(token)) / BPS;
            funds = principal - fee;
        } else {
            (funds, fee) = registry.previewSell(token, address(0), amount);
        }
    }

    // ---------------------------------------------------------------- trades
    /// @inheritdoc IGangGateway
    function buyTokenAMAP(address token, address to, uint256 funds, uint256 minAmount)
        external
        payable
        nonReentrant
        returns (uint256 amountOut, uint256 fundsUsed)
    {
        (address p, uint8 kind) = registry.lookup(token);
        if (kind == KIND_FLY) {
            (amountOut, fundsUsed) = _flyBuy(IGangGatewayFlywheel(p), token, to, funds, minAmount);
        } else {
            (amountOut, fundsUsed) = _curveBuy(token, to, funds, minAmount);
        }
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
        // the seller itself, or a whitelisted aggregator contract (audit M-1); the pad still requires from == tx.origin
        if (from != msg.sender && !isCaller[msg.sender]) revert NotWhitelisted();
        if (feeRate > MAX_FEE_RATE) revert FeeRateTooHigh();
        (address p, uint8 kind) = registry.lookup(token);
        IERC20 quote;
        uint256 base;
        // the minimum is checked on what `from` ends up with (after the router fee), so the pad's is 0
        if (kind == KIND_FLY) {
            IGangGatewayFlywheel f = IGangGatewayFlywheel(p);
            IFlywheelPad.Sale memory s = f.sales(token);
            if (s.launched) revert NotCurveToken();
            uint256 shares = _wholeShares(f, amount);
            if (shares == 0) revert NotWholeShares();
            quote = IERC20(s.quote);
            base = quote.balanceOf(address(this));
            f.withdrawFor(from, token, shares, 0);
        } else {
            IGangGatewayPad pad;
            (pad, quote) = _curve(token);
            base = quote.balanceOf(address(this));
            pad.sellFor(from, token, amount, 0);
        }
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

    // ---------------------------------------------------------------- internal: curve
    function _curveBuy(address token, address to, uint256 funds, uint256 minAmount)
        internal
        returns (uint256 amountOut, uint256 fundsUsed)
    {
        (IGangGatewayPad pad, IERC20 quote) = _curve(token);
        _payIn(quote, funds);
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
    }

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

    // ---------------------------------------------------------------- internal: 铸币飞轮 (kind 3)
    /// @dev Before launch: the most whole shares `funds` pays for (`mintFor`, capped by the pad to the quota, the per-mint
    ///      cap and the shares left). After launch (post-launch minting on): the largest mint within the per-mint cap
    ///      that `funds` pays for and the pad accepts now (`mintPostFor`, at most `funds`). The pad pulls what it spends;
    ///      the rest goes to `to` in the quote ERC-20.
    function _flyBuy(IGangGatewayFlywheel f, address token, address to, uint256 funds, uint256 minAmount)
        internal
        returns (uint256 amountOut, uint256 fundsUsed)
    {
        IFlywheelPad.Sale memory s = f.sales(token);
        if (s.launched && !s.postMint) revert NotCurveToken();
        IERC20 quote = IERC20(s.quote);
        _payIn(quote, funds);
        uint256 tokensBefore = IERC20(token).balanceOf(to);
        quote.forceApprove(address(f), funds);
        if (!s.launched) {
            uint256 shares = _sharesFor(s, funds);
            if (shares == 0) revert FundsTooLow();
            uint256 tps = f.TOKENS_PER_SHARE();
            // the shares `minAmount` asks for, rounded up: the pad refuses fewer (Slippage)
            fundsUsed = f.mintFor(to, token, shares, Math.ceilDiv(minAmount, tps), address(0));
        } else {
            (uint256 shares,,,, bool affordable) = _postMint(f, s, token, to, funds);
            if (!affordable) revert FundsTooLow();
            // none the pad accepts now: one share, so the pad names its reason (price guard, pace, supply cap, quota)
            (, fundsUsed) = f.mintPostFor(to, token, shares == 0 ? 1 : shares, minAmount, funds, address(0));
        }
        quote.forceApprove(address(f), 0);
        // what `to` received (as the curve's audit L-2)
        amountOut = IERC20(token).balanceOf(to) - tokensBefore;
        if (amountOut < minAmount) revert Slippage();
        if (funds > fundsUsed) quote.safeTransfer(to, funds - fundsUsed);
    }

    /// @dev What `_flyBuy(token, trader, funds, 0)` would buy now; zeros when it would revert (the pad does not list
    ///      this gateway, an ungated sale (RouterNeedsGate), filled, launched without post-launch minting, `trader`
    ///      fails the gate or has no quota left, the price guards, funds too low) and for trader address(0).
    function _flyQuote(IGangGatewayFlywheel f, address token, address trader, uint256 funds)
        internal
        view
        returns (uint256 shares, uint256 amountOut, uint256 cost, uint256 fee)
    {
        if (trader == address(0) || !f.routers(address(this))) return (0, 0, 0, 0);
        IFlywheelPad.Sale memory s = f.sales(token);
        if (s.gate == address(0)) return (0, 0, 0, 0);
        if (!s.launched) {
            uint256 want = _sharesFor(s, funds);
            if (want == 0) return (0, 0, 0, 0);
            uint256 price;
            (shares, price, fee) = f.previewMint(token, trader, want);
            if (shares == 0) return (0, 0, 0, 0);
            return (shares, shares * f.TOKENS_PER_SHARE(), price + fee, fee);
        }
        if (!s.postMint) return (0, 0, 0, 0);
        (shares, amountOut, cost, fee,) = _postMint(f, s, token, trader, funds);
    }

    /// @dev The largest post-launch mint that costs at most `funds` and the pad accepts now (all 0 if none), and
    ///      whether one at most `funds` exists at all (the pad may still refuse it: then `buyTokenAMAP` sends one share
    ///      so the pad names its reason). A post-launch share costs at least a pre-launch one (tier ≥ ×1, same fee), so
    ///      the search starts at the pre-launch count for `funds` (audit L-2), capped by the per-mint cap: at most
    ///      that many previews (≤ 10).
    function _postMint(IGangGatewayFlywheel f, IFlywheelPad.Sale memory s, address token, address trader, uint256 funds)
        internal
        view
        returns (uint256 shares, uint256 amountOut, uint256 cost, uint256 fee, bool affordable)
    {
        uint256 want = _sharesFor(s, funds);
        if (want > s.maxPerTx) want = s.maxPerTx;
        while (want != 0) {
            (uint256 accepted, uint256 paid, uint256 mintFee, uint256 out, bool ok) =
                f.previewMintPost(token, trader, want);
            if (accepted == 0) return (0, 0, 0, 0, true); // no quota (or no Agent ID): one share lets the pad say so
            if (paid + mintFee <= funds) {
                if (ok) return (accepted, out, paid + mintFee, mintFee, true);
                affordable = true;
            }
            want = accepted - 1;
        }
    }

    /// @dev Pre-launch: the most shares with `shares * price + fee` ≤ funds (fee = mintFeeBps of the price, rounded
    ///      down, as FlywheelLogic charges it). The estimate is at most one short (the fee's rounding), checked here.
    ///      `funds` above 2^128 - 1 counts as 2^128 - 1 (no overflow; still far more shares than any quota, audit I-2).
    function _sharesFor(IFlywheelPad.Sale memory s, uint256 funds) internal pure returns (uint256 n) {
        if (funds > type(uint128).max) funds = type(uint128).max;
        uint256 unit = s.basePrice;
        n = (funds * BPS) / (unit * (BPS + s.mintFeeBps));
        if (_mintCost(n + 1, unit, s.mintFeeBps) <= funds) n++;
    }

    function _mintCost(uint256 n, uint256 unit, uint256 feeBps) internal pure returns (uint256) {
        uint256 cost = n * unit;
        return cost + (cost * feeBps) / BPS;
    }

    /// @dev `amount` in whole shares (the pad sells back whole shares only); 0 if it is 0 or not whole.
    function _wholeShares(IGangGatewayFlywheel f, uint256 amount) internal view returns (uint256) {
        uint256 tps = f.TOKENS_PER_SHARE();
        if (amount == 0 || amount % tps != 0) return 0;
        return amount / tps;
    }

    /// @dev FlywheelLogic.withdrawable: before the sale fills (or opens early), or a filled sale past its launch time
    ///      plus the grace without launching.
    function _withdrawable(IFlywheelPad.Sale memory s) internal view returns (bool) {
        if (s.creator == address(0) || s.launched) return false;
        if (s.filledAt == 0) return true;
        return block.timestamp >= uint256(s.filledAt) + s.launchDelay + FLY_LAUNCH_GRACE;
    }

    // ---------------------------------------------------------------- internal: shared
    /// @dev `funds` of the quote in: BNB-quoted (WBNB), msg.value == funds, wrapped; else pulled from msg.sender.
    function _payIn(IERC20 quote, uint256 funds) internal {
        if (address(quote) == wbnb) {
            if (msg.value != funds) revert BadMsgValue();
            IWBNBGateway(address(quote)).deposit{value: funds}();
        } else {
            if (msg.value != 0) revert BadMsgValue();
            // a fee-on-transfer quote arrives short and the pad's exact pull fails (the pads refuse those)
            quote.safeTransferFrom(msg.sender, address(this), funds);
        }
    }

    /// @dev Has code, and that code is not an EIP-7702 delegation designator (0xef0100 ‖ address, 23 bytes).
    function _isPlainContract(address a) internal view returns (bool) {
        uint256 size = a.code.length;
        if (size == 0) return false;
        if (size != 23) return true;
        return bytes3(a.code) != 0xef0100;
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
