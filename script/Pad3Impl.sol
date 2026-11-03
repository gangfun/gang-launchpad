// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {GangLaunchpad3} from "../src/gang/GangLaunchpad3.sol";
import {Pad3Module} from "../src/gang/Pad3Module.sol";

/// @title Pad3Impl — how this build's GangLaunchpad 3.0 implementation is made: its vault mode module first (the same
///        six dependencies), then the implementation with the module's address as an immutable. Used by the deploy and
///        upgrade scripts and the tests, so they all make it the same way.
library Pad3Impl {
    struct Deps {
        address quoteRegistry;
        address dividendVault;
        address platformBucket;
        address taxHandler;
        address tokenDeployer;
        address wbnb;
        address padRegistry;
    }

    function depsOf(GangLaunchpad3 p) internal view returns (Deps memory d) {
        d = Deps({
            quoteRegistry: address(p.quoteRegistry()),
            dividendVault: address(p.dividendVault()),
            platformBucket: address(p.platformBucket()),
            taxHandler: p.taxHandler(),
            tokenDeployer: p.tokenDeployer(),
            wbnb: p.wbnb(),
            padRegistry: address(p.padRegistry())
        });
    }

    function module(Deps memory d) internal returns (address) {
        return address(
            new Pad3Module(d.quoteRegistry, d.dividendVault, d.platformBucket, d.taxHandler, d.tokenDeployer, d.wbnb)
        );
    }

    /// @dev The implementation over an existing module.
    function implWith(Deps memory d, address module_) internal returns (address) {
        return address(
            new GangLaunchpad3(
                d.quoteRegistry,
                d.dividendVault,
                d.platformBucket,
                d.taxHandler,
                d.tokenDeployer,
                d.wbnb,
                d.padRegistry,
                module_
            )
        );
    }

    /// @dev A new module and the implementation over it.
    function deploy(Deps memory d) internal returns (address impl) {
        impl = implWith(d, module(d));
    }

    function deploy(
        address quoteRegistry,
        address dividendVault,
        address platformBucket,
        address taxHandler,
        address tokenDeployer,
        address wbnb,
        address padRegistry
    ) internal returns (address) {
        return deploy(Deps(quoteRegistry, dividendVault, platformBucket, taxHandler, tokenDeployer, wbnb, padRegistry));
    }
}
