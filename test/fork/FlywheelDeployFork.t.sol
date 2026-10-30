// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SharedDividendVault} from "../../src/common/SharedDividendVault.sol";
import {SharedPlatformFeeBucket} from "../../src/common/SharedPlatformFeeBucket.sol";
import {SharedMigrator} from "../../src/common/SharedMigrator.sol";
import {GangPadRegistry} from "../../src/gang/GangPadRegistry.sol";
import {MintTokenDeployer} from "../../src/flywheel/MintTokenDeployer.sol";
import {FlywheelTaxHandler} from "../../src/flywheel/FlywheelTaxHandler.sol";
import {GangFlywheelPad} from "../../src/flywheel/GangFlywheelPad.sol";
import {IFlywheelPad} from "../../src/flywheel/interfaces/IFlywheelPad.sol";
import {MockAgentId} from "../mocks/MockAgentId.sol";

interface IGangPadSharedFork {
    function quoteRegistry() external view returns (address);
    function dividendVault() external view returns (address);
    function platformBucket() external view returns (address);
    function migrator() external view returns (address);
}

/// @notice The V2 mainnet deployment rehearsed on a fork, as DeployFlywheelV2 + the Safe batch would do it: a new
///         FlywheelTaxHandler and the V2 pad join the live shared contracts (read from the live GangLaunchpad) and the
///         live MintTokenDeployer; the platform Safe lists the pad on the deployer, vault, migrator, fee bucket and the
///         live GangPadRegistry, `setMigrator` opens the pad, and the live registry then finds a new token as kind 3,
///         next to the live V1 pad's. A fresh Agent ID registry stands in for the soulbound one (the deployment itself
///         sets the live registry). Skipped unless BSC_RPC_URL is set. Does not broadcast.
contract FlywheelDeployForkTest is Test {
    address constant GANG_PAD = 0x15CFD2dc8278Fb87a1783ef42111618E20874365;
    address constant PAD_REGISTRY = 0x4fF77D4d9ac080939a24E1B805206bA094C44e5C;
    address constant SAFE = 0x2866369F7acEFC9760bdE7779362fae5cD68B41E;
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant V2_FACTORY = 0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73;
    address constant V2_ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;
    address constant TOKEN_DEPLOYER = 0x2C95228AfA6eF211371A87f480aBa0f5c0Da072E;
    address constant V1_PAD = 0x631e66560F4FAE4e486B65349edE48189E48B029;

    function test_fork_mainnetDeploymentRehearsal() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        IGangPadSharedFork live = IGangPadSharedFork(GANG_PAD);
        address vault = live.dividendVault();
        address bucket = live.platformBucket();
        address migrator = live.migrator();
        // the shared contracts and the registry belong to the Safe: only its batch can list the new pad
        assertEq(Ownable(vault).owner(), SAFE);
        assertEq(Ownable(migrator).owner(), SAFE);
        assertEq(Ownable(bucket).owner(), SAFE);
        assertEq(GangPadRegistry(PAD_REGISTRY).owner(), SAFE);
        MintTokenDeployer d = MintTokenDeployer(TOKEN_DEPLOYER);
        assertEq(d.owner(), SAFE);
        assertTrue(d.launchpads(V1_PAD));

        // phase 1 (deployer): a new handler and the V2 pad on the live MintTokenDeployer
        address me = makeAddr("deployer");
        vm.startPrank(me);
        FlywheelTaxHandler h = new FlywheelTaxHandler(me, vault, bucket, V2_ROUTER);
        GangFlywheelPad p =
            new GangFlywheelPad(me, live.quoteRegistry(), vault, bucket, address(h), address(d), WBNB, V2_FACTORY);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, me));
        d.setLaunchpad(address(p), true); // the Safe's
        h.setLaunchpad(address(p));
        h.setKeeper(me);
        MockAgentId agents = new MockAgentId();
        p.setAgentGate(true, address(agents));
        vm.expectRevert(IFlywheelPad.WrongMigrator.selector);
        p.setMigrator(migrator); // not listed by the migrator yet
        vm.stopPrank();

        // the Safe batch (V1's seven listings, then the deployer)
        vm.startPrank(SAFE);
        SharedDividendVault(vault).setLaunchpad(address(p), true);
        SharedDividendVault(vault).setMinimumShareBalance(address(p), 1_000 ether);
        SharedDividendVault(vault).setOperator(address(h), address(p));
        SharedMigrator(migrator).addLaunchpad(address(p));
        SharedPlatformFeeBucket(bucket).setOperator(address(p), true);
        SharedPlatformFeeBucket(bucket).setOperator(address(h), true);
        GangPadRegistry(PAD_REGISTRY).addPad(address(p)); // the live registry accepts a second kind-3 pad
        d.setLaunchpad(address(p), true);
        vm.stopPrank();

        // phase 2 (deployer): open the pad
        vm.prank(me);
        p.setMigrator(migrator);

        // a creator launches a sale; the live registry finds the token
        address creator = makeAddr("creator");
        agents.mint(creator, 1);
        vm.deal(creator, 10 ether);
        vm.startPrank(creator);
        (bool ok,) = WBNB.call{value: 1 ether}(abi.encodeWithSignature("deposit()"));
        require(ok);
        IERC20(WBNB).approve(address(p), type(uint256).max);
        IFlywheelPad.FlyConfig memory c = IFlywheelPad.FlyConfig({
            raiseBnb: 20 ether,
            baseQuota: 10,
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
            postMint: true,
            tierMode: 1,
            stepBps: 0,
            stepShares: 0,
            maxMulX100: 0,
            supplyCapMul: 100,
            guardBps: 1_500,
            twapWindow: 900
        });
        address t = p.create(["Rehearsal", "RHS", "logo", "meta"], address(0), address(0), c, 1);
        vm.stopPrank();
        (address found, uint8 kind) = GangPadRegistry(PAD_REGISTRY).lookup(t);
        assertEq(found, address(p));
        assertEq(kind, 3);
        (uint16 g, uint32 w) = p.postRulesOf(t);
        assertEq(g, 1_500);
        assertEq(w, 900);
        // the live pads' tokens are still found as before, and both kind-3 pads are listed
        assertTrue(GangPadRegistry(PAD_REGISTRY).isPad(GANG_PAD));
        assertTrue(GangPadRegistry(PAD_REGISTRY).isPad(V1_PAD));
        assertTrue(GangPadRegistry(PAD_REGISTRY).isPad(address(p)));
    }
}
