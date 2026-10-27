// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {GangToken} from "../gang/GangToken.sol";

/// @title TokenDeployer (every launch token's creation code, outside the cores)
/// @notice Keeps the token bytecode out of the cores (24 KB limit). Only listed cores may deploy, and the caller is
///         always the token's launchpad (the core that mints and unlocks it). One token contract for every kind
///         (GangToken): V3 taxed (rates checked to 1%–5% by the pad), V3 untaxed (0 / 0), 打新 (1% / 1%, reclaimable).
contract TokenDeployer is Ownable2Step {
    mapping(address => bool) public launchpads;
    /// @notice Every token deployed here (all cores). The cores refuse these as quotes (audit 4 C-F3 / B-F1).
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

    /// @notice Deploys a GangToken whose launchpad is the caller (a listed core).
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
