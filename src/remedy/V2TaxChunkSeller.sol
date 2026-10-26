// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IV2TaxHandlerLite {
    function dividendVault() external view returns (address);
    function platformBucket() external view returns (address);
}

interface IV2VaultLite {
    function excluded(address account) external view returns (bool);
}

interface IV2BucketLite {
    function notifyAccrual(address quote, uint256 amount) external;
}

interface IV2TaxTokenLite {
    function pair() external view returns (address);
    function taxHandler() external view returns (address);
}

interface IPairLite {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

interface IPancakeRouterLite {
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IMerkleQuoteDistributor {
    function fund(address token, address quote, uint256 amount) external;
}

/// @title V2TaxChunkSeller (正式站 V2 存量外盘税的补救)
/// @notice Plugged into a deployed V2 PostGradTaxHandler as its `router` (owner `setRouter`). The handler's
///         `process` sells a token's whole accrued tax in one swap; for a token the owner has `arm`ed, the next
///         `process` lands here instead: this contract takes the whole backlog, pays the handler 1 wei of quote
///         (so the handler's 50/50 split is 0 to holders, 1 wei to the platform) and keeps the tokens. The keeper
///         then sells the backlog in small chunks (`sellChunk`, each under `maxImpactBps` of price impact, with a
///         mandatory `minOut`): half of every chunk's quote goes to the platform, half to the Merkle distributor,
///         which pays holders by their holdings at the time each tax was paid (computed off-chain).
///         Every other `process` (unarmed tokens, and new tax on adopted tokens) passes straight through: the tax
///         goes from the handler into the token's pair and is swapped there, as the handler's own pair path does.
/// @dev The V2 token can't exclude this contract from its 1% pool tax (only the V2 launchpad can), so each chunk
///      pays 1% back to the handler as new tax, processed normally later. That transfer calls the handler's
///      `notifyTax`, which is `nonReentrant` like `process`: so nothing taxed may move while the handler calls
///      in here — adoption only pulls from the handler (tax-excluded), passthrough only moves handler → pair.
///      The V2 vault must exclude this contract before adoption (`adopt` checks), or the backlog would earn
///      dividend shares here.
contract V2TaxChunkSeller is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint256 public constant HOLDER_BPS = 5_000; // the V2 handler's DIV_SHARE_BPS: half of the tax is the holders'
    uint256 public constant TOKEN_TAX_BPS = 100; // V2 token OUTER_TAX_BPS, paid on every chunk sold into the pair
    uint256 public constant MAX_IMPACT_CAP_BPS = 500;
    uint256 public constant DEX_FEE_NUM = 9975; // Pancake V2: 0.25%
    uint256 public constant DEX_FEE_DEN = 10_000;

    address public immutable handler;
    IV2VaultLite public immutable vault;
    IPancakeRouterLite public immutable pancakeRouter;

    address public keeper;
    IMerkleQuoteDistributor public distributor;
    /// @notice Platform half: the handler's PlatformFeeBucket via `notifyAccrual` (this contract must be its
    ///         operator), or, when `platformViaBucket` is false, a plain transfer to `platformSink`.
    address public platformSink;
    bool public platformViaBucket;
    /// @notice Price-impact ceiling of one chunk (execution price vs spot, before the 0.25% LP fee).
    uint256 public maxImpactBps = 100;

    struct Backlog {
        address quote;
        uint256 adopted; // tokens taken from the handler at adoption
        uint256 sold; // tokens sold so far (gross, before the token's 1% tax)
        uint256 quoteOut;
        uint256 toHolders;
        uint256 toPlatform;
        uint64 adoptedAt;
        uint64 adoptedBlock;
    }

    /// @notice The owner opted this token in: the handler's next `process` for it is the adoption.
    mapping(address token => bool) public armed;
    /// @notice Spot price (quote per token, 1e18-scaled) a chunk may not push the pool below; 0 = no floor.
    ///         Chunking alone does not shrink the total sell pressure — with no buyers in between, the backlog
    ///         moves the price as much as one dump. The floor makes the keeper sell only into demand.
    mapping(address token => uint256) public floorOf;
    mapping(address token => Backlog) public backlogOf;

    event KeeperSet(address indexed keeper);
    event DistributorSet(address indexed distributor);
    event PlatformSet(address indexed sink, bool viaBucket);
    event MaxImpactSet(uint256 bps);
    event FloorSet(address indexed token, uint256 price);
    event Armed(address indexed token, bool armed);
    event Adopted(address indexed token, address indexed quote, uint256 amount, uint256 seedPaid);
    event Passthrough(address indexed token, uint256 amountIn, uint256 quoteOut);
    event ChunkSold(
        address indexed token, uint256 amountIn, uint256 quoteOut, uint256 toHolders, uint256 toPlatform, uint256 left
    );
    event Rescued(address indexed asset, address indexed to, uint256 amount);

