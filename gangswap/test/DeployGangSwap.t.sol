// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DeployGangSwap} from "../script/DeployGangSwap.s.sol";
import {GangSwapMigrator} from "../src/GangSwapMigrator.sol";
import {IGangSwapFactory} from "../src/interfaces/IGangSwap.sol";
import {MockWBNB, MockBucket} from "./Mocks.sol";

/// @dev The deploy script's set passes its own `check`, and `check` refuses a set that differs in any one place.
contract DeployGangSwapTest is Test {
    DeployGangSwap s;
    MockWBNB wbnb;
    MockBucket bucket;
    address owner = makeAddr("safe");
    address migrator;
    address factory;
    address router;

    function setUp() public {
        wbnb = new MockWBNB();
        bucket = new MockBucket();
        _env(owner, address(wbnb), address(bucket));
        s = new DeployGangSwap();
        (migrator,,, factory, router) = s.run();
    }

    function _env(address o, address w, address b) internal {
        vm.setEnv("GANGSWAP_OWNER", vm.toString(o));
        vm.setEnv("WBNB", vm.toString(w));
        vm.setEnv("FEE_BUCKET", vm.toString(b));
    }

    /// @dev One test: the env is shared by every test of the process.
    function test_deployScript() public {
        s.check(migrator, router);
        assertEq(GangSwapMigrator(migrator).owner(), owner);

        // the deployed router's hash, not its source: one changed byte of the constant is refused
        bytes memory code = router.code;
        bytes32 hash = IGangSwapFactory(factory).INIT_CODE_PAIR_HASH();
        vm.etch(router, _flip(code, hash));
        vm.expectRevert(bytes("router init code hash"));
        s.check(migrator, router);
        vm.etch(router, code);

        vm.mockCall(migrator, abi.encodeWithSignature("wired()"), abi.encode(false));
        vm.expectRevert(bytes("not wired"));
        s.check(migrator, router);
        vm.clearMockedCalls();

        vm.mockCall(router, abi.encodeWithSignature("factory()"), abi.encode(address(1)));
        vm.expectRevert(bytes("router wiring"));
        s.check(migrator, router);
        vm.clearMockedCalls();

        _env(makeAddr("other"), address(wbnb), address(bucket));
        vm.expectRevert(bytes("migrator owner / quote"));
        s.check(migrator, router);

        _env(owner, address(wbnb), address(new MockBucket()));
        vm.expectRevert(bytes("fee bucket"));
        s.check(migrator, router);

        // a contract that is not a fee bucket (WBNB here) is refused at deploy
        _env(owner, address(wbnb), address(wbnb));
        vm.expectRevert();
        s.run();
        _env(owner, address(wbnb), address(bucket));
    }

    function _flip(bytes memory code, bytes32 hash) internal pure returns (bytes memory out) {
        out = bytes.concat(code);
        for (uint256 i; i + 32 <= out.length; i++) {
            bytes32 w;
            assembly ("memory-safe") {
                w := mload(add(add(out, 32), i))
            }
            if (w == hash) {
                out[i] = out[i] ^ 0x01;
                return out;
            }
        }
        revert("hash not in code");
    }
}
