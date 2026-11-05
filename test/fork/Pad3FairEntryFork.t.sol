// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Pad3Impl} from "../../script/Pad3Impl.sol";
import {UpgradeGangLaunchpad3} from "../../script/UpgradeGangLaunchpad3.s.sol";
import {FlyUpgradeHarness, Pad3LiveUpgrade} from "./Pad3LiveUpgrade.sol";
import {GangRouterDeployLib as R} from "../../script/GangRouterDeployLib.sol";
import {GangMainnetRefs as M} from "../../config/GangDeployRefs.sol";
import {GangLaunchpad3} from "../../src/gang/GangLaunchpad3.sol";
import {IGangPad} from "../../src/gang/interfaces/IGangPad.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";

interface IFairCreate {
    function create(
        string calldata name,
        string calldata symbol,
        string calldata logoURI,
        string calldata metaURI,
        address quote,
        address refPool,
        IGangLaunchpad.MintConfig calldata cfg,
        uint256 devShares
    ) external returns (address token);
}

/// @notice 打新 through GangLaunchpad 3.0's entry on a BSC mainnet fork: the live 3.0 proxy upgraded to this build
///         (UpgradeGangLaunchpad3's checks, then the Safe's call), a fresh 打新 sale on each of the live 1.0, 2.0 and
///         3.0 pads, each traded through 3.0's entry: status 1, `tryBuy` = `buyTokenAMAP` to the wei (the rest back
///         in WBNB), `trySell` = `sellToken` (native BNB), 3.0's own WBNB untouched by the forwarded trades. Agent IDs
///         are mocked. No broadcast. Run it alone (the script reads process-wide env vars).
/// @dev Needs BSC_RPC_URL (skipped without it) and the live PoolCheck linked:
///      --libraries src/launchpad-v2/PoolCheck.sol:PoolCheck:0xd2B159820749f178503E4faBCB18A7Ae4492bDb3
contract Pad3FairEntryForkTest is Test {
    address constant PAD3 = 0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29;
    address constant ROUTER3 = 0xec9717E5C68b9F18fA76D3961C9Cd7e67b5E61e7;
    address constant PAD_1 = 0x15CFD2dc8278Fb87a1783ef42111618E20874365;
    address constant PAD_2 = 0x770331a9accdb53ACb4a45B6c5B7D151fADCe557;
    address constant SAFE = 0x2866369F7acEFC9760bdE7779362fae5cD68B41E;
    uint256 constant TPS = 50_000 ether;
    /// @dev a gated 1.0 打新 sale minting at 2026-11-04 (56 of 10,000 shares sold then)
    address constant LIVE_SALE_1 = 0xF1FE17F4a67f0347dD3863a4f238eCD874DaCFF4;

    GangLaunchpad3 p = GangLaunchpad3(payable(PAD3));

    function test_fork_fairThroughEntry_onAllThreePads() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        uint256 pk = uint256(keccak256("GangLaunchpad 3.0 fair-entry fork test: throwaway, never funded"));
        vm.deal(vm.addr(pk), 1 ether);
        vm.mockCall(M.AGENT_ID_REGISTRY, abi.encodeWithSelector(IERC721.balanceOf.selector), abi.encode(uint256(1)));
        _env(pk);

        // a gated 打新 sale on 3.0 BEFORE the upgrade: the live implementation reports it as not traded (3); the
        // upgrade script leaves its entry views out of the comparison and checks it reads 1 after (audit 2B L-1)
        address pre = _createSale(PAD3, 9);
        (uint8 st0,,,,) = p.getTokenInfo(pre);
        // (1 once the Safe's upgrade has run: the upgrade below is then an empty batch)
        if (st0 != 1) assertEq(st0, 3, "live implementation: not traded through the entry");

        (FlyUpgradeHarness u, UpgradeGangLaunchpad3.Stack memory st) = Pad3LiveUpgrade.check();
        address impl = Pad3LiveUpgrade.execute(u, st, SAFE);
        assertEq(R.implementationOf(PAD3), impl);
        (uint8 st1,,,,) = p.getTokenInfo(pre);
        assertEq(st1, 1, "the sale from before the upgrade trades through the entry now");

        address[3] memory pads = [PAD_1, PAD_2, PAD3];
        for (uint256 i; i < 3; i++) {
            _roundTrip(pads[i], i);
        }
        _liveSale();
    }

    /// @dev A 打新 sale already minting on the live 1.0 (gated, real minters' shares in it): one share in and out
    ///      through 3.0's entry, if it is still minting at the fork block.
    function _liveSale() internal {
        address t = LIVE_SALE_1;
        (uint8 st,,,,) = p.getTokenInfo(t);
        if (st != 1) return; // launched since
        address w = makeAddr("live-sale-minter");
        (,, uint256 amount, uint256 cost,,,,) = p.tryBuy(t, w, 0, 0.002 ether);
        assertGt(amount, 0, "quoted");
        vm.deal(w, 1 ether);
        vm.prank(w, w);
        (uint256 out, uint256 used) = p.buyTokenAMAP{value: 0.002 ether}(t, w, 0.002 ether, amount);
        assertEq(out, amount);
        assertEq(used, cost);
        vm.prank(w);
        IERC20(t).approve(PAD3, type(uint256).max);
        (,, uint256 f,) = p.trySell(t, out);
        vm.prank(w, w);
        assertEq(p.sellToken(0, t, w, out, f, 0, address(0)), f, "sold back = trySell");
        assertEq(IERC20(t).balanceOf(w), 0);
    }

    function _createSale(address pad, uint256 i) internal returns (address t) {
        address creator = makeAddr(string.concat("fair-creator-", vm.toString(i)));
        deal(M.WBNB, creator, 1 ether);
        vm.prank(creator);
        IERC20(M.WBNB).approve(pad, type(uint256).max);
        IGangLaunchpad.MintConfig memory cfg = IGangLaunchpad.MintConfig({
            raiseBnb: 10 ether, capBps: 50, holdBps: 6_000, mintFeeBps: 100, exitFeeBps: 100
        });
        vm.prank(creator, creator);
        t = IFairCreate(pad).create("Fair fork", "FFK", "", "", address(0), address(0), cfg, 1);
    }

    function _roundTrip(address pad, uint256 i) internal {
        address alice = makeAddr(string.concat("fair-alice-", vm.toString(i)));
        address t = _createSale(pad, i);

        (uint8 st, address q,,,) = p.getTokenInfo(t);
        assertEq(st, 1, "tradable through the entry");
        assertEq(q, address(0));

        uint256 own0 = IERC20(M.WBNB).balanceOf(PAD3);
        uint256 funds = 0.0123 ether;
        (,, uint256 amount, uint256 cost,,,,) = p.tryBuy(t, alice, 0, funds);
        assertEq(amount, 12 * TPS, "12 whole shares");
        vm.deal(alice, 1 ether);
        vm.prank(alice, alice);
        (uint256 out, uint256 used) = p.buyTokenAMAP{value: funds}(t, alice, funds, amount);
        assertEq(out, amount, "= tryBuy amount");
        assertEq(used, cost, "= tryBuy cost");
        assertEq(IERC20(t).balanceOf(alice), amount);
        assertEq(IERC20(M.WBNB).balanceOf(alice), funds - cost, "the rest back in WBNB");

        vm.prank(alice);
        IERC20(t).approve(PAD3, type(uint256).max);
        (,, uint256 sellFunds,) = p.trySell(t, 5 * TPS);
        assertGt(sellFunds, 0);
        uint256 a0 = alice.balance;
        vm.prank(alice, alice);
        uint256 paid = p.sellToken(0, t, alice, 5 * TPS, sellFunds, 0, address(0));
        assertEq(paid, sellFunds, "= trySell");
        assertEq(alice.balance - a0, paid, "native BNB");
        assertEq(IERC20(t).balanceOf(alice), 7 * TPS);
        if (pad != PAD3) {
            assertEq(IERC20(M.WBNB).balanceOf(PAD3), own0, "3.0's own WBNB untouched");
            assertEq(IERC20(t).balanceOf(PAD3), 0, "3.0 holds none of the older pad's token");
            assertEq(IERC20(M.WBNB).allowance(PAD3, pad), 0, "no approval left");
        }
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
