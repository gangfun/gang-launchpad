// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IPostGradTaxHandlerV3} from "./interfaces/IPostGradTaxHandlerV3.sol";

/// @title TaxLaunchTokenV3 (LaunchpadV3 taxed track)
/// @notice Fixed-supply launch token. Locked until graduation. Same as V2 TaxLaunchToken except the pool tax rates
///         are chosen at create, one for buys and one for sells (immutable for the token's life).
/// @dev Bonding-phase tax is taken by LaunchpadV3 on quote, never here.
///      Post-grad: buys from the pair pay `buyTaxBps`, sells into it `sellTaxBps` → PostGradTaxHandlerV3 (accrue
///      only; keeper sells later — V2 Finding 2).
///      Every transfer syncs dividend shares (V2 Finding 3); the handler ignores tokens without dividends.
contract TaxLaunchTokenV3 is ERC20 {
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 ether;
    uint256 public constant BPS = 10_000;

    address public immutable launchpad;
    uint16 public immutable buyTaxBps;
    uint16 public immutable sellTaxBps;
    address public taxHandler;
    address public pair;
    bool public locked = true;

    mapping(address => bool) public isExcluded;

    error TransfersLocked();
    error OnlyLaunchpad();

    event Unlocked();
    event TaxHandlerSet(address indexed handler);
    event PairSet(address indexed pair);
    event Excluded(address indexed account, bool excluded);
    event OuterTax(address indexed from, address indexed to, uint256 taxed, uint256 net);

    /// @dev Deployed by TaxTokenDeployerV3 on behalf of `launchpad_` (keeps LaunchpadV3 under EIP-170).
    constructor(string memory name_, string memory symbol_, uint16 buyTaxBps_, uint16 sellTaxBps_, address launchpad_)
        ERC20(name_, symbol_)
    {
        launchpad = launchpad_;
        buyTaxBps = buyTaxBps_;
        sellTaxBps = sellTaxBps_;
        _mint(launchpad_, TOTAL_SUPPLY);
        isExcluded[launchpad_] = true;
        isExcluded[address(0)] = true;
        isExcluded[address(0xdead)] = true;
    }

    function unlock() external {
        if (msg.sender != launchpad) revert OnlyLaunchpad();
        if (!locked) return;
        locked = false;
        emit Unlocked();
    }

    /// @notice Wire the post-grad handler. Handler is auto-excluded (no tax recursion).
    function setTaxHandler(address handler) external {
        if (msg.sender != launchpad) revert OnlyLaunchpad();
        taxHandler = handler;
        if (handler != address(0)) isExcluded[handler] = true;
        emit TaxHandlerSet(handler);
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
        if (taxHandler == address(0)) return;
        if (from == address(0) && to == address(0)) return;
        IPostGradTaxHandlerV3(taxHandler).syncShares(address(this), from, to);
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

/// @title TaxTokenDeployerV3
/// @notice Holds TaxLaunchTokenV3 creation code so LaunchpadV3 stays under EIP-170. Stateless: the caller becomes
///         the token's launchpad, so anyone may call it but only gets tokens bound to themselves.
contract TaxTokenDeployerV3 {
    function deploy(string calldata name, string calldata symbol, uint16 buyTaxBps, uint16 sellTaxBps)
        external
        returns (address)
    {
        return address(new TaxLaunchTokenV3(name, symbol, buyTaxBps, sellTaxBps, msg.sender));
    }
}
