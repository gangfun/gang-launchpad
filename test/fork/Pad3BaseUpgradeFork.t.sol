// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {GangMainnetRefs as M} from "../../config/GangDeployRefs.sol";
import {GangLaunchpad3} from "../../src/gang/GangLaunchpad3.sol";
import {Pad3Module} from "../../src/gang/Pad3Module.sol";
import {Pad3BaseStore} from "../../src/gang/Pad3BaseStore.sol";
import {Pad3VanityDeployer} from "../../src/gang/Pad3VanityDeployer.sol";
import {GangBaseVault} from "../../src/gang/GangBaseVault.sol";
import {GangToken} from "../../src/gang/GangToken.sol";
import {IGangBasePad} from "../../src/gang/interfaces/IGangBasePad.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {Pad3Impl} from "../../script/Pad3Impl.sol";
import {Pad3VanitySalt} from "../../script/Pad3VanitySalt.sol";
import {GangRouterDeployLib as R} from "../../script/GangRouterDeployLib.sol";
import {FlyUpgradeHarness, Pad3LiveUpgrade} from "./Pad3LiveUpgrade.sol";
import {Pad3VanityAcceptanceVault} from "../../script/Pad3VanityTestnetAcceptance.s.sol";
import {Pad3VanityAcceptanceHarness} from "../utils/Pad3VanityAcceptanceHarness.sol";
import {SetGangBaseVaultImpl} from "../../script/SetGangBaseVaultImpl.s.sol";

interface IWBNB {
    function deposit() external payable;
    function approve(address, uint256) external returns (bool);
}

