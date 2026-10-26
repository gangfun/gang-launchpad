// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {PlatformFeeBucket} from "../launchpad-v2/PlatformFeeBucket.sol";
import {ISwapBack} from "../common/interfaces/ISwapBack.sol";
import {PostGradHandlerBase} from "../common/PostGradHandlerBase.sol";
import {FairToken} from "./FairToken.sol";

interface IFairMintPadView {
    function baselineOf(address token, address user) external view returns (uint256);
    function holdBpsOf(address token) external view returns (uint16);
}

/// @title HolderRewardHandler (打新发射 · 发射后 1% 税)
/// @notice Accrues the 1% tax in tokens. 50% of each tax is credited to the pre-launch holders of that moment
///         (tax-time units in DividendVault; with no eligible holder, it is the platform's); the tax is sold in small
///         chunks — one before every sell into the pair (`swapBack`), or by the keeper (`process`) — the holders'
///         units of each chunk turn into their quote, the rest goes to PlatformFeeBucket.
/// @dev Reward share of a minter = min(balance, baseline) where baseline = tokens minted pre-launch.
///      Once balance < baseline × holdBps, the minter is out for good (buying back does not restore it).
///      Everyone else (pair, handler, post-launch buyers) has baseline 0 and never holds shares.
///      Must be a DividendVault operator and a PlatformFeeBucket operator.
contract HolderRewardHandler is ISwapBack, PostGradHandlerBase {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant HOLDER_SHARE_BPS = 5_000;

    PlatformFeeBucket public immutable platformBucket;
    IFairMintPadView public pad;

    mapping(address token => mapping(address user => bool)) public isOut;

    error PadAlreadySet();
    error UnknownToken();

    event PadSet(address indexed pad);
    event OuterTaxProcessed(
        address indexed token,
        address indexed quote,
        uint256 taxTokens,
        uint256 quoteOut,
        uint256 toHolders,
        uint256 toPlatform
    );
    event Disqualified(address indexed token, address indexed user, uint256 balance, uint256 baseline);

    constructor(address owner_, address dividendVault_, address platformBucket_)
        PostGradHandlerBase(owner_, dividendVault_)
    {
        if (platformBucket_ == address(0)) revert ZeroAddress();
        platformBucket = PlatformFeeBucket(platformBucket_);
    }

    /// @notice One-shot: the pad that defines baselines.
    function setPad(address pad_) external onlyOwner {
        if (address(pad) != address(0)) revert PadAlreadySet();
        if (pad_ == address(0)) revert ZeroAddress();
        pad = IFairMintPadView(pad_);
        emit PadSet(pad_);
    }

    /// @notice FairToken's hook after taking the pool tax (`taxAmount` already sent here).
    function notifyTax(address token, address from, address to, uint256 taxAmount) external nonReentrant {
        _checkHook(token, taxAmount);
        // audit 4 A-F3: only this pad's tokens (any contract can name itself as `token`; the vault is shared)
        if (dividendVault.launchpadOf(token) != address(pad)) revert UnknownToken();
        // credited over the shares just before this trade (the token syncs them after): a seller gets its part of its
        // own sell's tax on its pre-sell share, even if this sell takes it out — it held until then
        _creditHolders(token, (taxAmount * HOLDER_SHARE_BPS) / BPS);
        _accrue(token, from, to, taxAmount);
    }

    /// @notice FairToken's hook on every transfer.
    /// @dev Permissionless: it only applies the rule to true balances. Never reverts for unknown / locked tokens
    ///      (runs inside token transfers). Pre-launch shares are written by the pad.
    function syncShares(address token, address from, address to) external {
        // The vault is shared with LaunchpadV3: only tokens this pad registered are FairTokens of this handler.
        if (dividendVault.launchpadOf(token) != address(pad)) return;
        if (FairToken(token).locked()) return;
        _sync(token, from);
        _sync(token, to);
    }

    /// @notice Keeper/owner only: sells `amount` (≤ `maxChunk(token)`) with a mandatory off-chain `minQuoteOut`.
    function process(address token, uint256 amount, uint256 minQuoteOut)
        external
        nonReentrant
        returns (uint256 quoteOut)
    {
        return _process(token, amount, minQuoteOut);
    }

    /// @inheritdoc ISwapBack
    function swapBack(address token, uint256 sellAmount) external nonReentrant returns (uint256 quoteOut) {
        if (dividendVault.launchpadOf(token) != address(pad)) revert UnknownToken();
        return _swapBack(token, sellAmount);
    }

    /// @notice Reward weight the rule gives `user` right now (0 when out or never minted).
    function eligibleShare(address token, address user) public view returns (uint256) {
        if (isOut[token][user] || dividendVault.excluded(user)) return 0;
        uint256 base = pad.baselineOf(token, user);
        if (base == 0) return 0;
        uint256 bal = IERC20(token).balanceOf(user);
        if (bal * BPS < base * pad.holdBpsOf(token)) return 0;
        return bal < base ? bal : base;
    }

    function _quoteOf(address token) internal view override returns (address quote) {
        quote = dividendVault.quoteOf(token);
        if (quote == address(0)) revert ZeroAddress();
    }

    function _sellTaxBps(address) internal pure override returns (uint256) {
        return 100; // FairToken.TAX_BPS
    }

    function _bucket() internal view override returns (PlatformFeeBucket) {
        return platformBucket;
    }

    function _takeAccrued(address, uint256, uint256, uint256) internal pure override returns (uint256) {
        return 0;
    }

    /// @dev The holders' quote is already in the vault (their units of this chunk); the rest is the platform's.
    function _onProceeds(address token, address quote, uint256 amount, uint256 quoteOut, uint256 toHolders, uint256)
        internal
        override
    {
        uint256 toPlatform = quoteOut - toHolders;
        _payPlatform(quote, toPlatform);

        emit OuterTaxProcessed(token, quote, amount, quoteOut, toHolders, toPlatform);
    }

    function _sync(address token, address user) internal {
        if (user == address(0)) return;
        uint256 base = pad.baselineOf(token, user);
        uint256 share;
        // base 0 (pair, handler, post-launch buyers, or a minter who sold everything back before launch) targets 0: a
        // share the pad could not clear on that sell-back (its vault write is non-blocking) is zeroed here.
        // Audit G-01: the vault does not clear shares on setExcluded, so an excluded user must target 0 here too —
        // comparing against its stale share would otherwise skip the write and keep it earning.
        if (base != 0 && !isOut[token][user] && !dividendVault.excluded(user)) {
            uint256 bal = IERC20(token).balanceOf(user);
            if (bal * BPS < base * pad.holdBpsOf(token)) {
                isOut[token][user] = true;
                emit Disqualified(token, user, bal, base);
            } else {
                share = bal < base ? bal : base;
            }
        }
        // Out users keep target 0 here, so a zeroing that failed earlier is retried on every later sync.
        // Runs inside token transfers: a vault-side failure (e.g. operator revoked) must not freeze trading.
        if (dividendVault.shares(token, user) != share) _setShareGuarded(token, user, share);
    }
}
