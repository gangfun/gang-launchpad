// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GangSwapV2Fixture, IRouter} from "./GangSwapV2.t.sol";
import {IGangSwapV2Pair} from "../../src/v2/interfaces/IGangSwapV2.sol";
import {GangSwapMigrator} from "../../src/GangSwapMigrator.sol";
import {GangSwapBoost} from "../../src/GangSwapBoost.sol";
import {GangSwapFees} from "../../src/GangSwapFees.sol";
import {IGangSwapPair} from "../../src/interfaces/IGangSwap.sol";
import {MockBucket, MockToken, MockWBNB} from "../Mocks.sol";

contract GangSwapV2VersionsTest is GangSwapV2Fixture {
    struct Legacy {
        GangSwapBoost boost;
        GangSwapFees fees;
        IGangSwapPair pair;
        IRouter router;
        MockToken token;
    }

    function test_versionsKeepTradingAndSettlingTheirOwnPairs() public {
        Legacy memory first = _legacyPool();
        address quote = address(wbnb);
        address old = address(first.token);
        uint256 out = first.router.getAmountsOut(1 ether, _path(quote, old))[1];
        vm.deal(trader, 1 ether);
        vm.prank(trader);
        first.router.swapExactETHForTokens{value: 1 ether}(out, _path(quote, old), trader, block.timestamp);
        assertEq(first.token.balanceOf(trader), out);
        assertEq(pair.feeAccrued(), 0);

        _buy(trader, 1 ether);
        assertEq(first.pair.feeAccrued(), 0.01 ether);
        assertEq(pair.feeAccrued(), 0.01 ether);
        vm.expectRevert();
        router.getAmountsOut(1 ether, _path(quote, old));
        vm.expectRevert();
        first.router.getAmountsOut(1 ether, _path(quote, address(token)));

        (,,,, uint128 left) = boost.boosts(address(token));
        first.boost.step(old);
        (,,,, uint128 sameLeft) = boost.boosts(address(token));
        assertEq(sameLeft, left);
        (,,,, uint128 legacyLeft) = first.boost.boosts(old);
        boost.step(address(token));
        (,,,, uint128 sameLegacyLeft) = first.boost.boosts(old);
        assertEq(sameLegacyLeft, legacyLeft);

        vm.expectRevert(GangSwapFees.UnknownPair.selector);
        first.fees.collect(address(pair));
        vm.expectRevert();
        fees.collect(address(first.pair));

        uint256 pending = fees.pendingPlatform();
        uint256 legacyCharge = first.pair.feeAccrued();
        assertGt(legacyCharge, 0);
        assertEq(first.fees.collect(address(first.pair)), legacyCharge);
        assertEq(fees.pendingPlatform(), pending);
        _sell(holder, 10_000_000 ether);
        assertGt(fees.collect(address(pair)), 0);
        assertEq(first.fees.creatorFeeOf(old), legacyCharge * 7 / 10);
    }

    function _legacyPool() private returns (Legacy memory first) {
        uint256 n = vm.getNonce(address(this));
        address mAddr = vm.computeCreateAddress(address(this), n);
        address bAddr = vm.computeCreateAddress(address(this), n + 1);
        address fAddr = vm.computeCreateAddress(address(this), n + 2);
        address facAddr = vm.computeCreateAddress(address(this), n + 3);
        address quote = address(wbnb);
        GangSwapMigrator m = new GangSwapMigrator(address(this), facAddr, bAddr, quote);
        first.boost = new GangSwapBoost(mAddr, quote);
        first.fees = new GangSwapFees(facAddr, mAddr, address(bucket), quote);
        assertEq(deployCode("GangSwapPair.sol:GangSwapFactory", abi.encode(mAddr, fAddr)), facAddr);
        first.router = IRouter(deployCode("GangSwapRouter.sol:GangSwapRouter", abi.encode(facAddr, quote)));
        m.addLaunchpad(address(pad));
        bucket.setOperator(address(first.fees), true);

        first.token = new MockToken(address(this));
        first.token.transfer(address(pad), POOL_TOKENS);
        first.token.transfer(holder, SUPPLY - POOL_TOKENS);
        pad.setCreator(address(first.token), creator);
        vm.deal(address(this), G);
        wbnb.deposit{value: G}();
        wbnb.transfer(address(pad), G);
        first.pair = IGangSwapPair(pad.graduate(address(m), address(first.token), quote, POOL_TOKENS, G));
    }
}

interface IPad3 {
    function owner() external view returns (address);
    function platformBucket() external view returns (address);
    function agentIdRegistry() external view returns (address);
    function vanityDeployer() external view returns (address);
    function setGangSwapMigrator(address migrator) external;
    function gangSwapMigrator() external view returns (address);
    function gangSwapMigratorOf(address token) external view returns (address);
    function createWithSalt(bytes32 salt, bytes calldata data) external returns (address);
    function createGangSwap(string calldata, string calldata, string calldata, string calldata, uint256, address)
        external returns (address);
    function buy(address token, uint256 amount, uint256 minOut) external returns (uint256);
    function getTokenInfo(address token) external view returns (uint8, address, address, uint256, uint256);
}