    error OnlyHandler();
    error OnlyKeeperOrOwner();
    error ZeroAddress();
    error BadPath();
    error NotHandlersToken();
    error NotExcludedInVault();
    error AlreadyAdopted();
    error SeedMinOut();
    error NeedQuoteSeed();
    error NothingToSell();
    error TooMuch();
    error ImpactTooHigh(uint256 impactBps);
    error Slippage();
    error BadPair();
    error DistributorNotSet();
    error BadImpact();
    error BelowFloor(uint256 priceAfter, uint256 floor);

    constructor(address owner_, address handler_, address pancakeRouter_, address distributor_) Ownable(owner_) {
        if (handler_ == address(0) || pancakeRouter_ == address(0)) revert ZeroAddress();
        handler = handler_;
        vault = IV2VaultLite(IV2TaxHandlerLite(handler_).dividendVault());
        pancakeRouter = IPancakeRouterLite(pancakeRouter_);
        distributor = IMerkleQuoteDistributor(distributor_);
        platformSink = IV2TaxHandlerLite(handler_).platformBucket();
        platformViaBucket = true;
    }

    // ---------------------------------------------------------------- admin
    function setKeeper(address keeper_) external onlyOwner {
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    function setDistributor(address distributor_) external onlyOwner {
        distributor = IMerkleQuoteDistributor(distributor_);
        emit DistributorSet(distributor_);
    }

    function setPlatform(address sink, bool viaBucket) external onlyOwner {
        if (sink == address(0)) revert ZeroAddress();
        platformSink = sink;
        platformViaBucket = viaBucket;
        emit PlatformSet(sink, viaBucket);
    }

    function setMaxImpactBps(uint256 bps) external onlyOwner {
        if (bps == 0 || bps > MAX_IMPACT_CAP_BPS) revert BadImpact();
        maxImpactBps = bps;
        emit MaxImpactSet(bps);
    }

    function setFloor(address token, uint256 price) external onlyOwner {
        floorOf[token] = price;
        emit FloorSet(token, price);
    }

    /// @notice Opt `token` in (or back out before adoption). Only tokens whose tax goes to this seller's handler.
    function arm(address token, bool on) external onlyOwner {
        if (IV2TaxTokenLite(token).taxHandler() != handler) revert NotHandlersToken();
        if (backlogOf[token].adopted != 0) revert AlreadyAdopted();
        armed[token] = on;
        emit Armed(token, on);
    }

    /// @notice Emergency exit: move any token or quote out (e.g. an unsold backlog back to the multisig).
    function rescue(address asset, address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        IERC20(asset).safeTransfer(to, amount);
        emit Rescued(asset, to, amount);
    }

    // ---------------------------------------------------------------- the handler's "router"
    /// @notice Called only by the handler, inside its `process` (the handler holds its reentrancy lock).
    ///         Armed token: adoption (pull everything, pay 1 wei). Otherwise: swap in the token's own pair.
    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 /* deadline */
    ) external nonReentrant {
        if (msg.sender != handler) revert OnlyHandler();
        if (path.length != 2 || to != handler) revert BadPath();
        address token = path[0];
        address quote = path[1];
        if (armed[token]) {
            _adopt(token, quote, amountIn, amountOutMin);
        } else {
            _passthrough(token, quote, amountIn, amountOutMin);
        }
    }

    // ---------------------------------------------------------------- keeper
    /// @notice Sell `amountIn` of `token`'s backlog into its pair; at most `maxImpactBps`, at least `minOut`.
    function sellChunk(address token, uint256 amountIn, uint256 minOut) external nonReentrant returns (uint256 got) {
        if (msg.sender != keeper && msg.sender != owner()) revert OnlyKeeperOrOwner();
        if (address(distributor) == address(0)) revert DistributorNotSet();
        Backlog storage b = backlogOf[token];
        uint256 left = b.adopted - b.sold;
        if (left == 0 || amountIn == 0) revert NothingToSell();
        if (amountIn > left) revert TooMuch();
        if (minOut == 0) revert Slippage();

        uint256 impact = impactBpsOf(token, amountIn);
        if (impact > maxImpactBps) revert ImpactTooHigh(impact);

        address quote = b.quote;
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = quote;
        IERC20(token).forceApprove(address(pancakeRouter), amountIn);
        uint256 before = IERC20(quote).balanceOf(address(this));
        pancakeRouter.swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountIn, minOut, path, address(this), block.timestamp
        );
        got = IERC20(quote).balanceOf(address(this)) - before;
        if (got < minOut) revert Slippage();
        uint256 floor = floorOf[token];
        if (floor != 0) {
            uint256 p = spotOf(token);
            if (p < floor) revert BelowFloor(p, floor);
        }

        uint256 toHolders = (got * HOLDER_BPS) / BPS;
        uint256 toPlatform = got - toHolders;
        b.sold += amountIn;
        b.quoteOut += got;
        b.toHolders += toHolders;
        b.toPlatform += toPlatform;

        IERC20(quote).forceApprove(address(distributor), toHolders);
        distributor.fund(token, quote, toHolders);
        if (platformViaBucket) {
            IERC20(quote).forceApprove(platformSink, toPlatform);
            IV2BucketLite(platformSink).notifyAccrual(quote, toPlatform);
        } else {
            IERC20(quote).safeTransfer(platformSink, toPlatform);
        }
        emit ChunkSold(token, amountIn, got, toHolders, toPlatform, b.adopted - b.sold);
    }

