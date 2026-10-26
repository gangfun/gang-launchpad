// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {DividendVault} from "../launchpad-v2/DividendVault.sol";
import {PlatformFeeBucket} from "../launchpad-v2/PlatformFeeBucket.sol";
import {IPostGradTaxHandler} from "../launchpad-v2/interfaces/IPostGradTaxHandler.sol";
import {IUniswapV2PairLite} from "../launchpad-v2/interfaces/IUniswapV2PairLite.sol";
import {IPancakeRouter02} from "../launchpad-v2/interfaces/IPancake.sol";
import {FairToken} from "./FairToken.sol";

interface IFairMintPadView {
    function baselineOf(address token, address user) external view returns (uint256);
    function holdBpsOf(address token) external view returns (uint16);
}

interface IUniswapV2PairSwap4F {
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

/// @title HolderRewardHandler (打新发射 · 发射后 1% 税)
/// @notice Accrues the 1% tax in tokens; the keeper sells it and splits 50% to pre-launch holders
///         (DividendVault) / 50% to PlatformFeeBucket. With no eligible holder left, 100% goes to the bucket.
/// @dev Reward share of a minter = min(balance, baseline) where baseline = tokens minted pre-launch.
///      Once balance < baseline × holdBps, the minter is out for good (buying back does not restore it).
///      Everyone else (pair, handler, post-launch buyers) has baseline 0 and never holds shares.
///      Must be a DividendVault operator and a PlatformFeeBucket operator.
contract HolderRewardHandler is IPostGradTaxHandler, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant HOLDER_SHARE_BPS = 5_000;
    uint256 public constant DEX_FEE_NUM = 9975;
    uint256 public constant DEX_FEE_DEN = 10000;

    DividendVault public immutable dividendVault;
    PlatformFeeBucket public immutable platformBucket;
    IFairMintPadView public pad;

    IPancakeRouter02 public router;
    address public keeper;
    mapping(address => uint256) public accruedTax;
    mapping(address token => mapping(address user => bool)) public isOut;

    error OnlyToken();
    error ZeroAddress();
    error ZeroAmount();
    error NoPair();
    error SwapFailed();
    error Slippage();
    error OnlyKeeperOrOwner();
    error PadAlreadySet();
    error OutOfGas();

    event PadSet(address indexed pad);
    event RouterSet(address indexed router);
    event KeeperSet(address indexed keeper);
    event TaxAccrued(
        address indexed token, address indexed from, address indexed to, uint256 taxAmount, uint256 accrued
    );
    event OuterTaxProcessed(
        address indexed token,
        address indexed quote,
        uint256 taxTokens,
        uint256 quoteOut,
        uint256 toHolders,
        uint256 toPlatform
    );
    event Disqualified(address indexed token, address indexed user, uint256 balance, uint256 baseline);

    constructor(address owner_, address dividendVault_, address platformBucket_) Ownable(owner_) {
        if (dividendVault_ == address(0) || platformBucket_ == address(0)) revert ZeroAddress();
        dividendVault = DividendVault(dividendVault_);
        platformBucket = PlatformFeeBucket(platformBucket_);
    }

    /// @notice One-shot: the pad that defines baselines.
    function setPad(address pad_) external onlyOwner {
        if (address(pad) != address(0)) revert PadAlreadySet();
        if (pad_ == address(0)) revert ZeroAddress();
        pad = IFairMintPadView(pad_);
        emit PadSet(pad_);
    }

    function setRouter(address router_) external onlyOwner {
        if (router_ == address(0)) revert ZeroAddress();
        router = IPancakeRouter02(router_);
        emit RouterSet(router_);
    }