interface IVanityDeployer {
    function tokenInitCodeHash(string calldata, string calldata, string calldata, address, uint16, uint16, bool)
        external view returns (bytes32);
}

interface IBucketOwner {
    function owner() external view returns (address);
}

contract GangSwapV2ForkTest is GangSwapV2Fixture {
    IPad3 private constant PAD = IPad3(0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29);
    address private constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    function setUp() public override {}

    function test_forkGraduatesThroughLivePadAndSettlesIntoLiveBucket() public {
        string memory rpc = vm.envOr("GANGSWAP_V2_FORK_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        uint256 forkBlock = vm.envOr("GANGSWAP_V2_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);
        assertEq(block.chainid, 56);

        wbnb = MockWBNB(payable(WBNB));
        bucket = MockBucket(PAD.platformBucket());
        _deploySet();
        migrator.addLaunchpad(address(PAD));
        vm.prank(IBucketOwner(address(bucket)).owner());
        bucket.setOperator(address(fees), true);
        vm.prank(PAD.owner());
        PAD.setGangSwapMigrator(address(migrator));
        assertEq(PAD.gangSwapMigrator(), address(migrator));

        address t = _createOnPad();
        _graduateOnPad(t);
        token = MockToken(t);
        assertEq(PAD.gangSwapMigratorOf(t), address(migrator));
        assertEq(factory.getPair(t, address(wbnb)), address(pair));
        assertEq(_runBoost(), 40);
        assertEq(pair.feeAccrued(), 0);
        assertApproxEqAbs(fees.pendingPlatform(), pair.virtualReserve() / 100, 40);

        uint256 bucketBefore = bucket.accruedQuote(address(wbnb));
        uint256 got = _buy(trader, 0.5 ether);
        uint256 want = pair.getAmountOut(got, t);
        assertEq(_sell(trader, got), want);
        uint256 expectedPlatform = fees.pendingPlatform() + pair.feeAccrued();
        _endWindow();
        vm.prank(creator);
        assertEq(fees.claim(t, creator), 0);
        assertTrue(fees.windowClosed(t));
        assertEq(bucket.accruedQuote(address(wbnb)) - bucketBefore, expectedPlatform);

        _buy(trader, 0.5 ether);
        uint256 fee = pair.feeAccrued();
        uint256 before = wbnb.balanceOf(creator);
        vm.prank(creator);
        assertEq(fees.claim(t, creator), fee * 7 / 10);
        assertEq(wbnb.balanceOf(creator) - before, fee * 7 / 10);
        _checkInvariants();
    }

    function _createOnPad() private returns (address t) {
        address deployer = PAD.vanityDeployer();
        string memory title = "GangSwap V2 fork";
        string memory symbol = "GSVF";
        bytes32 hash = IVanityDeployer(deployer).tokenInitCodeHash(title, symbol, "meta", address(0), 0, 0, false);
        (bytes32 salt, address predicted) = _findSalt(deployer, hash);
        _mockAgent(creator);
        bytes memory data = abi.encodeCall(
            IPad3.createGangSwap, (title, symbol, "", "meta", 6 ether, address(migrator))
        );
        vm.prank(creator, creator);
        t = PAD.createWithSalt(salt, data);
        assertEq(t, predicted);
    }

    function _graduateOnPad(address t) private {
        for (uint256 i; i < 100; i++) {
            (uint8 status,, address graduatingPair,,) = PAD.getTokenInfo(t);
            if (status == 4) {
                pair = IGangSwapV2Pair(graduatingPair);
                return;
            }
            assertEq(status, 1);
            address buyer = makeAddr(string.concat("fork buyer ", vm.toString(i)));
            _mockAgent(buyer);
            vm.deal(buyer, 0.2 ether);
            vm.startPrank(buyer, buyer);
            wbnb.deposit{value: 0.2 ether}();
            wbnb.approve(address(PAD), 0.2 ether);
            PAD.buy(t, 0.2 ether, 0);
            vm.stopPrank();
        }
        fail("graduation");
    }

    function _mockAgent(address who) private {
        vm.mockCall(PAD.agentIdRegistry(), abi.encodeCall(IERC20.balanceOf, (who)), abi.encode(uint256(1)));
    }

    function _findSalt(address deployer, bytes32 initHash) private view returns (bytes32 salt, address predicted) {
        for (uint256 i;; i++) {
            bytes32 bound = keccak256(abi.encode(creator, bytes32(i)));
            uint160 candidate = uint160(uint256(keccak256(abi.encodePacked(hex"ff", deployer, bound, initHash))));
            if (uint16(candidate) == 0xabcd && address(candidate).code.length == 0) {
                return (bytes32(i), address(candidate));
            }
        }
    }
}
