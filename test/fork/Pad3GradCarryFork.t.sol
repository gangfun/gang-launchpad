// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {GangMainnetRefs as M} from "../../config/GangDeployRefs.sol";
import {GangLaunchpad3} from "../../src/gang/GangLaunchpad3.sol";
import {Pad3Module} from "../../src/gang/Pad3Module.sol";
import {Pad3VanityDeployer} from "../../src/gang/Pad3VanityDeployer.sol";
import {Pad3GradStore} from "../../src/gang/Pad3GradStore.sol";
import {GangCountdownReward} from "../../src/gang/GangCountdownReward.sol";
import {GangCountdownRewardFactory} from "../../src/gang/GangCountdownRewardFactory.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {IGangGradReward, IGangGradRewardBase} from "../../src/gang/interfaces/IGangGradReward.sol";
import {Pad3VanitySalt} from "../../script/Pad3VanitySalt.sol";
import {Pad3Impl} from "../../script/Pad3Impl.sol";
import {SetGradRewardCountdown} from "../../script/SetGradRewardCountdown.s.sol";

interface IWBNBCarry {
    function deposit() external payable;
    function approve(address, uint256) external returns (bool);
}

/// @notice The graduation reward's carry into the countdown reward on a mainnet fork (spec
///         docs/SPEC-GRAD-REWARD-2026-11-17.md §5): SetGradRewardCountdown checks the live countdown factory and
///         prints its one-call batch; the Safe sends it (or PAD3_CARRY_BATCH, the file written for signing, as written).
///         Then a dev clones a countdown module for the token address to come, creates a taxed reward token at that
///         address with the module as its recipient and 20% carry, binds the module, and fresh (mocked) Agents buy it
///         to graduation: the carry lands in the module's reward pool through `receiveCarry`, nothing is owed, and the
///         buyers' claims stay within the rest. No broadcast.
/// @dev BSC_RPC_URL required (skipped if absent); BSC_FORK_BLOCK optional. Run WITHOUT --libraries: the factory's code
///      check compares metadata too, and linked libraries change it (nothing here deploys a pad)
contract Pad3GradCarryForkTest is Test {
    address internal constant PAD3 = 0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29;
    address internal constant ADMIN3 = 0xC833CEC2B283759003945C0Bf8C048aB1949Af76;
    address internal constant FACTORY = 0xa1e3117a59104de7D97667cF22f9AB886a5f2957;
    uint128 internal constant SEED = 0.5 ether;
    uint16 internal constant CARRY = 2_000;
    uint16 internal constant TAX = 300;

    GangLaunchpad3 internal p = GangLaunchpad3(payable(PAD3));
    Pad3Module internal m = Pad3Module(payable(PAD3));
    IGangGradReward internal g = IGangGradReward(PAD3);
    uint256 internal _n;

    function test_fork_openCarryThenGraduate() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 forkBlock = vm.envOr("BSC_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);
        vm.mockCall(M.AGENT_ID_REGISTRY, abi.encodeWithSelector(IERC721.balanceOf.selector), abi.encode(uint256(1)));
        (bool open, address admin, address before) = g.gradRewardDeps();
        assertTrue(open, "the graduation reward is open on mainnet");
        assertEq(admin, ADMIN3);

        // the batch: the script's (checks + simulation), or the file written for signing
        bytes memory call;
        string memory path = vm.envOr("PAD3_CARRY_BATCH", string(""));
        if (before == address(0)) {
            call = new SetGradRewardCountdown().run(PAD3, FACTORY);
            assertEq(call, abi.encodeCall(Pad3Module.setGradReward, (true, ADMIN3, FACTORY)));
            if (bytes(path).length != 0) {
                string memory json = vm.readFile(path);
                assertEq(vm.parseJsonString(json, ".chainId"), "56");
                assertEq(vm.parseJsonAddress(json, ".meta.createdFromSafeAddress"), M.OWNER_SAFE);
                assertFalse(vm.keyExistsJson(json, ".transactions[1]"), "one call");
                assertEq(vm.parseJsonAddress(json, ".transactions[0].to"), PAD3);
                assertEq(vm.parseJsonString(json, ".transactions[0].value"), "0");
                assertEq(vm.parseJsonBytes(json, ".transactions[0].data"), call, "the file is the script's call");
            }
            vm.record();
            vm.prank(M.OWNER_SAFE);
            (bool ok,) = PAD3.call(call);
            assertTrue(ok);
            (, bytes32[] memory writes) = vm.accesses(PAD3);
            for (uint256 i; i < writes.length; i++) {
                assertTrue(
                    writes[i] == Pad3GradStore.SLOT || writes[i] == bytes32(uint256(Pad3GradStore.SLOT) + 1),
                    "only the namespace's first two words"
                );
            }
        }
        (,, address f) = g.gradRewardDeps();
        assertEq(f, FACTORY);
        // a second run is refused
        SetGradRewardCountdown again = new SetGradRewardCountdown();
        vm.expectRevert(
            abi.encodeWithSelector(SetGradRewardCountdown.WiringCheck.selector, "this countdown factory is already set")
        );
        again.run(PAD3, FACTORY);

        // the dev: the token's address, the module cloned for it, the token at it with the module as recipient
        address dev = _actor();
        address vanity = m.vanityDeployer();
        address handler = Pad3Impl.depsOf(p).taxHandler;
        bytes32 hash = Pad3VanityDeployer(vanity).tokenInitCodeHash("Carry", "CARRY", "meta", handler, TAX, TAX, false);
        (bytes32 salt, address token) = Pad3VanitySalt.find(vanity, dev, hash);
        GangCountdownReward.Config memory cc = GangCountdownReward.Config({
            window: 1 hours,
            maxRound: 6 hours,
            idle: 30 days,
            payoutBps: 3_000,
            lastBps: 2_000,
            devBps: 0,
            entries: 10,
            minBuy: 0.05 ether,
            minPot: 0.1 ether,
            maxPayout: 1 ether
        });
        vm.prank(dev, dev);
        address module = GangCountdownRewardFactory(FACTORY).create(token, M.WBNB, cc, keccak256("carry module"));
        IGangLaunchpad.TaxConfig memory tax =
            IGangLaunchpad.TaxConfig({buyTaxBps: TAX, sellTaxBps: TAX, dividendBps: 0, recipient: module});
        IGangGradRewardBase.GradConfig memory cfg = IGangGradRewardBase.GradConfig({
            seed: SEED,
            minBuy: 0.01 ether,
            entries: 10,
            lastBps: 3_000,
            carryBps: CARRY,
            refundAfter: 90 days,
            promoteBps: 0,
            promoteWindow: 0
        });
        vm.startPrank(dev, dev);
        IWBNBCarry(M.WBNB).deposit{value: SEED}();
        IWBNBCarry(M.WBNB).approve(PAD3, SEED);
        address t = m.createWithSalt(
            salt,
            abi.encodeCall(
                IGangGradReward.createWithGradReward,
                ("Carry", "CARRY", "", "meta", address(0), address(0), tax, 6 ether, cfg)
            )
        );
        vm.stopPrank();
        assertEq(t, token);
        assertEq(g.gradReward(t).countdown, module, "the pad derived the module");
        assertEq(g.gradReward(t).carryBps, CARRY);
        GangCountdownReward(module).bind(t);

        // buy to graduation under the 1% cap
        uint256 potBefore = GangCountdownReward(module).pot();
        address[] memory buyers = new address[](200);
        uint256 nb;
        address pair;
        while (pair == address(0)) {
            address a = _actor();
            _buy(a, t, 0.3 ether);
            buyers[nb++] = a;
            (,, pair,,) = p.getTokenInfo(t);
        }
        uint256 carry = (uint256(SEED) * CARRY) / 10_000;
        IGangGradRewardBase.GradView memory v = g.gradReward(t);
        assertEq(v.state, 2);
        assertEq(v.carryOwed, 0, "nothing owed");
        assertEq(GangCountdownReward(module).pot() - potBefore, carry, "the carry is in the module's pool");

        // the buyers share the rest
        uint256 pay = SEED - carry;
        uint256 sum;
        for (uint256 i = nb > 12 ? nb - 12 : 0; i < nb; i++) {
            uint256 c = g.gradClaimable(t, buyers[i]);
            if (c == 0) continue;
            vm.prank(buyers[i]);
            g.claimGradReward(t);
            sum += c;
        }
        assertLe(sum, pay);
        assertGe(sum + 10, pay);
        // the sweep goes to the module too
        vm.warp(block.timestamp + 180 days);
        uint256 potMid = GangCountdownReward(module).pot();
        g.sweepGradReward(t);
        assertEq(GangCountdownReward(module).pot() - potMid, pay - sum);
    }

    function _actor() internal returns (address a) {
        a = makeAddr(string.concat("carry fork actor ", vm.toString(_n++)));
        vm.deal(a, 10 ether);
    }

    function _buy(address who, address t, uint256 amt) internal {
        vm.startPrank(who, who);
        IWBNBCarry(M.WBNB).deposit{value: amt}();
        IWBNBCarry(M.WBNB).approve(PAD3, amt);
        p.buy(t, amt, 0);
        vm.stopPrank();
    }
}
