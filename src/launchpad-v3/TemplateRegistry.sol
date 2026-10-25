// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title TemplateRegistry (LaunchpadV3 · platform-curated economic templates)
/// @notice Whitelist of IVaultFactory addresses LaunchpadV3 accepts at create. Owner = platform multisig.
/// @dev Listing only gates NEW creates. Delisting never touches tokens already created: their vault and the
///      author snapshotted into TaxRouterV3 keep working — the platform cannot redirect live tax flows.
///      `author` = 0 means platform-authored (no author cut). An external author earns AUTHOR_SHARE_BPS.
contract TemplateRegistry is Ownable2Step {
    struct Entry {
        address author;
        bool listed;
        uint64 listedAt;
    }

    mapping(address factory => Entry) public entries;
    address[] public allFactories;

    event TemplateListed(address indexed factory, address indexed author);
    event TemplateDelisted(address indexed factory);

    error NotContract();
    error AlreadyListed();
    error NotListed();

    constructor(address owner_) Ownable(owner_) {}

    /// @notice List (or re-list) a factory. Re-listing may set a new author; tokens created earlier keep theirs.
    function list(address factory, address author) external onlyOwner {
        if (factory.code.length == 0) revert NotContract();
        Entry storage e = entries[factory];
        if (e.listed) revert AlreadyListed();
        if (e.listedAt == 0) allFactories.push(factory);
        e.author = author;
        e.listed = true;
        e.listedAt = uint64(block.timestamp);
        emit TemplateListed(factory, author);
    }

    function delist(address factory) external onlyOwner {
        Entry storage e = entries[factory];
        if (!e.listed) revert NotListed();
        e.listed = false;
        emit TemplateDelisted(factory);
    }

    function isListed(address factory) external view returns (bool) {
        return entries[factory].listed;
    }

    function authorOf(address factory) external view returns (address) {
        return entries[factory].author;
    }

    /// @notice Every factory ever listed (including delisted), in listing order.
    function factories() external view returns (address[] memory) {
        return allFactories;
    }

    function listedFactories() external view returns (address[] memory out) {
        uint256 n = allFactories.length;
        uint256 count;
        for (uint256 i; i < n; ++i) {
            if (entries[allFactories[i]].listed) ++count;
        }
        out = new address[](count);
        uint256 j;
        for (uint256 i; i < n; ++i) {
            if (entries[allFactories[i]].listed) out[j++] = allFactories[i];
        }
    }
}
