// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IGangLockedToken {
    function locked() external view returns (bool);
}

/// @title GangBaseVault — one token's opening base (docs/SPEC-BASE-VAULT-V2-2026-11-12.md §5)
/// @notice Holds the tokens GangLaunchpad 3.0's `createWithBase` bought on the curve in the token's own create tx and,
///         after graduation, releases them to the creator linearly over the period fixed at create. That is all it
///         does: it never trades, holds no quote, never approves anyone, and nothing (the creator, the pad, its owner)
///         can change the recipient or the period, release early, pause or cancel.
///         - Start: the first `release` after the token unlocked (graduated; the token's own `locked()`, never a pad
///           view: the pad is upgradeable, this vault is not) records `startAt` = now and `total` = its balance.
///         - Release: by `startAt + elapsed`, `total × elapsed / duration` in all (rounded down); after the period,
///           everything the vault holds, tokens sent in after the start included.
///         Anyone may call `release`; the tokens only ever go to `creator`.
/// @dev One EIP-1167 clone per token, made and initialised by the pad in the same call. No owner, not upgradeable.
///      `pad` is the implementation's immutable (the clone runs the implementation's code, immutables included).
contract GangBaseVault {
    using SafeERC20 for IERC20;

    bytes32 public constant MODULE_TYPE = "base-v1";

    /// @notice The only address that may initialise a clone (the GangLaunchpad 3.0 proxy).
    address public immutable pad;

    address public token;
    address public creator;
    /// @notice 0 = not started.
    uint64 public startAt;
    uint64 public duration;
    uint256 public total;
    uint256 public released;
    bool private _entered;

    event Initialized(address indexed token, address indexed creator, uint32 vestDays);
    event Began(uint64 startAt, uint256 total);
    event Released(address indexed creator, uint256 amount, uint256 releasedTotal);

    error NotPad();
    error AlreadyInitialized();
    error BadInit();
    error NotGraduated();
    error NothingToRelease();
    error Reentered();

    modifier nonReentrant() {
        if (_entered) revert Reentered();
        _entered = true;
        _;
        _entered = false;
    }

    constructor(address pad_) {
        if (pad_ == address(0)) revert BadInit();
        pad = pad_;
    }

    /// @notice "base-v1": the pad's `setBaseVaultImpl` checks it.
    function moduleType() external pure returns (bytes32) {
        return MODULE_TYPE;
    }

    /// @notice Only the pad, once, in the call that cloned this vault. The pad checks `vestDays` against the base size.
    function initialize(address token_, address creator_, uint32 vestDays) external {
        if (msg.sender != pad) revert NotPad();
        if (token != address(0)) revert AlreadyInitialized();
        if (token_ == address(0) || creator_ == address(0) || vestDays == 0) revert BadInit();
        token = token_;
        creator = creator_;
        duration = uint64(vestDays) * 1 days;
        emit Initialized(token_, creator_, vestDays);
    }

    /// @notice What `release` would send to the creator now (0 before the start).
    function releasable() public view returns (uint256) {
        if (startAt == 0) return 0;
        uint256 elapsed = block.timestamp - startAt;
        if (elapsed >= duration) return IERC20(token).balanceOf(address(this));
        return (total * elapsed) / duration - released;
    }

    /// @notice Anyone. Not started yet: requires the token to be unlocked (graduated), starts the clock and returns 0.
    ///         Started: sends what has vested and not been sent yet to the creator.
    function release() external nonReentrant returns (uint256 amount) {
        if (startAt == 0) {
            if (IGangLockedToken(token).locked()) revert NotGraduated();
            startAt = uint64(block.timestamp);
            total = IERC20(token).balanceOf(address(this));
            emit Began(startAt, total);
            return 0;
        }
        amount = releasable();
        if (amount == 0) revert NothingToRelease();
        released += amount;
        IERC20(token).safeTransfer(creator, amount);
        emit Released(creator, amount, released);
    }
}
