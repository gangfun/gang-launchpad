// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {GangLaunchpad3} from "../../src/gang/GangLaunchpad3.sol";
import {Pad3Impl} from "../../script/Pad3Impl.sol";
import {FlywheelFixture} from "../flywheel/FlywheelFixture.sol";
import {Pad3FlyVaultCore} from "../../src/gang/Pad3FlyVaultCore.sol";
import {Vm} from "forge-std/Vm.sol";
import {FlywheelAuditBFixesTest} from "../flywheel/FlywheelAuditB.t.sol";
import {FlywheelAggregatorTest} from "../flywheel/FlywheelAggregator.t.sol";
import {FlywheelAttacksTest} from "../flywheel/FlywheelAttacks.t.sol";
import {FlywheelAuditFixesTest} from "../flywheel/FlywheelAttacks.t.sol";
import {FlywheelDumpHoldTest} from "../flywheel/FlywheelDumpHold.t.sol";
import {FlywheelDumpMintOneBlockTest} from "../flywheel/FlywheelDumpMint.t.sol";
import {FlywheelBackrunDumpTest} from "../flywheel/FlywheelDumpMint.t.sol";
import {FlywheelDumpMintUptrendTest} from "../flywheel/FlywheelDumpMintUptrend.t.sol";
import {FlywheelV2PreviewTest} from "../flywheel/FlywheelV2Preview.t.sol";
import {FlywheelV2SameBlockTest} from "../flywheel/FlywheelV2.t.sol";
import {FlywheelV2HonestTest} from "../flywheel/FlywheelV2.t.sol";
import {FlywheelV2GuardTest} from "../flywheel/FlywheelV2.t.sol";
import {FlywheelV2MintThenSellTest} from "../flywheel/FlywheelV2.t.sol";
import {FlywheelV2JPresetTenIdsTest} from "../flywheel/FlywheelV2.t.sol";
import {FlywheelV2AuditFixesTest} from "../flywheel/FlywheelV2.t.sol";
import {FlywheelV2InvariantTest} from "../flywheel/FlywheelV2Invariant.t.sol";
import {GangFlywheelPadTest} from "../flywheel/GangFlywheelPad.t.sol";

/// @dev An empty pad registry: 3.0 needs one, the 铸币飞轮 suites never forward to another pad.
contract EmptyPadRegistry {
    function lookup(address) external pure returns (address pad, uint8 kind) {
        return (address(0), 0);
    }
}

/// @dev GangLaunchpad 3.0 as a 铸币飞轮 pad for FlywheelFixture, wired as on mainnet: the implementation over this
///      build's modules behind a proxy owned by the fixture's owner, with its vault core (FlywheelFixture._bindFlyHandler
///      wires the vault as on mainnet). The fixture's handler and MintTokenDeployer are the 铸币飞轮 module's; they
///      also stand in for the curve / 打新 tax handler and token deployer, which these suites never use. The fixture
///      then wires the rest as it wires V2 (bucket, migrator, deployer, handler, gate).
library Pad3FlyPad {
    Vm internal constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function deploy(FlywheelFixture f) internal returns (address pad3) {
        address registry = address(new EmptyPadRegistry());
        // creates from here: the vault core, the 铸币飞轮 module, Pad3Module, the implementation, the proxy
        address proxy = VM.computeCreateAddress(address(this), VM.getNonce(address(this)) + 4);
        address core = address(new Pad3FlyVaultCore(address(f.vault()), proxy));
        Pad3Impl.Deps memory d = Pad3Impl.Deps({
            quoteRegistry: address(f.quoteRegistry()),
            dividendVault: address(f.vault()),
            platformBucket: address(f.bucket()),
            taxHandler: address(f.handler()),
            tokenDeployer: address(f.deployer()),
            wbnb: address(f.wbnb()),
            padRegistry: registry
        });
        address impl = Pad3Impl.deploy(d, Pad3Impl.FlyDeps(address(f.handler()), address(f.deployer()), core));
        pad3 = address(
            new TransparentUpgradeableProxy(
                impl, address(0xA0FF), abi.encodeCall(GangLaunchpad3.initialize, (f.owner(), address(f.factory())))
            )
        );
        require(pad3 == proxy, "the vault core's pad is the proxy");
    }
}

