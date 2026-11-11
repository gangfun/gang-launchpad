// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// THROWAWAY PROTOTYPE for docs/SPEC-BASE-VAULT-V2-2026-11-12.md §5 (version 3: the vault only releases the base to
// the creator over time) — not production code, not audited. Local mocks only (the repo's GangFixture).
// Run: forge test --match-path test/proto/BaseVestProto.t.sol -vv

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GangFixture} from "../utils/GangFixture.sol";

interface ILockedToken {
    function locked() external view returns (bool);
}

contract GangBaseVestProto {
    address public immutable pad;
    address public token;
    address public creator;
    uint64 public startAt;
    uint64 public duration;
    uint256 public total;
    uint256 public released;
    uint256 private _lock = 1;

    event Began(uint64 startAt, uint256 total);
    event Released(address indexed creator, uint256 amount, uint256 releasedTotal);

    error NotPad();
    error AlreadyInitialized();
    error NotGraduated();
    error NothingToRelease();
    error Reentered();

    modifier nonReentrant() {
        if (_lock != 1) revert Reentered();
        _lock = 2;
        _;
        _lock = 1;
    }

    constructor(address pad_) {
        pad = pad_;
    }

    function initialize(address token_, address creator_, uint32 vestDays) external {
        if (msg.sender != pad) revert NotPad();
        if (token != address(0)) revert AlreadyInitialized();
        token = token_;
        creator = creator_;
        duration = uint64(vestDays) * 1 days;
    }

    function releasable() public view returns (uint256) {
        if (startAt == 0) return 0;
        uint256 elapsed = block.timestamp - startAt;
        if (elapsed >= duration) return IERC20(token).balanceOf(address(this)); // everything, donations included
        return (total * elapsed) / duration - released;
    }

    /// @dev The first call after graduation starts the clock (the token's own `locked()` flag, not a pad view).
    function release() external nonReentrant returns (uint256 amount) {
        if (startAt == 0) {
            _start();
            return 0;
        }
        amount = releasable();
        if (amount == 0) revert NothingToRelease();
        released += amount;
        IERC20(token).transfer(creator, amount);
        emit Released(creator, amount, released);
    }

    function _start() private {
        if (ILockedToken(token).locked()) revert NotGraduated();
        startAt = uint64(block.timestamp);
        total = IERC20(token).balanceOf(address(this));
        emit Began(startAt, total);
    }

    /// @dev Not in the spec. Kept only so the review's tests (written against the previous draft, which had a separate
    ///      `begin`) still compile and run: the same start as the first `release`.
    function begin() external nonReentrant {
        require(startAt == 0, "begun");
        _start();
    }
}

