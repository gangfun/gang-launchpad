// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {LaunchpadV3TestnetRefs as T} from "../config/LaunchpadV3DeployRefs.sol";
import {MockSPCXB} from "../src/launchpad-v2/mocks/MockSPCXB.sol";
import {IPancakeRouter02} from "../src/launchpad-v2/interfaces/IPancake.sol";
import {LaunchpadV3} from "../src/launchpad-v3/LaunchpadV3.sol";
import {TaxRouterV3} from "../src/launchpad-v3/TaxRouterV3.sol";
import {TaxLaunchTokenV3} from "../src/launchpad-v3/TaxLaunchTokenV3.sol";
import {PostGradTaxHandlerV3} from "../src/launchpad-v3/PostGradTaxHandlerV3.sol";
import {ILaunchpadV3} from "../src/launchpad-v3/interfaces/ILaunchpadV3.sol";
import {TestnetBlacklistQuote} from "../src/launchpad-v3/mocks/TestnetBlacklistQuote.sol";

interface ITestnetAgentId {
    function balanceOf(address) external view returns (uint256);
    function register() external returns (uint256);
}

/// @title LaunchpadV3TestnetE2E — the partner flow on BSC testnet with the stack from DeployLaunchpadV3
/// @notice A: buy 2% / sell 2%, dividend 0, tax recipient = the listed demo treasury, in the test quote:
///         curve buy + sell (TaxPaid), then 80 throwaway agents fill the curve (graduation), then a pool buy + sell
///         that leave tax on the handler for the keeper (keeper-tax-process.sh in gangfun-server).
///         B: same tax in the blacklist quote with the treasury blocked: the curve buy books TaxOwed; the treasury is
///         unblocked afterwards so the keeper's release (or anyone) can push it.
/// @dev TESTNET ONLY. Resumable: TOKEN_A / TOKEN_B skip their create; minters that already hold A are skipped; the
///      fill stops once A graduates. Minter keys derive from DEPLOYER_PRIVATE_KEY (recoverable, worthless off testnet).
///      Env: DEPLOYER_PRIVATE_KEY, PAD, BLACKLIST_QUOTE; optional TEST_QUOTE, RECIPIENT, TOKEN_A, TOKEN_B,
///      GAS_PER_MINTER (wei). Router deadlines are a day out (fixed at simulation time; broadcasting takes minutes).
contract LaunchpadV3TestnetE2E is Script {
    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    uint256 internal constant MAX_MINTERS = 120;
    address internal constant TESTNET_DEMO_TREASURY = address(uint160(uint256(keccak256("gang-v3-testnet-treasury"))));

    error WrongChain(uint256 chainId);
    error Check(string what);

    LaunchpadV3 internal pad;
    MockSPCXB internal quote;
    TestnetBlacklistQuote internal blq;
    address internal treasury;
    uint256 internal deployerPk;
    address internal deployer;

    function run() external {
        if (block.chainid != 97) revert WrongChain(block.chainid);
        deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        deployer = vm.addr(deployerPk);
        pad = LaunchpadV3(vm.envAddress("PAD"));
        quote = MockSPCXB(vm.envOr("TEST_QUOTE", T.TEST_QUOTE));
        blq = TestnetBlacklistQuote(vm.envAddress("BLACKLIST_QUOTE"));
        treasury = vm.envOr("RECIPIENT", TESTNET_DEMO_TREASURY);
        TaxRouterV3 router = TaxRouterV3(address(pad.router()));

        // create / curve trades are Agent-only: a fresh deployer registers a testnet Agent ID first
        ITestnetAgentId agentId = ITestnetAgentId(address(pad.agentIdRegistry()));
        if (agentId.balanceOf(deployer) == 0) {
            vm.startBroadcast(deployerPk);
            agentId.register();
            vm.stopBroadcast();
        }

        // ---- A: create + curve buy / sell
        address a = vm.envOr("TOKEN_A", address(0));
        if (a == address(0)) a = _createA();
        console.log("token A", a);

        // ---- B: failed push → owed
        address b = vm.envOr("TOKEN_B", address(0));
        if (b == address(0)) b = _createB();
        console.log("token B", b, "owed", router.owedOf(b));

        // ---- A: fill the curve with agents (1% cap each) until it graduates
        _graduate(a, vm.envOr("GAS_PER_MINTER", uint256(0.00006 ether)));
        address pair = TaxLaunchTokenV3(a).pair();
        console.log("pair", pair);

        // ---- A: pool buy + sell, leaving tax on the handler for the keeper
        PostGradTaxHandlerV3 handler = PostGradTaxHandlerV3(pad.taxHandler());
        vm.startBroadcast(deployerPk);
        quote.mint(deployer, 1 ether);
        _swap(address(quote), a, 0.5 ether);
        _swap(a, address(quote), IERC20(a).balanceOf(deployer) / 2);
        vm.stopBroadcast();
        console.log("handler accruedTax", handler.accruedTax(a), "platform part", handler.accruedPlatformTax(a));
        console.log("treasury quote", quote.balanceOf(treasury), "treasury tBUSD", blq.balanceOf(treasury));
    }

    function _createA() internal returns (address a) {
        vm.startBroadcast(deployerPk);
        quote.mint(deployer, 1 ether);
        quote.approve(address(pad), type(uint256).max);
        a = pad.create(
            "V3 Tax Test",
            "V3T",
            "",
            address(quote),
            address(0),
            ILaunchpadV3.TaxConfig({buyTaxBps: 200, sellTaxBps: 200, dividendBps: 0, recipient: treasury})
        );
        uint256 before = quote.balanceOf(treasury);
        pad.buy(a, 0.05 ether, 0);
        uint256 bal = IERC20(a).balanceOf(deployer);
        IERC20(a).approve(address(pad), bal);
        pad.sell(a, bal / 2, 0);
        vm.stopBroadcast();
        if (quote.balanceOf(treasury) <= before) revert Check("treasury got nothing from curve trades");
    }

    function _createB() internal returns (address b) {
        vm.startBroadcast(deployerPk);
        blq.mint(deployer, 1 ether);
        blq.approve(address(pad), type(uint256).max);
        b = pad.create(
            "V3 Owed Test",
            "V3O",
            "",
            address(blq),
            address(0),
            ILaunchpadV3.TaxConfig({buyTaxBps: 200, sellTaxBps: 200, dividendBps: 0, recipient: treasury})
        );
        blq.setBlocked(treasury, true);
        pad.buy(b, 0.05 ether, 0); // the push to the treasury fails: booked as owed, the buy goes through
        blq.setBlocked(treasury, false); // the keeper (or anyone) can now release it
        vm.stopBroadcast();
        if (TaxRouterV3(address(pad.router())).owedOf(b) == 0) revert Check("nothing owed on B");
    }

    function _graduate(address a, uint256 gasPerMinter) internal {
        for (uint256 i = 0; i < MAX_MINTERS; i++) {
            if (_graduated(a)) return;
            uint256 pk = _minterKey(i);
            address m = vm.addr(pk);
            if (IERC20(a).balanceOf(m) > 0) continue; // bought on an earlier run
            // the buy that graduates also builds the pair: the last few get more gas
            bool nearEnd = pad.graduationRemaining(a) < 3 ether;
            vm.startBroadcast(deployerPk);
            payable(m).transfer(nearEnd ? gasPerMinter * 10 : gasPerMinter);
            vm.stopBroadcast();
            vm.startBroadcast(pk);
            if (ITestnetAgentId(address(pad.agentIdRegistry())).balanceOf(m) == 0) {
                ITestnetAgentId(address(pad.agentIdRegistry())).register();
            }
            quote.mint(m, 1 ether);
            quote.approve(address(pad), type(uint256).max);
            pad.buy(a, 1 ether, 0); // truncated to the 1% cap, the rest refunded
            vm.stopBroadcast();
        }
        if (!_graduated(a)) revert Check("not graduated");
    }

    function _graduated(address a) internal view returns (bool g) {
        (,,,,,, g,,,,,) = pad.curves(a);
    }

    function _swap(address tokenIn, address tokenOut, uint256 amountIn) internal {
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
        IERC20(tokenIn).approve(T.PANCAKE_V2_ROUTER, amountIn);
        IPancakeRouter02(T.PANCAKE_V2_ROUTER)
            .swapExactTokensForTokensSupportingFeeOnTransferTokens(
                amountIn, 0, path, deployer, block.timestamp + 1 days
            );
    }

    function _minterKey(uint256 i) internal view returns (uint256) {
        return uint256(keccak256(abi.encode("gang-v3-testnet", deployerPk, i))) % (SECP256K1_N - 1) + 1;
    }
}
