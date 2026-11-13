// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {RoutedBuybackBurner, IV3SwapRouter} from "../../src/buyback/RoutedBuybackBurner.sol";
import {IPlatformFeeBucket} from "./IPlatformFeeBucket.sol";
import {MockPancakeRouter} from "../mocks/MockPancakeRouter.sol";

contract RbbToken is ERC20 {
    constructor() ERC20("Mock", "MOCK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Pancake V3 exactInput stand-in: pulls `spendBps` of amountIn of the path's first token, pays amountIn × rate of
///      its last token to `payTo` (the recipient unless overridden).
contract MockV3Router {
    uint256 public rate = 2;
    uint256 public spendBps = 10_000;
    address public payTo;
    bytes public lastPath;

    function setRate(uint256 r) external {
        rate = r;
    }

    function setSpendBps(uint256 b) external {
        spendBps = b;
    }

    function setPayTo(address a) external {
        payTo = a;
    }

    function exactInput(IV3SwapRouter.ExactInputParams calldata p) external payable returns (uint256 out) {
        bytes calldata path = p.path;
        address tokenIn = address(bytes20(path[0:20]));
        address tokenOut = address(bytes20(path[path.length - 20:]));
        lastPath = path;
        IERC20(tokenIn).transferFrom(msg.sender, address(this), (p.amountIn * spendBps) / 10_000);
        out = p.amountIn * rate;
        require(out >= p.amountOutMinimum, "v3 min");
        IERC20(tokenOut).transfer(payTo == address(0) ? p.recipient : payTo, out);
    }
}

contract RoutedBuybackBurnerTest is Test {
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address owner = makeAddr("owner");
    address keeper = makeAddr("keeper");
    address feeVault = makeAddr("feeVault");
    address caller = makeAddr("caller");

    RbbToken gang;
    RbbToken wbnb;
    RbbToken usdt;
    RbbToken stock;
    MockPancakeRouter router;
    MockV3Router v3;
    RoutedBuybackBurner burner;

    function setUp() public {
        gang = new RbbToken();
        wbnb = new RbbToken();
        usdt = new RbbToken();
        stock = new RbbToken();
        router = new MockPancakeRouter(address(wbnb));
        router.setRate(3); // 1 WBNB (or V2 quote) → 3 GANG
        v3 = new MockV3Router(); // 1 stock → 2 WBNB
        burner = new RoutedBuybackBurner(owner, address(router), address(v3), address(wbnb), address(gang));
        gang.mint(address(router), 1_000_000 ether);
        wbnb.mint(address(v3), 1_000_000 ether);
    }

    function _fund(RbbToken token, uint256 amount) internal {
        token.mint(caller, amount);
        vm.prank(caller);
        token.approve(address(burner), amount);
    }

    function _route() internal view returns (bytes memory) {
        return abi.encodePacked(address(stock), uint24(2500), address(usdt), uint24(100), address(wbnb));
    }

    function _setRoute() internal {
        vm.prank(owner);
        burner.setV3Route(address(stock), _route());
    }

    // ---------------------------------------------------------------- V3 route

    function test_v3Route_swapsToWbnbThenGang_andBurns() public {
        _setRoute();
        _fund(stock, 10 ether);
        vm.expectEmit(address(burner));
        emit RoutedBuybackBurner.BuybackBurned(address(stock), 10 ether, 60 ether);
        vm.prank(caller);
        burner.buybackAndBurn(address(stock), 10 ether, 60 ether);

        assertEq(gang.balanceOf(DEAD), 60 ether); // 10 stock → 20 WBNB (V3) → 60 GANG (V2)
        assertEq(v3.lastPath(), _route());
        assertEq(stock.balanceOf(address(burner)), 0);
        assertEq(wbnb.balanceOf(address(burner)), 0);
        assertEq(gang.balanceOf(address(burner)), 0);
        assertEq(stock.allowance(address(burner), address(v3)), 0);
        assertEq(burner.quoteReceived(address(stock)), 10 ether);
    }

    function test_v3Route_minGangOutBindsWholeRoute() public {
        _setRoute();
        _fund(stock, 10 ether);
        vm.prank(caller);
        vm.expectRevert(bytes("slippage")); // the V2 leg is held to minGangOut
        burner.buybackAndBurn(address(stock), 10 ether, 60 ether + 1);
    }

    function test_v3Route_partialSpend_reverts() public {
        _setRoute();
        v3.setSpendBps(9_000);
        _fund(stock, 10 ether);
        vm.prank(caller);
        vm.expectRevert(RoutedBuybackBurner.IncompleteQuoteSpend.selector);
        burner.buybackAndBurn(address(stock), 10 ether, 1);
    }

    /// @dev A router that pays someone else leaves the burner with no WBNB: the V2 leg then cannot meet minGangOut.
    function test_v3Route_outputElsewhere_reverts() public {
        _setRoute();
        v3.setPayTo(keeper);
        _fund(stock, 10 ether);
        vm.prank(caller);
        vm.expectRevert(bytes("slippage"));
        burner.buybackAndBurn(address(stock), 10 ether, 1);
    }

    function test_clearRoute_backToV2() public {
        _setRoute();
        vm.prank(owner);
        burner.setV3Route(address(stock), "");
        assertEq(burner.v3Route(address(stock)).length, 0);

        _fund(stock, 10 ether);
        vm.prank(caller);
        burner.buybackAndBurn(address(stock), 10 ether, 30 ether); // V2 mock: 10 × 3
        assertEq(gang.balanceOf(DEAD), 30 ether);
        assertEq(v3.lastPath().length, 0);
    }

    // ---------------------------------------------------------------- V2 path and GANG, as GangBuybackBurner

    function test_noRoute_v2Path() public {
        _fund(stock, 10 ether);
        vm.prank(caller);
        burner.buybackAndBurn(address(stock), 10 ether, 30 ether);
        assertEq(gang.balanceOf(DEAD), 30 ether);
    }

    function test_wbnb_v2Path() public {
        _fund(wbnb, 1 ether);
        vm.prank(caller);
        burner.buybackAndBurn(address(wbnb), 1 ether, 3 ether);
        assertEq(gang.balanceOf(DEAD), 3 ether);
    }

    function test_gangQuote_burnsWithoutSwap() public {
        router.setRevertSwap(true);
        _fund(gang, 100 ether);
        vm.prank(caller);
        burner.buybackAndBurn(address(gang), 100 ether, 100 ether);
        assertEq(gang.balanceOf(DEAD), 100 ether);
    }

    function test_gangQuote_strayGangStaysPut() public {
        gang.mint(address(burner), 5 ether);
        _fund(gang, 100 ether);
        vm.prank(caller);
        vm.expectRevert(RoutedBuybackBurner.InsufficientGangOut.selector);
        burner.buybackAndBurn(address(gang), 100 ether, 100 ether + 1);
    }

    function test_zeroMinGangOut_reverts() public {
        _fund(stock, 1 ether);
        vm.prank(caller);
        vm.expectRevert(RoutedBuybackBurner.ZeroAmount.selector);
        burner.buybackAndBurn(address(stock), 1 ether, 0);
    }

    function test_zeroAmountIn_isNoop() public {
        vm.prank(caller);
        burner.buybackAndBurn(address(stock), 0, 0);
        assertEq(burner.quoteReceived(address(stock)), 0);
    }

    // ---------------------------------------------------------------- route checks

    function test_setV3Route_onlyOwner() public {
        bytes memory r = _route();
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        burner.setV3Route(address(stock), r);
    }

    function test_setV3Route_emits() public {
        vm.expectEmit(address(burner));
        emit RoutedBuybackBurner.V3RouteSet(address(stock), _route());
        _setRoute();
        assertEq(burner.v3Route(address(stock)), _route());
    }

    function test_setV3Route_directPool_ok() public {
        vm.prank(owner);
        burner.setV3Route(address(stock), abi.encodePacked(address(stock), uint24(500), address(wbnb)));
    }

    function _badRoute(address quote, bytes memory path) internal {
        vm.prank(owner);
        vm.expectRevert(RoutedBuybackBurner.BadRoute.selector);
        burner.setV3Route(quote, path);
    }

    function test_setV3Route_rejectsBadPaths() public {
        address s = address(stock);
        address u = address(usdt);
        address w = address(wbnb);
        address g = address(gang);
        _badRoute(s, abi.encodePacked(s)); // no hop
        _badRoute(s, abi.encodePacked(s, uint24(2500), w, uint8(0))); // ragged length
        _badRoute(s, abi.encodePacked(u, uint24(2500), w)); // does not start at the quote
        _badRoute(s, abi.encodePacked(s, uint24(2500), u)); // does not end at WBNB
        _badRoute(s, abi.encodePacked(s, uint24(3000), w)); // not a Pancake V3 tier
        _badRoute(s, abi.encodePacked(s, uint24(2500), g, uint24(2500), w)); // through GANG
        _badRoute(s, abi.encodePacked(s, uint24(2500), w, uint24(100), w)); // WBNB mid-route
        _badRoute(s, abi.encodePacked(s, uint24(2500), s, uint24(100), w)); // back through the quote
        _badRoute(w, abi.encodePacked(w, uint24(100), w)); // WBNB itself
        _badRoute(g, abi.encodePacked(g, uint24(100), w)); // GANG itself
        _badRoute(
            s,
            abi.encodePacked(s, uint24(100), u, uint24(100), address(0xA1), uint24(100), address(0xA2), uint24(100), w)
        ); // 4 hops
        vm.prank(owner);
        vm.expectRevert(RoutedBuybackBurner.ZeroAddress.selector);
        burner.setV3Route(address(0), "");
    }

    function test_constructor_rejectsZero() public {
        vm.expectRevert(RoutedBuybackBurner.ZeroAddress.selector);
        new RoutedBuybackBurner(owner, address(0), address(v3), address(wbnb), address(gang));
        vm.expectRevert(RoutedBuybackBurner.ZeroAddress.selector);
        new RoutedBuybackBurner(owner, address(router), address(0), address(wbnb), address(gang));
        assertEq(address(burner.router()), address(router));
        assertEq(burner.smartRouter(), address(v3));
        assertEq(burner.wbnb(), address(wbnb));
        assertEq(burner.gang(), address(gang));
        assertEq(burner.owner(), owner);
    }

    // ---------------------------------------------------------------- behind SharedPlatformFeeBucket

    function test_sharedBucket_v3Quote_collects80BurnAnd20Vault() public {
        IPlatformFeeBucket bucket = IPlatformFeeBucket(
            deployCode("src/common/SharedPlatformFeeBucket.sol:SharedPlatformFeeBucket", abi.encode(owner, feeVault))
        );
        vm.startPrank(owner);
        bucket.setLaunchpad(caller);
        bucket.setKeeper(keeper);
        bucket.setBurner(address(burner));
        burner.setV3Route(address(stock), _route());
        vm.stopPrank();

        stock.mint(caller, 10 ether);
        vm.startPrank(caller);
        stock.approve(address(bucket), 10 ether);
        bucket.notifyAccrual(address(stock), 10 ether);
        vm.stopPrank();

        vm.prank(keeper);
        bucket.collectPlatform(address(stock), 48 ether); // 8 stock → 16 WBNB → 48 GANG
        assertEq(gang.balanceOf(DEAD), 48 ether);
        assertEq(stock.balanceOf(feeVault), 2 ether);
        assertEq(bucket.accruedQuote(address(stock)), 0);
        assertEq(stock.balanceOf(address(bucket)), 0);
    }
}
