// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {FloorBase} from "../gang/GangFloorModule.t.sol";
import {Pad3Module} from "../../src/gang/Pad3Module.sol";
import {GangFloorModule} from "../../src/gang/GangFloorModule.sol";
import {GangFloorModuleFactory} from "../../src/gang/GangFloorModuleFactory.sol";
import {GangHandlerAdmin} from "../../src/gang/GangHandlerAdmin.sol";
import {DeployGangFloorModuleFactory} from "../../script/DeployGangFloorModuleFactory.s.sol";

/// @notice The floor module's real order on GangLaunchpad 3.0 with the CREATE2 (abcd) deployer on (spec K-13), step
///         by step: the dev computes the token's address, clones the module for it, creates the token at that address
///         with the module as its recipient, anyone binds. Nobody else can put a token at that address, and no other
///         token binds. And the deploy script's checks.
contract Pad3FloorVanityTest is FloorBase {
    Pad3Module internal m3;

    function setUp() public {
        _deployFloor();
        m3 = Pad3Module(payable(address(pad)));
    }

    function _data(string memory name, address recipient) internal view returns (bytes memory) {
        return abi.encodeWithSignature(
            CREATE_SIG, name, "CRV", "logo", "meta", address(wbnb), address(0), _tax(TAX, TAX, 0, recipient)
        );
    }

    function test_floor_tokenAddressFixedBeforeTheTokenExists() public {
        address dev = _newAgent();
        // 1. the token's address, before anything exists: it does not depend on the recipient
        bytes32 initHash = vanity.tokenInitCodeHash("Floor", "CRV", "meta", address(handler), TAX, TAX, false);
        (bytes32 salt, address predicted) = _mine(initHash, dev);
        assertEq(predicted.code.length, 0);

        // 2. the module, cloned for that address and listed
        address kol = makeAddr("kol");
        GangFloorModule m =
            _floor(dev, predicted, address(wbnb), 1 ether, 5_000, FEE, _list(dev, kol), _shares(7_000, 3_000));
        assertEq(m.floorToken(), predicted);
        vm.expectRevert(GangFloorModule.NotCurve.selector);
        m.bind(predicted);

        // another Agent with the same salt and the same token lands elsewhere: the creator is part of the salt
        address other = _newAgent();
        vm.prank(other);
        address elsewhere = m3.createWithSalt(_mineSalt(initHash, other), _data("Floor", address(m)));
        assertTrue(elsewhere != predicted);
        vm.expectRevert(GangFloorModule.WrongToken.selector);
        m.bind(elsewhere);

        // the dev's own second token naming the module: another address, never bound
        bytes32 decoyHash = vanity.tokenInitCodeHash("Decoy", "CRV", "meta", address(handler), TAX, TAX, false);
        (bytes32 decoySalt,) = _mine(decoyHash, dev);
        vm.prank(dev);
        address decoy = m3.createWithSalt(decoySalt, _data("Decoy", address(m)));
        vm.expectRevert(GangFloorModule.WrongToken.selector);
        m.bind(decoy);

        // 3. the token, at that address, with the module as its recipient; 4. anyone binds
        vm.prank(dev);
        address t = m3.createWithSalt(salt, _data("Floor", address(m)));
        assertEq(t, predicted);
        assertEq(uint16(uint160(t)), 0xabcd);
        vm.prank(makeAddr("anyone"));
        m.bind(t);
        assertEq(m.token(), t);

        // and it works as on any pad: the cap, then the treasury, then a redemption
        address alice = _holder(t, m);
        _graduate(t);
        wbnb.mintUnlimited(address(m), 10 ether);
        uint256 a = _bal(t, alice);
        (uint256 out,) = _quoteFor(a, 9 ether, m.floorSupply(), FEE);
        vm.prank(alice);
        assertEq(m.redeem(a, out, alice), out);
        assertTrue(m.capReached());
        m.split(); // the push a redemption leaves to the next split
        assertEq(_bal(address(wbnb), kol), 0.3 ether);
        assertEq(_bal(t, DEAD) >= a, true);
        assertEq(_bal(address(wbnb), address(m)), m.treasuryHeld(), "books = balance");
    }

    function _mineSalt(bytes32 initHash, address dev) internal view returns (bytes32 salt) {
        (salt,) = _mine(initHash, dev);
    }

    // ---------------------------------------------------------------- deploy script
    function test_script_check() public {
        DeployGangFloorModuleFactory script = new DeployGangFloorModuleFactory();
        script.check(address(pad), address(admin), address(factory));
        script.checkCode(address(factory));
        assertTrue(script.vanityEnabled(address(pad)), "K-13: the abcd deployer is on");
        assertFalse(script.vanityEnabled(address(new NoVanityPad())), "a pad without it");
        assertEq(script.pendingBatch(address(admin), address(factory)).length, 0);

        GangHandlerAdmin rogue = new GangHandlerAdmin(makeAddr("notTheSafe"), address(handler));
        GangFloorModuleFactory rogueFactory = new GangFloorModuleFactory(address(pad), address(rogue), GANG);
        vm.expectRevert(abi.encodeWithSelector(DeployGangFloorModuleFactory.WiringCheck.selector, "admin.handlerOwner"));
        script.check(address(pad), address(rogue), address(rogueFactory));
        vm.expectRevert(abi.encodeWithSelector(DeployGangFloorModuleFactory.WiringCheck.selector, "factory.admin"));
        script.check(address(pad), address(admin), address(rogueFactory));

        // other code that answers every view the same way
        FakeFloorImpl fakeImpl = new FakeFloorImpl(address(pad), address(handler));
        FakeFloorFactory fake = new FakeFloorFactory(address(pad), address(admin), address(fakeImpl));
        fakeImpl.setFactory(address(fake));
        script.check(address(pad), address(admin), address(fake));
        vm.expectRevert(
            abi.encodeWithSelector(DeployGangFloorModuleFactory.WiringCheck.selector, "factory.runtimeCode")
        );
        script.checkCode(address(fake));

        GangFloorModuleFactory f2 = new GangFloorModuleFactory(address(pad), address(admin), GANG);
        bytes[] memory batch = script.pendingBatch(address(admin), address(f2));
        assertEq(batch.length, 1);
        bytes memory c = batch[0];
        address to;
        assembly ("memory-safe") {
            to := shr(96, mload(add(c, 32)))
        }
        bytes memory data = new bytes(c.length - 20);
        for (uint256 j; j < data.length; j++) {
            data[j] = c[j + 20];
        }
        assertEq(to, address(admin));
        vm.prank(owner);
        (bool ok,) = to.call(data);
        assertTrue(ok);
        assertTrue(admin.isFactory(address(f2)));
        assertEq(script.pendingBatch(address(admin), address(f2)).length, 0);
    }
}

contract NoVanityPad {}

/// @dev Answers every view the deploy script's `check` reads like a real factory / implementation, with other code.
contract FakeFloorImpl {
    address public pad;
    address public taxHandler;
    address public factory;
    bytes32 public constant moduleType = "floor-v1";
    address public constant gangQuote = address(0x6A46);

    constructor(address pad_, address handler_) {
        (pad, taxHandler) = (pad_, handler_);
    }

    function setFactory(address f) external {
        factory = f;
    }
}

contract FakeFloorFactory {
    address public pad;
    address public admin;
    address public implementation;

    constructor(address pad_, address admin_, address impl_) {
        (pad, admin, implementation) = (pad_, admin_, impl_);
    }
}
