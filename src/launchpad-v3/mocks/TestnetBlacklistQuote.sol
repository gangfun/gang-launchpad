// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice BSC testnet only: a USDT-style quote that refuses transfers to blocked addresses, to show a tax recipient
///         push failing (TaxOwed) and being released later. Anyone may mint (faucet); only the deployer blocks.
contract TestnetBlacklistQuote is ERC20("Testnet Blacklist USD", "tBUSD") {
    address public immutable admin = msg.sender;
    mapping(address => bool) public blocked;

    error OnlyAdmin();
    error Blocked(address to);

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBlocked(address account, bool isBlocked) external {
        if (msg.sender != admin) revert OnlyAdmin();
        blocked[account] = isBlocked;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (blocked[to]) revert Blocked(to);
        super._update(from, to, value);
    }
}
