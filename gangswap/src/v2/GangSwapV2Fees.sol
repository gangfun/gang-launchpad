// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {
    IGangSwapV2Factory, IGangSwapV2Pair, IGangSwapV2PadView, IGangSwapV2FeeBucket, IGangSwapV2Boost
} from "./interfaces/IGangSwapV2.sol";

interface IGangSwapV2MigratorView {
    function padOf(address pair) external view returns (address);
}

/// @title GangSwapV2Fees
/// @notice Books accrued quote fees entirely to the platform through the first collection after the buy-back window.
///         The window includes the 60 seconds following the final step. Later collections split fees 70% creator,
///         30% platform.
/// @dev The bucket leg is a try: a bucket that refuses (operator revoked, bucket replaced) parks the platform share
///      for `flushPlatform` and never blocks the creator's share (review N4). No owner, nothing to change.
contract GangSwapV2Fees is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant CREATOR_BPS = 7_000;
    uint256 public constant GRACE = 60;
    uint256 internal constant BPS = 10_000;

    IGangSwapV2Factory public immutable factory;
    IGangSwapV2MigratorView public immutable migrator;
    IGangSwapV2FeeBucket public immutable bucket;
    address public immutable quote;
    address public immutable boost;

    mapping(address token => uint256) public creatorFeeOf;
    mapping(address token => bool) public windowClosed;
    uint256 public pendingPlatform;

    error ZeroAddress();
    error UnknownPair();
    error NotCreator();
    error OnlyBoost();
    error ZeroAmount();

    event FeesCollected(address indexed pair, address indexed token, uint256 amount, uint256 toCreator);
    event WindowClosed(address indexed token);
    event PlatformFlushed(uint256 amount);
    event PlatformDeferred(uint256 pending);
    event CreatorFeeClaimed(address indexed token, address indexed creator, address to, uint256 amount);

    constructor(address factory_, address migrator_, address bucket_, address quote_, address boost_) {
        if (
            factory_ == address(0) || migrator_ == address(0) || bucket_ == address(0) || quote_ == address(0)
                || boost_ == address(0)
        ) {
            revert ZeroAddress();
        }
        factory = IGangSwapV2Factory(factory_);
        migrator = IGangSwapV2MigratorView(migrator_);
        bucket = IGangSwapV2FeeBucket(bucket_);
        quote = quote_;
        boost = boost_;
    }

    function collect(address pair) external nonReentrant returns (uint256 amount) {
        (amount,) = _collect(pair, false);
        _flushPlatform();
    }

    /// @notice Books the pair's full fee to the platform from a buy-back step.
    function collectBoost(address pair) external nonReentrant returns (uint256 amount) {
        if (msg.sender != boost) revert OnlyBoost();
        (amount,) = _collect(pair, true);
    }

    function flushPlatform() external nonReentrant {
        _flushPlatform();
    }

    /// @notice The creator of `token` takes everything booked for it (collecting its pair first) to `to`.
    ///         The closing claim returns zero when there is nothing to pay.
    function claim(address token, address to) external nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        address pair = factory.getPair(token, quote);
        if (pair == address(0)) revert UnknownPair();
        (, bool platformOnly) = _collect(pair, false);
        if (msg.sender != creatorOf(token, pair)) revert NotCreator();
        amount = creatorFeeOf[token];
        if (amount == 0) {
            if (!platformOnly) revert ZeroAmount();
        } else {
            creatorFeeOf[token] = 0;
            IERC20(quote).safeTransfer(to, amount);
            emit CreatorFeeClaimed(token, msg.sender, to, amount);
        }
        _flushPlatform();
    }

    function creatorOf(address token, address pair) public view returns (address creator) {
        (creator,,,,,,,,,,,) = IGangSwapV2PadView(migrator.padOf(pair)).curves(token);
    }

    function _inWindow(address token) private view returns (bool) {
        (, uint64 lastStepAt,,, uint128 left) = IGangSwapV2Boost(boost).boosts(token);
        return left > 0 || block.timestamp < uint256(lastStepAt) + GRACE;
    }

    function _collect(address pair, bool forcePlatformOnly) private returns (uint256 amount, bool platformOnly) {
        // a pair this factory made (review M5); anything else could fake claimFees
        address t0 = IGangSwapV2Pair(pair).token0();
        address t1 = IGangSwapV2Pair(pair).token1();
        if (factory.getPair(t0, t1) != pair) revert UnknownPair();
        address token = t0 == quote ? t1 : t0;

        platformOnly = forcePlatformOnly || !windowClosed[token];
        if (!forcePlatformOnly && platformOnly && !_inWindow(token)) {
            windowClosed[token] = true;
            emit WindowClosed(token);
        }

        uint256 before = IERC20(quote).balanceOf(address(this));
        IGangSwapV2Pair(pair).claimFees();
        amount = IERC20(quote).balanceOf(address(this)) - before;
        if (amount == 0) return (0, platformOnly);
        uint256 toCreator;
        if (!platformOnly) {
            toCreator = (amount * CREATOR_BPS) / BPS;
            creatorFeeOf[token] += toCreator;
        }
        pendingPlatform += amount - toCreator;
        emit FeesCollected(pair, token, amount, toCreator);
    }

    function _flushPlatform() private {
        uint256 amount = pendingPlatform;
        if (amount == 0) return;
        IERC20(quote).forceApprove(address(bucket), amount);
        try bucket.notifyAccrual(quote, amount) {
            pendingPlatform = 0;
            emit PlatformFlushed(amount);
        } catch {
            emit PlatformDeferred(amount);
        }
        IERC20(quote).forceApprove(address(bucket), 0);
    }
}
