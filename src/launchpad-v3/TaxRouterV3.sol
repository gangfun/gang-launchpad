// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ITaxRouter} from "./interfaces/ITaxRouter.sol";
import {IVault} from "./interfaces/IVault.sol";
import {TemplateTypes} from "./interfaces/TemplateTypes.sol";

interface IDividendVaultV3 {
    function totalShares(address token) external view returns (uint256);
    function depositReward(address token, uint256 amount) external;
}

interface IPlatformFeeBucketV3 {
    function notifyAccrual(address quote, uint256 amount) external;
}

/// @title TaxRouterV3 (LaunchpadV3 · one split for every tax payment)
/// @notice Each tax payment (quote) → 30% platform / 70% token side. An external template author takes 10% of the
///         payment out of the platform's 30%. Token side → `dividendBps` DividendVault, rest → template vault.
/// @dev Must be an operator on DividendVault and PlatformFeeBucket.
///      Never reverts because of a vault: the push is a low-level transfer (failure → `owed`, anyone can
///      `release`), the hook runs with capped gas in try/catch. Author earnings are always pull (`owed`), so a
///      blacklisted author address on e.g. USDT cannot block curve trades.
///      Dividend leg with zero total shares would strand funds in DividendVault → rolls to vault, else platform.
contract TaxRouterV3 is ITaxRouter, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    /// @dev Platform total per payment (author cut, if any, comes out of this). Lazy: pending sign-off.
    uint256 public constant PLATFORM_SHARE_BPS = 3_000;
    uint256 public constant AUTHOR_SHARE_BPS = 1_000;
    uint256 public constant VAULT_HOOK_GAS = 150_000;

    struct Route {
        address quote;
        address vault;
        address author;
        uint16 dividendBps;
    }

    IDividendVaultV3 public immutable dividendVault;
    IPlatformFeeBucketV3 public immutable platformBucket;

    address public launchpad;
    mapping(address => bool) public sources;
    mapping(address token => Route) public routeOf;
    mapping(address account => mapping(address quote => uint256)) public owed;

    event LaunchpadSet(address indexed launchpad);
    event SourceUpdated(address indexed source, bool enabled);
    event RouteRegistered(
        address indexed token, address quote, address indexed vault, address indexed author, uint16 dividendBps
    );
    event TaxDistributed(
        address indexed token,
        TemplateTypes.Phase phase,
        uint256 amount,
        uint256 toPlatform,
        uint256 toAuthor,
        uint256 toDividend,
        uint256 toVault
    );
    event Owed(address indexed account, address indexed quote, uint256 amount);
    event Released(address indexed account, address indexed quote, uint256 amount);

    error ZeroAddress();
    error LaunchpadAlreadySet();
    error OnlyLaunchpad();
    error OnlySource();
    error AlreadyRegistered();
    error UnknownToken();
    error BadDividendBps();
    error NotContract();

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
    function register(address token, address quote, address vault, address author, uint16 dividendBps) external {
        if (msg.sender != launchpad) revert OnlyLaunchpad();
        if (token == address(0) || quote == address(0)) revert ZeroAddress();
        if (routeOf[token].quote != address(0)) revert AlreadyRegistered();
        if (dividendBps > BPS || (vault == address(0) && dividendBps != BPS)) revert BadDividendBps();
        if (vault != address(0) && vault.code.length == 0) revert NotContract();
        routeOf[token] = Route({quote: quote, vault: vault, author: author, dividendBps: dividendBps});
        emit RouteRegistered(token, quote, vault, author, dividendBps);
    }

    /// @inheritdoc ITaxRouter
    function distribute(address token, uint256 amount, TemplateTypes.Phase phase) external nonReentrant {
        if (!sources[msg.sender]) revert OnlySource();
        Route memory r = routeOf[token];
        if (r.quote == address(0)) revert UnknownToken();
        if (amount == 0) return;

        IERC20 quote = IERC20(r.quote);
        uint256 beforeBal = quote.balanceOf(address(this));
        quote.safeTransferFrom(msg.sender, address(this), amount);
        amount = quote.balanceOf(address(this)) - beforeBal; // fee-on-transfer quotes

        (uint256 toPlatform, uint256 toAuthor, uint256 toDividend, uint256 toVault) = _split(token, r, amount);

        if (toPlatform > 0) {
            quote.forceApprove(address(platformBucket), toPlatform);
            platformBucket.notifyAccrual(r.quote, toPlatform);
        }
        if (toAuthor > 0) _credit(r.author, r.quote, toAuthor);
        if (toDividend > 0) {
            quote.forceApprove(address(dividendVault), toDividend);
            dividendVault.depositReward(token, toDividend);
        }
        if (toVault > 0) {
            if (_tryTransfer(r.quote, r.vault, toVault)) {
                try IVault(r.vault).onTaxReceived{gas: VAULT_HOOK_GAS}(toVault, phase) {} catch {}
            } else {
                _credit(r.vault, r.quote, toVault);
            }
        }

        emit TaxDistributed(token, phase, amount, toPlatform, toAuthor, toDividend, toVault);
    }

    /// @inheritdoc ITaxRouter
    function release(address account, address quote) external nonReentrant returns (uint256 amount) {
        amount = owed[account][quote];
        if (amount == 0) return 0;
        owed[account][quote] = 0;
        IERC20(quote).safeTransfer(account, amount);
        emit Released(account, quote, amount);
    }

    /// @inheritdoc ITaxRouter
    function previewSplit(address token, uint256 amount)
        external
        view
        returns (uint256 toPlatform, uint256 toAuthor, uint256 toDividend, uint256 toVault)
    {
        Route memory r = routeOf[token];
        if (r.quote == address(0)) revert UnknownToken();
        return _split(token, r, amount);
    }

    function _split(address token, Route memory r, uint256 amount)
        internal
        view
        returns (uint256 toPlatform, uint256 toAuthor, uint256 toDividend, uint256 toVault)
    {
        uint256 platformTotal = (amount * PLATFORM_SHARE_BPS) / BPS;
        toAuthor = r.author == address(0) ? 0 : (amount * AUTHOR_SHARE_BPS) / BPS;
        toPlatform = platformTotal - toAuthor;

        uint256 tokenSide = amount - platformTotal;
        toDividend = (tokenSide * r.dividendBps) / BPS;
        toVault = tokenSide - toDividend;

        if (toDividend > 0 && dividendVault.totalShares(token) == 0) {
            if (r.vault != address(0)) toVault += toDividend;
            else toPlatform += toDividend;
            toDividend = 0;
        }
    }

    function _credit(address account, address quote, uint256 amount) internal {
        owed[account][quote] += amount;
        emit Owed(account, quote, amount);
    }

    /// @dev OZ 5.1 has no trySafeTransfer. Accepts tokens that return nothing (USDT-style) or `true`.
    function _tryTransfer(address quote, address to, uint256 amount) internal returns (bool) {
        (bool ok, bytes memory ret) = quote.call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!ok) return false;
        if (ret.length == 0) return quote.code.length > 0;
        return ret.length >= 32 && abi.decode(ret, (bool));
    }
}
