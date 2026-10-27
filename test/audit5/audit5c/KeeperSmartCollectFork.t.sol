// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DeployGang} from "../../../script/DeployGang.s.sol";
import {SharedPlatformFeeBucket as PlatformFeeBucket} from "../../../src/common/SharedPlatformFeeBucket.sol";

interface ISmartRouter {
    function swapExactTokensForTokens(uint256 amountIn, uint256 amountOutMin, address[] calldata path, address to)
        external
        payable
        returns (uint256);
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory);
}

/// @notice Internal audit 5 C-F2 (regression): the hot keeper could send the 80% buyback leg to itself through
///         collectPlatformSmart (keeper-supplied router calldata). The shared bucket the deploy scripts make has no
///         such function: the same call now fails and nothing moves.
contract KeeperSmartCollectForkTest is Test {
    address constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address constant GANG = 0x0c6302401aa5325C2E36F170f52C00B1d220B405;
    address constant SMART = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;
    address constant KEEPER = 0xB6f1F1BFb92476Abb0998B425dE0deC5F927cFc7;
    uint256 constant PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

    function test_fork_keeperCanNoLongerStealBuybackLeg() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(PK));
        vm.setEnv("OWNER", vm.toString(address(0xBEEF)));
        DeployGang.Stack memory s = new DeployGang().run();
        PlatformFeeBucket bucket = PlatformFeeBucket(s.bucket);
        address burner = address(bucket.burner());

        // 10 WBNB of platform fees accrued by an operator (e.g. the pad)
        deal(WBNB, s.pad, 10 ether);
        vm.startPrank(s.pad);
        IERC20(WBNB).approve(s.bucket, 10 ether);
        bucket.notifyAccrual(WBNB, 10 ether);
        vm.stopPrank();

        uint256 toBuyback = 8 ether;
        uint256 dust = 1e12;
        address[] memory steal = new address[](2);
        (steal[0], steal[1]) = (WBNB, USDT);
        address[] memory burn = new address[](2);
        (burn[0], burn[1]) = (WBNB, GANG);
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(ISmartRouter.swapExactTokensForTokens, (toBuyback - dust, 0, steal, KEEPER));
        calls[1] = abi.encodeCall(ISmartRouter.swapExactTokensForTokens, (dust, 0, burn, burner));
        bytes memory data = abi.encodeCall(ISmartRouter.multicall, (calls));

        uint256 k0 = IERC20(USDT).balanceOf(KEEPER);
        vm.prank(KEEPER);
        (bool ok,) = s.bucket
        .call(abi.encodeWithSignature("collectPlatformSmart(address,uint256,bytes)", WBNB, uint256(1), data));
        assertFalse(ok, "no collectPlatformSmart on the shared bucket");
        assertEq(IERC20(USDT).balanceOf(KEEPER), k0, "nothing to the keeper");
        assertEq(bucket.accruedQuote(WBNB), 10 ether, "the fees wait for the fixed-path collect");
    }
}
