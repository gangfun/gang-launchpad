// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IGangTaxHandler as IPostGradTaxHandlerV3} from "../interfaces/IGangTaxHandler.sol";
import {TokenURI} from "../../launchpad-v3/TokenURI.sol";

/// @title GangToken — STUB for feat/merge-pad (replaced at integration by feat/merge-token's GangToken)
/// @notice TaxLaunchTokenV3 + FairToken + LaunchTokenV3 in one contract, as MERGE-PLAN §3 describes, so the pad's tests
///         run against the agreed interface: constructor (name, symbol, uri, launchpad, taxHandler, buy, sell,
///         reclaimable); `unlock(migrator)`; `setPair(pair)` (untaxed → `Untaxed`); `reclaim(from, amount)` (打新 only,
///         while locked); handler hooks `notifyTax` (5 args), `syncShares`, `swapBack` (gas-capped try).
contract GangToken is ERC20, TokenURI {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 public constant BPS = 10_000;
    uint256 public constant SWAP_BACK_GAS = 600_000;

    address public immutable launchpad;
    address public immutable taxHandler;
    uint16 public immutable buyTaxBps;
    uint16 public immutable sellTaxBps;
    bool public immutable reclaimable;
    address public pair;
    bool public locked = true;

    mapping(address => bool) public isExcluded;

    error TransfersLocked();
    error OnlyLaunchpad();
    error NotLocked();
    error AlreadyUnlocked();
    error PairAlreadySet();
    error StillLocked();
    error ZeroAddress();
    error SwapBackOutOfGas();
    error SellDuringFlashSwap();
    error NotReclaimable();
    error Untaxed();

    event Unlocked();
    event TaxHandlerSet(address indexed handler);
    event PairSet(address indexed pair);
    event Excluded(address indexed account, bool excluded);
    event OuterTax(address indexed from, address indexed to, uint256 taxed, uint256 net);
    event SwapBackFailed();

    constructor(
        string memory name_,
        string memory symbol_,
        string memory uri_,
        address launchpad_,
        address taxHandler_,
        uint16 buyTaxBps_,
        uint16 sellTaxBps_,
        bool reclaimable_
    ) ERC20(name_, symbol_) TokenURI(uri_) {
        if (launchpad_ == address(0) || taxHandler_ == address(0)) revert ZeroAddress();
        launchpad = launchpad_;
        taxHandler = taxHandler_;
        buyTaxBps = buyTaxBps_;
        sellTaxBps = sellTaxBps_;
        reclaimable = reclaimable_;
        _mint(launchpad_, TOTAL_SUPPLY);
        if (buyTaxBps_ != 0 || sellTaxBps_ != 0) {
            isExcluded[launchpad_] = true;
            isExcluded[taxHandler_] = true;
            isExcluded[address(0)] = true;
            isExcluded[address(0xdead)] = true;
            emit TaxHandlerSet(taxHandler_);
        }
    }

    modifier onlyLaunchpad() {
        if (msg.sender != launchpad) revert OnlyLaunchpad();
        _;
    }

    function unlock(address migrator) external onlyLaunchpad {
        if (!locked) revert AlreadyUnlocked();
        if (migrator == address(0)) revert ZeroAddress();
        locked = false;
        isExcluded[migrator] = true;
        emit Excluded(migrator, true);
        emit Unlocked();
    }

    function reclaim(address from, uint256 amount) external onlyLaunchpad {
        if (!reclaimable) revert NotReclaimable();
        if (!locked) revert NotLocked();
        _transfer(from, launchpad, amount);
    }

    function setPair(address pair_) external onlyLaunchpad {
        if (buyTaxBps == 0 && sellTaxBps == 0) revert Untaxed();
        if (locked) revert StillLocked();
        if (pair != address(0)) revert PairAlreadySet();
        if (pair_ == address(0)) revert ZeroAddress();
        pair = pair_;
        emit PairSet(pair_);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (locked && from != address(0) && from != launchpad && msg.sender != launchpad) revert TransfersLocked();
        address p = pair;
        if (p == address(0)) return super._update(from, to, value);

        if (_shouldTax(p, from, to) && value > 0) {
            uint16 rate = from == p ? buyTaxBps : sellTaxBps;
            uint256 tax = (value * rate) / BPS;
            if (to == p && tax > 0) _swapBack(value);
            uint256 net = value - tax;
            super._update(from, to, net);
            if (tax > 0) {
                super._update(from, taxHandler, tax);
                IPostGradTaxHandlerV3(taxHandler).notifyTax(address(this), from, to, tax, rate);
            }
            emit OuterTax(from, to, tax, net);
        } else {
            super._update(from, to, value);
        }
        if (from != address(0) || to != address(0)) {
            IPostGradTaxHandlerV3(taxHandler).syncShares(address(this), from, to);
        }
    }

    function _swapBack(uint256 value) internal {
        uint256 g = gasleft();
        try IPostGradTaxHandlerV3(taxHandler).swapBack{gas: SWAP_BACK_GAS}(address(this), value) {}
        catch (bytes memory reason) {
            if (bytes4(reason) == SellDuringFlashSwap.selector) revert SellDuringFlashSwap();
            if (g - g / 64 < SWAP_BACK_GAS && gasleft() <= g / 63) revert SwapBackOutOfGas();
            emit SwapBackFailed();
        }
    }

    function _shouldTax(address p, address from, address to) internal view returns (bool) {
        if (from == address(0) || to == address(0)) return false;
        if (!(from == p || to == p)) return false;
        if (isExcluded[from] || isExcluded[to]) return false;
        return true;
    }
}
