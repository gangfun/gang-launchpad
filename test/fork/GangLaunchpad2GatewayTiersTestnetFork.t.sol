// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IGangPad} from "../../src/gang/interfaces/IGangPad.sol";
import {IGangGateway} from "../../src/router/interfaces/IGangGateway.sol";

interface IMintableQuoteGw {
    function mintUnlimited(address to, uint256 amount) external;
}

/// @notice The live testnet GangGateway (the aggregator entry, a registry reader) on GangLaunchpad 2.0's picked
///         graduation targets: for the tier fixtures of `script/GangLaunchpad2TierMatrixTestnet.s.sol` (half-raised
///         test-quote tokens and WBNB tokens, one per tier 6 / 9 / 12 / 15 BNB), `getTokenInfo` reports the token's own
///         amount left, `trySell` / `tryBuy` match the executed `sellToken` / `buyTokenAMAP` to the wei, and a buy past
///         the amount left is cut at it, graduates the token and refunds the rest. Needs BSC_TESTNET_RPC_URL (skipped
///         without it); the fork is the live head.
contract GangLaunchpad2GatewayTiersTestnetForkTest is Test {
    IGangPad constant PAD = IGangPad(0xb14d415f70D7F99f0D93Bd3BF76e0D6b38b53B3E);
    IGangGateway constant GW = IGangGateway(0xb325dde51129C592E443ecbEE1E219D14C66e091);
    address constant TEST_QUOTE = 0x02B3dE73aF2c1F99c7EFbDb65bcB960AACF4CF1c;
    /// @dev The deploy wallet: owns the testnet 2.0 (wallet cap off for one buyer to graduate) and holds an Agent ID.
    address constant ME = 0xCa8e63434072B40d3dFE6f5e7Fd885F93A3200b6;
    uint8 constant STATUS_CURVE = 1;
    uint8 constant STATUS_POOL = 2;

    function _fork() internal returns (bool) {
        string memory rpc = vm.envOr("BSC_TESTNET_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return false;
        vm.createSelectFork(rpc);
        vm.prank(ME);
        PAD.setWalletCapEnabled(false);
        assertEq(Ownable(address(PAD)).owner(), ME);
        return true;
    }

    function test_fork_gatewayOnEveryTier() public {
        if (!_fork()) {
            vm.skip(true);
            return;
        }
        address[4] memory half = [
            0x8f41028364F8825dCc3de3D8f0985C05738F952d,
            0x6b7De715FbB37F23b138C76751487631F1895f30,
            0x6a51cA4ab52c7A7e8c62f840E10a2D820ef83E1b,
            0x2700Fcd3f335Ffa0084997Abb481f874898EacE8
        ];
        address[4] memory wbnb = [
            0x70aaD0e5eF7ccE2b5512f01028D347FC6FcBe568,
            0xf17B6BaE39F2681C66D4580FC41F2ED6f43f1111,
            0xfb9Cd64F6ea99755fb2F573EDA0B5b3590C84daC,
            0x61dDDd669b97516Fe0F14d582e0fDd2D022cf633
        ];
        uint256[4] memory tiers = PAD.GRAD_BNB_TIERS();
        for (uint256 i; i < 4; i++) {
            assertEq(PAD.gradTargetOf(half[i]), tiers[i]);
            assertEq(PAD.gradTargetOf(wbnb[i]), tiers[i]);
            _sellThenBuyPast(half[i], false);
            _sellThenBuyPast(wbnb[i], true);
        }
    }

    function _left(address t) internal view returns (uint256) {
        (,, uint128 realQuote,, uint128 gradAmt,,,,,,,) = PAD.curves(t);
        return gradAmt - realQuote;
    }

    function _sellThenBuyPast(address t, bool isWbnb) internal {
        (uint8 status, address quote,, uint256 feeBps, uint256 left) = GW.getTokenInfo(t);
        assertEq(status, STATUS_CURVE, "on the curve");
        assertEq(feeBps, 100, "1% protocol fee");
        assertEq(left, _left(t), "the token's own amount left");
        assertEq(quote, isWbnb ? address(0) : TEST_QUOTE);

        // a sell through the gateway: trySell to the wei
        uint256 held = IERC20(t).balanceOf(ME);
        if (held > 1) {
            uint256 amount = held / 10;
            (,, uint256 funds,) = GW.trySell(t, amount);
            uint256 before = isWbnb ? ME.balance : IERC20(TEST_QUOTE).balanceOf(ME);
            vm.startPrank(ME, ME);
            IERC20(t).approve(address(GW), amount);
            uint256 got = GW.sellToken(0, t, ME, amount, 0, 0, address(0));
            vm.stopPrank();
            assertEq(got, funds, "sell matches trySell");
            assertEq((isWbnb ? ME.balance : IERC20(TEST_QUOTE).balanceOf(ME)) - before, funds);
            (,,,, left) = GW.getTokenInfo(t);
            assertEq(left, _left(t));
        }

        // a buy of twice the amount left: cut at it, graduated, the rest refunded
        uint256 funds2 = left * 2;
        (,, uint256 estAmount, uint256 estCost,, uint256 msgValue, uint256 approval,) = GW.tryBuy(t, ME, 0, funds2);
        assertGt(estAmount, 0);
        assertLt(estCost, funds2, "cut at the amount left");
        uint256 q0;
        if (isWbnb) {
            assertEq(msgValue, funds2);
            vm.deal(ME, ME.balance + funds2);
            q0 = IERC20(PAD.wbnb()).balanceOf(ME);
        } else {
            assertEq(approval, funds2);
            vm.prank(ME);
            IMintableQuoteGw(TEST_QUOTE).mintUnlimited(ME, funds2);
            vm.prank(ME);
            IERC20(TEST_QUOTE).approve(address(GW), funds2);
            q0 = IERC20(TEST_QUOTE).balanceOf(ME);
        }
        uint256 t0 = IERC20(t).balanceOf(ME);
        vm.prank(ME, ME);
        (uint256 out, uint256 used) = GW.buyTokenAMAP{value: isWbnb ? funds2 : 0}(t, ME, funds2, estAmount);
        assertEq(out, estAmount, "buy matches tryBuy (tokens)");
        assertEq(used, estCost, "buy matches tryBuy (cost)");
        assertEq(IERC20(t).balanceOf(ME) - t0, estAmount);
        if (!isWbnb) assertEq(q0 - IERC20(TEST_QUOTE).balanceOf(ME), estCost, "the rest refunded");
        else assertEq(IERC20(PAD.wbnb()).balanceOf(ME) - q0, funds2 - estCost, "the rest refunded as WBNB");
        (,,,,,, bool graduated,,,, address pair,) = PAD.curves(t);
        assertTrue(graduated && pair != address(0), "graduated at its own target");
        (status,,,,) = GW.getTokenInfo(t);
        assertEq(status, STATUS_POOL, "gateway: pool");
    }
}
