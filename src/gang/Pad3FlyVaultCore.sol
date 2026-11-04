// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SharedDividendVault} from "../common/SharedDividendVault.sol";

/// @title Pad3FlyVaultCore — the shared dividend vault's core for GangLaunchpad 3.0's 铸币飞轮 tokens
/// @notice The shared vault gives each core one floor and one operator, both fixed: 3.0's are its curve / 打新 ones (a
///         10,000-token floor, its GangTaxHandler). 3.0's 铸币飞轮 tokens are registered under this core instead, so
///         they get 铸币飞轮 V2's floor (1,000 tokens, set by FlywheelLogic at create) and their own operator: the
///         铸币飞轮 FlywheelTaxHandler, bound to this core by the vault's owner, writes holder shares and credits
///         dividends straight in the vault as on V2. The pad's own vault calls for these tokens (FlywheelLogic: the
///         floor at create, the registration, pre-launch shares) come through here; only the pad can make them.
///         Holders claim in the shared vault as for every other token. Immutable, no owner.
/// @dev FlywheelLogic sees this contract as its `dividendVault` (Pad3FlyModule's `_deps`): these are the vault
///      functions it and PadCommon call. `minimumShareBalanceOf` answers for this core whatever address it is asked
///      about (FlywheelLogic asks about the pad, i.e. itself); `launchpadOf` is the vault's (PadCommon's quote filter:
///      no token any core registered is a quote).
contract Pad3FlyVaultCore {
    SharedDividendVault public immutable vault;
    /// @notice The GangLaunchpad 3.0 proxy.
    address public immutable pad;

    error OnlyPad();
    error ZeroAddress();

    constructor(address vault_, address pad_) {
        if (vault_ == address(0) || pad_ == address(0)) revert ZeroAddress();
        vault = SharedDividendVault(vault_);
        pad = pad_;
    }

    modifier onlyPad() {
        if (msg.sender != pad) revert OnlyPad();
        _;
    }

    /// @notice This core's floor in the vault (the argument is ignored: see the contract's @dev).
    function minimumShareBalanceOf(address) external view returns (uint256) {
        return vault.minimumShareBalanceOf(address(this));
    }

    function launchpadOf(address token) external view returns (address) {
        return vault.launchpadOf(token);
    }

    function ensureMinimumShareBalance(uint256 amount) external onlyPad {
        vault.ensureMinimumShareBalance(amount);
    }

    function registerToken(address token, address quote) external onlyPad {
        vault.registerToken(token, quote);
    }

    function setShare(address token, address user, uint256 newShare) external onlyPad {
        vault.setShare(token, user, newShare);
    }
}
