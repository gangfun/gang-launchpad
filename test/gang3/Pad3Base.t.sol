// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GangFixture} from "../utils/GangFixture.sol";
import {GangLaunchpad} from "../../src/gang/GangLaunchpad.sol";
import {GangLaunchpad3} from "../../src/gang/GangLaunchpad3.sol";
import {Pad3Module} from "../../src/gang/Pad3Module.sol";
import {Pad3BaseStore} from "../../src/gang/Pad3BaseStore.sol";
import {Pad3VanityDeployer} from "../../src/gang/Pad3VanityDeployer.sol";
import {GangBaseVault} from "../../src/gang/GangBaseVault.sol";
import {GangToken} from "../../src/gang/GangToken.sol";
import {IGangBasePad} from "../../src/gang/interfaces/IGangBasePad.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {IGangLaunchpad3} from "../../src/gang/interfaces/IGangLaunchpad3.sol";
import {IGangVaultPad} from "../../src/gang/interfaces/IGangVaultPad.sol";
import {IGangPromote} from "../../src/gang/interfaces/IGangPromote.sol";
import {Pad3FlyModule} from "../../src/gang/Pad3FlyModule.sol";
import {IFlywheelPad} from "../../src/flywheel/interfaces/IFlywheelPad.sol";

/// @dev A vault implementation of another pad, or with the wrong type: setBaseVaultImpl refuses both.
contract FakeVault {
    address public pad;
    bytes32 public moduleType;

    constructor(address pad_, bytes32 t) {
        pad = pad_;
        moduleType = t;
    }
}

/// @dev A creator that is a contract.
contract Holder {}

