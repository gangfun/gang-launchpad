// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {GangFixture} from "../utils/GangFixture.sol";
import {GangRouter} from "../../src/router/GangRouter.sol";
import {GangRouterDeployLib as R} from "../../script/GangRouterDeployLib.sol";
import {GangMainnetRefs as M} from "../../config/GangDeployRefs.sol";

/// @dev Review PoC-2's look-alike "proxy": the same ERC-1967 slots, the real locked impl, a real ProxyAdmin as its
///      first CREATE owned by a real Safe-only 48 h timelock, initialized on the right pad / WBNB / Pancake — plus a
///      backdoor.
contract LookAlikeProxy {
    bytes32 constant IMPL = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    bytes32 constant ADMIN = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
    address immutable attacker;

    constructor(address impl, address timelock, bytes memory init, address attacker_) {
        attacker = attacker_;
        address pa = address(new ProxyAdmin(timelock)); // first CREATE: computeCreateAddress(this, 1)
        assembly {
            sstore(IMPL, impl)
            sstore(ADMIN, pa)
        }
        (bool ok,) = impl.delegatecall(init);
        require(ok);
    }

    function steal(IERC20 t, address from, address to) external {
        require(msg.sender == attacker);
        t.transferFrom(from, to, t.balanceOf(from));
    }

    fallback() external payable {
        assembly {
            let impl := sload(IMPL)
            calldatacopy(0, 0, calldatasize())
            let r := delegatecall(gas(), impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch r
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }
}

/// @notice Regressions of the strict review's two PoCs (AUDIT-BRIEF §21.2): both used to pass GangRouterDeployLib.check.
///         PoC-1: a router timelock run by the deploy wallet (OWNER = the deployer, or the router-only script with any
///         OWNER on mainnet). PoC-2: a contract that only imitates a TransparentUpgradeableProxy (re-run path).
contract GangRouterReviewPoCTest is GangFixture {
    address internal safe;
    address internal deployerEoa = makeAddr("deployWallet");

    function setUp() public {
        _deployGang(makeAddr("keeper"));
        safe = owner;
    }

    function _expect(address safe_, address deployer, bool mainnet) internal view returns (R.Expect memory) {
        return R.Expect({
            pad: address(pad),
            wbnb: address(wbnb),
            pancakeRouter: pancakeRouter,
            pancakeFactory: address(pairFactory),
            safe: safe_,
            deployer: deployer,
            minDelay: 48 hours,
            mainnet: mainnet
        });
    }

    /// PoC-1, now blocked three ways: the library refuses to build a mainnet timelock for anyone but the Safe; the
    /// mainnet check refuses a timelock whose role holder is not the Safe; and on mainnet the deploy wallet may hold no
    /// role even when it is the OWNER.
    function test_poc1_deployWalletTimelock_refusedOnMainnet() public {
        // 1) chain 56: deploy() refuses a timelock for the deploy wallet
        vm.chainId(56);
        vm.prank(deployerEoa);
        vm.expectRevert(abi.encodeWithSelector(R.MainnetTimelockNotSafe.selector, deployerEoa));
        this.deployFor(deployerEoa);
        vm.chainId(31337);

        // 2) such a timelock (built elsewhere) fails the mainnet check
        vm.startPrank(deployerEoa);
        R.Router memory r = R.deploy(address(pad), address(wbnb), pancakeRouter, deployerEoa, R.MAINNET_MIN_DELAY);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(R.WiringCheck.selector, "router timelock not the Safe"));
        this.checkFor(r, _expect(deployerEoa, deployerEoa, true));

        // 3) the Safe holds the roles but the deploy wallet kept one too: refused on mainnet
        address[] memory proposers = new address[](2);
        (proposers[0], proposers[1]) = (M.OWNER_SAFE, deployerEoa);
        address[] memory executors = new address[](1);
        executors[0] = M.OWNER_SAFE;
        r = _withTimelock(new TimelockController(48 hours, proposers, executors, address(0)));
        vm.expectRevert(abi.encodeWithSelector(R.WiringCheck.selector, "router timelock deployer role"));
        this.checkFor(r, _expect(M.OWNER_SAFE, deployerEoa, true));

        // and the Safe-only shape passes the mainnet rules
        address[] memory only = new address[](1);
        only[0] = M.OWNER_SAFE;
        r = _withTimelock(new TimelockController(48 hours, only, only, address(0)));
        R.check(r, _expect(M.OWNER_SAFE, deployerEoa, true));
        // testnet keeps its rehearsal shape (deploy wallet = owner = role holder)
        vm.startPrank(deployerEoa);
        r = R.deploy(address(pad), address(wbnb), pancakeRouter, deployerEoa, 600);
        vm.stopPrank();
        R.check(
            r,
            R.Expect({
                pad: address(pad),
                wbnb: address(wbnb),
                pancakeRouter: pancakeRouter,
                pancakeFactory: address(pairFactory),
                safe: deployerEoa,
                deployer: deployerEoa,
                minDelay: 600,
                mainnet: false
            })
        );
    }

    function _withTimelock(TimelockController tl) internal returns (R.Router memory r) {
        GangRouter impl = new GangRouter();
        address proxy = address(
            new TransparentUpgradeableProxy(
                address(impl),
                address(tl),
                abi.encodeCall(GangRouter.initialize, (address(pad), address(wbnb), pancakeRouter))
            )
        );
        r = R.load(proxy);
    }

    function deployFor(address s) external returns (R.Router memory) {
        return R.deploy(address(pad), address(wbnb), pancakeRouter, s, R.MAINNET_MIN_DELAY);
    }

    function checkFor(R.Router memory r, R.Expect memory e) external view {
        R.check(r, e);
    }

    /// PoC-2, now blocked: the proxy's own runtime code must be OZ 5.1's TransparentUpgradeableProxy.
    function test_poc2_lookAlikeProxy_refused() public {
        address attacker = makeAddr("attacker");
        address impl = address(new GangRouter());
        address[] memory only = new address[](1);
        only[0] = safe;
        address tl = address(new TimelockController(48 hours, only, only, address(0)));
        vm.prank(attacker);
        address fake = address(
            new LookAlikeProxy(
                impl, tl, abi.encodeCall(GangRouter.initialize, (address(pad), address(wbnb), pancakeRouter)), attacker
            )
        );
        R.Router memory r = R.load(fake);
        vm.expectRevert(abi.encodeWithSelector(R.WiringCheck.selector, "router proxy code"));
        this.checkFor(r, _expect(safe, address(this), false));
        // the real one passes
        R.check(routerStack, _expect(safe, address(this), false));
    }
}
