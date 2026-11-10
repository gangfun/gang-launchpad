// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {GangMainnetRefs as M} from "../../config/GangDeployRefs.sol";
import {IGangPad} from "../../src/gang/interfaces/IGangPad.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {GangLaunchpad3} from "../../src/gang/GangLaunchpad3.sol";
import {GangCallBond} from "../../src/gang/GangCallBond.sol";
import {IGangCallBond} from "../../src/gang/interfaces/IGangCallBond.sol";
import {DeployGangCallBond} from "../../script/DeployGangCallBond.s.sol";

/// @notice GangCallBond on a BSC mainnet fork against the live GangLaunchpad 3.0: deployed by its script (Safe owner, a
///         separate settler); WBNB- and USDT-quoted curve tokens made on the live pad; a call bonded, followed with the
///         follow reference in calldata, broken, reported (1% / 50% / 49% to the wei), paid through a root after the
///         veto window; another kept through graduation into a real Pancake pair and settled (the flash-swap check on
///         the live pair). Agent IDs are mocked and the wallet cap is off. No broadcast.
/// @dev Needs BSC_RPC_URL (skipped without it). Run each test alone (the script reads process-wide env vars).
contract CallBondMainnetForkTest is Test {
    address constant PAD3 = 0x2bEbED4be8c8F46C17776C71D7a6A45dbC5CAB29;
    address constant SAFE = 0x2866369F7acEFC9760bdE7779362fae5cD68B41E;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    address constant USD1 = 0x8d0D000Ee44948FC98c9B98A4FA4921476f08B0d;

    IGangPad p = IGangPad(PAD3);
    GangCallBond cb;
    address settlerAddr = makeAddr("callbond-fork-settler");
    address dev = makeAddr("callbond-fork-dev");
    address caller = makeAddr("callbond-fork-caller");
    address follower = makeAddr("callbond-fork-follower");
    address reporter = makeAddr("callbond-fork-reporter");
    uint256 internal _n;

    function _live() internal returns (bool) {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return false;
        }
        vm.createSelectFork(rpc);
        vm.mockCall(M.AGENT_ID_REGISTRY, abi.encodeWithSelector(IERC721.balanceOf.selector), abi.encode(uint256(1)));
        vm.prank(SAFE);
        GangLaunchpad3(payable(PAD3)).setWalletCapEnabled(false);
        uint256 pk = uint256(keccak256("call bond fork test: throwaway, never funded"));
        vm.deal(vm.addr(pk), 1 ether);
        vm.setEnv("DEPLOYER_PRIVATE_KEY", vm.toString(pk));
        vm.setEnv("GANG_PAD3", vm.toString(PAD3));
        vm.setEnv("GANG_PAD2", vm.toString(address(0)));
        vm.setEnv("CALLBOND_OWNER", vm.toString(SAFE));
        vm.setEnv("CALLBOND_SETTLER", vm.toString(settlerAddr));
        vm.setEnv("GANG_CALL_BOND", vm.toString(address(0)));
        cb = new DeployGangCallBond().run();
        assertEq(cb.pad(), PAD3);
        assertEq(cb.wbnb(), M.WBNB);
        assertEq(cb.quote1(), M.USDT);
        assertEq(cb.quote2(), USDC);
        assertEq(cb.quote3(), USD1);
        assertEq(cb.owner(), SAFE);
        assertEq(cb.settler(), settlerAddr);
        return true;
    }

    function _next(uint256 dt) internal {
        vm.warp(vm.getBlockTimestamp() + dt);
        vm.roll(vm.getBlockNumber() + 2);
    }

    function _token(address quote, address refPool) internal returns (address t) {
        vm.prank(dev, dev);
        t = p.create("Call", "CALL", "l", "m", quote, refPool, IGangLaunchpad.TaxConfig(0, 0, 0, address(0)));
        assertEq(p.kindOf(t), 1);
    }

    function _buy(address who, address t, address quote, uint256 amount, bytes memory suffix) internal {
        deal(quote, who, IERC20(quote).balanceOf(who) + amount);
        vm.startPrank(who, who);
        IERC20(quote).approve(PAD3, type(uint256).max);
        (bool ok,) = PAD3.call(abi.encodePacked(abi.encodeCall(IGangPad.buy, (t, amount, 0)), suffix));
        vm.stopPrank();
        assertTrue(ok, "buy");
    }

    function _post(address t, address quote, uint256 amount, uint64 duration) internal returns (uint256 id) {
        deal(quote, caller, IERC20(quote).balanceOf(caller) + amount);
        uint256 hold = IERC20(t).balanceOf(caller);
        vm.startPrank(caller, caller);
        IERC20(quote).approve(address(cb), amount);
        id = cb.post(t, keccak256(abi.encode("note", t)), amount, hold, duration);
        vm.stopPrank();
    }

    function test_fork_brokenCall_reportAndPayout_wbnb() public {
        if (!_live()) return;
        address t = _token(M.WBNB, address(0));
        _buy(caller, t, M.WBNB, 0.5 ether, "");
        uint256 id = _post(t, M.WBNB, 1 ether, 48 hours);
        // a follower buys with the follow reference at the end of its calldata, as gang follow sends it
        _buy(follower, t, M.WBNB, 0.3 ether, abi.encodePacked(bytes5(0x67616e6703), keccak256(abi.encode("note", t))));

        // the caller sells half on the live curve: broken
        vm.startPrank(caller, caller);
        IERC20(t).approve(PAD3, type(uint256).max);
        p.sell(t, IERC20(t).balanceOf(caller) / 2, 0);
        vm.stopPrank();
        uint256 dead0 = IERC20(M.WBNB).balanceOf(DEAD);
        vm.prank(reporter);
        cb.report(id);
        assertEq(IERC20(M.WBNB).balanceOf(reporter), 0.01 ether, "reporter 1%");
        assertEq(IERC20(M.WBNB).balanceOf(DEAD) - dead0, 0.5 ether, "50% burnt");
        assertEq(cb.bondOf(id).pool, 0.49 ether, "49% pool");

        // the settler posts a one-leaf root after the root delay; the Safe lets the dispute window pass; the follower claims
        _next(1 hours + 10 minutes);
        uint256 pay = 0.2 ether;
        bytes32 leaf = cb.leaf(id, follower, pay);
        vm.prank(settlerAddr);
        cb.postRoot(id, leaf, pay);
        _next(2 days);
        cb.claim(id, follower, pay, new bytes32[](0));
        assertEq(IERC20(M.WBNB).balanceOf(follower), pay, "paid");
        cb.burnRemainder(id);
        assertEq(IERC20(M.WBNB).balanceOf(address(cb)), 0, "nothing left");
    }

    function test_fork_keptCall_settlesAfterGraduation_usdt() public {
        if (!_live()) return;
        address t = _token(M.USDT, M.USDT_REF_POOL);
        _buy(caller, t, M.USDT, 300 ether, "");
        uint256 id = _post(t, M.USDT, 100 ether, 48 hours);
        assertEq(cb.bondOf(id).quote, M.USDT);

        // the curve fills: graduation into a real Pancake pair
        bool graduated;
        address pair;
        uint256 per = p.gradAmtOf(t) / 3 + 1;
        for (uint256 i; i < 10 && !graduated; i++) {
            address b = makeAddr(string.concat("callbond-fork-buyer-", vm.toString(_n++)));
            deal(M.USDT, b, per);
            vm.startPrank(b, b);
            IERC20(M.USDT).approve(PAD3, type(uint256).max);
            try p.buy(t, per, 0) {} catch {}
            vm.stopPrank();
            (,,,,,, graduated,,,, pair,) = p.curves(t);
        }
        assertTrue(graduated, "graduated");
        assertGt(pair.code.length, 0, "a real pair");

        _next(48 hours);
        cb.requestSettle(id);
        _next(1 hours);
        uint256 c0 = IERC20(M.USDT).balanceOf(caller);
        cb.settle(id);
        assertEq(IERC20(M.USDT).balanceOf(caller) - c0, 100 ether, "bond back");
        assertEq(uint8(cb.bondOf(id).state), uint8(IGangCallBond.State.Settled));
    }

    function test_fork_refusesWhatItDoesNotCover() public {
        if (!_live()) return;
        // a graduated live token: the first graduated curve token found on the pad
        uint256 n = p.tokenCount();
        address grad;
        for (uint256 i = n; i > 0 && grad == address(0); i--) {
            address t = p.allTokens(i - 1);
            if (p.kindOf(t) != 1) continue;
            (,,,,,, bool g,,,,,) = p.curves(t);
            if (g) grad = t;
        }
        if (grad != address(0)) {
            vm.prank(caller);
            vm.expectRevert(IGangCallBond.AlreadyGraduated.selector);
            cb.post(grad, bytes32(uint256(1)), 1 ether, 1, 48 hours);
        }
        // not a token of this pad
        vm.prank(caller);
        vm.expectRevert(IGangCallBond.NotCurveToken.selector);
        cb.post(M.USDT, bytes32(uint256(1)), 1 ether, 1, 48 hours);
        // renounce stays disabled for the Safe
        vm.prank(SAFE);
        vm.expectRevert(IGangCallBond.RenounceDisabled.selector);
        cb.renounceOwnership();
    }
}