/// @notice docs/SPEC-BASE-VAULT-V2-2026-11-12.md: createWithBase, the base buy, the vault, abcd.
contract Pad3BaseTest is GangFixture {
    Pad3Module internal m;
    GangLaunchpad3 internal p;
    GangBaseVault internal impl;
    address internal creator;

    uint256 internal constant SUPPLY = 1_000_000_000 ether;

    function _newPad() internal override returns (GangLaunchpad) {
        return _newPad3();
    }

    function setUp() public {
        _deployGang(makeAddr("keeper"));
        m = Pad3Module(payable(address(pad)));
        p = GangLaunchpad3(payable(address(pad)));
        impl = new GangBaseVault(address(pad));
        vm.prank(owner);
        m.setBaseVaultImpl(address(impl));
        creator = _newAgent();
    }

    function _cfg(uint16 bps, uint32 d) internal pure returns (IGangBasePad.BaseConfig memory) {
        return IGangBasePad.BaseConfig({baseBps: bps, vestDays: d});
    }

    function _create(address who, IGangLaunchpad.TaxConfig memory tax, uint256 g, uint16 bps, uint32 d)
        internal
        returns (address t)
    {
        uint256 cost = m.previewBaseCost(g, bps);
        vm.prank(who);
        t = m.createWithBase{value: cost}("Base", "BASE", "logo", "meta", tax, g, _cfg(bps, d));
    }

    function _plain(address who, uint16 bps, uint32 d) internal returns (address) {
        return _create(who, _tax(0, 0, 0, address(0)), 9 ether, bps, d);
    }

    function _vault(address t) internal view returns (GangBaseVault) {
        return GangBaseVault(m.baseVaultOf(t));
    }

    // ---------------------------------------------------------------- storage and admin
    function test_namespace() public pure {
        assertEq(
            Pad3BaseStore.SLOT,
            keccak256(abi.encode(uint256(keccak256("gang.pad3.base")) - 1)) & ~bytes32(uint256(0xff))
        );
    }

    /// @dev The members' positions: vaultImpl at SLOT, vaultOf at SLOT+1, baseOf at SLOT+2.
    function test_layoutPinned() public {
        address t = _plain(creator, 500, 90);
        bytes32 s = Pad3BaseStore.SLOT;
        assertEq(address(uint160(uint256(vm.load(address(pad), s)))), address(impl));
        bytes32 vSlot = keccak256(abi.encode(t, uint256(s) + 1));
        bytes32 bSlot = keccak256(abi.encode(t, uint256(s) + 2));
        assertEq(address(uint160(uint256(vm.load(address(pad), vSlot)))), m.baseVaultOf(t));
        assertEq(uint256(vm.load(address(pad), bSlot)), 50_000_000 ether);
    }

    function test_setBaseVaultImpl_checks() public {
        vm.prank(creator);
        vm.expectRevert();
        m.setBaseVaultImpl(address(impl));

        GangBaseVault otherPad = new GangBaseVault(makeAddr("otherPad"));
        FakeVault wrongType = new FakeVault(address(pad), "base-v2");
        vm.startPrank(owner);
        vm.expectRevert(IGangBasePad.WrongBaseVaultImpl.selector);
        m.setBaseVaultImpl(address(otherPad));
        vm.expectRevert(IGangBasePad.WrongBaseVaultImpl.selector);
        m.setBaseVaultImpl(address(wrongType));
        vm.expectRevert(IGangBasePad.WrongBaseVaultImpl.selector);
        m.setBaseVaultImpl(makeAddr("eoa"));
        vm.expectRevert(IGangBasePad.WrongBaseVaultImpl.selector);
        m.setBaseVaultImpl(address(wbnb)); // a contract without the views
        m.setBaseVaultImpl(address(0));
        vm.stopPrank();
        assertEq(m.baseVaultImpl(), address(0));

        uint256 cost = m.previewBaseCost(9 ether, 500);
        vm.prank(creator);
        vm.expectRevert(IGangBasePad.BaseNotOpen.selector);
        m.createWithBase{value: cost}("B", "B", "", "", _tax(0, 0, 0, address(0)), 9 ether, _cfg(500, 90));
    }

    /// @dev A new implementation only applies to tokens created after it.
    function test_newImplOnlyForNewTokens() public {
        address t1 = _plain(creator, 500, 90);
        GangBaseVault impl2 = new GangBaseVault(address(pad));
        vm.prank(owner);
        m.setBaseVaultImpl(address(impl2));
        address t2 = _plain(_newAgent(), 500, 90);
        assertEq(_codeTarget(m.baseVaultOf(t1)), address(impl));
        assertEq(_codeTarget(m.baseVaultOf(t2)), address(impl2));
    }

    /// @dev EIP-1167: the implementation address sits at bytes 10..30 of the clone's runtime code.
    function _codeTarget(address clone) internal view returns (address a) {
        bytes memory c = clone.code;
        assertEq(c.length, 45);
        assembly {
            a := shr(96, mload(add(c, 42)))
        }
    }

    // ---------------------------------------------------------------- costs
    /// @dev Spec §2's table, to 0.0001 BNB, and previewBaseCost = what the creator actually pays.
    function test_costTable() public {
        uint256[4] memory g = [uint256(6 ether), 9 ether, 12 ether, 15 ether];
        uint256[4] memory five = [uint256(0.0994e18), 0.149e18, 0.1987e18, 0.2484e18];
        uint256[4] memory ten = [uint256(0.209e18), 0.3135e18, 0.418e18, 0.5225e18];
        for (uint256 i; i < 4; ++i) {
            assertApproxEqAbs(m.previewBaseCost(g[i], 500), five[i], 0.00005e18);
            assertApproxEqAbs(m.previewBaseCost(g[i], 1000), ten[i], 0.00005e18);
            for (uint256 j; j < 2; ++j) {
                uint16 bps = j == 0 ? 500 : 1000;
                address who = _newAgent();
                uint256 cost = m.previewBaseCost(g[i], bps);
                uint256 bnbBefore = who.balance;
                uint256 wbnbBefore = wbnb.balanceOf(who);
                address t = _create(who, _tax(0, 0, 0, address(0)), g[i], bps, 90);
                assertEq(bnbBefore - who.balance, cost, "BNB paid");
                assertEq(wbnb.balanceOf(who), wbnbBefore, "no WBNB moved");
                _checkCurve(t, g[i], bps, cost);
            }
        }
    }

    function _checkCurve(address t, uint256 g, uint16 bps, uint256 cost) internal view {
        uint256 tokens = (SUPPLY * bps) / 10_000;
        uint256 fee = cost / 100;
        assertEq(m.baseOf(t), tokens);
        assertEq(IERC20(t).balanceOf(m.baseVaultOf(t)), tokens);
        assertEq(_curveSold(t), tokens);
        assertEq(_curveRealQuote(t), cost - fee);
        assertEq(p.creatorFeeOf(t), (fee * 7000) / 10_000);
        assertEq(m.gradAmtOf(t), g);
        assertEq(p.kindOf(t), 1);
    }

    function test_previewRejects() public {
        vm.expectRevert(IGangLaunchpad.BadGradTarget.selector);
        m.previewBaseCost(7 ether, 500);
        vm.expectRevert(IGangBasePad.BadBaseConfig.selector);
        m.previewBaseCost(9 ether, 700);
    }

    // ---------------------------------------------------------------- the create
    function test_create_recordsEventsAndMoney() public {
        uint256 cost = m.previewBaseCost(9 ether, 1000);
        uint256 fee = cost / 100;
        uint256 bucketBefore = wbnb.balanceOf(address(bucket));
        uint256 padBnb = address(pad).balance;
        uint256 padWbnb = wbnb.balanceOf(address(pad));
        vm.recordLogs();
        address t = _create(creator, _tax(0, 0, 0, address(0)), 9 ether, 1000, 180);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        GangBaseVault v = _vault(t);

        // the vault
        assertEq(v.token(), t);
        assertEq(v.creator(), creator);
        assertEq(v.duration(), 180 days);
        assertEq(v.startAt(), 0);
        assertEq(v.pad(), address(pad));
        // money: the pad holds the curve's quote and the creator's fee, the bucket got 30% of the fee, no BNB stays
        assertEq(address(pad).balance, padBnb);
        assertEq(wbnb.balanceOf(address(bucket)) - bucketBefore, fee - (fee * 7000) / 10_000);
        assertEq(wbnb.balanceOf(address(pad)) - padWbnb, cost - fee + (fee * 7000) / 10_000);
        // the creator's own wallet holds nothing yet and can still buy 1%
        assertEq(IERC20(t).balanceOf(creator), 0);

        // BaseCreated comes before the base buy's Buy and TradeV1
        uint256 iBase = type(uint256).max;
        uint256 iBuy = type(uint256).max;
        uint256 iTrade = type(uint256).max;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(pad)) continue;
            bytes32 sig = logs[i].topics[0];
            if (sig == IGangBasePad.BaseCreated.selector && iBase == type(uint256).max) {
                iBase = i;
                assertEq(address(uint160(uint256(logs[i].topics[2]))), address(v));
                (uint256 tokens, uint256 c, uint16 bps, uint32 d) =
                    abi.decode(logs[i].data, (uint256, uint256, uint16, uint32));
                assertEq(tokens, 100_000_000 ether);
                assertEq(c, cost);
                assertEq(bps, 1000);
                assertEq(d, 180);
            }
            if (sig == IGangLaunchpad.Buy.selector) {
                iBuy = i;
                assertEq(address(uint160(uint256(logs[i].topics[2]))), address(v));
                (uint256 net, uint256 f, uint256 tax, uint256 out, uint256 rq) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256));
                assertEq(net, cost - fee);
                assertEq(f, fee);
                assertEq(tax, 0);
                assertEq(out, 100_000_000 ether);
                assertEq(rq, cost - fee);
            }
            if (sig == IGangLaunchpad3.TradeV1.selector) iTrade = i;
        }
        assertLt(iBase, iBuy);
        assertLt(iBase, iTrade);
        assertTrue(iBuy != type(uint256).max && iTrade != type(uint256).max);
    }

    function test_create_rejects() public {
        uint256 cost = m.previewBaseCost(9 ether, 500);
        IGangLaunchpad.TaxConfig memory none = _tax(0, 0, 0, address(0));
        vm.startPrank(creator);
        vm.expectRevert(IGangLaunchpad3.BadMsgValue.selector);
        m.createWithBase{value: cost - 1}("B", "B", "", "", none, 9 ether, _cfg(500, 90));
        vm.expectRevert(IGangLaunchpad3.BadMsgValue.selector);
        m.createWithBase{value: cost + 1}("B", "B", "", "", none, 9 ether, _cfg(500, 90));
        vm.expectRevert(IGangLaunchpad3.BadMsgValue.selector);
        m.createWithBase("B", "B", "", "", none, 9 ether, _cfg(500, 90));
        // 10% for 30 days, other sizes and periods
        vm.expectRevert(IGangBasePad.BadBaseConfig.selector);
        m.createWithBase{value: cost}("B", "B", "", "", none, 9 ether, _cfg(1000, 30));
        vm.expectRevert(IGangBasePad.BadBaseConfig.selector);
        m.createWithBase{value: cost}("B", "B", "", "", none, 9 ether, _cfg(500, 60));
        vm.expectRevert(IGangBasePad.BadBaseConfig.selector);
        m.createWithBase{value: cost}("B", "B", "", "", none, 9 ether, _cfg(1500, 90));
        vm.expectRevert(IGangBasePad.BadBaseConfig.selector);
        m.createWithBase{value: cost}("B", "B", "", "", none, 9 ether, _cfg(0, 90));
        // dividend tax configs
        vm.expectRevert(IGangBasePad.BadBaseConfig.selector);
        m.createWithBase{value: cost}("B", "B", "", "", _tax(300, 300, 5000, creator), 9 ether, _cfg(500, 90));
        vm.expectRevert(IGangBasePad.BadBaseConfig.selector);
        m.createWithBase{value: cost}("B", "B", "", "", _tax(300, 300, 10_000, address(0)), 9 ether, _cfg(500, 90));
        // a graduation target that is not a tier: value must be 0, then the create refuses the tier
        vm.expectRevert(IGangLaunchpad.BadGradTarget.selector);
        m.createWithBase("B", "B", "", "", none, 7 ether, _cfg(500, 90));
        vm.stopPrank();
        // the Agent gate still applies to the creator
        address stranger = makeAddr("stranger");
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        vm.expectRevert(IGangLaunchpad.NotAgent.selector);
        m.createWithBase{value: cost}("B", "B", "", "", none, 9 ether, _cfg(500, 90));
    }

    /// @dev The base buy can't be reached any other way: the library entry is only behind createWithBase, and the
    ///      fallback chain doesn't expose it.
    function test_buyBase_notReachable() public {
        address t = _createV3(creator, address(wbnb), _tax(0, 0, 0, address(0)));
        (bool ok,) = address(pad)
            .call(abi.encodeWithSignature("buyBase(address,address,uint256,uint256)", t, creator, 1 ether, 1 ether));
        assertFalse(ok);
    }

    // ---------------------------------------------------------------- the curve after the base
    /// @dev Others trade and graduate as on any curve: the pair gets 200M tokens and the graduation amount, the vault
    ///      keeps the base, the creator can buy its 1%.
    function test_tradeAndGraduate() public {
        address t = _plain(creator, 1000, 90);
        vm.prank(creator);
        p.buy(t, 1 ether, 0);
        assertEq(IERC20(t).balanceOf(creator), 10_000_000 ether, "creator's 1% on top");
        address seller = _newAgent();
        vm.startPrank(seller);
        p.buy(t, 0.1 ether, 0);
        IERC20(t).approve(address(pad), type(uint256).max);
        p.sell(t, IERC20(t).balanceOf(seller), 0);
        vm.stopPrank();
        _graduate(t);
        address pair = _curvePair(t);
        assertEq(IERC20(t).balanceOf(pair), 200_000_000 ether);
        assertEq(wbnb.balanceOf(pair), 9 ether);
        assertEq(IERC20(t).balanceOf(address(_vault(t))), 100_000_000 ether);
        assertFalse(GangToken(t).locked());
    }

    /// @dev Before graduation nothing moves the vault's tokens: no allowance, no call, the token is locked.
    function test_vaultTokensStuckBeforeGraduation() public {
        address t = _plain(creator, 500, 90);
        GangBaseVault v = _vault(t);
        address agent = _newAgent();
        vm.startPrank(agent);
        vm.expectRevert();
        IERC20(t).transferFrom(address(v), agent, 1 ether);
        vm.expectRevert();
        p.sellToken(0, t, address(v), 1 ether, 0, 0, address(0));
        vm.stopPrank();
        // the vault itself can't send (the token is locked for anyone but the pad)
        vm.prank(address(v));
        vm.expectRevert();
        IERC20(t).transfer(agent, 1 ether);
        // the vault can't trade on the curve either
        vm.prank(address(v));
        vm.expectRevert();
        p.sell(t, 1 ether, 0);
        vm.expectRevert(GangBaseVault.NotGraduated.selector);
        v.release();
        assertEq(IERC20(t).balanceOf(address(v)), m.baseOf(t));
    }

    // ---------------------------------------------------------------- the vault
    function test_vault_initOnlyPadOnce() public {
        address t = _plain(creator, 500, 90);
        GangBaseVault v = _vault(t);
        vm.expectRevert(GangBaseVault.NotPad.selector);
        v.initialize(t, address(this), 30);
        vm.prank(address(pad));
        vm.expectRevert(GangBaseVault.AlreadyInitialized.selector);
        v.initialize(t, address(this), 30);
    }

    function test_vault_linearReleaseAfterGraduation() public {
        address t = _plain(creator, 500, 30);
        GangBaseVault v = _vault(t);
        uint256 base = m.baseOf(t);
        _graduate(t);
        // the clock starts at the first release, even in the graduation block
        vm.prank(makeAddr("anyone"));
        assertEq(v.release(), 0);
        assertEq(v.total(), base);
        assertEq(v.startAt(), block.timestamp);
        vm.expectRevert(GangBaseVault.NothingToRelease.selector);
        v.release();
        uint256 s = v.startAt();
        vm.warp(s + 3 days);
        v.release();
        assertEq(IERC20(t).balanceOf(creator), base / 10);
        vm.warp(s + 15 days);
        assertEq(v.releasable(), base / 2 - base / 10);
        v.release();
        assertEq(IERC20(t).balanceOf(creator), base / 2);
        vm.warp(s + 30 days);
        v.release();
        assertEq(IERC20(t).balanceOf(creator), base);
        assertEq(IERC20(t).balanceOf(address(v)), 0);
    }

    /// @dev A taxed token whose tax recipient is the creator: the release is no pool trade, nothing is taxed.
    function test_vault_taxedToken() public {
        address t = _create(creator, _tax(300, 300, 0, creator), 6 ether, 1000, 90);
        GangBaseVault v = _vault(t);
        _graduate(t);
        v.release();
        uint256 acc = handler.accruedTax(t);
        vm.warp(v.startAt() + 9 days);
        v.release();
        assertEq(IERC20(t).balanceOf(creator), m.baseOf(t) / 10);
        assertEq(handler.accruedTax(t), acc);
    }

    /// @dev Tokens sent in after the start come out at the end; they never speed the release up.
    function test_vault_donations() public {
        address t = _plain(creator, 500, 90);
        GangBaseVault v = _vault(t);
        _graduate(t);
        v.release();
        address donor = _newAgent();
        deal(t, donor, 5 ether);
        vm.prank(donor);
        IERC20(t).transfer(address(v), 5 ether);
        vm.warp(v.startAt() + 45 days);
        v.release();
        assertEq(IERC20(t).balanceOf(creator), m.baseOf(t) / 2);
        vm.warp(v.startAt() + 90 days);
        v.release();
        assertEq(IERC20(t).balanceOf(creator), m.baseOf(t) + 5 ether);
    }

    /// @dev A creator that is a contract holding an Agent ID: the base is released to that contract.
    function test_vault_contractCreator() public {
        Holder h = new Holder();
        agents.mint(address(h), 9_999);
        vm.deal(address(h), 1 ether);
        address t = _create(address(h), _tax(0, 0, 0, address(0)), 9 ether, 500, 30);
        GangBaseVault v = _vault(t);
        assertEq(v.creator(), address(h));
        _graduate(t);
        v.release();
        vm.warp(v.startAt() + 30 days);
        v.release();
        assertEq(IERC20(t).balanceOf(address(h)), m.baseOf(t));
    }

    /// @dev A token that never graduates: the base stays in the vault for good and nothing can start the release.
    function test_vault_neverGraduates() public {
        address t = _plain(creator, 1000, 180);
        GangBaseVault v = _vault(t);
        vm.prank(creator);
        p.buy(t, 1 ether, 0);
        vm.warp(block.timestamp + 3650 days);
        vm.expectRevert(GangBaseVault.NotGraduated.selector);
        v.release();
        assertEq(v.releasable(), 0);
        assertEq(IERC20(t).balanceOf(address(v)), m.baseOf(t));
    }

    /// @dev V1 / V2 / V3 under random call times (one fuzzed schedule of up to 6 releases).
    function testFuzz_vault_neverAhead(uint32[6] memory gaps, uint8 periodPick) public {
        uint32[3] memory ds = [uint32(30), uint32(90), uint32(180)];
        uint32 d = ds[periodPick % 3];
        address t = _plain(creator, 500, d);
        GangBaseVault v = _vault(t);
        _graduate(t);
        v.release();
        uint256 s0 = v.startAt();
        uint256 tot = v.total();
        uint256 dur = uint256(d) * 1 days;
        for (uint256 i; i < 6; ++i) {
            vm.warp(block.timestamp + (uint256(gaps[i]) % (40 days)));
            if (v.releasable() != 0) v.release();
            uint256 el = block.timestamp - s0;
            uint256 out = IERC20(t).balanceOf(creator);
            if (el < dur) {
                assertLe(out, (tot * el) / dur, "V1: ahead of the schedule");
                assertGe(IERC20(t).balanceOf(address(v)), tot - out, "V2");
            } else {
                assertEq(out, tot, "everything at the end");
            }
            assertEq(out, v.released(), "V3: only the creator");
        }
    }

    // ---------------------------------------------------------------- abcd
    function _enableVanity() internal returns (Pad3VanityDeployer f) {
        f = new Pad3VanityDeployer(address(pad), address(tokenDeployer), address(flyDeployer));
        vm.prank(owner);
        m.enableVanity(address(f));
    }

    function _mine(Pad3VanityDeployer f, bytes32 initHash, address dev) internal view returns (bytes32 salt) {
        for (uint256 i;; i++) {
            address a = f.predict(initHash, keccak256(abi.encode(dev, bytes32(i))));
            if (uint16(uint160(a)) == 0xabcd && a.code.length == 0) return bytes32(i);
        }
    }

    function _baseData(uint16 bps, uint32 d) internal pure returns (bytes memory) {
        IGangLaunchpad.TaxConfig memory none =
            IGangLaunchpad.TaxConfig({buyTaxBps: 0, sellTaxBps: 0, dividendBps: 0, recipient: address(0)});
        return abi.encodeCall(Pad3Module.createWithBase, ("Base", "BASE", "logo", "meta", none, 9 ether, _cfgP(bps, d)));
    }

    function _cfgP(uint16 bps, uint32 d) internal pure returns (IGangBasePad.BaseConfig memory) {
        return IGangBasePad.BaseConfig({baseBps: bps, vestDays: d});
    }

    function test_abcd_onlyThroughCreateWithSalt() public {
        Pad3VanityDeployer f = _enableVanity();
        uint256 cost = m.previewBaseCost(9 ether, 500);
        IGangLaunchpad.TaxConfig memory none = _tax(0, 0, 0, address(0));
        vm.prank(creator);
        vm.expectRevert(Pad3Module.VanityContextRequired.selector);
        m.createWithBase{value: cost}("Base", "BASE", "logo", "meta", none, 9 ether, _cfg(500, 90));

        bytes32 hash = f.tokenInitCodeHash("Base", "BASE", "meta", address(0), 0, 0, false);
        bytes32 salt = _mine(f, hash, creator);
        uint256 padBnb = address(pad).balance;
        // the wrong amount through the wrapper reverts too
        vm.prank(creator);
        vm.expectRevert(IGangLaunchpad3.BadMsgValue.selector);
        m.createWithSalt{value: cost - 1}(salt, _baseData(500, 90));
        vm.prank(creator);
        address t = m.createWithSalt{value: cost}(salt, _baseData(500, 90));
        assertEq(uint16(uint160(t)), 0xabcd);
        assertTrue(f.isLaunchToken(t));
        assertEq(address(pad).balance, padBnb);
        _checkCurve(t, 9 ether, 500, cost);
        assertEq(_vault(t).creator(), creator);
        // the context is cleared
        vm.expectRevert(Pad3Module.VanityContextRequired.selector);
        m.vanitySalt();
    }

    /// @dev BNB sent through createWithSalt to an entry that takes none reverts the whole call: nothing stays.
    function test_abcd_valueToOtherEntriesReverts() public {
        Pad3VanityDeployer f = _enableVanity();
        bytes32 hash = f.tokenInitCodeHash("Curve", "CRV", "meta", address(0), 0, 0, false);
        bytes32 salt = _mine(f, hash, creator);
        bytes memory data = abi.encodeWithSignature(
            "create(string,string,string,string,address,address,(uint16,uint16,uint16,address))",
            "Curve",
            "CRV",
            "logo",
            "meta",
            address(wbnb),
            address(0),
            _tax(0, 0, 0, address(0))
        );
        uint256 padBnb = address(pad).balance;
        vm.prank(creator);
        vm.expectRevert();
        m.createWithSalt{value: 1 ether}(salt, data);
        assertEq(address(pad).balance, padBnb);
        // without value it still works
        vm.prank(creator);
        address t = m.createWithSalt(salt, data);
        assertEq(uint16(uint160(t)), 0xabcd);
    }

    /// @dev Every listed entry but createWithBase rejects a value at its non-payable check: empty revert data with
    ///      arguments that decode (all zero: empty strings, zero addresses and numbers), while the same call without a
    ///      value gets past decoding and reverts with an error (or creates). A future payable entry in the list would
    ///      revert with its own error here, or take the value, and fail this test.
    function test_abcd_valueRejectedByEveryOtherEntry() public {
        _enableVanity();
        bytes4[6] memory sels = [
            bytes4(keccak256("create(string,string,string,string,address,address,(uint16,uint16,uint16,address))")),
            bytes4(
                keccak256(
                    "createWithGradTarget(string,string,string,string,address,address,(uint16,uint16,uint16,address),uint256)"
                )
            ),
            bytes4(
                keccak256(
                    "create(string,string,string,string,address,address,(uint256,uint16,uint16,uint16,uint16),uint256)"
                )
            ),
            IGangVaultPad.createWithVault.selector,
            IGangPromote.createWithPromote.selector,
            Pad3FlyModule.create.selector
        ];
        uint256 padBnb = address(pad).balance;
        vm.deal(creator, creator.balance + 1);
        for (uint256 i; i < sels.length; ++i) {
            IFlywheelPad.FlyConfig memory fly;
            string[4] memory text;
            // the 铸币飞轮 entry's string[4] does not decode from zeros: its own encoding
            bytes memory data = i == 5
                ? abi.encodeCall(Pad3FlyModule.create, (text, address(0), address(0), fly, 0))
                : abi.encodePacked(sels[i], new bytes(32 * 24));
            vm.prank(creator);
            (bool ok, bytes memory ret) =
                address(m).call{value: 1}(abi.encodeCall(m.createWithSalt, (bytes32(i), data)));
            assertFalse(ok);
            assertEq(ret.length, 0, "a value is refused before anything else");
            vm.prank(creator);
            (ok, ret) = address(m).call(abi.encodeCall(m.createWithSalt, (bytes32(i), data)));
            assertTrue(ok || ret.length != 0, "without a value the arguments decode");
        }
        assertEq(address(pad).balance, padBnb);
    }

    function test_codeSizes() public view {
        assertLe(p.module().code.length, 24_576);
        assertLe(pad3Impl.code.length, 24_576);
        assertLe(address(impl).code.length, 24_576);
    }
}
