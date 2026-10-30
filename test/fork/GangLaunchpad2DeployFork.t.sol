// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {DeployGang} from "../../script/DeployGang.s.sol";
import {DeployGangLaunchpad2} from "../../script/DeployGangLaunchpad2.s.sol";
import {GangMainnetRefs as M} from "../../config/GangDeployRefs.sol";
import {SharedDividendVault} from "../../src/common/SharedDividendVault.sol";
import {SharedPlatformFeeBucket} from "../../src/common/SharedPlatformFeeBucket.sol";
import {TokenDeployer} from "../../src/common/TokenDeployer.sol";
import {GangPadRegistry} from "../../src/gang/GangPadRegistry.sol";
import {IGangPad} from "../../src/gang/interfaces/IGangPad.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {CurveLogic} from "../../src/gang/CurveLogic.sol";
import {GangLaunchpad} from "../../src/gang/GangLaunchpad.sol";
import {MockAgentId} from "../mocks/MockAgentId.sol";

/// @dev Exposes the script's internal JSON builders and the creator-fee probe (same code the script runs / prints).
contract DeployGangLaunchpad2Harness is DeployGangLaunchpad2 {
    function wiringJson(DeployGang.Stack memory s, address pad1, address safe) external pure returns (string memory) {
        return _wiringJson(s, _ctxOf(pad1), true, safe);
    }

    function acceptJson(DeployGang.Stack memory s, address safe) external pure returns (string memory) {
        return _acceptJson(s, true, safe, true, true, true);
    }

    function cutoverJson(DeployGang.Stack memory s, address pad1, address safe) external pure returns (string memory) {
        return _cutoverJson(s, _ctxOf(pad1), true, safe);
    }

    function checkCreatorFee(address pad) external {
        _checkCreatorFee(pad);
    }

    function _ctxOf(address pad1) internal pure returns (Ctx memory x) {
        x = Ctx({pad1: pad1, padRegistry: M.PAD_REGISTRY, gateway: MAINNET_GATEWAY});
    }
}

interface IGangRouterA {
    function v3BuyBNB(address token, uint256 minTokensOut, uint256 deadline) external payable returns (uint256);
}

