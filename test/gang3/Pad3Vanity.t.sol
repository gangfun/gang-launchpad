// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {GangFixture} from "../utils/GangFixture.sol";
import {GangLaunchpad} from "../../src/gang/GangLaunchpad.sol";
import {GangLaunchpad3} from "../../src/gang/GangLaunchpad3.sol";
import {Pad3Module} from "../../src/gang/Pad3Module.sol";
import {Pad3FlyModule} from "../../src/gang/Pad3FlyModule.sol";
import {Pad3VanityDeployer} from "../../src/gang/Pad3VanityDeployer.sol";
import {Pad3VanityStore} from "../../src/gang/Pad3VanityStore.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {IFlywheelPad} from "../../src/flywheel/interfaces/IFlywheelPad.sol";
import {GangToken} from "../../src/gang/GangToken.sol";
import {GangMintToken} from "../../src/flywheel/GangMintToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Pad3Impl} from "../../script/Pad3Impl.sol";
import {GangRouterDeployLib as R} from "../../script/GangRouterDeployLib.sol";
import {UpgradeGangLaunchpad3} from "../../script/UpgradeGangLaunchpad3.s.sol";
import {DeployGang} from "../../script/DeployGang.s.sol";

contract VanityUpgradeHarness is UpgradeGangLaunchpad3 {
    function check(address proxy, address factory, address upgrader) external {
        _abcd = factory;
        _checkVanity(proxy, upgrader);
    }

    function batch(address proxy, address factory, address admin) external returns (string memory) {
        _abcd = factory;
        return _batchJson(false, address(1), new address[](0), new bytes[](0), admin, hex"12345678", proxy);
    }
}

