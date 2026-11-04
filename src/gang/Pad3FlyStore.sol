// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFlywheelPad} from "../flywheel/interfaces/IFlywheelPad.sol";

/// @title Pad3FlyStore — GangLaunchpad 3.0's 铸币飞轮 state, in its own ERC-7201 namespace
/// @notice The sales, accounts, dev cuts owed and post-launch rules of 3.0's own 铸币飞轮 tokens (kind 3): exactly
///         GangFlywheelPad V2's per-token state, read and written by Pad3FlyModule (delegatecalled in the proxy's
///         storage) through the same FlywheelLogic / FlywheelPostLogic code as V2. The rest a 铸币飞轮 sale needs is
///         the pad's own and shared with its other kinds: `_config`, `bridgePoolOf`, `routers`, `kindOf`, `logoURIOf`,
///         `owedFee` (per quote), `allTokens`, `tokenVersionOf`. UPGRADES: members are only ever appended at the end
///         (never reordered, retyped or removed) and SLOT never changes; test/gang3/Pad3Fly.t.sol pins both.
library Pad3FlyStore {
    /// @custom:storage-location erc7201:gang.pad3.fly
    struct Layout {
        mapping(address token => IFlywheelPad.Sale) sales;
        mapping(address token => mapping(address user => IFlywheelPad.Account)) accounts;
        /// @dev dev cuts the creator could not receive (anyone can `claimDev`)
        mapping(address token => uint256) owedDev;
        /// @dev each sale's post-launch guard and TWAP window (fixed at create)
        mapping(address token => IFlywheelPad.PostRules) postRulesOf;
        /// @dev the routers this mode's `mintFor` / `withdrawFor` / `mintPostFor` take (`setFlyRouter`)
        mapping(address router => bool) routers;
    }

    /// @dev keccak256(abi.encode(uint256(keccak256("gang.pad3.fly")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 internal constant SLOT = 0x15956bccb7600a669317101f335b012a0393c25d62c3c9a95428d13e61d8ed00;

    function layout() internal pure returns (Layout storage l) {
        bytes32 s = SLOT;
        assembly ("memory-safe") {
            l.slot := s
        }
    }
}
