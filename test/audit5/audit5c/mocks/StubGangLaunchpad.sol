// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// TEST FIXTURE ONLY. The deploy-time stand-in for GangLaunchpad that feat/merge-scripts used before the real pad
// existed (script/stubs/GangStubs.sol, deleted at integration). Same setters and wiring views as the real pad, no
// trading logic. DeployScriptsFork swaps it in for the real pad to prove that DeployGang's self-check refuses it.

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IGangLaunchpad} from "../../../../src/gang/interfaces/IGangLaunchpad.sol";

interface IStubPadMigrator {
    function launchpads(address) external view returns (bool);
}

/// @dev STUB of the external library CurveLogic (the real one is delegatecalled by the pad and links PoolCheck).
library StubCurveLogic {
    function graduationAmountOf(address wbnb, address quote) external pure returns (uint256) {
        return quote == wbnb ? 15 ether : 0;
    }
}

/// @dev STUB of the external library FairLogic.
library StubFairLogic {
    function previewCreate(address wbnb, address quote, uint256 raiseBnb)
        external
        pure
        returns (uint256 raiseQuote, uint256 sharePrice)
    {
        raiseQuote = quote == wbnb ? raiseBnb : 0;
        sharePrice = raiseQuote / 10_000;
    }
}

/// @dev STUB of GangLaunchpad. Constructor as assumed by DeployGang (merge plan §1.3: owner + the old cores' list).
contract StubGangLaunchpad is Ownable2Step, IGangLaunchpad {
    uint256 public constant TAXED_MIN_SHARE = 10_000 ether;
    uint256 public constant MIN_SHARE_BALANCE = 10_000 ether;
    uint256 public constant TARGET_GRAD_BNB = 15 ether;
    uint256 public constant TOTAL_SHARES = 10_000;

    address public immutable quoteRegistry;
    address public immutable dividendVault;
    address public immutable platformBucket;
    address public immutable taxHandler;
    address public immutable tokenDeployer;
    address public immutable wbnb;

    address public pairFactory;
    address public v3Factory;
    uint32 public twapWindow = 1800;
    address public migrator;
    address public agentIdRegistry;
    bool public agentGateEnabled = true;
    bool public walletCapEnabled = true;
    mapping(address => address) public bridgePoolOf;
    mapping(address => bool) public routers;
    mapping(address => uint8) public kindOf;

    constructor(
        address owner_,
        address quoteRegistry_,
        address dividendVault_,
        address platformBucket_,
        address taxHandler_,
        address tokenDeployer_,
        address wbnb_,
        address pairFactory_
    ) Ownable(owner_) {
        if (
            quoteRegistry_ == address(0) || dividendVault_ == address(0) || platformBucket_ == address(0)
                || taxHandler_ == address(0) || tokenDeployer_ == address(0) || wbnb_ == address(0)
        ) revert ZeroAddress();
        quoteRegistry = quoteRegistry_;
        dividendVault = dividendVault_;
        platformBucket = platformBucket_;
        taxHandler = taxHandler_;
        tokenDeployer = tokenDeployer_;
        wbnb = wbnb_;
        pairFactory = pairFactory_;
    }

    function setMigrator(address migrator_) external onlyOwner {
        if (migrator != address(0)) revert MigratorAlreadySet();
        if (migrator_ == address(0)) revert ZeroAddress();
        if (!IStubPadMigrator(migrator_).launchpads(address(this))) revert WrongMigrator();
        migrator = migrator_;
        emit MigratorSet(migrator_);
    }

    function setPairFactory(address f) external onlyOwner {
        pairFactory = f;
        emit PairFactorySet(f);
    }

    function setRouter(address r, bool enabled) external onlyOwner {
        if (r == address(0)) revert ZeroAddress();
        routers[r] = enabled;
        emit RouterSet(r, enabled);
    }

    function setAgentGate(bool enabled, address registry) external onlyOwner {
        agentGateEnabled = enabled;
        agentIdRegistry = registry;
        emit AgentGateUpdated(enabled, registry);
    }

    function setWalletCapEnabled(bool enabled) external onlyOwner {
        walletCapEnabled = enabled;
        emit WalletCapUpdated(enabled);
    }

    function setV3Factory(address f) external onlyOwner {
        v3Factory = f;
        emit V3FactorySet(f);
    }

    function setTwapWindow(uint32 w) external onlyOwner {
        twapWindow = w;
        emit TwapWindowUpdated(w);
    }

    function setBridgePool(address asset, address pool) external onlyOwner {
        bridgePoolOf[asset] = pool;
        emit BridgePoolSet(asset, pool);
    }

    function graduationAmountOf(address quote, address) external view returns (uint256) {
        return StubCurveLogic.graduationAmountOf(wbnb, quote == address(0) ? wbnb : quote);
    }

    function previewCreate(address quote, address, uint256 raiseBnb) external view returns (uint256, uint256) {
        return StubFairLogic.previewCreate(wbnb, quote == address(0) ? wbnb : quote, raiseBnb);
    }
}
