// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice GangCallBond: a caller bonds its own call (a buy note on a 3.0 curve token). See
///         docs/SPEC-AGENT-CALLS-2026-11-09.md §5.
interface IGangCallBond {
    enum State {
        None,
        /// promise running (also after the deadline, until `settle`)
        Active,
        /// kept: the bond went back to the caller
        Settled,
        /// broken: reporter paid, half burned, the rest is the followers' pool
        Reported,
        /// broken and closed: what the pool had left went to 0xdead
        Closed
    }

    struct Bond {
        // slot 0
        address caller;
        uint64 postedAt;
        State state;
        // slot 1
        address token;
        uint64 deadline;
        // slot 2
        address quote;
        /// settle may run from here (0 = not requested)
        uint64 settleAt;
        // slot 3
        uint128 amount;
        uint128 hold;
        // slot 4
        uint64 reportedAt;
        uint64 reportedBlock;
        /// the pending / live root's post time (0 = none)
        uint64 rootAt;
        /// the last veto (0 = none)
        uint64 vetoAt;
        // slot 5
        /// what the followers' pool got at the report
        uint128 pool;
        /// what left the pool since: claims and the burnt remainder
        uint128 spent;
        // slot 6
        /// the pending / live root's total
        uint128 total;
        bool remainderBurned;
        // slots 7-8
        bytes32 noteTx;
        bytes32 root;
    }

    event CallBondPosted(
        uint256 indexed id,
        address indexed caller,
        address indexed token,
        bytes32 noteTx,
        address quote,
        uint256 amount,
        uint256 hold,
        uint64 deadline
    );
    event CallBondReported(
        uint256 indexed id,
        address indexed reporter,
        uint256 reportedBlock,
        uint256 balance,
        uint256 reward,
        uint256 burned,
        uint256 pool
    );
    event SettleRequested(uint256 indexed id, uint64 settleAt);
    event CallBondSettled(uint256 indexed id, address indexed caller, uint256 amount);
    event RootPosted(uint256 indexed id, bytes32 root, uint256 total, uint64 claimableAt);
    event RootVetoed(uint256 indexed id, bytes32 root);
    event Claimed(uint256 indexed id, address indexed account, uint256 amount);
    event RemainderBurned(uint256 indexed id, uint256 amount);
    event UnpaidBurned(uint256 indexed id, uint256 amount);
    event SettlerSet(address indexed settler);

    error ZeroAddress();
    error ZeroAmount();
    error SettlerIsOwner();
    error NotCurveToken();
    error BadTokenVersion();
    error AlreadyGraduated();
    error QuoteNotAllowed();
    error BadDuration();
    error BadHold();
    error BadNote();
    error BondLive();
    error BadValue();
    error FeeOnTransferQuote();
    error NotActive();
    error NotViolated();
    error Violated();
    error FlashSwapActive();
    error NotDue();
    error AlreadyRequested();
    error NoSettleRequest();
    error NotReported();
    error NotSettler();
    error RootExists();
    error TooEarly();
    error PostWindowClosed();
    error BadTotal();
    error NoPendingRoot();
    error DisputeOver();
    error NotClaimable();
    error AlreadyClaimed();
    error BadProof();
    error OverTotal();
    error AlreadyBurned();
    error StillPayable();
    error NotFollower();
    error RenounceDisabled();

    function post(address token, bytes32 noteTx, uint256 amount, uint256 hold, uint64 duration)
        external
        payable
        returns (uint256 id);
    function report(uint256 id) external;
    function requestSettle(uint256 id) external;
    function settle(uint256 id) external;
    function postRoot(uint256 id, bytes32 root, uint256 total) external;
    function veto(uint256 id) external;
    function claim(uint256 id, address account, uint256 amount, bytes32[] calldata proof) external;
    function burnRemainder(uint256 id) external;
    function burnUnpaid(uint256 id) external;

    function bondOf(uint256 id) external view returns (Bond memory);
    function activeBondOf(address caller, address token) external view returns (uint256 id);
    function claimed(uint256 id, address account) external view returns (bool);
    function canPostRoot(uint256 id) external view returns (bool);
    function leaf(uint256 id, address account, uint256 amount) external view returns (bytes32);
}