    function setKeeper(address keeper_) external onlyOwner {
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    /// @inheritdoc IPostGradTaxHandler
    function notifyTax(address token, address from, address to, uint256 taxAmount) external nonReentrant {
        if (msg.sender != token) revert OnlyToken();
        if (taxAmount == 0) revert ZeroAmount();
        accruedTax[token] += taxAmount;
        emit TaxAccrued(token, from, to, taxAmount, accruedTax[token]);
    }

    /// @inheritdoc IPostGradTaxHandler
    /// @dev Permissionless: it only applies the rule to true balances. Never reverts for unknown / locked tokens
    ///      (runs inside token transfers). Pre-launch shares are written by the pad.
    function syncShares(address token, address from, address to) external {
        // Only the pad registers tokens in this vault, so a registered token is a FairToken.
        if (dividendVault.quoteOf(token) == address(0)) return;
        if (FairToken(token).locked()) return;
        _sync(token, from);
        _sync(token, to);
    }

    /// @inheritdoc IPostGradTaxHandler
    /// @dev Keeper/owner only with a mandatory off-chain `minQuoteOut` (V2 H1).
    function process(address token, uint256 minQuoteOut) external nonReentrant returns (uint256 quoteOut) {
        if (msg.sender != keeper && msg.sender != owner()) revert OnlyKeeperOrOwner();
        if (minQuoteOut == 0) revert ZeroAmount();
        uint256 amount = accruedTax[token];
        if (amount == 0) revert ZeroAmount();

        address pair = FairToken(token).pair();
        if (pair == address(0)) revert NoPair();
        address quote = dividendVault.quoteOf(token);
        if (quote == address(0)) revert ZeroAddress();

        uint256 bal = IERC20(token).balanceOf(address(this));
        if (amount > bal) amount = bal;
        if (amount == 0) revert ZeroAmount();
        accruedTax[token] = 0;

        if (address(router) != address(0)) {
            quoteOut = _swapViaRouter(token, quote, amount, minQuoteOut);
        } else {
            quoteOut = _swapViaPair(token, pair, quote, amount, minQuoteOut);
        }

        // No eligible holder left → the holder half would be stuck in the vault; send it to the platform.
        uint256 toHolders = dividendVault.totalShares(token) == 0 ? 0 : (quoteOut * HOLDER_SHARE_BPS) / BPS;
        uint256 toPlatform = quoteOut - toHolders;

        if (toHolders > 0) {
            IERC20(quote).forceApprove(address(dividendVault), toHolders);
            dividendVault.depositReward(token, toHolders);
        }
        if (toPlatform > 0) {
            IERC20(quote).forceApprove(address(platformBucket), toPlatform);
            platformBucket.notifyAccrual(quote, toPlatform);
        }

        emit OuterTaxProcessed(token, quote, amount, quoteOut, toHolders, toPlatform);
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

    function _sync(address token, address user) internal {
        if (user == address(0)) return;
        uint256 base = pad.baselineOf(token, user);
        if (base == 0) return; // pair / handler / post-launch buyers: never had a share
        uint256 share;
        // Audit G-01: the vault does not clear shares on setExcluded, so an excluded user must target 0 here too —
        // comparing against its stale share would otherwise skip the write and keep it earning.
        if (!isOut[token][user] && !dividendVault.excluded(user)) {
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
        if (dividendVault.shares(token, user) != share) {
            uint256 gasBefore = gasleft();
            try dividendVault.setShare(token, user, share) {}
            catch {
                // the caller starved the call (63/64 rule) rather than the vault refusing: swallowing that would let
                // a transfer pick the gas that leaves a stale share behind
                if (gasleft() <= gasBefore / 63) revert OutOfGas();
            }
        }
    }

    function _swapViaRouter(address token, address quote, uint256 amountIn, uint256 minQuoteOut)
        internal
        returns (uint256 quoteOut)
    {
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = quote;

        IERC20(token).forceApprove(address(router), amountIn);
        uint256 before = IERC20(quote).balanceOf(address(this));
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountIn, minQuoteOut, path, address(this), block.timestamp
        );
        quoteOut = IERC20(quote).balanceOf(address(this)) - before;
        if (quoteOut == 0) revert SwapFailed();
        if (quoteOut < minQuoteOut) revert Slippage();
    }

    /// @dev Direct pair swap with the Pancake V2 0.25% fee; prices what the pair actually received
    ///      (the handler is tax-excluded, so that equals `amountIn`).
    function _swapViaPair(address token, address pair, address quote, uint256 amountIn, uint256 minQuoteOut)
        internal
        returns (uint256 quoteOut)
    {
        address t0 = IUniswapV2PairLite(pair).token0();
        bool tokenIs0 = token == t0;
        if (!tokenIs0 && token != IUniswapV2PairLite(pair).token1()) revert SwapFailed();
        if (quote != (tokenIs0 ? IUniswapV2PairLite(pair).token1() : t0)) revert SwapFailed();
        (uint112 r0, uint112 r1,) = IUniswapV2PairLite(pair).getReserves();
        (uint256 reserveIn, uint256 reserveOut) = tokenIs0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        if (reserveIn == 0 || reserveOut == 0) revert SwapFailed();

        uint256 inWithFee = amountIn * DEX_FEE_NUM;
        uint256 out = (inWithFee * reserveOut) / (reserveIn * DEX_FEE_DEN + inWithFee);
        if (out == 0 || out >= reserveOut) revert SwapFailed();
        if (out < minQuoteOut) revert Slippage();

        IERC20(token).safeTransfer(pair, amountIn);
        uint256 before = IERC20(quote).balanceOf(address(this));
        if (tokenIs0) IUniswapV2PairSwap4F(pair).swap(0, out, address(this), "");
        else IUniswapV2PairSwap4F(pair).swap(out, 0, address(this), "");
        quoteOut = IERC20(quote).balanceOf(address(this)) - before;
    }
}
