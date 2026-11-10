// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GangTestnetRefs as T} from "../config/GangDeployRefs.sol";
import {MockSPCXB} from "../src/launchpad-v2/mocks/MockSPCXB.sol";
import {IGangPad} from "../src/gang/interfaces/IGangPad.sol";
import {IGangLaunchpad} from "../src/gang/interfaces/IGangLaunchpad.sol";
import {GangCallBond} from "../src/gang/GangCallBond.sol";
import {IGangCallBond} from "../src/gang/interfaces/IGangCallBond.sol";

interface ICallBondAgentIdLite {
    function balanceOf(address) external view returns (uint256);
    function register() external returns (uint256);
}

interface ICallBondWbnbLite {
    function deposit() external payable;
}

/// @title CallBondTestnetAcceptance — GangCallBond on BSC testnet, in five runs (the contract's own clocks between them)
/// @notice Wallets: the deployer (reporter, owner), caller C, followers F1 / F2 and the settler, all keys derived from
///         DEPLOYER_PRIVATE_KEY (the settler's is CALLBOND_SETTLER of the deploy).
///         1. `setup()`: the deployer creates three 3.0 curve tokens (T1, T2 in WBNB, T3 in the test quote); C buys
///            each (those buy txs are C's calls).
///         2. `bonds()` (NOTE1..3 = those buy tx hashes): C bonds T1 (A), T2 (B), T3 (D), all its balance, 48 h;
///            F1 / F2 buy T1 with a follow reference to NOTE1 in the calldata; C sells half of T1 and the deployer
///            reports A (1% / 50% burnt / 49% pool, to the wei); C sells 1 wei of T3 and reports D itself (51% burnt).
///         3. `roots()` (≥ ROOT_DELAY after the report): the settler posts a root paying C, the owner vetoes it; the
///            settler posts the real one (F1 / F2 pro rata to what they paid, 90% of the pool).
///         4. `claims()` (≥ DISPUTE after the root, ≥ 48 h after B): claims for F1 / F2 sent by the deployer, the
///            caller's leaf refused, the remainder burnt; `requestSettle(B)`.
///         5. `settleB()` (≥ 1 h later): B returns to C, to the wei.
///         `report()` prints the state; `sweep()` returns the wallets' leftover gas money.
/// @dev TESTNET ONLY. Env: DEPLOYER_PRIVATE_KEY, CALL_BOND; T1, T2, T3 and NOTE1..3 from run 2 on. Broadcast with
///      --legacy --with-gas-price 100000000 --slow.
contract CallBondTestnetAcceptance is Script {
    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    uint256 internal constant BOND = 0.01 ether;
    uint256 internal constant CALL_BUY = 0.002 ether;
    uint256 internal constant F1_BUY = 0.002 ether;
    uint256 internal constant F2_BUY = 0.004 ether;
    uint64 internal constant DURATION = 48 hours;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    bytes5 internal constant FOLLOW_MAGIC = 0x67616e6703; // "gang" 03

    error WrongChain(uint256 chainId);
    error Check(string what);

    uint256 internal deployerPk;
    address internal deployer;
    IGangPad internal pad;
    GangCallBond internal cb;

    // ---------------------------------------------------------------- runs
    function setup() external {
        _init();
        uint256 cPk = _key("caller");
        _ready(cPk, 0.05 ether);
        vm.startBroadcast(deployerPk);
        address t1 = _create("CallBond A", "CBA", T.WBNB);
        address t2 = _create("CallBond B", "CBB", T.WBNB);
        address t3 = _create("CallBond D", "CBD", T.TEST_QUOTE);
        vm.stopBroadcast();

        address c = vm.addr(cPk);
        vm.startBroadcast(cPk);
        ICallBondWbnbLite(T.WBNB).deposit{value: 2 * CALL_BUY + 2 * BOND}();
        IERC20(T.WBNB).approve(address(pad), type(uint256).max);
        IERC20(T.WBNB).approve(address(cb), type(uint256).max);
        MockSPCXB(T.TEST_QUOTE).mint(c, CALL_BUY + BOND);
        IERC20(T.TEST_QUOTE).approve(address(pad), type(uint256).max);
        IERC20(T.TEST_QUOTE).approve(address(cb), type(uint256).max);
        pad.buy(t1, CALL_BUY, 0);
        pad.buy(t2, CALL_BUY, 0);
        pad.buy(t3, CALL_BUY, 0);
        vm.stopBroadcast();
        console.log("T1", t1);
        console.log("T2", t2);
        console.log("T3", t3);
        console.log("caller", c);
        console.log("NOTE1..3 = the caller's last three buy txs in this run's broadcast file");
    }

    function bonds() external {
        _init();
        (address t1, address t2, address t3) = _tokens();
        uint256 cPk = _key("caller");
        address c = vm.addr(cPk);
        if (cb.bondCount() != 0) revert Check("fresh contract expected");

        vm.startBroadcast(cPk);
        uint256 a = cb.post(t1, vm.envBytes32("NOTE1"), BOND, IERC20(t1).balanceOf(c), DURATION);
        uint256 b = cb.post(t2, vm.envBytes32("NOTE2"), BOND, IERC20(t2).balanceOf(c), DURATION);
        uint256 d = cb.post(t3, vm.envBytes32("NOTE3"), BOND, IERC20(t3).balanceOf(c), DURATION);
        vm.stopBroadcast();
        if (a != 1 || b != 2 || d != 3) revert Check("ids");
        if (IERC20(T.WBNB).balanceOf(address(cb)) != 2 * BOND) revert Check("WBNB pulled");
        if (IERC20(T.TEST_QUOTE).balanceOf(address(cb)) != BOND) revert Check("test quote pulled");

        // followers buy T1 naming the call
        _followBuy(_key("f1"), t1, F1_BUY);
        _followBuy(_key("f2"), t1, F2_BUY);

        // C breaks A; the deployer reports
        vm.startBroadcast(cPk);
        IERC20(t1).approve(address(pad), type(uint256).max);
        pad.sell(t1, IERC20(t1).balanceOf(c) / 2, 0);
        vm.stopBroadcast();
        uint256 r0 = IERC20(T.WBNB).balanceOf(deployer);
        uint256 dead0 = IERC20(T.WBNB).balanceOf(DEAD);
        vm.startBroadcast(deployerPk);
        cb.report(a);
        vm.stopBroadcast();
        IGangCallBond.Bond memory ba = cb.bondOf(a);
        if (IERC20(T.WBNB).balanceOf(deployer) - r0 != BOND / 100) revert Check("reporter 1%");
        if (IERC20(T.WBNB).balanceOf(DEAD) - dead0 != BOND / 2) revert Check("50% burnt");
        if (ba.pool != BOND - BOND / 100 - BOND / 2) revert Check("49% pool");
        if (uint8(ba.state) != uint8(IGangCallBond.State.Reported)) revert Check("A reported");

        // C breaks D and reports itself: the 1% burns too
        uint256 qDead0 = IERC20(T.TEST_QUOTE).balanceOf(DEAD);
        vm.startBroadcast(cPk);
        IERC20(t3).approve(address(pad), type(uint256).max);
        pad.sell(t3, 1, 0);
        cb.report(d);
        vm.stopBroadcast();
        if (IERC20(T.TEST_QUOTE).balanceOf(DEAD) - qDead0 != BOND / 2 + BOND / 100) revert Check("51% burnt");
        if (cb.bondOf(d).pool != BOND - BOND / 2 - BOND / 100) revert Check("D pool");
        console.log("A reported at block", ba.reportedBlock);
        console.log("roots from", uint256(ba.reportedAt) + cb.ROOT_DELAY());
    }

    function roots() external {
        _init();
        uint256 sPk = _key("settler");
        if (vm.addr(sPk) != cb.settler()) revert Check("settler key");
        _prefund(vm.addr(sPk), 0.002 ether);
        address c = vm.addr(_key("caller"));
        IGangCallBond.Bond memory ba = cb.bondOf(1);

        // a root paying the caller: the owner vetoes it
        bytes32 bad = cb.leaf(1, c, ba.pool);
        vm.startBroadcast(sPk);
        cb.postRoot(1, bad, ba.pool);
        vm.stopBroadcast();
        vm.startBroadcast(deployerPk);
        cb.veto(1);
        vm.stopBroadcast();
        if (cb.bondOf(1).root != bytes32(0)) revert Check("vetoed");

        (uint256 x1, uint256 x2) = _payouts(ba.pool);
        vm.startBroadcast(sPk);
        cb.postRoot(1, _root(x1, x2), x1 + x2);
        vm.stopBroadcast();
        IGangCallBond.Bond memory after_ = cb.bondOf(1);
        if (after_.total != x1 + x2 || after_.vetoAt == 0) revert Check("root posted");
        console.log("claims from", uint256(after_.rootAt) + cb.DISPUTE());
        console.log("F1 / F2", x1, x2);
    }

    function claims() external {
        _init();
        address f1 = vm.addr(_key("f1"));
        address f2 = vm.addr(_key("f2"));
        address c = vm.addr(_key("caller"));
        IGangCallBond.Bond memory ba = cb.bondOf(1);
        (uint256 x1, uint256 x2) = _payouts(ba.pool);
        bytes32 l1 = cb.leaf(1, f1, x1);
        bytes32 l2 = cb.leaf(1, f2, x2);
        bytes32[] memory p1 = new bytes32[](1);
        bytes32[] memory p2 = new bytes32[](1);
        p1[0] = l2;
        p2[0] = l1;
        uint256 b1 = IERC20(T.WBNB).balanceOf(f1);
        uint256 b2 = IERC20(T.WBNB).balanceOf(f2);
        uint256 dead0 = IERC20(T.WBNB).balanceOf(DEAD);

        vm.startBroadcast(deployerPk);
        cb.claim(1, f1, x1, p1);
        cb.claim(1, f2, x2, p2);
        cb.burnRemainder(1);
        cb.requestSettle(2);
        vm.stopBroadcast();
        if (IERC20(T.WBNB).balanceOf(f1) - b1 != x1) revert Check("F1 paid");
        if (IERC20(T.WBNB).balanceOf(f2) - b2 != x2) revert Check("F2 paid");
        if (IERC20(T.WBNB).balanceOf(DEAD) - dead0 != ba.pool - x1 - x2) revert Check("remainder burnt");
        if (IERC20(T.WBNB).balanceOf(address(cb)) != BOND) revert Check("only B left");
        try cb.claim(1, c, 1, new bytes32[](0)) {
            revert Check("caller claim");
        } catch {}
        console.log("settle B from", uint256(cb.bondOf(2).settleAt));
    }

    function settleB() external {
        _init();
        address c = vm.addr(_key("caller"));
        uint256 c0 = IERC20(T.WBNB).balanceOf(c);
        vm.startBroadcast(deployerPk);
        cb.settle(2);
        vm.stopBroadcast();
        if (IERC20(T.WBNB).balanceOf(c) - c0 != BOND) revert Check("B returned");
        if (uint8(cb.bondOf(2).state) != uint8(IGangCallBond.State.Settled)) revert Check("B settled");
        if (IERC20(T.WBNB).balanceOf(address(cb)) != 0) revert Check("empty");
        console.log("B returned", BOND);
    }

    function report() external view {
        GangCallBond c = GangCallBond(vm.envAddress("CALL_BOND"));
        for (uint256 id = 1; id <= c.bondCount(); id++) {
            IGangCallBond.Bond memory b = c.bondOf(id);
            console.log("bond", id, uint256(uint8(b.state)));
            console.log("  token / quote", b.token, b.quote);
            console.log("  amount / hold", b.amount, b.hold);
            console.log("  deadline / settleAt", uint256(b.deadline), uint256(b.settleAt));
            console.log("  pool / total / spent", b.pool, b.total, b.spent);
            console.log("  rootAt / vetoAt", uint256(b.rootAt), uint256(b.vetoAt));
        }
        console.log("WBNB held", IERC20(T.WBNB).balanceOf(address(c)));
        console.log("test quote held", IERC20(T.TEST_QUOTE).balanceOf(address(c)));
    }

    /// @notice Return each wallet's leftover gas money to the deployer.
    function sweep() external {
        _init();
        string[4] memory labels = ["caller", "f1", "f2", "settler"];
        uint256 fee = 21_000 * 0.1 gwei;
        for (uint256 i; i < 4; i++) {
            uint256 pk = _key(labels[i]);
            address w = vm.addr(pk);
            if (w.balance <= 2 * fee) continue;
            vm.startBroadcast(pk);
            (bool ok,) = payable(deployer).call{value: w.balance - 2 * fee}("");
            vm.stopBroadcast();
            if (!ok) revert Check("sweep");
        }
    }

    /// @notice The settler address for the deploy (CALLBOND_SETTLER).
    function settlerAddress() external view returns (address) {
        return vm.addr(
            uint256(keccak256(abi.encode("gang-callbond-testnet", vm.envUint("DEPLOYER_PRIVATE_KEY"), "settler")))
                % (SECP256K1_N - 1) + 1
        );
    }

    // ---------------------------------------------------------------- helpers
    function _init() internal {
        if (block.chainid != 97) revert WrongChain(block.chainid);
        deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        deployer = vm.addr(deployerPk);
        cb = GangCallBond(vm.envAddress("CALL_BOND"));
        pad = IGangPad(cb.pad());
    }

    function _tokens() internal view returns (address, address, address) {
        return (vm.envAddress("T1"), vm.envAddress("T2"), vm.envAddress("T3"));
    }

    function _create(string memory name, string memory symbol, address quote) internal returns (address) {
        return pad.create(
            name,
            symbol,
            "",
            "",
            quote,
            address(0),
            IGangLaunchpad.TaxConfig({buyTaxBps: 0, sellTaxBps: 0, dividendBps: 0, recipient: address(0)})
        );
    }

    /// @dev A buy whose calldata ends with the follow reference ("gang" 03 noteTx), as `gang follow` sends it.
    function _followBuy(uint256 pk, address t, uint256 funds) internal {
        _ready(pk, funds + 0.003 ether);
        bytes memory data =
            abi.encodePacked(abi.encodeCall(IGangPad.buy, (t, funds, 0)), FOLLOW_MAGIC, vm.envBytes32("NOTE1"));
        vm.startBroadcast(pk);
        ICallBondWbnbLite(T.WBNB).deposit{value: funds}();
        IERC20(T.WBNB).approve(address(pad), funds);
        (bool ok,) = address(pad).call(data);
        vm.stopBroadcast();
        if (!ok) revert Check("follow buy");
    }

    /// @dev Pro rata to what F1 / F2 paid, 90% of the pool (the rest tests the remainder burn).
    function _payouts(uint256 pool) internal pure returns (uint256 x1, uint256 x2) {
        uint256 total = (pool * 9) / 10;
        x1 = (total * F1_BUY) / (F1_BUY + F2_BUY);
        x2 = (total * F2_BUY) / (F1_BUY + F2_BUY);
    }

    function _root(uint256 x1, uint256 x2) internal view returns (bytes32) {
        bytes32 a = cb.leaf(1, vm.addr(_key("f1")), x1);
        bytes32 b = cb.leaf(1, vm.addr(_key("f2")), x2);
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    /// @dev Funded with gas money and registered as an Agent.
    function _ready(uint256 pk, uint256 funds) internal {
        address w = vm.addr(pk);
        _prefund(w, funds);
        ICallBondAgentIdLite agentId = ICallBondAgentIdLite(pad.agentIdRegistry());
        if (agentId.balanceOf(w) > 0) return;
        vm.startBroadcast(pk);
        agentId.register();
        vm.stopBroadcast();
    }

    function _prefund(address to, uint256 amount) internal {
        if (to.balance >= amount) return;
        vm.startBroadcast(deployerPk);
        (bool ok,) = payable(to).call{value: amount - to.balance}("");
        vm.stopBroadcast();
        if (!ok) revert Check("prefund");
    }

    function _key(string memory label) internal view returns (uint256) {
        return uint256(keccak256(abi.encode("gang-callbond-testnet", deployerPk, label))) % (SECP256K1_N - 1) + 1;
    }
}
