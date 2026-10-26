// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ITaxRouter} from "./interfaces/ITaxRouter.sol";

interface IDividendVaultV3 {
    function totalShares(address token) external view returns (uint256);
    function depositReward(address token, uint256 amount) external;
}

interface IPlatformFeeBucketV3 {
    function notifyAccrual(address quote, uint256 amount) external;
}

/// @title TaxRouterV3 (LaunchpadV3 · one split for every tax payment)
/// @notice Each tax payment (quote) → the platform's part (0.5% of the trade's volume, computed by the payer) →
///         `dividendBps` of the rest to DividendVault → the remainder to the token's tax recipient, in quote.
/// @dev Must be an operator on DividendVault and PlatformFeeBucket.
///      Never reverts because of the recipient: the push is a low-level transfer; a failed one is booked as `owedOf`
///      and anyone can `release` it later. Every payment that reaches the recipient emits `TaxPaid`.
///      Dividend leg with zero total shares would strand funds in DividendVault → recipient, else platform.
contract TaxRouterV3 is ITaxRouter, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;

    struct Route {
        address quote;
        address recipient;
        uint16 dividendBps;
    }

    IDividendVaultV3 public immutable dividendVault;
    IPlatformFeeBucketV3 public immutable platformBucket;

    address public launchpad;
    mapping(address => bool) public sources;
    mapping(address token => Route) public routeOf;
    /// @notice Quote owed to `token`'s recipient after a failed push.
    mapping(address token => uint256) public owedOf;

    event LaunchpadSet(address indexed launchpad);
    event SourceUpdated(address indexed source, bool enabled);
    event RouteRegistered(address indexed token, address quote, address indexed recipient, uint16 dividendBps);
    event TaxDistributed(
        address indexed token, Phase phase, uint256 amount, uint256 toPlatform, uint256 toDividend, uint256 toRecipient
    );
    /// @notice Quote that reached the recipient (a direct push, or a `release` of what was owed).
    event TaxPaid(address indexed token, address indexed recipient, address indexed quote, uint256 amount);
    /// @notice A push that failed; `release(token)` sends it.
    event TaxOwed(address indexed token, address indexed recipient, address indexed quote, uint256 amount);

    error ZeroAddress();
    error LaunchpadAlreadySet();
    error OnlyLaunchpad();
    error OnlySource();
    error AlreadyRegistered();
    error UnknownToken();
    error BadDividendBps();
    error BadPlatformAmount();
    error NothingOwed();

    constructor(address owner_, address dividendVault_, address platformBucket_) Ownable(owner_) {
        if (dividendVault_ == address(0) || platformBucket_ == address(0)) revert ZeroAddress();
        dividendVault = IDividendVaultV3(dividendVault_);
        platformBucket = IPlatformFeeBucketV3(platformBucket_);
    }

    /// @notice One-shot. The launchpad is also a source (bonding-phase tax).
    function setLaunchpad(address launchpad_) external onlyOwner {
        if (launchpad_ == address(0)) revert ZeroAddress();
        if (launchpad != address(0)) revert LaunchpadAlreadySet();
        launchpad = launchpad_;
        sources[launchpad_] = true;
        emit LaunchpadSet(launchpad_);
        emit SourceUpdated(launchpad_, true);
    }

    /// @dev Sources only ever pay in; a rogue source cannot take anything out.
    function setSource(address source, bool enabled) external onlyOwner {
        if (source == address(0)) revert ZeroAddress();
        sources[source] = enabled;
        emit SourceUpdated(source, enabled);
    }

    /// @inheritdoc ITaxRouter
    function register(address token, address quote, address recipient, uint16 dividendBps) external {
        if (msg.sender != launchpad) revert OnlyLaunchpad();
        if (token == address(0) || quote == address(0)) revert ZeroAddress();
        if (routeOf[token].quote != address(0)) revert AlreadyRegistered();
        if (dividendBps > BPS || (recipient == address(0) && dividendBps != BPS)) revert BadDividendBps();
        routeOf[token] = Route({quote: quote, recipient: recipient, dividendBps: dividendBps});
        emit RouteRegistered(token, quote, recipient, dividendBps);
    }

    /// @inheritdoc ITaxRouter
    function distribute(address token, uint256 amount, uint256 platformAmount, Phase phase) external nonReentrant {
        if (!sources[msg.sender]) revert OnlySource();
        Route memory r = routeOf[token];
        if (r.quote == address(0)) revert UnknownToken();
        if (platformAmount > amount) revert BadPlatformAmount();
        if (amount == 0) return;

        IERC20 quote = IERC20(r.quote);
        uint256 beforeBal = quote.balanceOf(address(this));
        quote.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = quote.balanceOf(address(this)) - beforeBal;
        // fee-on-transfer quote: every leg shrinks in proportion
        if (received != amount) platformAmount = (platformAmount * received) / amount;

        (uint256 toPlatform, uint256 toDividend, uint256 toRecipient) = _split(token, r, received, platformAmount);

        if (toPlatform > 0) {
            quote.forceApprove(address(platformBucket), toPlatform);
            platformBucket.notifyAccrual(r.quote, toPlatform);
        }
        if (toDividend > 0) {
            quote.forceApprove(address(dividendVault), toDividend);
            dividendVault.depositReward(token, toDividend);
        }
        if (toRecipient > 0) {
            if (_tryTransfer(r.quote, r.recipient, toRecipient)) {
                emit TaxPaid(token, r.recipient, r.quote, toRecipient);
            } else {
                owedOf[token] += toRecipient;
                emit TaxOwed(token, r.recipient, r.quote, toRecipient);
            }
        }

        emit TaxDistributed(token, phase, received, toPlatform, toDividend, toRecipient);
    }

    /// @inheritdoc ITaxRouter
    /// @dev Reverts while the recipient still cannot receive, so nothing owed is ever lost.
    function release(address token) external nonReentrant returns (uint256 amount) {
        amount = owedOf[token];
        if (amount == 0) revert NothingOwed();
        Route memory r = routeOf[token];
        owedOf[token] = 0;
        IERC20(r.quote).safeTransfer(r.recipient, amount);
        emit TaxPaid(token, r.recipient, r.quote, amount);
    }

    /// @inheritdoc ITaxRouter
    function previewSplit(address token, uint256 amount, uint256 platformAmount)
        external
        view
        returns (uint256 toPlatform, uint256 toDividend, uint256 toRecipient)
    {
        Route memory r = routeOf[token];
        if (r.quote == address(0)) revert UnknownToken();
        if (platformAmount > amount) revert BadPlatformAmount();
        return _split(token, r, amount, platformAmount);
    }

    function _split(address token, Route memory r, uint256 amount, uint256 platformAmount)
        internal
        view
        returns (uint256 toPlatform, uint256 toDividend, uint256 toRecipient)
    {
        toPlatform = platformAmount;
        uint256 rest = amount - platformAmount;
        toDividend = (rest * r.dividendBps) / BPS;
        toRecipient = rest - toDividend;

        if (toDividend > 0 && dividendVault.totalShares(token) == 0) {
            if (r.recipient != address(0)) toRecipient += toDividend;
            else toPlatform += toDividend;
            toDividend = 0;
        }
    }

    /// @dev OZ 5.1 has no trySafeTransfer. Accepts tokens that return nothing (USDT-style) or `true`.
    function _tryTransfer(address quote, address to, uint256 amount) internal returns (bool) {
        (bool ok, bytes memory ret) = quote.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!ok) return false;
        if (ret.length == 0) return quote.code.length > 0;
        return ret.length >= 32 && abi.decode(ret, (bool));
    }
}