    // ---------------------------------------------------------------- views
    /// @notice Pool spot price, quote per token, 1e18-scaled.
    function spotOf(address token) public view returns (uint256) {
        (uint256 rIn, uint256 rOut) = _reserves(token, backlogOf[token].quote);
        return (rOut * 1e18) / rIn;
    }

    /// @notice Price impact (bps) of selling `amountIn` gross: the 1% token tax is taken first, the LP fee ignored.
    function impactBpsOf(address token, uint256 amountIn) public view returns (uint256) {
        (uint256 rIn,) = _reserves(token, backlogOf[token].quote);
        uint256 eff = (amountIn * (BPS - TOKEN_TAX_BPS)) / BPS;
        return (eff * BPS) / (rIn + eff);
    }

    /// @notice Largest gross chunk within `maxImpactBps` now (capped at what is left).
    function maxChunk(address token) external view returns (uint256 amountIn) {
        Backlog storage b = backlogOf[token];
        uint256 left = b.adopted - b.sold;
        if (left == 0) return 0;
        (uint256 rIn,) = _reserves(token, b.quote);
        // eff / (rIn + eff) <= m  ⇔  eff <= rIn·m / (BPS − m); gross = eff / 0.99 (rounded down twice: stays under)
        uint256 eff = (rIn * maxImpactBps) / (BPS - maxImpactBps);
        amountIn = (eff * BPS) / (BPS - TOKEN_TAX_BPS);
        if (amountIn > left) amountIn = left;
    }

    /// @notice Quote a chunk would bring right now (after the 1% token tax and the 0.25% LP fee).
    function quoteChunk(address token, uint256 amountIn) external view returns (uint256) {
        (uint256 rIn, uint256 rOut) = _reserves(token, backlogOf[token].quote);
        return _amountOut((amountIn * (BPS - TOKEN_TAX_BPS)) / BPS, rIn, rOut);
    }

    function leftOf(address token) external view returns (uint256) {
        Backlog storage b = backlogOf[token];
        return b.adopted - b.sold;
    }

    // ---------------------------------------------------------------- internal
    function _adopt(address token, address quote, uint256 amountIn, uint256 amountOutMin) internal {
        Backlog storage b = backlogOf[token];
        if (b.adopted != 0) revert AlreadyAdopted();
        if (amountOutMin != 1) revert SeedMinOut(); // the owner runs adoption with process(token, 1), on purpose
        if (!vault.excluded(address(this))) revert NotExcludedInVault();
        if (IERC20(quote).balanceOf(address(this)) == 0) revert NeedQuoteSeed();
        armed[token] = false;
        b.quote = quote;
        b.adopted = amountIn;
        b.adoptedAt = uint64(block.timestamp);
        b.adoptedBlock = uint64(block.number);
        // handler → here: the handler is tax-excluded on the token, so this moves exactly amountIn, untaxed
        IERC20(token).safeTransferFrom(handler, address(this), amountIn);
        IERC20(quote).safeTransfer(handler, 1);
        emit Adopted(token, quote, amountIn, 1);
    }

    /// @dev The handler's own fee-aware pair path: handler → pair (untaxed, the handler is excluded), then swap.
    function _passthrough(address token, address quote, uint256 amountIn, uint256 amountOutMin) internal {
        address pair = IV2TaxTokenLite(token).pair();
        if (pair == address(0)) revert BadPair();
        (uint256 rIn, uint256 rOut) = _reserves(token, quote);
        IERC20(token).safeTransferFrom(handler, pair, amountIn);
        uint256 arrived = IERC20(token).balanceOf(pair) - rIn;
        uint256 out = _amountOut(arrived, rIn, rOut);
        if (out == 0 || out < amountOutMin) revert Slippage();
        bool tokenIs0 = IPairLite(pair).token0() == token;
        IPairLite(pair).swap(tokenIs0 ? 0 : out, tokenIs0 ? out : 0, handler, "");
        emit Passthrough(token, amountIn, out);
    }

    /// @dev (reserve of token, reserve of quote) in the token's own pair; the pair must be token/quote.
    function _reserves(address token, address quote) internal view returns (uint256 rIn, uint256 rOut) {
        address pair = IV2TaxTokenLite(token).pair();
        if (pair == address(0)) revert BadPair();
        address t0 = IPairLite(pair).token0();
        address t1 = IPairLite(pair).token1();
        if (!((t0 == token && t1 == quote) || (t1 == token && t0 == quote))) revert BadPair();
        (uint112 r0, uint112 r1,) = IPairLite(pair).getReserves();
        (rIn, rOut) = t0 == token ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }

    function _amountOut(uint256 amountIn, uint256 rIn, uint256 rOut) internal pure returns (uint256) {
        if (amountIn == 0 || rIn == 0 || rOut == 0) return 0;
        uint256 inWithFee = amountIn * DEX_FEE_NUM;
        return (inWithFee * rOut) / (rIn * DEX_FEE_DEN + inWithFee);
    }
}