contract Pad3VanityTest is GangFixture {
    Pad3Module internal m;
    GangLaunchpad3 internal p;
    Pad3VanityDeployer internal factory;
    address internal creator;

    function _newPad() internal override returns (GangLaunchpad) {
        return _newPad3();
    }

    function setUp() public {
        _deployGang(makeAddr("keeper"));
        m = Pad3Module(payable(address(pad)));
        p = GangLaunchpad3(payable(address(pad)));
        factory = new Pad3VanityDeployer(address(pad), address(tokenDeployer), address(flyDeployer));
        creator = _newAgent();
    }

    function _enable() internal {
        vm.prank(owner);
        m.enableVanity(address(factory));
    }

    /// @dev Reuse a small buffer so mining never expands memory in proportion to the number of attempts.
    function _mine(bytes32 initHash, address dev) internal view returns (bytes32 salt, address predicted) {
        address deployer = address(factory);
        bytes memory buffer = new bytes(85);
        for (uint256 i;; i++) {
            uint256 hash;
            assembly ("memory-safe") {
                let ptr := add(buffer, 32)
                mstore(ptr, dev)
                mstore(add(ptr, 32), i)
                let effectiveSalt := keccak256(ptr, 64)
                mstore(ptr, shl(248, 0xff))
                mstore(add(ptr, 1), shl(96, deployer))
                mstore(add(ptr, 21), effectiveSalt)
                mstore(add(ptr, 53), initHash)
                hash := keccak256(ptr, 85)
            }
            if (uint16(hash) == 0xabcd) return (bytes32(i), address(uint160(hash)));
        }
    }

    function _curveData(uint256 mode) internal view returns (bytes memory) {
        IGangLaunchpad.TaxConfig memory tax = mode == 1 ? _tax(100, 200, 0, creator) : _tax(0, 0, 0, address(0));
        if (mode == 2) {
            return abi.encodeWithSignature(
                "createWithGradTarget(string,string,string,string,address,address,(uint16,uint16,uint16,address),uint256)",
                "Curve",
                "CRV",
                "logo",
                "meta",
                address(wbnb),
                address(0),
                tax,
                6 ether
            );
        }
        if (mode == 3) {
            return abi.encodeCall(
                Pad3Module.createWithVault,
                ("Curve", "CRV", "logo", "meta", address(wbnb), address(0), tax, 9 ether, address(this))
            );
        }
        if (mode == 4) {
            return abi.encodeCall(
                Pad3Module.createWithPromote,
                ("Curve", "CRV", "logo", "meta", address(wbnb), address(0), tax, 9 ether, 1000, uint32(7 days))
            );
        }
        return abi.encodeWithSignature(
            "create(string,string,string,string,address,address,(uint16,uint16,uint16,address))",
            "Curve",
            "CRV",
            "logo",
            "meta",
            address(wbnb),
            address(0),
            tax
        );
    }

    function test_curveEntries_allEndInAbcd() public {
        _enable();
        for (uint256 mode; mode < 5; mode++) {
            if (mode == 3) {
                vm.startPrank(owner);
                m.setVault(address(this), true);
                m.setVaultCreator(address(this), creator);
                vm.stopPrank();
            }
            bytes32 hash = factory.tokenInitCodeHash(
                "Curve",
                "CRV",
                "meta",
                mode == 1 ? address(handler) : address(0),
                mode == 1 ? 100 : 0,
                mode == 1 ? 200 : 0,
                false
            );
            (bytes32 salt, address expected) = _mine(hash, creator);
            // The untaxed cases share constructor arguments: choose a fresh salt for each deployment.
            if (expected.code.length != 0) {
                creator = _newAgent();
                (salt, expected) = _mine(hash, creator);
                if (mode == 3) {
                    vm.prank(owner);
                    m.setVaultCreator(address(this), creator);
                }
            }
            vm.prank(creator);
            address token = m.createWithSalt(salt, _curveData(mode));
            assertEq(token, expected);
            assertEq(uint16(uint160(token)), 0xabcd);
            assertEq(p.kindOf(token), 1);
            assertTrue(factory.isLaunchToken(token));
            assertEq(GangToken(token).launchpad(), address(pad));
            (address dev,,,,,,,,,,,) = p.curves(token);
            assertEq(dev, creator);
            vm.prank(creator);
            p.buy(token, 0.01 ether, 1);
            assertGt(IERC20(token).balanceOf(creator), 0);
        }
    }

    function test_fair_addressAndInitialMint() public {
        _enable();
        bytes32 hash = factory.tokenInitCodeHash("Fair", "FAIR", "meta", address(handler), 100, 100, true);
        assertEq(
            hash,
            keccak256(
                abi.encodePacked(
                    type(GangToken).creationCode,
                    abi.encode("Fair", "FAIR", "meta", address(pad), address(handler), uint16(100), uint16(100), true)
                )
            )
        );
        (bytes32 salt, address expected) = _mine(hash, creator);
        bytes memory data = abi.encodeWithSignature(
            "create(string,string,string,string,address,address,(uint256,uint16,uint16,uint16,uint16),uint256)",
            "Fair",
            "FAIR",
            "logo",
            "meta",
            address(wbnb),
            address(0),
            _mintCfg(10 ether, 50, 6000, 100, 100),
            uint256(1)
        );
        vm.prank(creator);
        assertEq(m.createWithSalt(salt, data), expected);
        assertEq(p.kindOf(expected), 2);
        assertEq(IERC20(expected).balanceOf(creator), TOKENS_PER_SHARE);
    }

    function _flyCfg() internal pure returns (IFlywheelPad.FlyConfig memory cfg) {
        cfg.raiseBnb = 20 ether;
        cfg.baseQuota = 10;
        cfg.inviteBonus = 1;
        cfg.maxPerTx = 10;
        cfg.holdBps = 6000;
        cfg.mintFeeBps = 100;
        cfg.exitFeeBps = 100;
        cfg.devCutBps = 1000;
        cfg.buyBps = 3000;
        cfg.sellTaxBps = 200;
        cfg.launchDelay = 60;
        cfg.window = 600;
        cfg.windowCapMul = 1;
        cfg.postMint = true;
        cfg.tierMode = 1;
        cfg.supplyCapMul = 100;
        cfg.twapWindow = 1800;
    }

    function test_fly_addressAndInitialMint() public {
        _enable();
        uint256 cap = 200_000_000_000 ether;
        bytes32 hash = factory.mintInitCodeHash("Fly", "FLY", "meta", address(flyHandler), 100, 200, 0, cap);
        assertEq(
            hash,
            keccak256(
                abi.encodePacked(
                    type(GangMintToken).creationCode,
                    abi.encode(
                        "Fly",
                        "FLY",
                        "meta",
                        address(pad),
                        address(flyHandler),
                        uint16(100),
                        uint16(200),
                        true,
                        uint256(0),
                        cap
                    )
                )
            )
        );
        (bytes32 salt, address expected) = _mine(hash, creator);
        string[4] memory text = ["Fly", "FLY", "logo", "meta"];
        vm.prank(creator);
        address token = m.createWithSalt(
            salt, abi.encodeCall(Pad3FlyModule.create, (text, address(wbnb), address(0), _flyCfg(), uint256(1)))
        );
        assertEq(token, expected);
        assertEq(p.kindOf(token), 3);
        assertEq(IERC20(token).balanceOf(creator), 100_000 ether);
        assertTrue(factory.isLaunchToken(token));
    }

    function test_rejectsUnsaltedWrongSuffixAndReusedSalt() public {
        _enable();
        vm.expectRevert(Pad3Module.VanityContextRequired.selector);
        _createV3(creator, address(wbnb), _tax(0, 0, 0, address(0)));
        bytes32 hash = factory.tokenInitCodeHash("Curve", "CRV", "meta", address(0), 0, 0, false);
        (bytes32 salt,) = _mine(hash, creator);
        vm.startPrank(creator);
        bytes32 bad = bytes32(uint256(salt) + 1);
        while (uint16(uint160(factory.predict(hash, keccak256(abi.encode(creator, bad))))) == 0xabcd) {
            bad = bytes32(uint256(bad) + 1);
        }
        vm.expectRevert(Pad3VanityDeployer.InvalidSuffix.selector);
        m.createWithSalt(bad, _curveData(0));
        m.createWithSalt(salt, _curveData(0));
        vm.expectRevert();
        m.createWithSalt(salt, _curveData(0));
        vm.expectRevert(Pad3Module.VanityContextRequired.selector);
        m.vanitySalt();
        vm.stopPrank();
    }

    function test_onlyOwnerCanActivate_once_andOnlyCreatesCanBeWrapped() public {
        vm.prank(creator);
        vm.expectRevert();
        m.enableVanity(address(factory));
        _enable();
        vm.prank(owner);
        vm.expectRevert(Pad3Module.VanityAlreadyEnabled.selector);
        m.enableVanity(address(factory));
        vm.expectRevert(Pad3Module.BadVanityCall.selector);
        m.createWithSalt(0, abi.encodeCall(Pad3Module.enableVanity, (address(factory))));
        vm.expectRevert(Pad3VanityDeployer.OnlyLaunchpad.selector);
        factory.deploy("A", "A", "", address(0), 0, 0, false);
    }

    function test_copiedSalt_cannotTakeCreatorsAddress() public {
        _enable();
        bytes32 hash = factory.tokenInitCodeHash("Curve", "CRV", "meta", address(0), 0, 0, false);
        (bytes32 salt, address expected) = _mine(hash, creator);
        address other = _newAgent();
        address otherAddress = factory.predict(hash, keccak256(abi.encode(other, salt)));
        assertNotEq(otherAddress, expected);
        vm.prank(other);
        if (uint16(uint160(otherAddress)) != 0xabcd) vm.expectRevert(Pad3VanityDeployer.InvalidSuffix.selector);
        m.createWithSalt(salt, _curveData(0));
        assertEq(expected.code.length, 0);
        vm.prank(creator);
        assertEq(m.createWithSalt(salt, _curveData(0)), expected);
    }

    function test_legacyMintTokens_remainInQuoteFilter() public {
        string[4] memory text = ["Old Fly", "OFLY", "logo", "meta"];
        vm.prank(creator);
        address old = Pad3FlyModule(address(pad)).create(text, address(wbnb), address(0), _flyCfg(), 1);
        _enable();
        assertTrue(factory.isLaunchToken(old));
        vm.expectRevert(IGangLaunchpad.QuoteNotAllowed.selector);
        _createV3(creator, old, _tax(0, 0, 0, address(0)));
    }

    function test_activationAndUpgrade_preserveOldTokensAndFilter() public {
        address old = _createV3(creator, address(wbnb), _tax(0, 0, 0, address(0)));
        _enable();
        assertTrue(factory.isLaunchToken(old));
        vm.prank(creator);
        p.buy(old, 0.001 ether, 1);
        assertGt(IERC20(old).balanceOf(creator), 0);
        address next = Pad3Impl.deploy(
            Pad3Impl.depsOf(p), Pad3Impl.FlyDeps(address(flyHandler), address(flyDeployer), address(flyCore))
        );
        vm.prank(upgrader);
        ProxyAdmin(R.adminOf(address(pad))).upgradeAndCall(ITransparentUpgradeableProxy(address(pad)), next, "");
        assertEq(m.vanityDeployer(), address(factory));
        assertEq(p.kindOf(old), 1);
        assertTrue(factory.isLaunchToken(old));
        vm.prank(creator);
        p.buy(old, 0.01 ether, 1);
    }

    function test_namespaceAndCodeSizes() public view {
        assertEq(
            Pad3VanityStore.SLOT,
            keccak256(abi.encode(uint256(keccak256("gang.pad3.vanity")) - 1)) & ~bytes32(uint256(0xff))
        );
        assertLe(address(factory).code.length, 24_576);
        assertLe(p.module().code.length, 24_576);
        assertLe(pad3Impl.code.length, 24_576);
    }

    function test_upgradeBatch_checksFactory_andAppendsActivation() public {
        VanityUpgradeHarness h = new VanityUpgradeHarness();
        vm.prank(owner);
        p.transferOwnership(upgrader);
        vm.prank(upgrader);
        p.acceptOwnership();
        h.check(address(pad), address(factory), upgrader);
        Pad3VanityDeployer wrong = new Pad3VanityDeployer(address(1), address(tokenDeployer), address(flyDeployer));
        vm.expectRevert();
        h.check(address(pad), address(wrong), upgrader);
        vm.expectRevert();
        h.check(address(pad), address(tokenDeployer), upgrader);
        address admin = R.adminOf(address(pad));
        string memory batch = h.batch(address(pad), address(factory), admin);
        assertEq(vm.parseJsonAddress(batch, ".transactions[0].to"), admin);
        assertEq(vm.parseJsonBytes(batch, ".transactions[0].data"), hex"12345678");
        assertEq(vm.parseJsonAddress(batch, ".transactions[1].to"), address(pad));
        assertEq(
            vm.parseJsonBytes(batch, ".transactions[1].data"),
            abi.encodeCall(Pad3Module.enableVanity, (address(factory)))
        );
        string memory plain = h.batch(address(pad), address(0), admin);
        assertFalse(vm.keyExistsJson(plain, ".transactions[1]"));
    }

    function test_upgradeCheck_rejectsTamperedInternalImmutableReferences() public {
        VanityUpgradeHarness h = new VanityUpgradeHarness();
        vm.prank(owner);
        p.transferOwnership(upgrader);
        vm.prank(upgrader);
        p.acceptOwnership();
        bytes memory original = address(factory).code;
        bytes memory altered = bytes.concat(original);
        address[3] memory expected = [address(pad), address(tokenDeployer), address(flyDeployer)];
        bytes32 replacement = bytes32(uint256(uint160(makeAddr("wrong factory reference"))));
        bytes32 initHash = factory.tokenInitCodeHash("Curve", "CRV", "meta", address(0), 0, 0, false);
        bool changedInitHash;
        uint256[3] memory rejected;
        for (uint256 field; field < expected.length; field++) {
            bytes32 word = bytes32(uint256(uint160(expected[field])));
            for (uint256 i; i + 32 <= altered.length; i++) {
                bytes32 here;
                assembly ("memory-safe") { here := mload(add(add(altered, 32), i)) }
                if (here != word) continue;
                // Mutate one actual runtime reference, without compiler-specific offsets or immutable IDs.
                assembly ("memory-safe") { mstore(add(add(altered, 32), i), replacement) }
                vm.etch(address(factory), altered);
                if (
                    factory.pad() == expected[0] && factory.legacyTokenDeployer() == expected[1]
                        && factory.legacyMintTokenDeployer() == expected[2]
                ) {
                    if (factory.tokenInitCodeHash("Curve", "CRV", "meta", address(0), 0, 0, false) != initHash) {
                        changedInitHash = true;
                    }
                    vm.expectRevert(abi.encodeWithSelector(DeployGang.WiringCheck.selector, "abcd deployer code"));
                    h.check(address(pad), address(factory), upgrader);
                    rejected[field]++;
                }
                assembly ("memory-safe") { mstore(add(add(altered, 32), i), word) }
                vm.etch(address(factory), original);
            }
            assertGt(rejected[field], 0, "must exercise a non-getter reference of each immutable");
        }
        assertTrue(changedInitHash, "the mutation must affect behavior while leaving all getters correct");
        h.check(address(pad), address(factory), upgrader);
    }
}
