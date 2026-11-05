// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Pad3Impl} from "../../script/Pad3Impl.sol";
import {UpgradeGangLaunchpad3} from "../../script/UpgradeGangLaunchpad3.s.sol";
import {GangRouterDeployLib as R} from "../../script/GangRouterDeployLib.sol";
import {FlyUpgradeHarness, Pad3LiveUpgrade} from "./Pad3LiveUpgrade.sol";
import {GangMainnetRefs as M} from "../../config/GangDeployRefs.sol";
import {GangLaunchpad3} from "../../src/gang/GangLaunchpad3.sol";
import {Pad3FlyModule} from "../../src/gang/Pad3FlyModule.sol";
import {IGangPad} from "../../src/gang/interfaces/IGangPad.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {SharedDividendVault} from "../../src/common/SharedDividendVault.sol";
import {FlywheelTaxHandler} from "../../src/flywheel/FlywheelTaxHandler.sol";
import {IFlywheelPad} from "../../src/flywheel/interfaces/IFlywheelPad.sol";

interface IPairSwap {
    function token0() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

/// @notice GangLaunchpad 3.0's 铸币飞轮 mode on a BSC mainnet fork, end to end: UpgradeGangLaunchpad3 run as on
///         mainnet (it deploys the 铸币飞轮 tax handler and the implementation from the deploy wallet, checks the
///         upgrade in its simulation and prints the Safe batch), then the batch as the Safe sends it (V2's
///         MintTokenDeployer lists 3.0, the handler's launchpad and keeper, the handler a bucket operator, the vault
///         core listed in the shared vault with the handler as its operator, the upgrade). Then a 铸币飞轮 sale on 3.0: through the entry and back, opened early, launched on
///         Pancake, and the handler's share writes and pool taxes' dividends reaching holders in the live shared vault
///         under the vault core (the vault's one operator for 3.0 itself is its curve / 打新 handler). Agent IDs are mocked. No
///         broadcast. Run it alone (the script reads process-wide env vars).
/// @dev Needs BSC_RPC_URL (skipped without it) and the live PoolCheck linked:
///      --libraries src/launchpad-v2/PoolCheck.sol:PoolCheck:0xd2B159820749f178503E4faBCB18A7Ae4492bDb3
contract Pad3FlyUpgradeForkTest is Test {
    address constant PAD3 = 0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29;
    address constant ROUTER3 = 0xec9717E5C68b9F18fA76D3961C9Cd7e67b5E61e7;
    address constant PAD_1 = 0x15CFD2dc8278Fb87a1783ef42111618E20874365;
    address constant SAFE = 0x2866369F7acEFC9760bdE7779362fae5cD68B41E;
    uint256 constant FLY_TPS = 100_000 ether;

    GangLaunchpad3 p = GangLaunchpad3(payable(PAD3));
    Pad3FlyModule fly = Pad3FlyModule(PAD3);
    uint256 internal _n;

    function test_fork_flyModeUpgradeAndSale() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        // under gas metering the upgrade script's run ends in OutOfGas at any gas limit, on this file's base commit too
        // (cause not tracked down); paused, it completes. This test doesn't measure gas.
        vm.pauseGasMetering();
        vm.createSelectFork(rpc);
        uint256 pk = uint256(keccak256("GangLaunchpad 3.0 fly-mode fork test: throwaway, never funded"));
        vm.deal(vm.addr(pk), 1 ether);
        vm.mockCall(M.AGENT_ID_REGISTRY, abi.encodeWithSelector(IERC721.balanceOf.selector), abi.encode(uint256(1)));
        _env(pk);

        FlyUpgradeHarness h = new FlyUpgradeHarness();
        UpgradeGangLaunchpad3.Stack memory s = h.run();
        Pad3Impl.FlyDeps memory f = h.fly();
        assertEq(f.flyTokenDeployer, M.FLYWHEEL_TOKEN_DEPLOYER);
        FlywheelTaxHandler handler = FlywheelTaxHandler(f.flyTaxHandler);
        assertEq(handler.owner(), SAFE, "the Safe's from the start");
        address impl = h.deployedImpl();

        // as on mainnet: the deploying run printed no batch; the read-only re-run with the deployed addresses does
        vm.setEnv("PAD3_IMPL", vm.toString(impl));
        vm.setEnv("PAD3_FLY_HANDLER", vm.toString(f.flyTaxHandler));
        vm.setEnv("PAD3_FLY_VAULT_CORE", vm.toString(f.flyVaultCore));
        uint256 nonce = vm.getNonce(vm.addr(pk));
        FlyUpgradeHarness h2 = new FlyUpgradeHarness();
        h2.run();
        assertEq(vm.getNonce(vm.addr(pk)), nonce, "the re-run deploys nothing");
        Pad3Impl.FlyDeps memory f2 = h2.fly();
        assertEq(abi.encode(f2), abi.encode(f), "same dependencies");
        (address[] memory to, bytes[] memory data) = h2.prep(s, M.KEEPER, SAFE);
        // handler launchpad + keeper, deployer, bucket, vault core + operator: all done by the fly-mode upgrade
        assertEq(to.length, 0, "the live wiring is done");

        vm.startPrank(SAFE);
        for (uint256 i; i < to.length; i++) {
            (bool ok,) = to[i].call(data[i]);
            assertTrue(ok, "a listing");
        }
        ProxyAdmin(R.adminOf(PAD3)).upgradeAndCall(ITransparentUpgradeableProxy(PAD3), impl, "");
        vm.stopPrank();
        assertEq(handler.owner(), SAFE);
        (to,) = h.prep(s, M.KEEPER, SAFE);
        assertEq(to.length, 0, "nothing left for the Safe");

        address t = _sale();
        _gatewayRefused(t);
        _entryRoundTrip(t);
        _launchAndPayHolders(t, handler);
    }

