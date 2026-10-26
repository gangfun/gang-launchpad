// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {LaunchTokenV3} from "../launchpad-v3/LaunchTokenV3.sol";
import {TaxLaunchTokenV3} from "../launchpad-v3/TaxLaunchTokenV3.sol";
import {FairToken} from "../fair-mint/FairToken.sol";

/// @title TokenDeployer (LaunchpadV3 + 打新 · token creation code, outside the cores)
/// @notice Keeps the token bytecode out of the cores (24 KB limit). Only listed cores may deploy, and the caller is
///         always the token's launchpad (the core that mints and unlocks it).
contract TokenDeployer is Ownable2Step {
    mapping(address => bool) public launchpads;
    /// @notice Every token deployed here (both cores). The cores refuse these as quotes (audit 4 C-F3 / B-F1).
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

    /// @notice LaunchpadV3 untaxed token.
    function deployPlain(string calldata name, string calldata symbol, string calldata uri)
        external
        returns (address)
    {
        _onlyLaunchpad();
        return _record(address(new LaunchTokenV3(name, symbol, msg.sender, uri)));
    }

    /// @notice LaunchpadV3 taxed token.
    function deployTax(
        string calldata name,
        string calldata symbol,
        uint16 buyTaxBps,
        uint16 sellTaxBps,
        address taxHandler,
        string calldata uri
    ) external returns (address) {
        _onlyLaunchpad();
        return _record(address(new TaxLaunchTokenV3(name, symbol, buyTaxBps, sellTaxBps, msg.sender, taxHandler, uri)));
    }

    /// @notice 打新 token.
    function deployFair(string calldata name, string calldata symbol, address taxHandler, string calldata uri)
        external
        returns (address)
    {
        _onlyLaunchpad();
        return _record(address(new FairToken(name, symbol, msg.sender, taxHandler, uri)));
    }

    function _record(address token) internal returns (address) {
        isLaunchToken[token] = true;
        return token;
    }

    function _onlyLaunchpad() internal view {
        if (!launchpads[msg.sender]) revert OnlyLaunchpad();
    }
}