/// @notice GangLaunchpad 3.0's 铸币飞轮 mode: every FlywheelFixture suite of GangFlywheelPad V2 re-run with the pad
///         deployed as 3.0 (proxy, Pad3Module → Pad3FlyModule), through V2's own selectors (`sales`, `withdraw`,
///         `previewMint`, … dispatched by token kind). Same tests, same expectations.

contract FlywheelAuditBFixes3Test is FlywheelAuditBFixesTest {
    function _newFlyPad() internal override returns (address) {
        return Pad3FlyPad.deploy(this);
    }
}

contract FlywheelAggregator3Test is FlywheelAggregatorTest {
    function _newFlyPad() internal override returns (address) {
        return Pad3FlyPad.deploy(this);
    }
}

contract FlywheelAttacks3Test is FlywheelAttacksTest {
    function _newFlyPad() internal override returns (address) {
        return Pad3FlyPad.deploy(this);
    }
}

contract FlywheelAuditFixes3Test is FlywheelAuditFixesTest {
    function _newFlyPad() internal override returns (address) {
        return Pad3FlyPad.deploy(this);
    }
}

contract FlywheelDumpHold3Test is FlywheelDumpHoldTest {
    function _newFlyPad() internal override returns (address) {
        return Pad3FlyPad.deploy(this);
    }
}

contract FlywheelDumpMintOneBlock3Test is FlywheelDumpMintOneBlockTest {
    function _newFlyPad() internal override returns (address) {
        return Pad3FlyPad.deploy(this);
    }
}

contract FlywheelBackrunDump3Test is FlywheelBackrunDumpTest {
    function _newFlyPad() internal override returns (address) {
        return Pad3FlyPad.deploy(this);
    }
}

contract FlywheelDumpMintUptrend3Test is FlywheelDumpMintUptrendTest {
    function _newFlyPad() internal override returns (address) {
        return Pad3FlyPad.deploy(this);
    }
}

contract FlywheelV2Preview3Test is FlywheelV2PreviewTest {
    function _newFlyPad() internal override returns (address) {
        return Pad3FlyPad.deploy(this);
    }
}

contract FlywheelV2SameBlock3Test is FlywheelV2SameBlockTest {
    function _newFlyPad() internal override returns (address) {
        return Pad3FlyPad.deploy(this);
    }
}

contract FlywheelV2Honest3Test is FlywheelV2HonestTest {
    function _newFlyPad() internal override returns (address) {
        return Pad3FlyPad.deploy(this);
    }
}

contract FlywheelV2Guard3Test is FlywheelV2GuardTest {
    function _newFlyPad() internal override returns (address) {
        return Pad3FlyPad.deploy(this);
    }
}

contract FlywheelV2MintThenSell3Test is FlywheelV2MintThenSellTest {
    function _newFlyPad() internal override returns (address) {
        return Pad3FlyPad.deploy(this);
    }
}

contract FlywheelV2JPresetTenIds3Test is FlywheelV2JPresetTenIdsTest {
    function _newFlyPad() internal override returns (address) {
        return Pad3FlyPad.deploy(this);
    }
}

contract FlywheelV2AuditFixes3Test is FlywheelV2AuditFixesTest {
    function _newFlyPad() internal override returns (address) {
        return Pad3FlyPad.deploy(this);
    }
}

/// @dev Inline config is not inherited: without these two lines this suite runs at the default 256 runs x 500 calls.
/// forge-config: default.invariant.runs = 4
/// forge-config: default.invariant.depth = 60
contract FlywheelV2Invariant3Test is FlywheelV2InvariantTest {
    function _newFlyPad() internal override returns (address) {
        return Pad3FlyPad.deploy(this);
    }
}

contract GangFlywheelPad3Test is GangFlywheelPadTest {
    function _newFlyPad() internal override returns (address) {
        return Pad3FlyPad.deploy(this);
    }
}
