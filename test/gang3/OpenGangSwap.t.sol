// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {GangFixture} from "../utils/GangFixture.sol";
import {GangLaunchpad} from "../../src/gang/GangLaunchpad.sol";
import {GangLaunchpad3} from "../../src/gang/GangLaunchpad3.sol";
import {Pad3Module} from "../../src/gang/Pad3Module.sol";
import {Pad3VanityDeployer} from "../../src/gang/Pad3VanityDeployer.sol";
import {SharedPlatformFeeBucket} from "../../src/common/SharedPlatformFeeBucket.sol";
import {IGangSwapPad} from "../../src/gang/interfaces/IGangSwapPad.sol";
import {GangMainnetRefs} from "../../config/GangDeployRefs.sol";
import {OpenGangSwap, IOpenMigrator, IOpenFees, IOpenFactory} from "../../script/OpenGangSwap.s.sol";

contract OpenGangSwapHarness is OpenGangSwap {
    bytes32[5] public created;
    bool public stale;

    function setStale() external {
        stale = true;
    }

    function _buildHash() internal view override returns (bytes32) {
        return stale ? bytes32(uint256(1)) : super._buildHash();
    }

    /// @dev no chain to read the deploy transactions from here: record what would be compared
    function _checkCreation(uint256 i, address, bytes memory initCode) internal override {
        created[i] = keccak256(initCode);
    }

    function buildHash() external view returns (bytes32, bytes32) {
        return (_buildHash(), BUILD);
    }

    function json(address pad, address migrator, address router, bool open, address safe)
        external
        returns (string memory)
    {
        Version memory v = _version(pad, migrator, router, safe);
        (address[] memory to, bytes[] memory data) = _batch(pad, v, open);
        return _json(false, safe, open, to, data);
    }

    function rehearse(address pad, address migrator, address router, address safe) external {
        _rehearse(pad, _version(pad, migrator, router, safe), safe);
    }
}

