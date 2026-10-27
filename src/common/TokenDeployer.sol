// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {GangToken} from "../gang/stub/GangToken.sol";

/// @title TokenDeployer (GangLaunchpad · token creation code, outside the pad)
/// @notice Keeps the token bytecode out of the pad (24 KB limit). Only listed pads may deploy, and the caller is always
///         the token's launchpad (the pad that mints and unlocks it).
/// @dev feat/merge-pad: minimal `deploy` on the STUB GangToken; feat/merge-token's version replaces this file.
contract TokenDeployer is Ownable2Step {
    mapping(address => bool) public launchpads;
    /// @notice Every token deployed here. The pad refuses these as quotes (audit 4 C-F3 / B-F1).
    mapping(address token => bool) public isLaunchToken;

    error OnlyLaunchpad();
    error ZeroAddress();

    event LaunchpadSet(address indexed launchpad, bool enabled);

    constructor(address owner_) Ownable(owner_) {}

    function setLaunchpad(address launchpad, bool enabled) external onlyOwner {
        if (launchpad == address(0)) revert ZeroAddress();
        launchpads[launchpad] = enabled;
        emit LaunchpadSet(launchpad, enabled);
    }

    /// @notice V3 taxed: (buy, sell, false); V3 untaxed: (0, 0, false); 打新: (100, 100, true).
    function deploy(
        string calldata name,
        string calldata symbol,
        string calldata uri,
        address handler,
        uint16 buyTaxBps,
        uint16 sellTaxBps,
        bool reclaimable
    ) external returns (address token) {
        if (!launchpads[msg.sender]) revert OnlyLaunchpad();
        token = address(new GangToken(name, symbol, uri, msg.sender, handler, buyTaxBps, sellTaxBps, reclaimable));
        isLaunchToken[token] = true;
    }
}
