// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPostGradTaxHandler} from "./interfaces/IPostGradTaxHandler.sol";

/// @title TaxLaunchToken (Stocks / any-pool taxed track)
/// @notice Fixed-supply launch token. Locked until graduation.
/// @dev In-curve 1% tax is applied by Launchpad on quote (avoids double-tax).
///      Post-grad (Tip B): 1% transfer tax on pair trades → PostGradTaxHandler
///      (50% DividendVault / 50% PlatformFeeBucket → 80/20 feeVault).
///      Finding 2: notifyTax accrues only (no in-hook swap).
///      Finding 3: every transfer syncs dividend shares for non-excluded from/to.
contract TaxLaunchToken is ERC20 {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;
    /// @dev Outer (post-grad) transfer tax: 1% of token amount on pair buys/sells.
    uint256 public constant OUTER_TAX_BPS = 100;
    uint256 public constant BPS = 10_000;

    address public immutable launchpad;
    address public taxHandler;
    address public pair;
    bool public locked = true;

    mapping(address => bool) public isExcluded;

    error TransfersLocked();
    error OnlyLaunchpad();

    event Unlocked();
    event TaxHandlerSet(address indexed handler);
    event TaxSinkSet(address indexed sink); // alias event for older callers of setTaxSink
    event PairSet(address indexed pair);
    event Excluded(address indexed account, bool excluded);
    event OuterTax(address indexed from, address indexed to, uint256 taxed, uint256 net);

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

    /// @notice Wire Tip B outer-tax handler. Handler is auto-excluded (no tax recursion).
    function setTaxHandler(address handler) external {
        if (msg.sender != launchpad) revert OnlyLaunchpad();
        taxHandler = handler;
        if (handler != address(0)) isExcluded[handler] = true;
        emit TaxHandlerSet(handler);
    }

    /// @dev Back-compat alias used by older LaunchpadS comments / scripts.
    function setTaxSink(address sink) external {
        if (msg.sender != launchpad) revert OnlyLaunchpad();
        taxHandler = sink;
        if (sink != address(0)) isExcluded[sink] = true;
        emit TaxSinkSet(sink);
        emit TaxHandlerSet(sink);
    }

    function taxSink() external view returns (address) {
        return taxHandler;
    }

    /// @notice Set graduated DEX pair. Pair is NOT excluded — outer tax applies to pair transfers.
    function setPair(address pair_) external {
        if (msg.sender != launchpad) revert OnlyLaunchpad();
        pair = pair_;
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

        if (_shouldTax(from, to) && value > 0) {
            uint256 tax = (value * OUTER_TAX_BPS) / BPS;
            uint256 net = value - tax;
            super._update(from, to, net);
            if (tax > 0) {
                // Transfer tax tokens to handler, then accrue only (Finding 2 — no swap here).
                super._update(from, taxHandler, tax);
                IPostGradTaxHandler(taxHandler).notifyTax(address(this), from, to, tax);
            }
            emit OuterTax(from, to, tax, net);
            _syncDividendShares(from, to);
            return;
        }

        super._update(from, to, value);
        _syncDividendShares(from, to);
    }

    /// @dev Finding 3: mirror balances into DividendVault for every non-mint/burn transfer.
    function _syncDividendShares(address from, address to) internal {
        if (taxHandler == address(0)) return;
        if (from == address(0) && to == address(0)) return;
        // Skip pure mint to launchpad during construct / unlock wiring noise is fine.
        IPostGradTaxHandler(taxHandler).syncShares(address(this), from, to);
    }

    function _shouldTax(address from, address to) internal view returns (bool) {
        if (locked) return false;
        if (taxHandler == address(0) || pair == address(0)) return false;
        if (from == address(0) || to == address(0)) return false; // mint/burn
        if (!(from == pair || to == pair)) return false;
        if (isExcluded[from] || isExcluded[to]) return false;
        return true;
    }
}