/// @notice Runs the real DeployGangLaunchpad2 (both phases) on a BSC mainnet fork with a throwaway key, executes the
///         three Safe batches exactly as encoded, then a curve life on 2.0 through the live shared contracts: the
///         creator's 70% kept and claimed, the platform's 30% in the live bucket, graduation through the live
///         migrator, the registry and the gateway listing; 1.0 stops creating after the cut-over. No broadcast.
///         One test: the script reads process-wide env vars and tests run in parallel. Run it alone
///         (`--match-path test/fork/GangLaunchpad2DeployFork.t.sol`): FlywheelDeployScriptFork sets OWNER / KEEPER /
///         GANG_PAD too, and the two interfere when they run at the same time.
contract GangLaunchpad2DeployForkTest is Test {
    address constant PAD_1 = 0x15CFD2dc8278Fb87a1783ef42111618E20874365;
    address constant GATEWAY = 0x9dD16b73f624bdd8a210CBB2602FdF70f1B450B8;
    address constant SAFE = 0x2866369F7acEFC9760bdE7779362fae5cD68B41E;
    /// @dev The CurveLogic GangLaunchpad 1.0 links on BSC 56 (no creator fee; buy / sell without `creatorFeeOf`).
    address constant CURVE_LOGIC_1 = 0x45cf4cC2Fe0A3007a0a9cC58D44bb100537Ac6Fb;

    DeployGangLaunchpad2Harness d;

    function _execAsSafe(string memory json, uint256 count) internal {
        assertEq(vm.parseJsonString(json, ".chainId"), "56");
        assertEq(vm.parseJsonAddress(json, ".meta.createdFromSafeAddress"), SAFE);
        assertTrue(vm.keyExistsJson(json, string.concat(".transactions[", vm.toString(count - 1), "]")), "batch size");
        assertFalse(vm.keyExistsJson(json, string.concat(".transactions[", vm.toString(count), "]")), "batch size");
        for (uint256 i; i < count; i++) {
            string memory k = string.concat(".transactions[", vm.toString(i), "]");
            address to = vm.parseJsonAddress(json, string.concat(k, ".to"));
            bytes memory data = vm.parseJsonBytes(json, string.concat(k, ".data"));
            vm.prank(SAFE);
            (bool ok, bytes memory ret) = to.call(data);
            if (!ok) {
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
    }

    function _env(address me, uint256 pk) internal {
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(pk));
        vm.setEnv("GANG_PAD", vm.toString(PAD_1));
        vm.setEnv("OWNER", vm.toString(SAFE));
        vm.setEnv("KEEPER", vm.toString(M.KEEPER));
        vm.setEnv("GANG_GATEWAY", vm.toString(GATEWAY));
        vm.setEnv("GANG_PAD_REGISTRY", vm.toString(M.PAD_REGISTRY));
        vm.setEnv("GANG_PAD2", vm.toString(address(0)));
        vm.setEnv("GANG_ROUTER2", vm.toString(address(0)));
        vm.setEnv("ROUTER_TIMELOCK_DELAY", "172800");
        vm.setEnv("MAINNET_OWNER_IS_DEPLOYER", "false");
        vm.setEnv("KEEPER_OVERRIDE_OK", "false");
        vm.setEnv("FEE_VAULT", vm.toString(address(0)));
        vm.setEnv("BURNER", vm.toString(address(0)));
        vm.setEnv("RECIPIENT", vm.toString(address(0)));
        me;
    }

    function test_fork_deploy2_mainnetPathThenLife() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        uint256 pk = uint256(keccak256("GangLaunchpad 2.0 deploy-script fork test: throwaway, never funded"));
        address me = vm.addr(pk);
        vm.deal(me, 10 ether);
        _env(me, pk);
        d = new DeployGangLaunchpad2Harness();
        IGangPad p1 = IGangPad(PAD_1);

        // pinned mainnet inputs
        vm.setEnv("GANG_GATEWAY", vm.toString(address(0xBEEF)));
        vm.expectRevert(abi.encodeWithSelector(DeployGang.WiringCheck.selector, "GANG_GATEWAY is not the live gateway"));
        d.run();
        vm.setEnv("GANG_GATEWAY", vm.toString(GATEWAY));

        // the probe refuses 1.0 (no creator fee) — the audit's "old pad / old CurveLogic" case
        vm.expectRevert(
            abi.encodeWithSelector(DeployGang.WiringCheck.selector, "pad.CREATOR_FEE_SHARE_BPS (a 1.0 pad?)")
        );
        d.checkCreatorFee(PAD_1);

        // review 2026-10-31: leftover env values are refused on mainnet before anything is deployed
        vm.setEnv("KEEPER", vm.toString(address(0xBAD)));
        vm.expectRevert(abi.encodeWithSelector(DeployGang.KeeperNotDefault.selector, address(0xBAD)));
        d.run();
        vm.setEnv("KEEPER_OVERRIDE_OK", "true"); // DeployGang's escape hatch: 2.0 still refuses
        vm.setEnv("KEEPER", vm.toString(M.KEEPER));
        _expectCheck("KEEPER is not the platform keeper", "KEEPER", vm.toString(address(0xBAD)), M.KEEPER);
        vm.setEnv("KEEPER_OVERRIDE_OK", "false");
        vm.setEnv("TWAP_WINDOW", "600");
        vm.expectRevert(abi.encodeWithSelector(DeployGang.WiringCheck.selector, "TWAP_WINDOW differs from 1.0's"));
        d.run();
        vm.setEnv("TWAP_WINDOW", vm.toString(uint256(p1.twapWindow())));
        _expectCheck("RECIPIENT must be empty on mainnet", "RECIPIENT", vm.toString(address(0xCAFE)), address(0));

        // review M-1: a 2.0 pad linked to 1.0's CurveLogic fails phase 1 itself, before Safe batch 1 is printed (the
        // simulation reverts: nothing would be broadcast, nothing for the Safe to list)
        address lib = _curveLogicOf();
        bytes memory good = lib.code;
        vm.etch(lib, CURVE_LOGIC_1.code);
        vm.expectRevert(abi.encodeWithSelector(DeployGang.WiringCheck.selector, "CurveLogic is not the 2.0 library"));
        d.run();
        vm.etch(lib, good);

        // phase 1: deployed, own wiring done, shared listing left to the Safe
        DeployGang.Stack memory s = d.run();
        IGangPad p = IGangPad(s.pad);
        assertEq(p.taxHandler(), s.handler);
        assertEq(p.dividendVault(), p1.dividendVault(), "shared vault");
        assertEq(p.platformBucket(), p1.platformBucket(), "shared bucket");
        assertEq(p.tokenDeployer(), p1.tokenDeployer(), "shared token deployer");
        assertEq(p.migrator(), address(0), "closed");
        assertTrue(p.routers(s.router) && p.routers(GATEWAY), "router + gateway listed");
        assertEq(p.twapWindow(), p1.twapWindow(), "1.0's TWAP window");
        assertEq(p.bridgePoolOf(M.USDT), M.USDT_WBNB_V3);

        // Safe batch 1 (9 listings), phase 2: self-check with the pad closed, hand-over started
        _execAsSafe(d.wiringJson(s, PAD_1, SAFE), 9);
        vm.setEnv("GANG_PAD2", vm.toString(s.pad));
        vm.setEnv("GANG_ROUTER2", vm.toString(s.router));
        d.run();
        assertEq(Ownable2Step(s.pad).pendingOwner(), SAFE);
        assertEq(Ownable2Step(s.handler).pendingOwner(), SAFE);
        assertEq(p.migrator(), address(0), "not open while the deploy wallet owns it");

        // Safe batch 2: accept both, open 2.0; phase 2 again: nothing left
        _execAsSafe(d.acceptJson(s, SAFE), 3);
        assertEq(Ownable(s.pad).owner(), SAFE);
        assertEq(Ownable(s.handler).owner(), SAFE);
        assertEq(p.migrator(), p1.migrator(), "open on the live migrator");
        d.run();

        // a curve life on 2.0 (the soulbound live Agent ID registry can't be minted on a fork)
        MockAgentId agents = new MockAgentId();
        vm.prank(SAFE);
        p.setAgentGate(true, address(agents));
        address creator = makeAddr("creator2");
        agents.mint(creator, 1);
        IGangLaunchpad.TaxConfig memory untaxed =
            IGangLaunchpad.TaxConfig({buyTaxBps: 0, sellTaxBps: 0, dividendBps: 0, recipient: address(0)});
        vm.prank(creator);
        address t = p.create("Two", "TWO", "", "", M.WBNB, address(0), untaxed);
        assertEq(GangPadRegistry(M.PAD_REGISTRY).padOf(t), s.pad, "registry finds 2.0's token");

        SharedPlatformFeeBucket bucket = SharedPlatformFeeBucket(p.platformBucket());
        uint256 acc0 = bucket.accruedQuote(M.WBNB);
        address buyer = makeAddr("buyer2");
        agents.mint(buyer, 2);
        vm.deal(buyer, 1 ether);
        vm.prank(buyer, buyer);
        IGangRouterA(s.router).v3BuyBNB{value: 0.02 ether}(t, 0, block.timestamp);
        uint256 fee = (0.02 ether * 100) / 10_000;
        assertEq(p.creatorFeeOf(t), (fee * 7_000) / 10_000, "70% kept for the creator");
        assertEq(bucket.accruedQuote(M.WBNB) - acc0, fee - (fee * 7_000) / 10_000, "30% to the live bucket");

        for (uint256 i = 1; i < 400; i++) {
            (,,,,,, bool graduated,,,,,) = _curve(p, t);
            if (graduated) break;
            address w = address(uint160(0xB2000 + i));
            agents.mint(w, 100 + i);
            vm.deal(w, 2 ether);
            vm.prank(w, w);
            IGangRouterA(s.router).v3BuyBNB{value: 1 ether}(t, 0, block.timestamp);
        }
        (,,,,,, bool done,,,, address pair,) = _curve(p, t);
        assertTrue(done && pair != address(0), "graduated through the live migrator");
        uint256 owed = p.creatorFeeOf(t);
        assertGt(owed, 0.1 ether, "about 0.7% of ~15 BNB");
        uint256 before = IERC20(M.WBNB).balanceOf(creator);
        vm.prank(creator);
        p.claimCreatorFee(t, creator);
        assertEq(IERC20(M.WBNB).balanceOf(creator) - before, owed, "claimed after graduation");
        assertLe(IERC20(M.WBNB).balanceOf(s.pad), 1, "2.0 holds only dust");

        // Safe batch 3 (cut-over): 1.0 stops creating; 2.0 keeps creating
        vm.prank(SAFE);
        p1.setAgentGate(true, address(agents));
        vm.prank(creator);
        p1.create("One", "ONE", "", "", M.WBNB, address(0), untaxed); // still open before the cut-over
        _execAsSafe(d.cutoverJson(s, PAD_1, SAFE), 1);
        assertFalse(TokenDeployer(p.tokenDeployer()).launchpads(PAD_1));
        vm.prank(creator);
        vm.expectRevert();
        p1.create("One", "ONE", "", "", M.WBNB, address(0), untaxed);
        vm.prank(creator);
        p.create("Two", "TWO", "", "", M.WBNB, address(0), untaxed);

        // 1.0 and 2.0 share the vault without touching each other's floor
        SharedDividendVault v = SharedDividendVault(p.dividendVault());
        assertEq(v.minimumShareBalanceOf(PAD_1), 10_000 ether);
        assertEq(v.minimumShareBalanceOf(s.pad), 10_000 ether);
    }

    function _expectCheck(string memory what, string memory key, string memory bad, address restore) internal {
        vm.setEnv(key, bad);
        vm.expectRevert(abi.encodeWithSelector(DeployGang.WiringCheck.selector, what));
        d.run();
        vm.setEnv(key, vm.toString(restore));
    }

    /// @dev The CurveLogic this build links into GangLaunchpad: the PUSH20 in its code whose target has
    ///      `claimCreatorFee` in its dispatcher.
    function _curveLogicOf() internal returns (address) {
        bytes memory code = address(new GangLaunchpad(SAFE, SAFE, SAFE, SAFE, SAFE, SAFE, SAFE, SAFE)).code;
        for (uint256 i; i + 21 <= code.length; i++) {
            if (code[i] != 0x73) continue;
            address a;
            assembly ("memory-safe") {
                a := shr(96, mload(add(add(code, 33), i)))
            }
            if (a.code.length > 0 && _hasSelector(a.code, CurveLogic.claimCreatorFee.selector)) return a;
        }
        revert("CurveLogic not found");
    }

    function _hasSelector(bytes memory code, bytes4 sel) internal pure returns (bool) {
        uint256 want = (uint256(0x63) << 32) | uint256(uint32(sel));
        for (uint256 i; i + 5 <= code.length; i++) {
            uint256 w;
            assembly ("memory-safe") {
                w := shr(216, mload(add(add(code, 32), i)))
            }
            if (w == want) return true;
        }
        return false;
    }

    function _curve(IGangPad p, address t)
        internal
        view
        returns (address, address, uint128, uint128, uint128, uint128, bool, uint16, uint16, uint16, address, address)
    {
        return p.curves(t);
    }
}
