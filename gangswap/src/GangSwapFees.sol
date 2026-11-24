// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IGangSwapFactory, IGangSwapPair, IGangSwapPadView, IGangSwapFeeBucket} from "./interfaces/IGangSwap.sol";

interface IGangSwapMigratorView {
    function padOf(address pair) external view returns (address);
}

/// @title GangSwapFees (the pairs' quote fee: 70% creator, 30% platform)
/// @notice `collect(pair)` (anyone) claims a GangSwap pair's accrued quote fee and splits what actually arrived: 70%
///         booked to the token's creator (read from the pad that graduated it), 30% to the platform bucket. The
///         creator pulls with `claim`. Spec: docs/SPEC-GANGSWAP-2026-11-22.md §6.4.
/// @dev The bucket leg is a try: a bucket that refuses (operator revoked, bucket replaced) parks the platform share
///      for `flushPlatform` and never blocks the creator's share (review N4). No owner, nothing to change.
contract GangSwapFees is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant CREATOR_BPS = 7_000;
    uint256 internal constant BPS = 10_000;

    IGangSwapFactory public immutable factory;
    IGangSwapMigratorView public immutable migrator;
    IGangSwapFeeBucket public immutable bucket;
    address public immutable quote;

    mapping(address token => uint256) public creatorFeeOf;
    uint256 public pendingPlatform;

    error ZeroAddress();
    error UnknownPair();
    error NotCreator();
    error ZeroAmount();

    event FeesCollected(address indexed pair, address indexed token, uint256 amount, uint256 toCreator);
    event PlatformFlushed(uint256 amount);
    event PlatformDeferred(uint256 pending);
    event CreatorFeeClaimed(address indexed token, address indexed creator, address to, uint256 amount);

    constructor(address factory_, address migrator_, address bucket_, address quote_) {
        if (factory_ == address(0) || migrator_ == address(0) || bucket_ == address(0) || quote_ == address(0)) {
            revert ZeroAddress();
        }
        factory = IGangSwapFactory(factory_);
        migrator = IGangSwapMigratorView(migrator_);
        bucket = IGangSwapFeeBucket(bucket_);
        quote = quote_;
    }

    function collect(address pair) external nonReentrant returns (uint256 amount) {
        amount = _collect(pair);
        _flushPlatform();
    }

    function flushPlatform() external nonReentrant {
        _flushPlatform();
    }

    /// @notice The creator of `token` takes everything booked for it (collecting its pair first) to `to`.
    function claim(address token, address to) external nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        address pair = factory.getPair(token, quote);
        if (pair == address(0)) revert UnknownPair();
        _collect(pair);
        if (msg.sender != creatorOf(token, pair)) revert NotCreator();
        amount = creatorFeeOf[token];
        if (amount == 0) revert ZeroAmount();
        creatorFeeOf[token] = 0;
        IERC20(quote).safeTransfer(to, amount);
        emit CreatorFeeClaimed(token, msg.sender, to, amount);
        _flushPlatform();
    }

    function creatorOf(address token, address pair) public view returns (address creator) {
        (creator,,,,,,,,,,,) = IGangSwapPadView(migrator.padOf(pair)).curves(token);
    }

    function _collect(address pair) private returns (uint256 amount) {
        // a pair this factory made (review M5); anything else could fake claimFees
        address t0 = IGangSwapPair(pair).token0();
        address t1 = IGangSwapPair(pair).token1();
        if (factory.getPair(t0, t1) != pair) revert UnknownPair();
        address token = t0 == quote ? t1 : t0;

        uint256 before = IERC20(quote).balanceOf(address(this));
        IGangSwapPair(pair).claimFees();
        amount = IERC20(quote).balanceOf(address(this)) - before;
        if (amount == 0) return 0;
        uint256 toCreator = (amount * CREATOR_BPS) / BPS;
        creatorFeeOf[token] += toCreator;
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
