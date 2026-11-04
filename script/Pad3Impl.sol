// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {GangLaunchpad3} from "../src/gang/GangLaunchpad3.sol";
import {Pad3Module} from "../src/gang/Pad3Module.sol";
import {Pad3FlyModule} from "../src/gang/Pad3FlyModule.sol";

/// @title Pad3Impl — how this build's GangLaunchpad 3.0 implementation is made: the 铸币飞轮 module first (three of the
///        pad's dependencies plus its own three: tax handler, token deployer, vault core), then Pad3Module over it (the pad's six
///        dependencies), then the implementation with Pad3Module's address as an immutable. Used by the deploy and
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

    /// @dev The 铸币飞轮 module's own three: a FlywheelTaxHandler whose launchpad is the 3.0 proxy (the vault core's
    ///      operator in the shared vault), a MintTokenDeployer that lists the proxy, and the Pad3FlyVaultCore of the
    ///      proxy.
    struct FlyDeps {
        address flyTaxHandler;
        address flyTokenDeployer;
        address flyVaultCore;
    }

    /// @dev Tests that never create a 铸币飞轮 token: placeholders (a create would fail on them). The scripts never use
    ///      these: they pass real FlyDeps, and the upgrade script refuses a 铸币飞轮 module whose handler / deployer
    ///      don't serve the proxy.
    address internal constant TEST_FLY_HANDLER = address(0xf1A7000000000000000000000000000000000001);
    address internal constant TEST_FLY_DEPLOYER = address(0xF1A7000000000000000000000000000000000002);
    address internal constant TEST_FLY_VAULT_CORE = address(0xf1A7000000000000000000000000000000000003);

    function testFlyDeps() internal pure returns (FlyDeps memory) {
        return FlyDeps(TEST_FLY_HANDLER, TEST_FLY_DEPLOYER, TEST_FLY_VAULT_CORE);
    }

    /// @dev `p`'s 铸币飞轮 module dependencies, if its Pad3Module has a 铸币飞轮 module (`ok` false before that).
    function flyDepsOf(GangLaunchpad3 p) internal view returns (bool ok, FlyDeps memory f) {
        address m = p.module();
        try Pad3Module(payable(m)).flyModule() returns (address fm) {
            Pad3FlyModule fly = Pad3FlyModule(fm);
            return (true, FlyDeps(fly.flyTaxHandler(), fly.flyTokenDeployer(), fly.flyVaultCore()));
        } catch {
            return (false, f);
        }
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

    function flyModule(Deps memory d, FlyDeps memory f) internal returns (address) {
        return address(
            new Pad3FlyModule(
                d.quoteRegistry, d.platformBucket, f.flyTaxHandler, f.flyTokenDeployer, f.flyVaultCore, d.wbnb
            )
        );
    }

    /// @dev Pad3Module over an existing 铸币飞轮 module.
    function moduleWith(Deps memory d, address fly) internal returns (address) {
        return address(
            new Pad3Module(
                d.quoteRegistry, d.dividendVault, d.platformBucket, d.taxHandler, d.tokenDeployer, d.wbnb, fly
            )
        );
    }

    function module(Deps memory d, FlyDeps memory f) internal returns (address) {
        return moduleWith(d, flyModule(d, f));
    }

    /// @dev Tests only (placeholder 铸币飞轮 dependencies).
    function module(Deps memory d) internal returns (address) {
        return module(d, testFlyDeps());
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

    /// @dev New modules and the implementation over them.
    function deploy(Deps memory d, FlyDeps memory f) internal returns (address impl) {
        impl = implWith(d, module(d, f));
    }

    /// @dev Tests only (placeholder 铸币飞轮 dependencies).
    function deploy(Deps memory d) internal returns (address impl) {
        impl = deploy(d, testFlyDeps());
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