/// @notice The opening base on a mainnet fork (docs/SPEC-BASE-VAULT-V2-2026-11-12.md §10): UpgradeGangLaunchpad3 run
///         against the live proxy (abcd already on) and its batch sent as the Safe (the upgrade alone: createWithBase
///         stays closed), then SetGangBaseVaultImpl and its one-call batch (§8's second batch), then an untaxed and a taxed base token created through createWithSalt, graduated to the
///         real Pancake V2 pair, and released in full. Agent IDs are mocked only on this fork. No broadcast.
/// @dev BSC_RPC_URL required (skipped if absent). Link the live PoolCheck:
///      --libraries src/launchpad-v2/PoolCheck.sol:PoolCheck:0xd2B159820749f178503E4faBCB18A7Ae4492bDb3
contract Pad3BaseUpgradeForkTest is Test {
    address internal constant PAD3 = 0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29;
    address internal constant PAD1 = 0x15CFD2dc8278Fb87a1783ef42111618E20874365;
    address internal constant ROUTER3 = 0xec9717E5C68b9F18fA76D3961C9Cd7e67b5E61e7;

    GangLaunchpad3 internal p = GangLaunchpad3(payable(PAD3));
    Pad3Module internal m = Pad3Module(payable(PAD3));
    uint256 internal _n;

    function test_fork_upgradeSetImplCreateGraduateRelease() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        // BSC_FORK_BLOCK pins the block: a pruned node drops the state of a fork that runs longer than about a minute
        uint256 forkBlock = vm.envOr("BSC_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);
        vm.mockCall(M.AGENT_ID_REGISTRY, abi.encodeWithSelector(IERC721.balanceOf.selector), abi.encode(uint256(1)));
        address factory = m.vanityDeployer();
        assertTrue(factory != address(0), "abcd is live on mainnet");

        // a token created before the upgrade, to trade after it
        address creator = _actor();
        IGangLaunchpad.TaxConfig memory untaxed;
        address old = _saltCreate(
            creator,
            factory,
            "Old",
            "OLD",
            address(0),
            0,
            abi.encodeWithSignature(
                "create(string,string,string,string,address,address,(uint16,uint16,uint16,address))",
                "Old",
                "OLD",
                "",
                "meta",
                address(0),
                address(0),
                untaxed
            )
        );

        // DeployGangBaseVault, then the upgrade script without PAD3_BASE_VAULT_IMPL (spec §8: first batch)
        address impl = address(new GangBaseVault(PAD3));
        (, uint256 key) = makeAddrAndKey("base fork deployer");
        vm.deal(vm.addr(key), 10 ether);
        _env(key, address(0));
        FlyUpgradeHarness upgrade = new FlyUpgradeHarness();
        vm.pauseGasMetering();
        upgrade.run();
        vm.resumeGasMetering();
        address next = upgrade.deployedImpl();
        assertTrue(next != address(0));

        // first batch: the upgrade alone; createWithBase stays closed
        vm.record();
        vm.prank(M.OWNER_SAFE);
        ProxyAdmin(R.adminOf(PAD3)).upgradeAndCall(ITransparentUpgradeableProxy(PAD3), next, "");
        (, bytes32[] memory writes) = vm.accesses(PAD3);
        assertEq(writes.length, 1, "only the implementation slot");
        assertEq(writes[0], R.IMPLEMENTATION_SLOT);
        assertEq(R.implementationOf(PAD3), next);
        assertEq(m.baseVaultImpl(), address(0), "closed after the upgrade");
        IGangLaunchpad.TaxConfig memory none;
        bytes memory closed = abi.encodeCall(
            Pad3Module.createWithBase, ("C", "C", "", "", none, 6 ether, IGangBasePad.BaseConfig(500, 30))
        );
        uint256 closedCost = m.previewBaseCost(6 ether, 500);
        vm.deal(creator, creator.balance + closedCost);
        vm.prank(creator, creator);
        vm.expectRevert(IGangBasePad.BaseNotOpen.selector);
        m.createWithSalt{value: closedCost}(bytes32(0), closed);

        // second batch, once the off-chain parts are live: SetGangBaseVaultImpl checks and prints it, the Safe sends it
        new SetGangBaseVaultImpl().run(PAD3, impl, 0, false);
        assertEq(m.baseVaultImpl(), address(0), "the script only prints on mainnet");
        vm.record();
        vm.prank(M.OWNER_SAFE);
        m.setBaseVaultImpl(impl);
        (, writes) = vm.accesses(PAD3);
        assertEq(writes.length, 1, "only the base namespace");
        assertEq(writes[0], Pad3BaseStore.SLOT);
        assertEq(m.baseVaultImpl(), impl);
        assertEq(m.vanityDeployer(), factory);
        assertEq(p.owner(), M.OWNER_SAFE);

        // the older token still trades
        _buy(_actor(), old, 0.05 ether);

        // direct createWithBase is refused (abcd on); through createWithSalt it works, untaxed and taxed
        uint256 cost = m.previewBaseCost(6 ether, 500);
        vm.prank(creator, creator);
        vm.expectRevert(Pad3Module.VanityContextRequired.selector);
        m.createWithBase{value: cost}("B", "B", "", "", untaxed, 6 ether, IGangBasePad.BaseConfig(500, 30));

        _base(creator, factory, 0, 500, 30);
        _base(_actor(), factory, 300, 1000, 90);
    }

    /// @notice The first-batch JSON written for signing (PAD3_FORK_BATCH), as written, over the deployed mainnet
    ///         contracts; then the seven create entries, and the second batch with the deployed vault implementation
    ///         (PAD3_BASE_VAULT_IMPL) checked by SetGangBaseVaultImpl. Skipped unless both are set.
    function test_fork_signedBatchThenOpenBase() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        string memory path = Pad3LiveUpgrade.batchFile();
        address impl = vm.envOr("PAD3_BASE_VAULT_IMPL", address(0));
        if (bytes(rpc).length == 0 || bytes(path).length == 0 || impl == address(0)) {
            vm.skip(true);
            return;
        }
        uint256 forkBlock = vm.envOr("BSC_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);
        vm.mockCall(M.AGENT_ID_REGISTRY, abi.encodeWithSelector(IERC721.balanceOf.selector), abi.encode(uint256(1)));
        address factory = m.vanityDeployer();

        (address creator, uint256 creatorKey) = makeAddrAndKey("base signed batch creator");
        vm.deal(creator, 10 ether);
        IGangLaunchpad.TaxConfig memory untaxed;
        address old = _saltCreate(
            creator,
            factory,
            "Old",
            "OLD",
            address(0),
            0,
            abi.encodeWithSignature(
                "create(string,string,string,string,address,address,(uint16,uint16,uint16,address))",
                "Old",
                "OLD",
                "",
                "meta",
                address(0),
                address(0),
                untaxed
            )
        );

        // first batch, as written: one upgradeAndCall, no value, no set-up call
        string memory json = vm.readFile(path);
        assertEq(vm.parseJsonString(json, ".chainId"), "56");
        assertEq(vm.parseJsonAddress(json, ".meta.createdFromSafeAddress"), M.OWNER_SAFE);
        assertFalse(vm.keyExistsJson(json, ".transactions[1]"), "expected the one-call upgrade batch");
        assertEq(vm.parseJsonAddress(json, ".transactions[0].to"), R.adminOf(PAD3));
        assertEq(vm.parseJsonString(json, ".transactions[0].value"), "0");
        vm.record();
        address next = Pad3LiveUpgrade.executeBatchFile(path, M.OWNER_SAFE);
        (, bytes32[] memory writes) = vm.accesses(PAD3);
        assertEq(writes.length, 1, "only the implementation slot");
        assertEq(writes[0], R.IMPLEMENTATION_SLOT);
        assertEq(
            vm.parseJsonBytes(json, ".transactions[0].data"),
            abi.encodeCall(ProxyAdmin.upgradeAndCall, (ITransparentUpgradeableProxy(PAD3), next, bytes("")))
        );
        assertEq(p.owner(), M.OWNER_SAFE);
        assertEq(m.vanityDeployer(), factory);
        assertEq(m.baseVaultImpl(), address(0), "closed after the upgrade");

        // closed until the second batch
        IGangLaunchpad.TaxConfig memory none;
        uint256 closedCost = m.previewBaseCost(6 ether, 500);
        vm.prank(creator, creator);
        vm.expectRevert(IGangBasePad.BaseNotOpen.selector);
        m.createWithSalt{value: closedCost}(
            bytes32(0),
            abi.encodeCall(
                Pad3Module.createWithBase, ("C", "C", "", "", none, 6 ether, IGangBasePad.BaseConfig(500, 30))
            )
        );

        // the seven existing create entries and the older tokens still work on the new implementation
        _buy(_actor(), old, 0.05 ether);
        vm.startPrank(M.OWNER_SAFE);
        address vault = address(new Pad3VanityAcceptanceVault());
        m.setVault(vault, true);
        m.setVaultCreator(vault, creator);
        vm.stopPrank();
        // address(0): the harness picks a live pre-abcd WBNB curve (`old` above is an abcd token)
        address[] memory tokens = new Pad3VanityAcceptanceHarness().accept(PAD3, creatorKey, vault, address(0));
        assertEq(tokens.length, 7);

        // second batch with the deployed vault implementation: the script's checks pass, then the Safe sends it
        new SetGangBaseVaultImpl().run(PAD3, impl, 0, false);
        assertEq(m.baseVaultImpl(), address(0), "the script only prints on mainnet");
        vm.prank(M.OWNER_SAFE);
        m.setBaseVaultImpl(impl);
        assertEq(m.baseVaultImpl(), impl);

        _base(creator, factory, 0, 500, 30);
        _base(_actor(), factory, 300, 1000, 90);
    }

    /// @notice The second-batch JSON written for signing (PAD3_FORK_BATCH2), as written, on the live pad after the first
    ///         batch: it writes only the base namespace, then base tokens are created, graduated and released, and the
    ///         older tokens still trade. Skipped unless PAD3_FORK_BATCH2 is set (and the live pad runs the base build).
    function test_fork_secondBatchOpensBase() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        string memory path = vm.envOr("PAD3_FORK_BATCH2", string(""));
        if (bytes(rpc).length == 0 || bytes(path).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 forkBlock = vm.envOr("BSC_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);
        vm.mockCall(M.AGENT_ID_REGISTRY, abi.encodeWithSelector(IERC721.balanceOf.selector), abi.encode(uint256(1)));
        address factory = m.vanityDeployer();
        assertEq(m.baseVaultImpl(), address(0), "still closed before the second batch");
        address implBefore = R.implementationOf(PAD3);

        (address creator, uint256 creatorKey) = makeAddrAndKey("base second batch creator");
        vm.deal(creator, 10 ether);

        string memory json = vm.readFile(path);
        assertEq(vm.parseJsonString(json, ".chainId"), "56");
        assertEq(vm.parseJsonAddress(json, ".meta.createdFromSafeAddress"), M.OWNER_SAFE);
        assertFalse(vm.keyExistsJson(json, ".transactions[1]"), "expected the one-call batch");
        assertEq(vm.parseJsonAddress(json, ".transactions[0].to"), PAD3);
        assertEq(vm.parseJsonString(json, ".transactions[0].value"), "0");
        address impl = abi.decode(_tail(vm.parseJsonBytes(json, ".transactions[0].data")), (address));
        assertEq(vm.parseJsonBytes(json, ".transactions[0].data"), abi.encodeCall(Pad3Module.setBaseVaultImpl, (impl)));
        assertEq(GangBaseVault(impl).pad(), PAD3);
        new SetGangBaseVaultImpl().run(PAD3, impl, 0, false);

        vm.record();
        Pad3LiveUpgrade.executeBatchFile(path, M.OWNER_SAFE);
        (, bytes32[] memory writes) = vm.accesses(PAD3);
        assertEq(writes.length, 1, "only the base namespace");
        assertEq(writes[0], Pad3BaseStore.SLOT);
        assertEq(m.baseVaultImpl(), impl);
        assertEq(R.implementationOf(PAD3), implBefore);
        assertEq(m.vanityDeployer(), factory);
        assertEq(p.owner(), M.OWNER_SAFE);

        // the existing entries still work, then base tokens through graduation and release
        vm.startPrank(M.OWNER_SAFE);
        address vault = address(new Pad3VanityAcceptanceVault());
        m.setVault(vault, true);
        m.setVaultCreator(vault, creator);
        vm.stopPrank();
        address[] memory tokens = new Pad3VanityAcceptanceHarness().accept(PAD3, creatorKey, vault, address(0));
        assertEq(tokens.length, 7);
        _base(creator, factory, 0, 500, 30);
        _base(_actor(), factory, 300, 1000, 90);
    }

    function _tail(bytes memory data) private pure returns (bytes memory out) {
        out = new bytes(data.length - 4);
        for (uint256 i; i < out.length; i++) {
            out[i] = data[i + 4];
        }
    }

    function _base(address creator, address factory, uint16 taxBps, uint16 bps, uint32 vestDays) internal {
        address handler = Pad3Impl.depsOf(p).taxHandler;
        IGangLaunchpad.TaxConfig memory tax = IGangLaunchpad.TaxConfig({
            buyTaxBps: taxBps, sellTaxBps: taxBps, dividendBps: 0, recipient: taxBps == 0 ? address(0) : creator
        });
        uint256 cost = m.previewBaseCost(6 ether, bps);
        string memory name = taxBps == 0 ? "Base" : "BaseTax";
        bytes memory data = abi.encodeCall(
            Pad3Module.createWithBase, (name, "BASE", "", "meta", tax, 6 ether, IGangBasePad.BaseConfig(bps, vestDays))
        );
        uint256 padBnb = PAD3.balance;
        uint256 bnbBefore = creator.balance;
        address t = _saltCreate(creator, factory, name, "BASE", taxBps == 0 ? address(0) : handler, taxBps, data, cost);
        assertEq(bnbBefore - creator.balance, cost);
        assertEq(PAD3.balance, padBnb, "no BNB left on the pad");
        assertEq(uint16(uint160(t)), 0xabcd);
        GangBaseVault v = GangBaseVault(m.baseVaultOf(t));
        uint256 base = m.baseOf(t);
        assertEq(base, (1_000_000_000 ether * uint256(bps)) / 10_000);
        assertEq(IERC20(t).balanceOf(address(v)), base);
        assertEq(v.creator(), creator);
        vm.expectRevert(GangBaseVault.NotGraduated.selector);
        v.release();

        // graduate to the real pair
        for (uint256 i; i < 200 && GangToken(t).locked(); i++) {
            _buy(_actor(), t, 0.2 ether);
        }
        assertFalse(GangToken(t).locked(), "graduated");
        (,,,,,,,,,, address pair,) = p.curves(t);
        assertEq(IERC20(t).balanceOf(pair), 200_000_000 ether);
        assertEq(IERC20(M.WBNB).balanceOf(pair), 6 ether);

        // release: start, a third, all
        v.release();
        vm.warp(v.startAt() + uint256(vestDays) * 1 days / 3);
        v.release();
        assertEq(IERC20(t).balanceOf(creator), base / 3);
        vm.warp(v.startAt() + uint256(vestDays) * 1 days);
        v.release();
        assertEq(IERC20(t).balanceOf(creator), base, "the whole base, untaxed");
        assertEq(IERC20(t).balanceOf(address(v)), 0);
    }

    function _saltCreate(
        address creator,
        address factory,
        string memory name,
        string memory symbol,
        address handler,
        uint16 taxBps,
        bytes memory data
    ) internal returns (address) {
        return _saltCreate(creator, factory, name, symbol, handler, taxBps, data, 0);
    }

    function _saltCreate(
        address creator,
        address factory,
        string memory name,
        string memory symbol,
        address handler,
        uint16 taxBps,
        bytes memory data,
        uint256 value
    ) internal returns (address t) {
        bytes32 hash = Pad3VanityDeployer(factory)
            .tokenInitCodeHash(name, symbol, "meta", handler, taxBps, taxBps, false);
        (bytes32 salt, address expected) = Pad3VanitySalt.find(factory, creator, hash);
        vm.prank(creator, creator);
        t = m.createWithSalt{value: value}(salt, data);
        assertEq(t, expected);
    }

    function _actor() internal returns (address a) {
        a = makeAddr(string.concat("base fork actor ", vm.toString(_n++)));
        vm.deal(a, 10 ether);
    }

    function _buy(address who, address t, uint256 amt) internal {
        vm.startPrank(who, who);
        IWBNB(M.WBNB).deposit{value: amt}();
        IWBNB(M.WBNB).approve(PAD3, amt);
        p.buy(t, amt, 0);
        vm.stopPrank();
    }

    function _env(uint256 key, address baseImpl) private {
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(key));
        vm.setEnv("GANG_PAD", vm.toString(PAD1));
        vm.setEnv("GANG_PAD3", vm.toString(PAD3));
        vm.setEnv("GANG_ROUTER3", vm.toString(ROUTER3));
        vm.setEnv("OWNER", vm.toString(M.OWNER_SAFE));
        vm.setEnv("KEEPER", vm.toString(M.KEEPER));
        vm.setEnv("GANG_GATEWAY", vm.toString(M.GANG_GATEWAY));
        vm.setEnv("GANG_PAD_REGISTRY", vm.toString(M.PAD_REGISTRY));
        vm.setEnv("PAD3_ABCD_DEPLOYER", vm.toString(address(0)));
        vm.setEnv("PAD3_BASE_VAULT_IMPL", vm.toString(baseImpl));
        vm.setEnv("PAD3_IMPL", vm.toString(address(0)));
        vm.setEnv("PAD3_GRAD_REWARD", "false");
        vm.setEnv("PAD3_INIT_CALL", "0x");
        vm.setEnv("PAD3_FLY_HANDLER", vm.toString(address(0)));
        vm.setEnv("PAD3_FLY_TOKEN_DEPLOYER", vm.toString(address(0)));
        vm.setEnv("PAD3_FLY_VAULT_CORE", vm.toString(address(0)));
        vm.setEnv("CALLERS", "");
        vm.setEnv("PAD3_NEW", "false");
        vm.setEnv("GANG_MAINNET_OK", "true");
        vm.setEnv("CUTOVER", "false");
        vm.setEnv("RECIPIENT", vm.toString(address(0)));
        vm.setEnv("TWAP_WINDOW", vm.toString(GangLaunchpad3(payable(PAD1)).twapWindow()));
    }
}
