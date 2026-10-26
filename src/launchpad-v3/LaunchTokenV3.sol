// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TokenURI} from "./TokenURI.sol";

/// @title LaunchTokenV3 (LaunchpadV3 untaxed track)
/// @notice V2 LaunchToken plus a metadata URI, with the launchpad's power cut to one call: fixed supply minted to the
///         launchpad; while `locked`, tokens only move from the launchpad (curve buys) or are pulled by it (curve
///         sells via transferFrom); graduation calls `unlock()` once and the token has no admin function left.
///         (V2's `burn` is gone: LaunchpadV3 never burns.)
contract LaunchTokenV3 is ERC20, TokenURI {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;

    address public immutable launchpad;
    bool public locked = true;

    error TransfersLocked();
    error OnlyLaunchpad();
    error AlreadyUnlocked();

    event Unlocked();

    constructor(string memory name_, string memory symbol_, string memory uri_) ERC20(name_, symbol_) TokenURI(uri_) {
        launchpad = msg.sender;
        _mint(msg.sender, TOTAL_SUPPLY);
    }

    /// @notice Permanently unlocks transfers (once). Called by the launchpad at graduation.
    function unlock() external {
        if (msg.sender != launchpad) revert OnlyLaunchpad();
        if (!locked) revert AlreadyUnlocked();
        locked = false;
        emit Unlocked();
    }

    function _update(address from, address to, uint256 value) internal override {
        if (locked && from != address(0) && from != launchpad && msg.sender != launchpad) revert TransfersLocked();
        super._update(from, to, value);
    }
}
