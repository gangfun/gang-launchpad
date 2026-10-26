// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title RecipientRegistry (LaunchpadV3 · tax recipients the platform allows)
/// @notice A token can only send its tax to a listed address (e.g. a partner's vault contract). Owner = platform
///         multisig. Delisting only stops new tokens from choosing it: tokens already created keep paying it.
contract RecipientRegistry is Ownable2Step {
    struct Entry {
        bool listed;
        uint64 listedAt;
        string label;
    }

    mapping(address recipient => Entry) public entries;
    address[] internal _all;

    event Listed(address indexed recipient, string label);
    event Delisted(address indexed recipient);

    error ZeroAddress();
    error AlreadyListed();
    error NotListed();

    constructor(address owner_) Ownable(owner_) {}

    /// @param label who it is, for the UI (e.g. "Acme treasury")
    function list(address recipient, string calldata label) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        Entry storage e = entries[recipient];
        if (e.listed) revert AlreadyListed();
        if (e.listedAt == 0) _all.push(recipient);
        e.listed = true;
        e.listedAt = uint64(block.timestamp);
        e.label = label;
        emit Listed(recipient, label);
    }

    function delist(address recipient) external onlyOwner {
        if (!entries[recipient].listed) revert NotListed();
        entries[recipient].listed = false;
        emit Delisted(recipient);
    }

    function isListed(address recipient) external view returns (bool) {
        return entries[recipient].listed;
    }

    /// @notice Every address ever listed (delisted ones included; check `isListed`).
    function recipients() external view returns (address[] memory) {
        return _all;
    }
}
