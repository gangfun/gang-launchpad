// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FairMintTestnetRefs as T} from "../config/FairMintDeployRefs.sol";
import {SharedDividendVault} from "../src/common/SharedDividendVault.sol";
import {PlatformFeeBucket} from "../src/launchpad-v2/PlatformFeeBucket.sol";
import {MockSPCXB} from "../src/launchpad-v2/mocks/MockSPCXB.sol";
import {IPancakeRouter02} from "../src/launchpad-v2/interfaces/IPancake.sol";
import {FairMintPad} from "../src/fair-mint/FairMintPad.sol";
import {GangToken} from "../src/gang/GangToken.sol";
import {HolderRewardHandler} from "../src/fair-mint/HolderRewardHandler.sol";
import {TestnetAgentId} from "../src/fair-mint/mocks/TestnetAgentId.sol";

/// @title FairMintTestnetE2E — one full sale on BSC testnet with the stack from DeployFairMint
/// @notice Deployer creates a sale in the mock quote, 100 throwaway minters fill it (Pancake pair is created),
///         then: a buy, a minter selling below the line, keeper `process`, and a holder claim.
/// @dev TESTNET ONLY. Minter keys are derived from DEPLOYER_PRIVATE_KEY (recoverable, worthless off testnet).
///      Env: DEPLOYER_PRIVATE_KEY (also the handler keeper), PAD, TEST_QUOTE; optional GAS_PER_MINTER (wei),
///      TOKEN (an already-launched sale: skip create + fill and run only the trading steps).
///      Router deadlines are a day out: they are fixed at simulation time and the ~500 broadcasts take minutes.
///      Needs ≈ 0.03 tBNB at 0.1 gwei (≈ 0.0055 gas, the rest prefunds the minters).
contract FairMintTestnetE2E is Script {
    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    uint256 internal constant MINTERS = 100;
    uint256 internal constant TPS = 50_000 ether;

    error WrongChain(uint256 chainId);
    error Check(string what);

    FairMintPad internal pad;
    MockSPCXB internal quote;
    TestnetAgentId internal agentId;
    uint256 internal deployerPk;

    function run() external {
        if (block.chainid != 97) revert WrongChain(block.chainid);
        deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        pad = FairMintPad(vm.envAddress("PAD"));
        quote = MockSPCXB(vm.envAddress("TEST_QUOTE"));
        agentId = TestnetAgentId(address(pad.agentIdRegistry()));
        uint256 gasPerMinter = vm.envOr("GAS_PER_MINTER", uint256(0.0002 ether));
        address deployer = vm.addr(deployerPk);

        // 1–2. create + fill, unless TOKEN names a sale that already launched (resume after a failed trading step)
        address token = vm.envOr("TOKEN", address(0));
        if (token == address(0)) token = _createAndFill(deployer, gasPerMinter);
        if (pad.status(token) != FairMintPad.Status.Launched) revert Check("not launched");
        address pair = GangToken(token).pair();
        console.log("pair", pair);

        // 3. trading: deployer buys, minter 0 sells 55% (out), keeper processes, minter 5 claims
        HolderRewardHandler handler = HolderRewardHandler(pad.taxHandler());
        address m0 = _minterAddr(0);
        vm.startBroadcast(deployerPk);
        _swap(address(quote), token, 3 ether, deployer);
        vm.stopBroadcast();

        vm.startBroadcast(_minterKey(0));
        _swap(token, address(quote), 55 * TPS, m0);
        vm.stopBroadcast();
        if (!handler.isOut(token, m0)) revert Check("minter 0 not out");

        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = address(quote);
        // the buys' tax was already sold by minter 0's sell (swap-back); the keeper sells one chunk of what is left
        uint256 chunk = handler.maxChunk(token);
        uint256 quoted = IPancakeRouter02(T.PANCAKE_V2_ROUTER).getAmountsOut(chunk, path)[1];
        vm.startBroadcast(deployerPk);
        uint256 out = handler.process(token, chunk, (quoted * 99) / 100);
        vm.stopBroadcast();

        SharedDividendVault vault = pad.dividendVault();
        address m5 = _minterAddr(5);
        uint256 pend = vault.pending(token, m5);
        if (pend == 0) revert Check("no reward for minter 5");
        vm.startBroadcast(_minterKey(5));
        vault.claim(token);
        vm.stopBroadcast();

        console.log("tax processed (quote wei)", out);
        console.log("minter 5 claimed (quote wei)", pend);
        console.log(
            "bucket accrued (quote wei)", PlatformFeeBucket(address(pad.platformBucket())).accruedQuote(address(quote))
        );
    }

    function _createAndFill(address deployer, uint256 gasPerMinter) internal returns (address token) {
        // 1. deployer: Agent ID, quote, create (dev mints 1 share)
        (, uint256 price) = pad.previewCreate(address(quote), address(0), 15 ether);
        vm.startBroadcast(deployerPk);
        if (agentId.balanceOf(deployer) == 0) agentId.register();
        quote.mint(deployer, 10 ether);
        quote.approve(address(pad), type(uint256).max);
        FairMintPad.MintConfig memory cfg =
            FairMintPad.MintConfig({raiseBnb: 15 ether, capBps: 50, holdBps: 5000, mintFeeBps: 100, exitFeeBps: 100});
        token = pad.create("Fair Testnet", "FAIRT", "", "", address(quote), address(0), cfg, 1);
        for (uint256 i = 0; i < MINTERS; i++) {
            // the filling mint also builds the pair: give the last minter 10x gas
            payable(_minterAddr(i)).transfer(i == MINTERS - 1 ? gasPerMinter * 10 : gasPerMinter);
        }
        vm.stopBroadcast();
        console.log("token", token);

        // 2. 100 minters × 100 shares (the last one is truncated to 99) → launch
        for (uint256 i = 0; i < MINTERS; i++) {
            uint256 pk = _minterKey(i);
            vm.startBroadcast(pk);
            // the Agent ID registry is shared by every testnet stack: minters from an earlier run are registered
            if (agentId.balanceOf(vm.addr(pk)) == 0) agentId.register();
            quote.mint(vm.addr(pk), (price * 100 * 101) / 100);
            quote.approve(address(pad), type(uint256).max);
            pad.mint(token, 100, 1);
            vm.stopBroadcast();
        }
    }

    function _swap(address tokenIn, address tokenOut, uint256 amountIn, address to) internal {
        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = tokenOut;
        IERC20(tokenIn).approve(T.PANCAKE_V2_ROUTER, amountIn);
        IPancakeRouter02(T.PANCAKE_V2_ROUTER)
            .swapExactTokensForTokensSupportingFeeOnTransferTokens(amountIn, 0, path, to, block.timestamp + 1 days);
    }

    function _minterKey(uint256 i) internal view returns (uint256) {
        return uint256(keccak256(abi.encode("gang-fair-mint-testnet", deployerPk, i))) % (SECP256K1_N - 1) + 1;
    }

    function _minterAddr(uint256 i) internal view returns (address) {
        return vm.addr(_minterKey(i));
    }
}