/// @notice script/OpenGangSwap: what it checks, what it prints, what it sends.
contract OpenGangSwapTest is GangFixture {
    struct Set {
        address mig;
        address boost;
        address fees;
        address factory;
        address router;
    }

    GangLaunchpad3 internal p;
    Pad3Module internal m;
    OpenGangSwapHarness internal h;
    address internal dep;
    uint256 internal key;
    Set internal a;

    function _newPad() internal override returns (GangLaunchpad) {
        return _newPad3();
    }

    function setUp() public {
        _deployGang(makeAddr("keeper"));
        p = GangLaunchpad3(payable(address(pad)));
        m = Pad3Module(payable(address(pad)));
        (dep, key) = makeAddrAndKey("testnet deployer");
        // one owner of all three, as the Safe on mainnet
        vm.startPrank(owner);
        p.transferOwnership(dep);
        bucket.transferOwnership(dep);
        // 3.0's registry must list the pad to look it up
        padRegistry3.addPad(address(pad));
        vm.stopPrank();
        vm.startPrank(dep);
        p.acceptOwnership();
        if (bucket.owner() != dep) Ownable2Step(address(bucket)).acceptOwnership();
        vm.stopPrank();
        h = new OpenGangSwapHarness();
        a = _set(dep);
        vm.chainId(97);
    }

    function _set(address o) internal returns (Set memory s) {
        uint256 n = vm.getNonce(address(this));
        address mA = vm.computeCreateAddress(address(this), n);
        address bA = vm.computeCreateAddress(address(this), n + 1);
        address fA = vm.computeCreateAddress(address(this), n + 2);
        address facA = vm.computeCreateAddress(address(this), n + 3);
        s.mig = _dep("GangSwapMigrator.sol/GangSwapMigrator", abi.encode(o, facA, bA, address(wbnb)));
        s.boost = _dep("GangSwapBoost.sol/GangSwapBoost", abi.encode(mA, address(wbnb)));
        s.fees = _dep("GangSwapFees.sol/GangSwapFees", abi.encode(facA, mA, address(bucket), address(wbnb)));
        s.factory = _dep("GangSwapPair.sol/GangSwapFactory", abi.encode(mA, fA));
        s.router = _dep("GangSwapRouter.sol/GangSwapRouter", abi.encode(facA, address(wbnb)));
        assertEq(s.mig, mA);
    }

    function _dep(string memory art, bytes memory args) internal returns (address) {
        return deployCode(string.concat("gangswap/out/", art, ".json"), args);
    }

    function _list(Set memory s) internal {
        vm.startPrank(dep);
        IOpenMigrator(s.mig).addLaunchpad(address(pad));
        bucket.setOperator(s.fees, true);
        vm.stopPrank();
    }

    function _refuse(Set memory s, bool open, bool replace, string memory what) internal {
        vm.expectRevert(abi.encodeWithSelector(OpenGangSwap.Check.selector, what));
        h.runWith(address(pad), s.mig, s.router, open, replace, 0);
    }

    function test_printsOnly() public {
        uint256 tokens = p.tokenCount();
        h.runWith(address(pad), a.mig, a.router, false, false, 0);
        assertFalse(IOpenMigrator(a.mig).launchpads(address(pad)));
        assertFalse(bucket.operators(a.fees));
        assertTrue(p.agentGateEnabled() && p.walletCapEnabled(), "the rehearsal is rolled back");
        assertEq(p.tokenCount(), tokens);
        _list(a);
        h.runWith(address(pad), a.mig, a.router, true, false, 0);
        assertEq(m.gangSwapMigrator(), address(0));
        // another key: printed only
        (, uint256 other) = makeAddrAndKey("someone else");
        h.runWith(address(pad), a.mig, a.router, true, false, other);
        assertEq(m.gangSwapMigrator(), address(0));
        assertEq(p.tokenCount(), tokens);
    }

    function test_testnetSends_bothSteps_thenASecondVersion() public {
        h.runWith(address(pad), a.mig, a.router, false, false, key);
        assertTrue(IOpenMigrator(a.mig).launchpads(address(pad)) && bucket.operators(a.fees));
        assertEq(m.gangSwapMigrator(), address(0), "listing opens nothing");
        _refuse(a, false, false, "already listed: go on with GANGSWAP_STEP=open");
        h.runWith(address(pad), a.mig, a.router, true, false, key);
        assertEq(m.gangSwapMigrator(), a.mig);
        _refuse(a, true, false, "already open with this version");

        Set memory b = _set(dep);
        _refuse(b, false, false, "a version is already set: GANGSWAP_REPLACE=true to replace it");
        _refuse(b, true, true, "the list step is not on chain yet");
        h.runWith(address(pad), b.mig, b.router, false, true, key);
        assertEq(m.gangSwapMigrator(), a.mig);
        vm.prank(dep);
        bucket.setOperator(a.fees, false);
        _refuse(b, true, true, "an older version's fee contract is no bucket operator");
        vm.prank(dep);
        bucket.setOperator(a.fees, true);
        h.runWith(address(pad), b.mig, b.router, true, true, key);
        assertEq(m.gangSwapMigrator(), b.mig);
        assertTrue(bucket.operators(a.fees));
    }

    /// @dev BUILD is gangswap/src's; on an edit there, rebuild gangswap/ and pin the hash this prints.
    function test_buildPinned() public {
        (bytes32 got, bytes32 pinned) = h.buildHash();
        emit log_named_bytes32("BUILD", got);
        assertEq(got, pinned);
        h.setStale();
        _refuse(a, false, false, "gangswap/out is not this commit's build");
    }

    function test_creationCodeCompared() public {
        h.runWith(address(pad), a.mig, a.router, false, false, 0);
        bytes memory code = vm.getCode("gangswap/out/GangSwapMigrator.sol/GangSwapMigrator.json");
        assertEq(h.created(0), keccak256(bytes.concat(code, abi.encode(dep, a.factory, a.boost, address(wbnb)))));
        for (uint256 i; i < 5; i++) {
            assertTrue(h.created(i) != 0);
        }
    }

    function test_refusesAnotherPadAndOldPairs() public {
        address other = makeAddr("another pad");
        address[] memory pads = new address[](2);
        (pads[0], pads[1]) = (address(pad), other);
        vm.mockCall(address(padRegistry3), abi.encodeWithSignature("pads()"), abi.encode(pads));
        uint256 id = vm.snapshotState();
        vm.prank(dep);
        IOpenMigrator(a.mig).addLaunchpad(other);
        _refuse(a, false, false, "the migrator lists another pad");
        vm.revertToState(id);
        vm.mockCall(a.factory, abi.encodeCall(IOpenFactory.allPairsLength, ()), abi.encode(uint256(1)));
        _refuse(a, false, false, "the factory has pairs already");
        _list(a);
        h.runWith(address(pad), a.mig, a.router, true, false, 0); // listed: its own pad's pairs
    }

    /// @dev Both steps rehearse; listing without the operator is not enough to open; `list` repairs a live version.
    function test_rehearsesBothSteps_andRepairs() public {
        bytes memory look = abi.encodeWithSignature("lookup(address)");
        vm.mockCall(address(padRegistry3), look, abi.encode(address(0), uint8(0)));
        _refuse(a, false, false, "rehearsal: the registry does not know kind 4");
        _list(a);
        _refuse(a, true, false, "rehearsal: the registry does not know kind 4");
        vm.clearMockedCalls();
        h.runWith(address(pad), a.mig, a.router, true, false, key);
        vm.prank(dep);
        bucket.setOperator(a.fees, false);
        _refuse(a, true, false, "already open with this version");
        h.runWith(address(pad), a.mig, a.router, false, false, key);
        assertTrue(bucket.operators(a.fees));
    }

    function test_openNeedsTheOperator() public {
        vm.prank(dep);
        bucket.setOperator(a.fees, true);
        _refuse(a, true, false, "the list step is not on chain yet");
        vm.prank(dep);
        bucket.setOperator(a.fees, false);
        vm.prank(dep);
        IOpenMigrator(a.mig).addLaunchpad(address(pad));
        _refuse(a, true, false, "the list step is not on chain yet");
    }

    /// @dev A version closed since, with a token still on it, must keep its fee operator too.
    function test_closedOldVersionKeepsItsOperator() public {
        _list(a);
        h.runWith(address(pad), a.mig, a.router, true, false, key);
        address who = _newAgent();
        vm.prank(who);
        m.createGangSwap("Swap", "GSW", "logo", "meta", 6 ether, a.mig);
        vm.startPrank(dep);
        m.setGangSwapMigrator(address(0));
        bucket.setOperator(a.fees, false);
        vm.stopPrank();
        Set memory b = _set(dep);
        _list(b);
        _refuse(b, true, false, "an older version's fee contract is no bucket operator");
        vm.prank(dep);
        bucket.setOperator(a.fees, true);
        h.runWith(address(pad), b.mig, b.router, true, false, 0);
    }

    function test_parkedPlatformFee() public {
        _list(a);
        vm.prank(dep);
        m.setGangSwapMigrator(a.mig);
        // 5 parked earlier (slot found by name: pendingPlatform is the fee contract's own storage)
        uint256 slot = _slotOfPending();
        vm.store(a.fees, bytes32(slot), bytes32(uint256(5)));
        assertEq(IOpenFees(a.fees).pendingPlatform(), 5);
        wbnb.mintUnlimited(a.fees, 5);
        h.rehearse(address(pad), a.mig, a.router, dep);
    }

    function _slotOfPending() internal returns (uint256 s) {
        vm.record();
        IOpenFees(a.fees).pendingPlatform();
        (bytes32[] memory reads,) = vm.accesses(a.fees);
        s = uint256(reads[0]);
    }

    function test_withAbcd() public {
        Pad3VanityDeployer f = new Pad3VanityDeployer(address(pad), address(tokenDeployer), address(flyDeployer));
        vm.prank(dep);
        m.enableVanity(address(f));
        h.runWith(address(pad), a.mig, a.router, false, false, 0);
    }

    function test_batches() public {
        string memory j = h.json(address(pad), a.mig, a.router, false, dep);
        assertEq(vm.parseJsonAddress(j, ".transactions[0].to"), a.mig);
        assertEq(
            vm.parseJsonBytes(j, ".transactions[0].data"), abi.encodeCall(IOpenMigrator.addLaunchpad, (address(pad)))
        );
        assertEq(vm.parseJsonAddress(j, ".transactions[1].to"), address(bucket));
        assertEq(
            vm.parseJsonBytes(j, ".transactions[1].data"),
            abi.encodeCall(SharedPlatformFeeBucket.setOperator, (a.fees, true))
        );
        assertFalse(vm.keyExistsJson(j, ".transactions[2]"));
        assertEq(vm.parseJsonAddress(j, ".meta.createdFromSafeAddress"), dep);
        // only what is missing
        vm.prank(dep);
        IOpenMigrator(a.mig).addLaunchpad(address(pad));
        j = h.json(address(pad), a.mig, a.router, false, dep);
        assertEq(vm.parseJsonAddress(j, ".transactions[0].to"), address(bucket));
        assertFalse(vm.keyExistsJson(j, ".transactions[1]"));
        _refuse(a, true, false, "the list step is not on chain yet");
        vm.prank(dep);
        bucket.setOperator(a.fees, true);
        j = h.json(address(pad), a.mig, a.router, true, dep);
        assertEq(vm.parseJsonAddress(j, ".transactions[0].to"), address(pad));
        assertEq(
            vm.parseJsonBytes(j, ".transactions[0].data"), abi.encodeCall(IGangSwapPad.setGangSwapMigrator, (a.mig))
        );
        assertFalse(vm.keyExistsJson(j, ".transactions[1]"));
    }

    function test_refusesOtherCode() public {
        // each contract with one byte changed
        string[5] memory art = [
            "GangSwapMigrator.sol/GangSwapMigrator",
            "GangSwapBoost.sol/GangSwapBoost",
            "GangSwapFees.sol/GangSwapFees",
            "GangSwapPair.sol/GangSwapFactory",
            "GangSwapRouter.sol/GangSwapRouter"
        ];
        address[5] memory at = [a.mig, a.boost, a.fees, a.factory, a.router];
        for (uint256 i; i < 5; i++) {
            bytes memory was = at[i].code;
            bytes memory code = bytes.concat(was);
            code[code.length - 1] = bytes1(uint8(code[code.length - 1]) ^ 1); // metadata only: still another build
            vm.etch(at[i], code);
            _refuse(a, false, false, string.concat("code is not this build's: ", art[i]));
            vm.etch(at[i], was);
        }
        // a router of another set is this build's code with other immutables
        Set memory b = _set(dep);
        b.mig = a.mig;
        _refuse(b, false, false, "code is not this build's: GangSwapRouter.sol/GangSwapRouter");
        b.router = makeAddr("eoa");
        _refuse(b, false, false, "GANGSWAP_MIGRATOR / GANGSWAP_ROUTER");
    }

    function test_refusesWiringAndOwners() public {
        // the factory names another migrator (storage, not code)
        vm.mockCall(a.mig, abi.encodeCall(IOpenMigrator.wired, ()), abi.encode(false));
        _refuse(a, false, false, "migrator quote / wired");
        vm.clearMockedCalls();
        Set memory b = _set(owner);
        _refuse(b, false, false, "the pad, the migrator and the fee bucket must have the same owner");
        vm.prank(dep);
        Ownable2Step(a.mig).transferOwnership(owner);
        _refuse(a, false, false, "an ownership transfer is pending");
        vm.prank(dep);
        Ownable2Step(a.mig).transferOwnership(address(0));
        vm.prank(dep);
        p.transferOwnership(owner);
        _refuse(a, false, false, "an ownership transfer is pending");
        vm.prank(dep);
        p.transferOwnership(address(0));
        vm.prank(dep);
        bucket.transferOwnership(owner);
        _refuse(a, false, false, "an ownership transfer is pending");
        vm.prank(owner);
        bucket.acceptOwnership();
        _refuse(a, false, false, "the pad, the migrator and the fee bucket must have the same owner");
        vm.prank(owner);
        bucket.transferOwnership(dep);
        vm.prank(dep);
        bucket.acceptOwnership();
        vm.mockCall(address(pad), abi.encodeWithSignature("platformBucket()"), abi.encode(address(1)));
        _refuse(a, false, false, "fee bucket is not the pad's");
        vm.clearMockedCalls();
        vm.mockCallRevert(address(pad), abi.encodeCall(IGangSwapPad.gangSwapMigrator, ()), "");
        _refuse(a, false, false, "pad does not serve GangSwap: upgrade it first");
        vm.clearMockedCalls();
        h.runWith(address(pad), a.mig, a.router, false, false, 0);
    }

    function test_rehearsalRefuses() public {
        // before opening
        vm.expectRevert(IGangSwapPad.GangSwapNotOpen.selector);
        h.rehearse(address(pad), a.mig, a.router, dep);
        _list(a);
        vm.prank(dep);
        m.setGangSwapMigrator(a.mig);
        uint256 id = vm.snapshotState();
        h.rehearse(address(pad), a.mig, a.router, dep);
        vm.revertToState(id);
        // an old registry: it does not know kind 4
        vm.mockCall(address(padRegistry3), abi.encodeWithSignature("lookup(address)"), abi.encode(address(0), uint8(0)));
        vm.expectRevert(
            abi.encodeWithSelector(OpenGangSwap.Check.selector, "rehearsal: the registry does not know kind 4")
        );
        h.rehearse(address(pad), a.mig, a.router, dep);
        vm.clearMockedCalls();
        vm.revertToState(id);
        // the fees do not reach the bucket
        vm.prank(dep);
        bucket.setOperator(a.fees, false);
        vm.expectRevert(abi.encodeWithSelector(OpenGangSwap.Check.selector, "rehearsal: fees"));
        h.rehearse(address(pad), a.mig, a.router, dep);
    }

    function test_chains() public {
        vm.chainId(56);
        _refuse(a, false, false, "GANG_PAD3 is not the mainnet 3.0 proxy");
        vm.chainId(31337);
        _refuse(a, false, false, "chain: BSC mainnet or testnet only");
    }
}