    /// @notice The file the Safe signs (PAD3_FORK_BATCH), as written, over the contracts it names: then the same sale.
    function test_fork_signedBatchThenSale() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        string memory batch = Pad3LiveUpgrade.batchFile();
        if (bytes(rpc).length == 0 || bytes(batch).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 forkBlock = vm.envOr("PAD3_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);
        vm.mockCall(M.AGENT_ID_REGISTRY, abi.encodeWithSelector(IERC721.balanceOf.selector), abi.encode(uint256(1)));
        Pad3LiveUpgrade.executeBatchFile(batch, SAFE);
        FlywheelTaxHandler handler = FlywheelTaxHandler(Pad3FlyModule(PAD3).flyTaxHandler());
        assertEq(handler.owner(), SAFE, "the Safe's from the start");

        address t = _sale();
        _gatewayRefused(t);
        _entryRoundTrip(t);
        _launchAndPayHolders(t, handler);
    }

    function _agent() internal returns (address w) {
        w = makeAddr(string.concat("fly-fork-", vm.toString(_n++)));
        vm.deal(w, 10 ether);
        deal(M.WBNB, w, 10 ether);
        vm.prank(w);
        IERC20(M.WBNB).approve(PAD3, type(uint256).max);
    }

    function _sale() internal returns (address t) {
        IFlywheelPad.FlyConfig memory c = IFlywheelPad.FlyConfig({
            raiseBnb: 3 ether,
            baseQuota: 100,
            inviteBonus: 1,
            maxPerTx: 10,
            holdBps: 6_000,
            mintFeeBps: 100,
            exitFeeBps: 100,
            devCutBps: 1_000,
            buyBps: 3_000,
            sellTaxBps: 200,
            launchDelay: 60,
            window: 600,
            windowCapMul: 1,
            postMint: false,
            tierMode: 1,
            stepBps: 0,
            stepShares: 0,
            maxMulX100: 0,
            supplyCapMul: 100,
            guardBps: 0,
            twapWindow: 1800
        });
        (bool ok, string memory why) = fly.checkConfig(c, 1);
        assertTrue(ok, why);
        address creator = _agent();
        string[4] memory text = ["Fly fork", "FFLY", "", ""];
        vm.prank(creator, creator);
        t = fly.create(text, address(0), address(0), c, 1);
        assertEq(p.kindOf(t), 3);
        SharedDividendVault vault = SharedDividendVault(address(p.dividendVault()));
        // under the vault core at V2's floor (3.0's own floor is 10,000)
        assertEq(vault.launchpadOf(t), fly.flyVaultCore());
        assertEq(vault.minimumShareBalanceFor(t), 1_000 ether);
    }

    /// @dev GangGateway is a router of 3.0 but not a 铸币飞轮 router (its V2 code, not deployed on mainnet, sizes shares
    ///      by TOKENS_PER_SHARE, 50,000), so its for-trader calls on a 3.0 铸币飞轮 token revert (audit B M-1).
    function _gatewayRefused(address t) internal {
        address w = _agent();
        vm.prank(w);
        fly.mint(t, 2, 2, address(0));
        assertFalse(fly.flyRouters(M.GANG_GATEWAY));
        vm.prank(M.GANG_GATEWAY, w);
        vm.expectRevert(IGangLaunchpad.OnlyRouter.selector);
        p.withdrawFor(w, t, 1, 0);
        vm.prank(M.GANG_GATEWAY, w);
        vm.expectRevert(IGangLaunchpad.OnlyRouter.selector);
        fly.mintFor(w, t, 1, 1, address(0));
    }

    function _entryRoundTrip(address t) internal {
        (uint8 st,,,,) = p.getTokenInfo(t);
        assertEq(st, 1);
        address w = _agent();
        (,, uint256 amount, uint256 cost,, uint256 msgValue,,) = p.tryBuy(t, w, 0, 0.0031 ether);
        assertEq(amount, 10 * FLY_TPS, "ten whole shares");
        vm.prank(w, w);
        (uint256 out, uint256 used) = p.buyTokenAMAP{value: msgValue}(t, w, msgValue, amount);
        assertEq(out, amount);
        assertEq(used, cost);
        (,, uint256 funds,) = p.trySell(t, 4 * FLY_TPS);
        vm.startPrank(w, w);
        IERC20(t).approve(PAD3, 4 * FLY_TPS);
        assertEq(p.sellToken(0, t, w, 4 * FLY_TPS, funds, 0, address(0)), funds, "= trySell");
        vm.stopPrank();
    }

    function _launchAndPayHolders(address t, FlywheelTaxHandler handler) internal {
        SharedDividendVault vault = SharedDividendVault(address(p.dividendVault()));
        address holder = _agent();
        vm.prank(holder);
        fly.mint(t, 10, 10, address(0));
        while (fly.sales(t).sold < 3_000) {
            address w = _agent();
            vm.startPrank(w);
            for (uint256 i; i < 10 && fly.sales(t).sold < 3_000; i++) {
                fly.mint(t, 10, 1, address(0));
            }
            vm.stopPrank();
        }
        vm.prank(fly.sales(t).creator);
        fly.openEarly(t);
        vm.warp(vm.getBlockTimestamp() + 61);
        fly.launch(t);
        vm.warp(vm.getBlockTimestamp() + 601);
        vm.roll(vm.getBlockNumber() + 1);

        // the handler's share write in the live vault (the vault core's operator)
        assertEq(vault.shares(t, holder), 10 * FLY_TPS);
        vm.prank(holder);
        IERC20(t).transfer(makeAddr("friend"), 3 * FLY_TPS);
        assertEq(vault.shares(t, holder), 7 * FLY_TPS, "share = balance, written by the handler");

        // a pool sell's tax, processed by the keeper: the holders' part converted in the vault
        address seller = _agent();
        _poolBuy(t, seller, 0.2 ether);
        _poolSell(t, seller, IERC20(t).balanceOf(seller));
        uint256 accrued = handler.accruedTax(t);
        assertGt(accrued, 0);
        // a later block than the trades (each block has its own reference price)
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(M.KEEPER);
        handler.process(t, accrued, 1);
        assertGt(vault.pending(t, holder), 0, "dividends reach a holder");
    }

    function _poolBuy(address t, address who, uint256 quoteIn) internal {
        IPairSwap pr = IPairSwap(fly.sales(t).pair);
        (uint112 r0, uint112 r1,) = pr.getReserves();
        bool t0 = pr.token0() == t;
        (uint256 rT, uint256 rQ) = t0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        vm.prank(who);
        IERC20(M.WBNB).transfer(address(pr), quoteIn);
        uint256 inFee = quoteIn * 9975;
        uint256 out = (inFee * rT) / (rQ * 10_000 + inFee);
        pr.swap(t0 ? out : 0, t0 ? 0 : out, who, "");
    }

    function _poolSell(address t, address who, uint256 amount) internal {
        IPairSwap pr = IPairSwap(fly.sales(t).pair);
        vm.prank(who);
        IERC20(t).transfer(address(pr), amount);
        (uint112 r0, uint112 r1,) = pr.getReserves();
        bool t0 = pr.token0() == t;
        (uint256 rT, uint256 rQ) = t0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 inAmt = IERC20(t).balanceOf(address(pr)) - rT;
        uint256 inFee = inAmt * 9975;
        uint256 out = (inFee * rQ) / (rT * 10_000 + inFee);
        pr.swap(t0 ? 0 : out, t0 ? out : 0, who, "");
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
