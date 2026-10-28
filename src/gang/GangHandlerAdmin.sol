// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

interface IHandlerListing {
    function list(address recipient, string calldata label) external;
}

/// @title GangHandlerAdmin — the tax handler's owner, so that module factories can list their own recipients
/// @notice GangTaxHandler lets a V3 token pay its tax to the creator or to an address its owner `list`ed, and it can't be
///         changed. This contract becomes that owner (the Safe stays this contract's owner) and adds one thing: a
///         factory the Safe allowed lists the recipient modules it just made (`listModule`), so a dev who wants one
///         gets it from the CLI with no listing by hand. Everything else stays the Safe's, one call away:
///         - `exec(data)`: any call on the handler as its owner (list / delist, keeper and DEX router changes, and
///           handing the handler back: `exec(transferOwnership(safe))`, then the Safe accepts);
///         - `setFactory`: allow a factory (a new kind or version of module) or stop one (its modules stay listed —
///           a token's recipient is fixed at create — `exec(delist)` drops one).
///         Taking over: the Safe calls `handler.transferOwnership(admin)`, then `admin.exec(acceptOwnership())`.
/// @dev Not upgradeable: it holds the handler's owner role, so it stays this small. A factory is trusted to pass only
///      modules it deployed (audited before it is allowed); `moduleOf` records which one did, for the keeper and the site.
contract GangHandlerAdmin is Ownable2Step {
    address public immutable handler;

    mapping(address factory => bool) public isFactory;
    /// @notice The factory that listed `module` (0: not listed through here).
    mapping(address module => address factory) public moduleOf;

    mapping(address factory => bool) internal _seen;
    address[] internal _factories;
    address[] internal _modules;

    event FactorySet(address indexed factory, bool allowed);
    event ModuleListed(address indexed module, address indexed factory, string label);
    event Executed(bytes4 indexed selector);

    error ZeroAddress();
    error NotFactory();
    error NoCode();
    error AlreadyListed();

    constructor(address owner_, address handler_) Ownable(owner_) {
        if (handler_ == address(0)) revert ZeroAddress();
        handler = handler_;
    }

    /// @notice Call the handler as its owner (reverts with the handler's own error).
    function exec(bytes calldata data) external onlyOwner returns (bytes memory result) {
        bool ok;
        (ok, result) = handler.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(result, 32), mload(result))
            }
        }
        emit Executed(bytes4(data));
    }

    function setFactory(address factory, bool allowed) external onlyOwner {
        if (factory == address(0)) revert ZeroAddress();
        if (allowed && !_seen[factory]) {
            _seen[factory] = true;
            _factories.push(factory);
        }
        isFactory[factory] = allowed;
        emit FactorySet(factory, allowed);
    }

    /// @notice An allowed factory lists a module it just deployed as a tax recipient (once per module).
    function listModule(address module, string calldata label) external {
        if (!isFactory[msg.sender]) revert NotFactory();
        if (module.code.length == 0) revert NoCode();
        if (moduleOf[module] != address(0)) revert AlreadyListed();
        moduleOf[module] = msg.sender;
        _modules.push(module);
        IHandlerListing(handler).list(module, label);
        emit ModuleListed(module, msg.sender, label);
    }

    /// @notice Every factory ever allowed (`isFactory` says which still are).
    function factories() external view returns (address[] memory) {
        return _factories;
    }

    /// @notice Every module listed through here, oldest first.
    function modules() external view returns (address[] memory) {
        return _modules;
    }

    function moduleCount() external view returns (uint256) {
        return _modules.length;
    }
}
