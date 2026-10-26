// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPostGradTaxHandlerV3} from "./interfaces/IPostGradTaxHandlerV3.sol";
import {TokenURI} from "./TokenURI.sol";

/// @title TaxLaunchTokenV3 (LaunchpadV3 taxed track)
/// @notice Fixed-supply launch token. Locked until graduation. Same as V2 TaxLaunchToken except the pool tax rates
///         are chosen at create, one for buys and one for sells (immutable for the token's life).
/// @dev Bonding-phase tax is taken by LaunchpadV3 on quote, never here.
///      Post-grad: buys from the pair pay `buyTaxBps`, sells into it `sellTaxBps` → TaxHandlerV3 (accrue
///      only; keeper sells later — V2 Finding 2).
///      Every transfer syncs dividend shares (V2 Finding 3); the handler ignores tokens without dividends.
///      The launchpad's power is fixed and one-shot (2026-10-26): the handler is set at construction, graduation
///      calls `unlock(migrator)` and `setPair(pair)` once each, and after that the token has no admin function left.
///      Pool tax and share syncing start only once the pair is set (the migration itself runs untaxed and unsynced).
contract TaxLaunchTokenV3 is ERC20, TokenURI {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 public constant BPS = 10_000;

    address public immutable launchpad;
    address public immutable taxHandler;
    uint16 public immutable buyTaxBps;
    uint16 public immutable sellTaxBps;
    address public pair;
    bool public locked = true;

    mapping(address => bool) public isExcluded;

    error TransfersLocked();
    error OnlyLaunchpad();
    error AlreadyUnlocked();
    error PairAlreadySet();
    error StillLocked();
    error ZeroAddress();

    event Unlocked();
    event TaxHandlerSet(address indexed handler);
    event PairSet(address indexed pair);
    event Excluded(address indexed account, bool excluded);
    event OuterTax(address indexed from, address indexed to, uint256 taxed, uint256 net);

    /// @dev Deployed by TaxTokenDeployerV3 on behalf of `launchpad_` (keeps LaunchpadV3 under EIP-170). The handler is
    ///      excluded from the start (no tax recursion when it sells).
    constructor(
        string memory name_,
        string memory symbol_,
        uint16 buyTaxBps_,
        uint16 sellTaxBps_,
        address launchpad_,
        address taxHandler_,
        string memory uri_
    ) ERC20(name_, symbol_) TokenURI(uri_) {
        if (launchpad_ == address(0) || taxHandler_ == address(0)) revert ZeroAddress();
        launchpad = launchpad_;
        taxHandler = taxHandler_;
        buyTaxBps = buyTaxBps_;
        sellTaxBps = sellTaxBps_;
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

    /// @notice Graduation, step 1 (once): unlock transfers for good and exclude the migrator that seeds the pair.
    function unlock(address migrator) external onlyLaunchpad {
        if (!locked) revert AlreadyUnlocked();
        if (migrator == address(0)) revert ZeroAddress();
        locked = false;
        isExcluded[migrator] = true;
        emit Excluded(migrator, true);
        emit Unlocked();
    }

    /// @notice Graduation, step 2 (once, after the migrator made the pair): pool tax and share syncing start here.
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
            // from the pair = a buy; into it = a sell (pair → pair cannot happen)
            uint16 rate = from == pair ? buyTaxBps : sellTaxBps;
            uint256 tax = (value * rate) / BPS;
            uint256 net = value - tax;
            super._update(from, to, net);
            if (tax > 0) {
                super._update(from, taxHandler, tax);
                IPostGradTaxHandlerV3(taxHandler).notifyTax(address(this), from, to, tax, rate);
            }
            emit OuterTax(from, to, tax, net);
            _syncDividendShares(from, to);
            return;
        }

        super._update(from, to, value);
        _syncDividendShares(from, to);
    }

    function _syncDividendShares(address from, address to) internal {
        if (pair == address(0)) return; // before graduation the pad writes shares itself
        if (from == address(0) && to == address(0)) return;
        IPostGradTaxHandlerV3(taxHandler).syncShares(address(this), from, to);
    }

    function _shouldTax(address from, address to) internal view returns (bool) {
        if (pair == address(0)) return false; // unset until graduation (implies locked or migrating)
        if (from == address(0) || to == address(0)) return false; // mint/burn
        if (!(from == pair || to == pair)) return false;
        if (isExcluded[from] || isExcluded[to]) return false;
        return true;
    }
}

/// @title TaxTokenDeployerV3
/// @notice Holds TaxLaunchTokenV3 creation code so LaunchpadV3 stays under EIP-170. Stateless: the caller becomes
///         the token's launchpad, so anyone may call it but only gets tokens bound to themselves.
contract TaxTokenDeployerV3 {
    function deploy(
        string calldata name,
        string calldata symbol,
        uint16 buyTaxBps,
        uint16 sellTaxBps,
        address taxHandler,
        string calldata uri
    ) external returns (address) {
        return address(new TaxLaunchTokenV3(name, symbol, buyTaxBps, sellTaxBps, msg.sender, taxHandler, uri));
    }
}
