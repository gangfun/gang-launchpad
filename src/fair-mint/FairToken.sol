// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPostGradTaxHandler} from "../launchpad-v2/interfaces/IPostGradTaxHandler.sol";

/// @title FairToken (打新发射)
/// @notice Fixed-supply token minted entirely to FairMintPad. Locked until launch: only the pad moves tokens, and
///         it can pull a minter's tokens back for withdraw / refund. Launch unlocks forever and disables reclaim.
///         After launch: 1% tax on pair buys / sells → HolderRewardHandler; every transfer syncs reward shares.
/// @dev Same tax hook as V2 TaxLaunchToken (Finding 2: accrue only, no swap in the hook).
contract FairToken is ERC20 {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 public constant TAX_BPS = 100;
    uint256 public constant BPS = 10_000;

    address public immutable launchpad;
    address public taxHandler;
    address public pair;
    bool public locked = true;

    mapping(address => bool) public isExcluded;

    error TransfersLocked();
    error OnlyLaunchpad();
    error NotLocked();

    event Unlocked();
    event TaxHandlerSet(address indexed handler);
    event PairSet(address indexed pair);
    event Excluded(address indexed account, bool excluded);
    event OuterTax(address indexed from, address indexed to, uint256 taxed, uint256 net);

    constructor(string memory name_, string memory symbol_, address launchpad_) ERC20(name_, symbol_) {
        launchpad = launchpad_;
        _mint(launchpad_, TOTAL_SUPPLY);
        isExcluded[launchpad_] = true;
        isExcluded[address(0)] = true;
        isExcluded[address(0xdead)] = true;
    }

    modifier onlyLaunchpad() {
        if (msg.sender != launchpad) revert OnlyLaunchpad();
        _;
    }

    function unlock() external onlyLaunchpad {
        if (!locked) return;
        locked = false;
        emit Unlocked();
    }

    /// @notice Pre-launch only: pull `amount` from `from` back to the pad (withdraw / failed-sale refund).
    function reclaim(address from, uint256 amount) external onlyLaunchpad {
        if (!locked) revert NotLocked();
        _transfer(from, launchpad, amount);
    }

    function setTaxHandler(address handler) external onlyLaunchpad {
        taxHandler = handler;
        if (handler != address(0)) isExcluded[handler] = true;
        emit TaxHandlerSet(handler);
    }

    /// @notice Pair is NOT excluded — the tax applies to pair transfers.
    function setPair(address pair_) external onlyLaunchpad {
        pair = pair_;
        emit PairSet(pair_);
    }

    function exclude(address account, bool excluded) external onlyLaunchpad {
        isExcluded[account] = excluded;
        emit Excluded(account, excluded);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (locked && from != address(0) && from != launchpad && msg.sender != launchpad) {
            revert TransfersLocked();
        }

        if (_shouldTax(from, to) && value > 0) {
            uint256 tax = (value * TAX_BPS) / BPS;
            uint256 net = value - tax;
            super._update(from, to, net);
            if (tax > 0) {
                super._update(from, taxHandler, tax);
                IPostGradTaxHandler(taxHandler).notifyTax(address(this), from, to, tax);
            }
            emit OuterTax(from, to, tax, net);
        } else {
            super._update(from, to, value);
        }
        if (taxHandler != address(0)) IPostGradTaxHandler(taxHandler).syncShares(address(this), from, to);
    }

    function _shouldTax(address from, address to) internal view returns (bool) {
        if (locked) return false;
        if (taxHandler == address(0) || pair == address(0)) return false;
        if (from == address(0) || to == address(0)) return false;
        if (!(from == pair || to == pair)) return false;
        if (isExcluded[from] || isExcluded[to]) return false;
        return true;
    }
}

/// @notice Holds FairToken's creation code so FairMintPad stays under EIP-170.
contract FairTokenDeployer {
    function deploy(string calldata name, string calldata symbol) external returns (address) {
        return address(new FairToken(name, symbol, msg.sender));
    }
}
