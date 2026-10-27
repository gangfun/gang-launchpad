// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPostGradTaxHandler} from "../launchpad-v2/interfaces/IPostGradTaxHandler.sol";
import {ISwapBack} from "../common/interfaces/ISwapBack.sol";
import {TokenURI} from "../launchpad-v3/TokenURI.sol";

/// @title FairToken (打新发射)
/// @notice Fixed-supply token minted entirely to FairMintPad. Locked until launch: only the pad moves tokens, and
///         it can pull a minter's tokens back when they sell shares back (withdraw). Launch unlocks forever and
///         disables reclaim.
///         After launch: 1% tax on pair buys / sells → HolderRewardHandler; every transfer syncs reward shares.
/// @dev The tax is accrued in the handler; before a sell's tokens move, the handler sells one small chunk of it
///      (`swapBack`, ≤ 0.5% of the pair's token side) in a gas-capped try, so it can never fail the sell (except a
///      sell paid in from a flash swap's callback, which is refused: `SellDuringFlashSwap`).
///      The pad's power is fixed and one-shot (2026-10-26): the handler is set at construction, `reclaim` works only
///      while locked, launch calls `unlock(migrator)` and `setPair(pair)` once each, and after that the token has no
///      admin function left. Tax and reward syncing start only once the pair is set.
contract FairToken is ERC20, TokenURI {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 public constant TAX_BPS = 100;
    uint256 public constant BPS = 10_000;
    /// @notice Gas cap for the handler's sell-time chunk. A chunk that runs out because the caller sent too little gas
    ///         (it got less than this cap) makes the transfer revert instead of being skipped, so gas estimation lands
    ///         on a limit where the chunk runs; a chunk failing on its own is swallowed (SwapBackFailed).
    uint256 public constant SWAP_BACK_GAS = 600_000;

    address public immutable launchpad;
    address public immutable taxHandler;
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
    /// @notice A sell paid in from a flash swap's callback (the pair already paid the quote out): refused, since it
    ///         would skip the swap-back chunk for free (the handler's error, passed on).
    error SellDuringFlashSwap();

    event Unlocked();
    event TaxHandlerSet(address indexed handler);
    event PairSet(address indexed pair);
    event Excluded(address indexed account, bool excluded);
    event OuterTax(address indexed from, address indexed to, uint256 taxed, uint256 net);
    /// @notice The handler's sell-time chunk failed; the tax stays accrued for the next sell or the keeper.
    event SwapBackFailed();

    constructor(string memory name_, string memory symbol_, address launchpad_, address taxHandler_, string memory uri_)
        ERC20(name_, symbol_)
        TokenURI(uri_)
    {
        if (launchpad_ == address(0) || taxHandler_ == address(0)) revert ZeroAddress();
        launchpad = launchpad_;
        taxHandler = taxHandler_;
        _mint(launchpad_, TOTAL_SUPPLY);
        isExcluded[launchpad_] = true;
        isExcluded[taxHandler_] = true;
        isExcluded[address(0)] = true;
        isExcluded[address(0xdead)] = true;
        emit TaxHandlerSet(taxHandler_);
    }

    modifier onlyLaunchpad() {
        if (msg.sender != launchpad) revert OnlyLaunchpad();
        _;
    }

    /// @notice Launch, step 1 (once): unlock transfers for good (ends `reclaim`) and exclude the migrator.
    function unlock(address migrator) external onlyLaunchpad {
        if (!locked) revert AlreadyUnlocked();
        if (migrator == address(0)) revert ZeroAddress();
        locked = false;
        isExcluded[migrator] = true;
        emit Excluded(migrator, true);
        emit Unlocked();
    }

    /// @notice Pre-launch only: pull `amount` from `from` back to the pad (a sell-back, `withdraw`).
    function reclaim(address from, uint256 amount) external onlyLaunchpad {
        if (!locked) revert NotLocked();
        _transfer(from, launchpad, amount);
    }

    /// @notice Launch, step 2 (once, after the migrator made the pair): tax and reward syncing start here.
    ///         The pair is NOT excluded — the tax applies to pair transfers.
    function setPair(address pair_) external onlyLaunchpad {
        if (locked) revert StillLocked();
        if (pair != address(0)) revert PairAlreadySet();
        if (pair_ == address(0)) revert ZeroAddress();
        pair = pair_;
        emit PairSet(pair_);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (locked && from != address(0) && from != launchpad && msg.sender != launchpad) {
            revert TransfersLocked();
        }

        if (_shouldTax(from, to) && value > 0) {
            uint256 tax = (value * TAX_BPS) / BPS;
            // a taxed sell: the pair is not locked yet, so the handler can sell a chunk of accrued tax first (it is
            // tax-excluded, so its own chunk into the pair never comes back here)
            if (to == pair && tax > 0) {
                uint256 g = gasleft();
                try ISwapBack(taxHandler).swapBack{gas: SWAP_BACK_GAS}(address(this), value) {}
                catch (bytes memory reason) {
                    // a flash-swap sell, refused by the handler: passed on (it would skip the chunk for free)
                    if (bytes4(reason) == SellDuringFlashSwap.selector) revert SellDuringFlashSwap();
                    if (g - g / 64 < SWAP_BACK_GAS && gasleft() <= g / 63) revert SwapBackOutOfGas();
                    emit SwapBackFailed();
                }
            }
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
        // before launch the pad writes reward shares itself
        if (pair != address(0)) IPostGradTaxHandler(taxHandler).syncShares(address(this), from, to);
    }

    function _shouldTax(address from, address to) internal view returns (bool) {
        if (pair == address(0)) return false; // unset until launch (implies locked or migrating)
        if (from == address(0) || to == address(0)) return false;
        if (!(from == pair || to == pair)) return false;
        if (isExcluded[from] || isExcluded[to]) return false;
        return true;
    }
}
