// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {GangRouter} from "../../src/router/GangRouter.sol";
// the well-formed next version lives in its own file (a copy of v1 that takes its new slot from the gap)
import {GangRouterV2Mock} from "./GangRouterV2Next.sol";

/// @dev What a malicious upgrade could do with users' standing approvals to the router address (AUDIT-BRIEF §21 risk):
///      pull whatever a user approved and has. The 48 h timelock makes it public first; exact approvals cap it.
contract GangRouterDrainMock is GangRouter {
    function drain(IERC20 token, address from, address to) external {
        uint256 a = token.allowance(from, address(this));
        uint256 b = token.balanceOf(from);
        token.transferFrom(from, to, a < b ? a : b);
    }
}

/// @dev A caller whose BNB refund callback tries to re-enter the router; it records what the inner call reverted with
///      and swallows it, so the outer call completes and the test sees the guard's own error.
contract ReenteringBuyer {
    GangRouter internal immutable router;
    address internal token;
    uint8 internal mode; // 1 = v3BuyBNB, 2 = fairMintBNB, 3 = v3Buy (ERC-20 entry)
    bytes public innerError;
    uint256 public reentries;

    constructor(GangRouter router_) {
        router = router_;
    }

    function setTarget(address token_, uint8 mode_) external {
        token = token_;
        mode = mode_;
    }

    function buyBnb(uint256 value) external returns (uint256) {
        return router.v3BuyBNB{value: value}(token, 0, block.timestamp);
    }

    function mintBnb(uint256 shares, uint256 value) external returns (uint256) {
        return router.fairMintBNB{value: value}(token, shares, 1, block.timestamp);
    }

    receive() external payable {
        if (reentries > 0) return; // once
        reentries++;
        if (mode == 1) {
            try router.v3BuyBNB{value: msg.value}(token, 0, block.timestamp) {}
            catch (bytes memory err) {
                innerError = err;
            }
        } else if (mode == 2) {
            try router.fairMintBNB{value: msg.value}(token, 1, 1, block.timestamp) {}
            catch (bytes memory err) {
                innerError = err;
            }
        } else if (mode == 3) {
            try router.v3Buy(token, 1, 0, block.timestamp) {}
            catch (bytes memory err) {
                innerError = err;
            }
        }
    }
}

/// @dev Stand-in for PancakeSwap V2's router (unit tests; the real one is on the fork): pulls `amountIn` of path[0]
///      from the caller and pays path[last] 1:1 (times `rateBps` / 10_000) from its own balance to `to`.
contract MockPancakeV2Swap {
    uint256 public rateBps = 10_000;
    /// @dev Router02's getters (the deploy self-check asks them)
    address public factory;
    address public WETH;

    function setRefs(address factory_, address weth_) external {
        (factory, WETH) = (factory_, weth_);
    }

    function setRate(uint256 r) external {
        rateBps = r;
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external {
        require(block.timestamp <= deadline, "PancakeRouter: EXPIRED");
        IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        uint256 out = (amountIn * rateBps) / 10_000;
        require(out >= amountOutMin, "PancakeRouter: INSUFFICIENT_OUTPUT_AMOUNT");
        IERC20(path[path.length - 1]).transfer(to, out);
    }
}

/// @dev ERC-20 that, once armed, re-enters the router from inside its own transfer (a hostile token or quote).
contract ReenteringToken {
    string public constant name = "Reenter";
    string public constant symbol = "RE";
    uint8 public constant decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    GangRouter public router;
    address public other;
    bytes public innerError;
    bool internal armed;

    function arm(GangRouter router_, address other_) external {
        router = router_;
        other = other_;
        armed = true;
    }

    function mint(address to, uint256 a) external {
        balanceOf[to] += a;
    }

    function approve(address s, uint256 a) external returns (bool) {
        allowance[msg.sender][s] = a;
        return true;
    }

    function transfer(address to, uint256 a) external returns (bool) {
        _move(msg.sender, to, a);
        return true;
    }

    function transferFrom(address f, address to, uint256 a) external returns (bool) {
        if (allowance[f][msg.sender] != type(uint256).max) allowance[f][msg.sender] -= a;
        _move(f, to, a);
        return true;
    }

    function _move(address f, address to, uint256 a) internal {
        balanceOf[f] -= a;
        balanceOf[to] += a;
        if (armed && to == address(router)) {
            armed = false;
            try router.poolSell(address(this), other, 1, 0, block.timestamp) {}
            catch (bytes memory err) {
                innerError = err;
            }
        }
    }
}

/// @dev Sells for BNB through the router and, in the BNB callback, tries to re-enter a pool entry.
contract PoolReenterer {
    GangRouter internal immutable router;
    bytes public innerError;
    uint256 public reentries;
    address internal token;
    address internal quote;

    constructor(GangRouter router_) {
        router = router_;
    }

    function sellForBnb(address token_, address quote_, uint256 amount) external returns (uint256) {
        (token, quote) = (token_, quote_);
        IERC20(token_).approve(address(router), type(uint256).max);
        return router.poolSellForBNB(token_, quote_, amount, 0, block.timestamp);
    }

    receive() external payable {
        if (reentries > 0) return;
        reentries++;
        try router.poolBuyBNB{value: msg.value}(token, quote, 0, block.timestamp) {}
        catch (bytes memory err) {
            innerError = err;
        }
    }
}
