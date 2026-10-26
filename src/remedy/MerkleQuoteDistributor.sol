// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @title MerkleQuoteDistributor (正式站 V2 存量税的持有人补发)
/// @notice One drop per V2 token: the holders' half of the token's tax backlog, sold by V2TaxChunkSeller and paid
///         to the addresses that held the token when each tax was paid (amounts computed off-chain from the
///         chain's Transfer / TaxAccrued logs; tools/remedy/). Leaf = keccak256(bytes.concat(keccak256(abi.encode(
///         index, account, amount)))), pairs hashed sorted (OpenZeppelin MerkleProof).
/// @dev Funders (the chunk sellers) push quote in with `fund`; the owner (multisig) sets each drop's root once the
///      backlog is sold, with the drop's `total` (Σ amounts in the tree), which must be covered by what was funded.
///      After `deadline` the owner may sweep what is left (unclaimed amounts and rounding dust).
contract MerkleQuoteDistributor is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Drop {
        address quote;
        bytes32 root;
        uint256 funded;
        uint256 total; // Σ leaf amounts (set with the root)
        uint256 claimed;
        uint64 deadline;
        bool swept;
    }

    mapping(address token => Drop) public drops;
    mapping(address token => mapping(uint256 word => uint256 bits)) private _claimedBits;
    mapping(address funder => bool) public funders;

    event FunderSet(address indexed funder, bool enabled);
    event Funded(address indexed token, address indexed quote, uint256 amount, uint256 funded);
    event RootSet(address indexed token, bytes32 root, uint256 total, uint64 deadline);
    event Claimed(address indexed token, uint256 index, address indexed account, uint256 amount);
    event Swept(address indexed token, address indexed to, uint256 amount);

    error OnlyFunder();
    error QuoteMismatch();
    error ZeroAddress();
    error RootAlreadySet();
    error Underfunded();
    error BadDeadline();
    error NoRoot();
    error AlreadyClaimed();
    error BadProof();
    error Expired();
    error NotExpired();
    error AlreadySwept();

    constructor(address owner_) Ownable(owner_) {}

    function setFunder(address funder, bool enabled) external onlyOwner {
        funders[funder] = enabled;
        emit FunderSet(funder, enabled);
    }

    /// @notice Funder pushes `amount` of `quote` for `token`'s drop (pulled with transferFrom).
    function fund(address token, address quote, uint256 amount) external nonReentrant {
        if (!funders[msg.sender]) revert OnlyFunder();
        Drop storage d = drops[token];
        if (d.quote == address(0)) {
            if (quote == address(0)) revert ZeroAddress();
            d.quote = quote;
        } else if (d.quote != quote) {
            revert QuoteMismatch();
        }
        if (amount == 0) return;
        uint256 before = IERC20(quote).balanceOf(address(this));
        IERC20(quote).safeTransferFrom(msg.sender, address(this), amount);
        uint256 got = IERC20(quote).balanceOf(address(this)) - before; // a fee-on-transfer quote counts what arrived
        d.funded += got;
        emit Funded(token, quote, got, d.funded);
    }

    /// @notice Set `token`'s drop once its backlog is sold: `total` = Σ amounts in the tree, ≤ funded.
    function setRoot(address token, bytes32 root, uint256 total, uint64 deadline) external onlyOwner {
        Drop storage d = drops[token];
        if (d.root != bytes32(0)) revert RootAlreadySet();
        if (root == bytes32(0)) revert NoRoot();
        if (total > d.funded) revert Underfunded();
        if (deadline <= block.timestamp) revert BadDeadline();
        d.root = root;
        d.total = total;
        d.deadline = deadline;
        emit RootSet(token, root, total, deadline);
    }

    function isClaimed(address token, uint256 index) public view returns (bool) {
        return (_claimedBits[token][index >> 8] >> (index & 0xff)) & 1 == 1;
    }

    /// @notice Anyone can submit; the quote always goes to `account`.
    function claim(address token, uint256 index, address account, uint256 amount, bytes32[] calldata proof)
        external
        nonReentrant
    {
        Drop storage d = drops[token];
        if (d.root == bytes32(0)) revert NoRoot();
        if (block.timestamp > d.deadline || d.swept) revert Expired();
        if (isClaimed(token, index)) revert AlreadyClaimed();
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(index, account, amount))));
        if (!MerkleProof.verifyCalldata(proof, d.root, leaf)) revert BadProof();
        _claimedBits[token][index >> 8] |= uint256(1) << (index & 0xff);
        d.claimed += amount;
        if (d.claimed > d.total) revert Underfunded(); // a tree whose leaves exceed its declared total
        IERC20(d.quote).safeTransfer(account, amount);
        emit Claimed(token, index, account, amount);
    }

    /// @notice After the deadline: what was funded and not claimed (unclaimed leaves + dust) to `to`.
    function sweep(address token, address to) external onlyOwner nonReentrant {
        Drop storage d = drops[token];
        if (to == address(0)) revert ZeroAddress();
        if (d.root == bytes32(0) || block.timestamp <= d.deadline) revert NotExpired();
        if (d.swept) revert AlreadySwept();
        d.swept = true;
        uint256 amount = d.funded - d.claimed;
        IERC20(d.quote).safeTransfer(to, amount);
        emit Swept(token, to, amount);
    }
}