contract BaseVestProtoTest is GangFixture {
    address keeper = makeAddr("keeper");
    address creator;
    address t;
    GangBaseVestProto vault;
    uint256 constant BASE = 100_000_000 ether;

    function setUp() public {
        _deployGang(keeper);
    }

    /// @dev The base stands in the vault as if bought at create (in production the pad's `buyBase` puts it there).
    function _make(uint16 buyTax, uint16 sellTax, bool graduateNow) internal {
        _makeDays(buyTax, sellTax, graduateNow, 90);
    }

    function _makeDays(uint16 buyTax, uint16 sellTax, bool graduateNow, uint32 vestDays) internal {
        creator = _newAgent();
        t = _createV3(creator, address(wbnb), _tax(buyTax, sellTax, 0, buyTax == 0 ? address(0) : creator));
        vault = new GangBaseVestProto(address(pad));
        vm.prank(address(pad));
        vault.initialize(t, creator, vestDays);
        deal(t, address(vault), BASE);
        if (graduateNow) _graduate(t);
    }

    function test_cannotBeginBeforeGraduation() public {
        _make(0, 0, false);
        vm.expectRevert(GangBaseVestProto.NotGraduated.selector);
        vault.release();
        assertEq(vault.releasable(), 0);
    }

    function test_onlyThePadInitialises_once() public {
        _make(0, 0, false);
        vm.expectRevert(GangBaseVestProto.NotPad.selector);
        vault.initialize(t, address(this), 1);
        vm.prank(address(pad));
        vm.expectRevert(GangBaseVestProto.AlreadyInitialized.selector);
        vault.initialize(t, address(this), 1);
    }

    function test_linearRelease() public {
        _make(0, 0, true);
        vm.prank(makeAddr("anyone"));
        assertEq(vault.release(), 0, "the first call only starts the clock");
        assertEq(vault.total(), BASE);
        vm.expectRevert(GangBaseVestProto.NothingToRelease.selector);
        vault.release();

        uint256 start = vault.startAt();
        // day 9: a tenth
        vm.warp(start + 9 days);
        vm.prank(makeAddr("anyone"));
        uint256 got = vault.release();
        assertEq(got, BASE / 10);
        assertEq(IERC20(t).balanceOf(creator), BASE / 10);
        // day 45: half in total
        vm.warp(start + 45 days);
        vault.release();
        assertEq(IERC20(t).balanceOf(creator), BASE / 2);
        assertEq(vault.released(), BASE / 2);
        assertEq(IERC20(t).balanceOf(address(vault)), BASE / 2);
        // never ahead of the schedule
        vm.warp(start + 60 days);
        assertEq(vault.releasable(), (BASE * 60) / 90 - BASE / 2);
        // after the end: everything
        vm.warp(start + 200 days);
        vault.release();
        assertEq(IERC20(t).balanceOf(creator), BASE);
        assertEq(IERC20(t).balanceOf(address(vault)), 0);
        vm.expectRevert(GangBaseVestProto.NothingToRelease.selector);
        vault.release();
    }

    /// @dev The other two periods: a third of the way in, a third is out; nothing early, everything at the end.
    function test_otherPeriods() public {
        uint32[2] memory ds = [uint32(30), uint32(180)];
        for (uint256 i; i < 2; ++i) {
            _makeDays(0, 0, true, ds[i]);
            vault.release();
            assertEq(vault.duration(), uint64(ds[i]) * 1 days);
            uint256 start = vault.startAt();
            vm.warp(start + (uint256(ds[i]) * 1 days) / 3);
            vault.release();
            assertEq(IERC20(t).balanceOf(creator), BASE / 3);
            vm.warp(start + uint256(ds[i]) * 1 days - 1);
            assertLt(vault.releasable() + vault.released(), BASE);
            vm.warp(start + uint256(ds[i]) * 1 days);
            vault.release();
            assertEq(IERC20(t).balanceOf(creator), BASE);
        }
    }

    /// @dev There is no way to redirect the release: the vault has no setter and only pays the creator.
    function test_onlyTheCreatorIsPaid() public {
        _make(0, 0, true);
        vault.release();
        vm.warp(vault.startAt() + 30 days);
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vault.release();
        assertEq(IERC20(t).balanceOf(stranger), 0);
        assertEq(IERC20(t).balanceOf(creator), BASE / 3);
        (bool ok,) = address(vault).call(abi.encodeWithSignature("setBeneficiary(address)", stranger));
        assertFalse(ok, "a setter exists");
    }

    /// @dev Tokens sent in: before `begin` they join the total; after it they come out at the end. Never stuck.
    function test_donations() public {
        _make(0, 0, true);
        address donor = _newAgent();
        deal(t, donor, 30 ether);
        vm.prank(donor);
        IERC20(t).transfer(address(vault), 10 ether);
        vault.release();
        assertEq(vault.total(), BASE + 10 ether);
        vm.prank(donor);
        IERC20(t).transfer(address(vault), 20 ether);
        vm.warp(vault.startAt() + 45 days);
        vault.release();
        assertEq(IERC20(t).balanceOf(creator), (BASE + 10 ether) / 2);
        vm.warp(vault.startAt() + 90 days);
        vault.release();
        assertEq(IERC20(t).balanceOf(creator), BASE + 30 ether);
        assertEq(IERC20(t).balanceOf(address(vault)), 0);
    }

    /// @dev A 5% / 5% token: a release is not a pool trade, so nothing is taxed.
    function test_taxedToken_releaseIsNotTaxed() public {
        _make(500, 500, true);
        vault.release();
        uint256 acc = handler.accruedTax(t);
        vm.warp(vault.startAt() + 9 days);
        vault.release();
        assertEq(IERC20(t).balanceOf(creator), BASE / 10, "the release was taxed");
        assertEq(handler.accruedTax(t), acc);
    }

    /// @dev Before graduation nothing can move the vault's tokens through the pad: it never approves and never calls.
    function test_padCannotMoveTheBaseBeforeGraduation() public {
        _make(0, 0, false);
        address agent = _newAgent();
        // someone else trying to pull or transfer the vault's tokens
        vm.prank(agent);
        vm.expectRevert();
        IERC20(t).transferFrom(address(vault), agent, 1 ether);
        // a direct transfer out is not possible either: the vault has no such function, and the token is locked for
        // anyone but the pad
        vm.prank(address(vault));
        vm.expectRevert();
        IERC20(t).transfer(agent, 1 ether);
        assertEq(IERC20(t).balanceOf(address(vault)), BASE);
    }
}
