// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockWBNB is ERC20 {
    constructor() ERC20("Wrapped BNB", "WBNB") {}

    receive() external payable {
        deposit();
    }

    function deposit() public payable {
        _mint(msg.sender, msg.value);
    }

    function withdraw(uint256 wad) external {
        _burn(msg.sender, wad);
        (bool ok,) = msg.sender.call{value: wad}("");
        require(ok, "WBNB: send");
    }
}

/// @dev 1B supply, untaxed (GangToken after unlock behaves as a plain ERC-20 for GangSwap).
contract MockToken is ERC20 {
    constructor(address to) ERC20("Gang Test", "GT") {
        _mint(to, 1_000_000_000 ether);
    }
}

interface IMigrate {
    function migrate(address token, address quote, uint256 tokenAmount, uint256 quoteAmount)
        external
        returns (address pair);
}

/// @dev Stands in for GangLaunchpad3 at graduation: sends the leftover tokens + the raise to the migrator and calls
///      `migrate` (PadCommon.migrate's order), and serves `curves(token).creator`.
contract MockPad {
    mapping(address => address) public creatorOf;

    function setCreator(address token, address creator) external {
        creatorOf[token] = creator;
    }

    function graduate(address migrator, address token, address quote, uint256 tokenAmount, uint256 quoteAmount)
        external
        returns (address pair)
    {
        IERC20(token).transfer(migrator, tokenAmount);
        IERC20(quote).transfer(migrator, quoteAmount);
        pair = IMigrate(migrator).migrate(token, quote, tokenAmount, quoteAmount);
    }

    function curves(address token)
        external
        view
        returns (
            address creator,
            address quote,
            uint128 realQuote,
            uint128 sold,
            uint128 gradAmt,
            uint128 virtualQuote,
            bool graduated,
            uint16 buyTaxBps,
            uint16 sellTaxBps,
            uint16 dividendBps,
            address pair,
            address refPair
        )
    {
        creator = creatorOf[token]; // the rest stays zero: GangSwapFees reads only the creator
    }
}

/// @dev SharedPlatformFeeBucket.notifyAccrual: operator only, pulls with transferFrom, credits what arrived.
contract MockBucket {
    mapping(address => bool) public operators;
    mapping(address => uint256) public accruedQuote;
    bool public refuse;

    function setOperator(address a, bool on) external {
        operators[a] = on;
    }

    function setRefuse(bool r) external {
        refuse = r;
    }

    function notifyAccrual(address quote, uint256 amount) external {
        require(operators[msg.sender] && !refuse, "bucket: refused");
        uint256 before = IERC20(quote).balanceOf(address(this));
        IERC20(quote).transferFrom(msg.sender, address(this), amount);
        accruedQuote[quote] += IERC20(quote).balanceOf(address(this)) - before;
    }
}
