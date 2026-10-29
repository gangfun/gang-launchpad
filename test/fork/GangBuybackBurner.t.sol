// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GangBuybackBurner} from "../../src/buyback/GangBuybackBurner.sol";
import {IPlatformFeeBucket} from "../buyback/IPlatformFeeBucket.sol";
import {MainnetAddresses as M} from "../../config/MainnetAddresses.sol";

/// @dev BSC mainnet fork: swap the live buckets onto GangBuybackBurner and collect the GANG fees the old burner
///      could not. Runs only when BSC_RPC_URL is set: forge test --match-path 'test/fork/*'
contract GangBuybackBurnerForkTest is Test {
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address constant BUCKET_U = 0xe314efeB69229386baAd32034f4C06c196F6260c;
    address constant BUCKET_S = 0xad34653E20a33bE38340a837b0C67d85C899dEeC;

    GangBuybackBurner burner;

    function setUp() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        burner = new GangBuybackBurner(M.OWNER, M.PANCAKE_V2_ROUTER, M.PANCAKE_SMART_ROUTER, M.WBNB, M.GANG);
    }

    function _rewire(address bucket) internal returns (IPlatformFeeBucket b) {
        b = IPlatformFeeBucket(bucket);
        vm.prank(b.owner());
        b.setBurner(address(burner));
    }

    /// @dev Accrue `amount` of `quote` the way the pad does, on top of whatever the bucket already holds.
    function _accrue(IPlatformFeeBucket b, address quote, uint256 amount) internal {
        address pad = b.launchpad();
        deal(quote, pad, IERC20(quote).balanceOf(pad) + amount);
        vm.startPrank(pad);
        IERC20(quote).approve(address(b), amount);
        b.notifyAccrual(quote, amount);
        vm.stopPrank();
    }

    /// @dev Seeds 1,000 GANG so the test still bites once the live stuck balance has been collected.
    function _collectGang(address bucket) internal {
        IPlatformFeeBucket b = _rewire(bucket);
        _accrue(b, M.GANG, 1_000 ether);
        uint256 acc = b.accruedQuote(M.GANG);
        uint256 toBurn = (acc * b.BUYBACK_BPS()) / b.BPS();
        uint256 dead0 = IERC20(M.GANG).balanceOf(DEAD);
        uint256 vault0 = IERC20(M.GANG).balanceOf(b.feeVault());

        vm.prank(b.keeper());
        b.collectPlatform(M.GANG, toBurn);

        console.log("GANG burned (e18)", toBurn / 1e18);
        assertEq(IERC20(M.GANG).balanceOf(DEAD) - dead0, toBurn);
        assertEq(IERC20(M.GANG).balanceOf(b.feeVault()) - vault0, acc - toBurn);
        assertEq(b.accruedQuote(M.GANG), 0);
    }

    function test_collectGang_v2Bucket() public {
        if (address(burner) == address(0)) return;
        _collectGang(M.PLATFORM_FEE_BUCKET_V2);
    }

    function test_collectGang_uBucket() public {
        if (address(burner) == address(0)) return;
        _collectGang(BUCKET_U);
    }

    function test_collectGang_sBucket() public {
        if (address(burner) == address(0)) return;
        _collectGang(BUCKET_S);
    }

    /// @dev Non-GANG quotes still go through Pancake V2 after the rewire.
    function test_wbnbQuote_stillSwaps() public {
        if (address(burner) == address(0)) return;
        IPlatformFeeBucket b = _rewire(M.PLATFORM_FEE_BUCKET_V2);
        _accrue(b, M.WBNB, 1 ether);

        uint256 dead0 = IERC20(M.GANG).balanceOf(DEAD);
        vm.prank(b.keeper());
        b.collectPlatform(M.WBNB, 1);
        assertGt(IERC20(M.GANG).balanceOf(DEAD), dead0);
    }
}
