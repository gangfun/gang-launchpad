// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title TaxLaunchToken (Stocks track)
/// @notice Fixed-supply launch token. Locked until graduation; optional pair tax after unlock.
/// @dev In-curve 1% tax is applied by LaunchpadS on quote (avoids double-tax). Post-grad tax on
///      pair swaps is stubbed for PoC (setPair + taxSink); full DEX tax path can be expanded later.
contract TaxLaunchToken is ERC20 {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;

    address public immutable launchpad;
    address public taxSink;
    address public pair;
    bool public locked = true;

    mapping(address => bool) public isExcluded;

    error TransfersLocked();
    error OnlyLaunchpad();

    event Unlocked();
    event TaxSinkSet(address indexed sink);
    event PairSet(address indexed pair);
    event Excluded(address indexed account, bool excluded);

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {
        launchpad = msg.sender;
        _mint(msg.sender, TOTAL_SUPPLY);
        isExcluded[msg.sender] = true;
        isExcluded[address(0)] = true;
        isExcluded[address(0xdead)] = true;
    }

    function unlock() external {
        if (msg.sender != launchpad) revert OnlyLaunchpad();
        if (!locked) return;
        locked = false;
        emit Unlocked();
    }

    function setTaxSink(address sink) external {
        if (msg.sender != launchpad) revert OnlyLaunchpad();
        taxSink = sink;
        emit TaxSinkSet(sink);
    }

    function setPair(address pair_) external {
        if (msg.sender != launchpad) revert OnlyLaunchpad();
        pair = pair_;
        if (pair_ != address(0)) isExcluded[pair_] = true;
        emit PairSet(pair_);
    }

    function exclude(address account, bool excluded) external {
        if (msg.sender != launchpad) revert OnlyLaunchpad();
        isExcluded[account] = excluded;
        emit Excluded(account, excluded);
    }

    function burn(uint256 amount) external {
        if (msg.sender != launchpad) revert OnlyLaunchpad();
        _burn(msg.sender, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (locked && from != address(0) && from != launchpad && msg.sender != launchpad) {
            revert TransfersLocked();
        }
        // PoC: post-grad pair tax not enforced in transfer (handled off-curve / future).
        // Keeping exclude list + pair hooks so MigratorS/LaunchpadS can wire them.
        super._update(from, to, value);
    }
}
