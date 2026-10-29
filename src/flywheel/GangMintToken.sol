// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IGangTaxHandler} from "../gang/interfaces/IGangTaxHandler.sol";
import {TokenURI} from "../launchpad-v3/TokenURI.sol";

/// @title GangMintToken (持续打新 / continuous-mint tokens)
/// @notice GangToken with a growing supply. It starts with `startSupply` minted to its launchpad (the pre-launch shares
///         and the pool's tokens); once the pair exists, only the launchpad can mint more (`padMint`, for post-launch
///         mints), never above `maxSupply`. Everything else is GangToken's: locked until launch (`reclaim` / `pullFor`
///         only while locked), pool tax on pair trades (buy `buyTaxBps`, sell `sellTaxBps`) → the handler
///         (`notifyTax`), the handler's sell-time chunk (`swapBack`), share syncing on every transfer (`syncShares`),
///         launchpad / handler excluded from tax, no owner.
/// @dev The launchpad's power is fixed: the handler, the rates and the cap are set at construction; `unlock` and
///      `setPair` run once each at launch; `padMint` only mints after launch and only up to the cap.
contract GangMintToken is ERC20, TokenURI {
    uint256 public constant BPS = 10_000;
    /// @notice Gas cap for the handler's sell-time chunk. A chunk that runs out because the caller sent too little gas
    ///         (it got less than this cap) makes the transfer revert instead of being skipped, so gas estimation lands
    ///         on a limit where the chunk runs; a chunk failing on its own is swallowed (SwapBackFailed).
    uint256 public constant SWAP_BACK_GAS = 600_000;

    address public immutable launchpad;
    /// @notice The tax handler (fixed); unused (and may be 0) on an untaxed token.
    address public immutable taxHandler;
    uint16 public immutable buyTaxBps;
    uint16 public immutable sellTaxBps;
    /// @notice The pad can `reclaim` while locked (pre-launch sell-backs).
    bool public immutable reclaimable;
    /// @notice Supply never goes above this (`padMint`).
    uint256 public immutable maxSupply;
    // `pair` and `locked` share one slot
    address public pair;
    bool public locked = true;

    mapping(address => bool) public isExcluded;

    error TransfersLocked();
    error OnlyLaunchpad();
    error NotLocked();
    error NotReclaimable();
    error AlreadyUnlocked();
    error PairAlreadySet();
    error StillLocked();
    error Untaxed();
    error ZeroAddress();
    error SwapBackOutOfGas();
    error BadSupply();
    error CapExceeded();
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

    /// @dev Deployed by TokenDeployer on behalf of `launchpad_` (keeps the pads under EIP-170). A taxed token needs a
    ///      handler, excluded from the start (no tax recursion when it sells, and its skim / return around a chunk is
    ///      untaxed); an untaxed token writes no exclusions (it never taxes).
    constructor(
        string memory name_,
        string memory symbol_,
        string memory uri_,
        address launchpad_,
        address taxHandler_,
        uint16 buyTaxBps_,
        uint16 sellTaxBps_,
        bool reclaimable_,
        uint256 startSupply_,
        uint256 maxSupply_
    ) ERC20(name_, symbol_) TokenURI(uri_) {
        if (launchpad_ == address(0)) revert ZeroAddress();
        if (startSupply_ == 0 || startSupply_ > maxSupply_) revert BadSupply();
        maxSupply = maxSupply_;
        launchpad = launchpad_;
        taxHandler = taxHandler_;
        buyTaxBps = buyTaxBps_;
        sellTaxBps = sellTaxBps_;
        reclaimable = reclaimable_;
        _mint(launchpad_, startSupply_);
        if (buyTaxBps_ != 0 || sellTaxBps_ != 0) {
            if (taxHandler_ == address(0)) revert ZeroAddress();
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

    /// @notice Graduation / launch, step 1 (once): unlock transfers for good (ends `reclaim`) and exclude the migrator
    ///         that seeds the pair.
    function unlock(address migrator) external onlyLaunchpad {
        if (!locked) revert AlreadyUnlocked();
        if (migrator == address(0)) revert ZeroAddress();
        locked = false;
        isExcluded[migrator] = true;
        emit Excluded(migrator, true);
        emit Unlocked();
    }

    /// @notice 打新 only, pre-launch only: pull `amount` from `from` back to the pad (a sell-back, `withdraw`).
    function reclaim(address from, uint256 amount) external onlyLaunchpad {
        if (!reclaimable) revert NotReclaimable();
        if (!locked) revert NotLocked();
        _transfer(from, launchpad, amount);
    }

    /// @notice Any kind, pre-graduation / pre-launch only: pull `amount` from `owner` to the pad, spending the
    ///         allowance `owner` gave `spender` (a curve `sellFor` / 打新 `withdrawFor` by an aggregator, AUDIT-BRIEF
    ///         §23). Locked only, so it can never move a pool trade's tokens or skip the pool tax: while locked there
    ///         is no pair, nothing is taxed and no share is synced here (the pad writes the shares).
    function pullFor(address owner, address spender, uint256 amount) external onlyLaunchpad {
        if (!locked) revert NotLocked();
        _spendAllowance(owner, spender, amount);
        _transfer(owner, launchpad, amount);
    }

    /// @notice Graduation / launch, step 2 (taxed kinds, once, after the migrator made the pair): pool tax and share
    ///         syncing start here. The pair is NOT excluded — the tax applies to pair transfers. An untaxed token
    ///         never gets a pair, so it never calls the handler.
    function setPair(address pair_) external onlyLaunchpad {
        if (buyTaxBps == 0 && sellTaxBps == 0) revert Untaxed();
        if (locked) revert StillLocked();
        if (pair != address(0)) revert PairAlreadySet();
        if (pair_ == address(0)) revert ZeroAddress();
        pair = pair_;
        emit PairSet(pair_);
    }

    /// @notice After launch only: mint `amount` to `to` for a post-launch mint (the buyer's tokens, or the tokens added
    ///         to the pool with the mint's quote). Untaxed (a mint, not a pool trade); syncs `to`'s share.
    function padMint(address to, uint256 amount) external onlyLaunchpad {
        if (locked) revert StillLocked();
        if (totalSupply() + amount > maxSupply) revert CapExceeded();
        _mint(to, amount);
    }

    /// @notice How much more can still be minted.
    function mintRoom() external view returns (uint256) {
        return maxSupply - totalSupply();
    }

    function _update(address from, address to, uint256 value) internal override {
        if (locked && from != address(0) && from != launchpad && msg.sender != launchpad) {
            revert TransfersLocked();
        }

        if (_shouldTax(from, to) && value > 0) {
            // from the pair = a buy; into it = a sell (pair → pair cannot happen)
            uint16 rate = from == pair ? buyTaxBps : sellTaxBps;
            uint256 tax = (value * rate) / BPS;
            // a taxed sell: the pair is not locked yet, so the handler can sell a chunk of accrued tax first
            if (to == pair && tax > 0) _swapBack(value);
            uint256 net = value - tax;
            super._update(from, to, net);
            if (tax > 0) {
                super._update(from, taxHandler, tax);
                IGangTaxHandler(taxHandler).notifyTax(address(this), from, to, tax, rate);
            }
            emit OuterTax(from, to, tax, net);
        } else {
            super._update(from, to, value);
        }
        _syncShares(from, to);
    }

    /// @dev The handler is tax-excluded, so its own chunk into the pair never comes back here. Its failures are
    ///      swallowed, except a flash-swap sell, which it refuses (`SellDuringFlashSwap`) and this passes on.
    function _swapBack(uint256 value) internal {
        uint256 g = gasleft();
        try IGangTaxHandler(taxHandler).swapBack{gas: SWAP_BACK_GAS}(address(this), value) {}
        catch (bytes memory reason) {
            if (bytes4(reason) == SellDuringFlashSwap.selector) revert SellDuringFlashSwap();
            if (g - g / 64 < SWAP_BACK_GAS && gasleft() <= g / 63) revert SwapBackOutOfGas();
            emit SwapBackFailed();
        }
    }

    function _syncShares(address from, address to) internal {
        if (pair == address(0)) return; // before graduation / launch the pad writes shares; untaxed: never
        if (from == address(0) && to == address(0)) return;
        IGangTaxHandler(taxHandler).syncShares(address(this), from, to);
    }

    function _shouldTax(address from, address to) internal view returns (bool) {
        if (pair == address(0)) return false; // unset until graduation (implies locked or migrating); untaxed: never
        if (from == address(0) || to == address(0)) return false; // mint/burn
        if (!(from == pair || to == pair)) return false;
        if (isExcluded[from] || isExcluded[to]) return false;
        return true;
    }
}
