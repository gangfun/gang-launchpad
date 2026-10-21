// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title LaunchToken
/// @notice Fixed-supply ERC20 minted entirely to the Launchpad. While `locked`, tokens can only move
///         from the Launchpad (curve buys) or be pulled by the Launchpad (curve sells via transferFrom).
///         Nothing else — not even a plain transfer *to* the Launchpad. Graduation unlocks transfers forever.
contract LaunchToken is ERC20 {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;

    address public immutable launchpad;
    bool public locked = true;

    error TransfersLocked();
    error OnlyLaunchpad();

    event Unlocked();

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        launchpad = msg.sender;
        _mint(msg.sender, TOTAL_SUPPLY);
    }

    /// @notice Permanently unlocks transfers. Called by the Launchpad at graduation.
    function unlock() external {
        if (msg.sender != launchpad) revert OnlyLaunchpad();
        if (!locked) return;
        locked = false;
        emit Unlocked();
    }

    /// @notice Protocol buyback burn. OZ v5 rejects transfer(address(0)); use this instead.
    function burn(uint256 amount) external {
        if (msg.sender != launchpad) revert OnlyLaunchpad();
        _burn(msg.sender, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (locked && from != address(0) && from != launchpad && msg.sender != launchpad) revert TransfersLocked();
        super._update(from, to, value);
    }
}
