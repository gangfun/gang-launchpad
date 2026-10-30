// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {GangMintToken} from "./GangMintToken.sol";

/// @title MintTokenDeployer (GangMintToken creation code, outside the pad)
/// @notice TokenDeployer for continuous-mint tokens: only listed pads may deploy, and the caller is always the token's
///         launchpad. Keeps the token bytecode out of the pad (24 KB limit).
contract MintTokenDeployer is Ownable2Step {
    mapping(address => bool) public launchpads;
    /// @notice Every token deployed here. A pad refuses these as quotes.
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

    /// @notice Deploys a reclaimable GangMintToken whose launchpad is the caller (a listed pad).
    function deploy(
        string calldata name,
        string calldata symbol,
        string calldata uri,
        address handler,
        uint16 buyTaxBps,
        uint16 sellTaxBps,
        uint256 startSupply,
        uint256 maxSupply
    ) external returns (address token) {
        if (!launchpads[msg.sender]) revert OnlyLaunchpad();
        token = address(
            new GangMintToken(
                name, symbol, uri, msg.sender, handler, buyTaxBps, sellTaxBps, true, startSupply, maxSupply
            )
        );
        isLaunchToken[token] = true;
    }
}
