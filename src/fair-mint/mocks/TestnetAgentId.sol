// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

/// @notice BSC testnet stand-in for the SPACE ID Agent ID registry: soulbound, one ID per wallet, self-registered.
///         Mainnet uses the real registry (0x60B9…022F), which needs an official signature to register.
contract TestnetAgentId is ERC721("Testnet Agent ID", "tAI") {
    uint256 public nextId = 1;

    error Soulbound();
    error AlreadyRegistered();

    function register() external returns (uint256 id) {
        if (balanceOf(msg.sender) != 0) revert AlreadyRegistered();
        id = nextId++;
        _mint(msg.sender, id);
    }

    function _update(address to, uint256 id, address auth) internal override returns (address from) {
        if (_ownerOf(id) != address(0)) revert Soulbound();
        return super._update(to, id, auth);
    }
}
