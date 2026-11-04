// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {UpgradeGangLaunchpad3} from "../../script/UpgradeGangLaunchpad3.s.sol";
import {FlyUpgradeHarness, Pad3LiveUpgrade} from "./Pad3LiveUpgrade.sol";
import {GangMainnetRefs as M} from "../../config/GangDeployRefs.sol";
import {GangLaunchpad3} from "../../src/gang/GangLaunchpad3.sol";
import {GangLaunchpad} from "../../src/gang/GangLaunchpad.sol";
import {IGangPad} from "../../src/gang/interfaces/IGangPad.sol";
import {IFlywheelPad} from "../../src/flywheel/interfaces/IFlywheelPad.sol";

interface IFlySales {
    function tokenCount() external view returns (uint256);
    function allTokens(uint256 i) external view returns (address);
    function sales(address token) external view returns (IFlywheelPad.Sale memory);
    function TOKENS_PER_SHARE() external view returns (uint256);
}

/// @notice The live tokens of the pads before 3.0, traded through 3.0's entry on a BSC mainnet fork after the upgrade
///         to this build: an open curve on 1.0 and on 2.0, a minting 铸币飞轮 sale on V1 and on V2 (3.0's own WBNB
///         untouched). 打新 on 1.0 / 2.0 is in Pad3FairEntryFork; the vault pad's one token has graduated, and its
///         curves run on 2.0's code. Agent IDs are mocked. No broadcast. Run it alone (the script reads process-wide
///         env vars).
/// @dev Needs BSC_RPC_URL (skipped without it) and the live PoolCheck linked:
///      --libraries src/launchpad-v2/PoolCheck.sol:PoolCheck:0xd2B159820749f178503E4faBCB18A7Ae4492bDb3
contract Pad3LegacyForwardForkTest is Test {
    address constant PAD3 = 0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29;
    address constant ROUTER3 = 0xec9717E5C68b9F18fA76D3961C9Cd7e67b5E61e7;
    address constant PAD_1 = 0x15CFD2dc8278Fb87a1783ef42111618E20874365;
    address constant PAD_2 = 0x770331a9accdb53ACb4a45B6c5B7D151fADCe557;
    address constant SAFE = 0x2866369F7acEFC9760bdE7779362fae5cD68B41E;

    GangLaunchpad3 p = GangLaunchpad3(payable(PAD3));

    function test_fork_olderPadsThroughTheEntry() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        uint256 pk = uint256(keccak256("GangLaunchpad 3.0 forward fork test: throwaway, never funded"));
        vm.deal(vm.addr(pk), 1 ether);
        vm.mockCall(M.AGENT_ID_REGISTRY, abi.encodeWithSelector(IERC721.balanceOf.selector), abi.encode(uint256(1)));
        _env(pk);
        (FlyUpgradeHarness u, UpgradeGangLaunchpad3.Stack memory st) = Pad3LiveUpgrade.check();
        Pad3LiveUpgrade.execute(u, st, SAFE);

        _curve(PAD_1, "1.0");
        _curve(PAD_2, "2.0");
        _fly(M.FLYWHEEL_PAD_V1, "fly V1");
        _fly(M.FLYWHEEL_PAD_V2, "fly V2");
    }

    function _curve(address pad, string memory name) internal {
        GangLaunchpad g = GangLaunchpad(payable(pad));
        address t;
        for (uint256 i = g.tokenCount(); i > 0 && t == address(0); i--) {
            address c = g.allTokens(i - 1);
            if (g.kindOf(c) != 1) continue;
            (uint8 st, address q,,,) = p.getTokenInfo(c);
            if (st == 1 && q == address(0)) t = c;
        }
        assertTrue(t != address(0), name);
        _roundTrip(t, 0.001 ether, 0, name);
    }

    function _fly(address pad, string memory name) internal {
        IFlySales f = IFlySales(pad);
        address t;
        for (uint256 i = f.tokenCount(); i > 0 && t == address(0); i--) {
            address c = f.allTokens(i - 1);
            IFlywheelPad.Sale memory s = f.sales(c);
            if (s.gate != address(0) && s.quote == M.WBNB && !s.launched && s.filledAt == 0 && s.sold < 9_000) t = c;
        }
        assertTrue(t != address(0), name);
        _roundTrip(t, 0.05 ether, f.TOKENS_PER_SHARE(), name);
    }

    /// @dev `unit` != 0: 铸币飞轮, whole shares both ways.
    function _roundTrip(address t, uint256 funds, uint256 unit, string memory name) internal {
        address w = makeAddr(string.concat("forward-", name));
        vm.deal(w, 1 ether);
        uint256 own0 = IERC20(M.WBNB).balanceOf(PAD3);
        (,, uint256 amount,,,,,) = p.tryBuy(t, w, 0, funds);
        assertGt(amount, 0, string.concat(name, ": quoted"));
        vm.prank(w, w);
        (uint256 out,) = p.buyTokenAMAP{value: funds}(t, w, funds, amount);
        assertEq(out, amount, string.concat(name, ": fill = quote"));
        assertEq(IERC20(t).balanceOf(w), out, string.concat(name, ": tokens to the trader"));
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.roll(vm.getBlockNumber() + 1);
        uint256 back = unit == 0 ? out / 2 : unit;
        vm.prank(w);
        IERC20(t).approve(PAD3, back);
        (,, uint256 quoted,) = p.trySell(t, back);
        assertGt(quoted, 0, string.concat(name, ": sell quoted"));
        vm.prank(w, w);
        assertEq(p.sellToken(0, t, w, back, quoted, 0, address(0)), quoted, string.concat(name, ": sell = quote"));
        assertEq(IERC20(M.WBNB).balanceOf(PAD3), own0, string.concat(name, ": 3.0's WBNB untouched"));
    }

    function _env(uint256 pk) internal {
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(pk));
        vm.setEnv("GANG_PAD", vm.toString(PAD_1));
        vm.setEnv("OWNER", vm.toString(SAFE));
        vm.setEnv("KEEPER", vm.toString(M.KEEPER));
        vm.setEnv("GANG_GATEWAY", vm.toString(M.GANG_GATEWAY));
        vm.setEnv("GANG_PAD_REGISTRY", vm.toString(M.PAD_REGISTRY));
        vm.setEnv("GANG_PAD3", vm.toString(PAD3));
        vm.setEnv("GANG_ROUTER3", vm.toString(ROUTER3));
        vm.setEnv("PAD3_NEW", "false");
        vm.setEnv(
            "CALLERS",
            "0x1de460f363AF910f51726DEf188F9004276Bf4bc,0xDB97fC3329Ed1939012D56ECeaef00Be1C0CdFF5,0x3508DcA95a64C9378Cb07eF6F40553A50905372a"
        );
        vm.setEnv("CALLER_CODEHASHES", "");
        vm.setEnv("CALLERS_PROXY_OK", "true");
        vm.setEnv("PAD3_INIT_CALL", "0x");
        // the script deploys the implementation and the 铸币飞轮 tax handler (Pad3LiveUpgrade)
        vm.setEnv("PAD3_IMPL", vm.toString(address(0)));
        vm.setEnv("PAD3_FLY_HANDLER", vm.toString(address(0)));
        vm.setEnv("PAD3_FLY_TOKEN_DEPLOYER", vm.toString(address(0)));
        vm.setEnv("PAD3_FLY_VAULT_CORE", vm.toString(address(0)));
        vm.setEnv("GANG_MAINNET_OK", "true");
        vm.setEnv("PAD3_LOG_SCAN", "false");
        vm.setEnv("CUTOVER", "false");
        vm.setEnv("ROUTER_TIMELOCK_DELAY", "172800");
        vm.setEnv("MAINNET_OWNER_IS_DEPLOYER", "false");
        vm.setEnv("KEEPER_OVERRIDE_OK", "false");
        vm.setEnv("FEE_VAULT", vm.toString(address(0)));
        vm.setEnv("BURNER", vm.toString(address(0)));
        vm.setEnv("RECIPIENT", vm.toString(address(0)));
        vm.setEnv("TWAP_WINDOW", vm.toString(uint256(IGangPad(PAD_1).twapWindow())));
    }
}
