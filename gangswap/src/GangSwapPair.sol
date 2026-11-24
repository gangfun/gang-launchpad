// SPDX-License-Identifier: GPL-3.0
// GangSwap pair + factory: PancakeSwap V2 (upstream/PancakeFactory.sol, BSC 0xcA14…0c73) with a virtual quote reserve,
// a 1% fee taken out of the pool, one-shot liquidity and no flash swaps. Spec: docs/SPEC-GANGSWAP-2026-11-22.md §6.
// Every change against upstream: gangswap/check-diff.sh.
pragma solidity =0.5.16;


interface IPancakeFactory {
    event PairCreated(address indexed token0, address indexed token1, address pair, uint);

    function migrator() external view returns (address);
    function fees() external view returns (address);

    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function allPairs(uint) external view returns (address pair);
    function allPairsLength() external view returns (uint);

    function createPair(address tokenA, address tokenB, address quote, uint virtualReserve) external returns (address pair);
}

interface IPancakePair {
    event Approval(address indexed owner, address indexed spender, uint value);
    event Transfer(address indexed from, address indexed to, uint value);

    function name() external pure returns (string memory);
    function symbol() external pure returns (string memory);
    function decimals() external pure returns (uint8);
    function totalSupply() external view returns (uint);
    function balanceOf(address owner) external view returns (uint);
    function allowance(address owner, address spender) external view returns (uint);

    function approve(address spender, uint value) external returns (bool);
    function transfer(address to, uint value) external returns (bool);
    function transferFrom(address from, address to, uint value) external returns (bool);

    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function PERMIT_TYPEHASH() external pure returns (bytes32);
    function nonces(address owner) external view returns (uint);

    function permit(address owner, address spender, uint value, uint deadline, uint8 v, bytes32 r, bytes32 s) external;

    event Mint(address indexed sender, uint amount0, uint amount1);
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    function MINIMUM_LIQUIDITY() external pure returns (uint);
    function factory() external view returns (address);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function price0CumulativeLast() external view returns (uint);
    function price1CumulativeLast() external view returns (uint);
    function kLast() external view returns (uint);

    function mint(address to) external returns (uint liquidity);
    function burn(address to) external returns (uint amount0, uint amount1);
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external;
    function skim(address to) external;
    function sync() external;

    function initialize(address, address, bool, uint) external;
}

interface IPancakeERC20 {
    event Approval(address indexed owner, address indexed spender, uint value);
    event Transfer(address indexed from, address indexed to, uint value);

    function name() external pure returns (string memory);
    function symbol() external pure returns (string memory);
    function decimals() external pure returns (uint8);
    function totalSupply() external view returns (uint);
    function balanceOf(address owner) external view returns (uint);
    function allowance(address owner, address spender) external view returns (uint);

    function approve(address spender, uint value) external returns (bool);
    function transfer(address to, uint value) external returns (bool);
    function transferFrom(address from, address to, uint value) external returns (bool);

    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function PERMIT_TYPEHASH() external pure returns (bytes32);
    function nonces(address owner) external view returns (uint);

    function permit(address owner, address spender, uint value, uint deadline, uint8 v, bytes32 r, bytes32 s) external;
}

// a library for performing overflow-safe math, courtesy of DappHub (https://github.com/dapphub/ds-math)
library SafeMath {
    function add(uint x, uint y) internal pure returns (uint z) {
        require((z = x + y) >= x, 'ds-math-add-overflow');
    }

    function sub(uint x, uint y) internal pure returns (uint z) {
        require((z = x - y) <= x, 'ds-math-sub-underflow');
    }

    function mul(uint x, uint y) internal pure returns (uint z) {
        require(y == 0 || (z = x * y) / y == x, 'ds-math-mul-overflow');
    }
}

contract GangSwapERC20 is IPancakeERC20 {
    using SafeMath for uint;

    string public constant name = 'GangSwap LPs';
    string public constant symbol = 'GS-LP';
    uint8 public constant decimals = 18;
    uint  public totalSupply;
    mapping(address => uint) public balanceOf;
    mapping(address => mapping(address => uint)) public allowance;

    bytes32 public DOMAIN_SEPARATOR;
    // keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 public constant PERMIT_TYPEHASH = 0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;
    mapping(address => uint) public nonces;

    event Approval(address indexed owner, address indexed spender, uint value);
    event Transfer(address indexed from, address indexed to, uint value);

    constructor() public {
        uint chainId;
        assembly {
            chainId := chainid
        }
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)'),
                keccak256(bytes(name)),
                keccak256(bytes('1')),
                chainId,
                address(this)
            )
        );
    }

    function _mint(address to, uint value) internal {
        totalSupply = totalSupply.add(value);
        balanceOf[to] = balanceOf[to].add(value);
        emit Transfer(address(0), to, value);
    }

    function _burn(address from, uint value) internal {
        balanceOf[from] = balanceOf[from].sub(value);
        totalSupply = totalSupply.sub(value);
        emit Transfer(from, address(0), value);
    }

    function _approve(address owner, address spender, uint value) private {
        allowance[owner][spender] = value;
        emit Approval(owner, spender, value);
    }

    function _transfer(address from, address to, uint value) private {
        balanceOf[from] = balanceOf[from].sub(value);
        balanceOf[to] = balanceOf[to].add(value);
        emit Transfer(from, to, value);
    }

    function approve(address spender, uint value) external returns (bool) {
        _approve(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint value) external returns (bool) {
        if (allowance[from][msg.sender] != uint(-1)) {
            allowance[from][msg.sender] = allowance[from][msg.sender].sub(value);
        }
        _transfer(from, to, value);
        return true;
    }

    function permit(address owner, address spender, uint value, uint deadline, uint8 v, bytes32 r, bytes32 s) external {
        require(deadline >= block.timestamp, 'GangSwap: EXPIRED');
        bytes32 digest = keccak256(
            abi.encodePacked(
                '\x19\x01',
                DOMAIN_SEPARATOR,
                keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonces[owner]++, deadline))
            )
        );
        address recoveredAddress = ecrecover(digest, v, r, s);
        require(recoveredAddress != address(0) && recoveredAddress == owner, 'GangSwap: INVALID_SIGNATURE');
        _approve(owner, spender, value);
    }
}

// a library for performing various math operations
library Math {
    function min(uint x, uint y) internal pure returns (uint z) {
        z = x < y ? x : y;
    }

    // babylonian method (https://en.wikipedia.org/wiki/Methods_of_computing_square_roots#Babylonian_method)
    function sqrt(uint y) internal pure returns (uint z) {
        if (y > 3) {
            z = y;
            uint x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}

// a library for handling binary fixed point numbers (https://en.wikipedia.org/wiki/Q_(number_format))
// range: [0, 2**112 - 1]
// resolution: 1 / 2**112
library UQ112x112 {
    uint224 constant Q112 = 2**112;

    // encode a uint112 as a UQ112x112
    function encode(uint112 y) internal pure returns (uint224 z) {
        z = uint224(y) * Q112; // never overflows
    }

    // divide a UQ112x112 by a uint112, returning a UQ112x112
    function uqdiv(uint224 x, uint112 y) internal pure returns (uint224 z) {
        z = x / uint224(y);
    }
}

interface IERC20 {
    event Approval(address indexed owner, address indexed spender, uint value);
    event Transfer(address indexed from, address indexed to, uint value);

    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);
    function totalSupply() external view returns (uint);
    function balanceOf(address owner) external view returns (uint);
    function allowance(address owner, address spender) external view returns (uint);

    function approve(address spender, uint value) external returns (bool);
    function transfer(address to, uint value) external returns (bool);
    function transferFrom(address from, address to, uint value) external returns (bool);
}

contract GangSwapPair is IPancakePair, GangSwapERC20 {
    using SafeMath  for uint;
    using UQ112x112 for uint224;

    uint public constant MINIMUM_LIQUIDITY = 10**3;
    bytes4 private constant SELECTOR = bytes4(keccak256(bytes('transfer(address,uint256)')));

    address public factory;
    address public token0;
    address public token1;

    uint112 private reserve0;           // uses single storage slot, accessible via getReserves
    uint112 private reserve1;           // uses single storage slot, accessible via getReserves
    uint32  private blockTimestampLast; // uses single storage slot, accessible via getReserves

    uint public price0CumulativeLast;
    uint public price1CumulativeLast;
    uint public kLast; // GangSwap: always 0 (no protocol fee); kept for the V2 interface

    // GangSwap (spec §6.1 P1): the quote side carries a virtual reserve V, fixed at creation. getReserves() and
    // Sync report EFFECTIVE reserves (quote side = real + V); real quote = reserve - V. feeAccrued is the quote fee
    // held for GangSwapFees, never part of the reserves.
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;
    bool public quoteIs0;
    uint public virtualReserve;
    uint public feeAccrued;

    uint private unlocked = 1;
    modifier lock() {
        require(unlocked == 1, 'GangSwap: LOCKED');
        unlocked = 0;
        _;
        unlocked = 1;
    }

    function getReserves() public view returns (uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    function _safeTransfer(address token, address to, uint value) private {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'GangSwap: TRANSFER_FAILED');
    }

    event Mint(address indexed sender, uint amount0, uint amount1);
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);
    event FeeTaken(uint feeQuote, uint feeTokenBurned);
    event FeesClaimed(address indexed to, uint amount);

    constructor() public {
        factory = msg.sender;
    }

    // called once by the factory at time of deployment
    function initialize(address _token0, address _token1, bool _quoteIs0, uint _virtualReserve) external {
        require(msg.sender == factory, 'GangSwap: FORBIDDEN'); // sufficient check
        token0 = _token0;
        token1 = _token1;
        quoteIs0 = _quoteIs0;
        virtualReserve = _virtualReserve;
    }

    // GangSwap (P2): balances as the V2 maths sees them. Quote side: + V - feeAccrued (the pair always holds at least
    // feeAccrued of the quote, spec I6).
    function _balances() private view returns (uint balance0, uint balance1) {
        balance0 = IERC20(token0).balanceOf(address(this));
        balance1 = IERC20(token1).balanceOf(address(this));
        if (quoteIs0) balance0 = balance0.add(virtualReserve).sub(feeAccrued);
        else balance1 = balance1.add(virtualReserve).sub(feeAccrued);
    }

    // GangSwap (P11) views for integrators and GangSwapRouter.
    function realQuoteReserve() external view returns (uint) {
        return uint(quoteIs0 ? reserve0 : reserve1).sub(virtualReserve);
    }

    // The part of the pair's quote balance that is not an input: balanceOf(pair) - quoteBalanceBase() = quote sent in.
    function quoteBalanceBase() external view returns (uint) {
        return uint(quoteIs0 ? reserve0 : reserve1).sub(virtualReserve).add(feeAccrued);
    }

    // GangSwap (P8): the quote fee goes to GangSwapFees only.
    function claimFees() external lock returns (uint amount) {
        require(msg.sender == IPancakeFactory(factory).fees(), 'GangSwap: FORBIDDEN');
        amount = feeAccrued;
        feeAccrued = 0;
        if (amount > 0) _safeTransfer(quoteIs0 ? token0 : token1, msg.sender, amount);
        emit FeesClaimed(msg.sender, amount);
    }

    // update reserves and, on the first call per block, price accumulators
    function _update(uint balance0, uint balance1, uint112 _reserve0, uint112 _reserve1) private {
        require(balance0 <= uint112(-1) && balance1 <= uint112(-1), 'GangSwap: OVERFLOW');
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            // * never overflows, and + overflow is desired
            price0CumulativeLast += uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
            price1CumulativeLast += uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
        }
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;
        emit Sync(reserve0, reserve1);
    }

    // this low-level function should be called from a contract which performs important safety checks
    // GangSwap (P5): one-shot, by the factory's migrator, at graduation; the LP goes to 0xdead.
    function mint(address to) external lock returns (uint liquidity) {
        require(msg.sender == IPancakeFactory(factory).migrator() && totalSupply == 0, 'GangSwap: FORBIDDEN');
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        (uint balance0, uint balance1) = _balances();
        uint amount0 = balance0.sub(_reserve0);
        uint amount1 = balance1.sub(_reserve1);

        liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY);
       _mint(address(0), MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens
        require(liquidity > 0, 'GangSwap: INSUFFICIENT_LIQUIDITY_MINTED');
        _mint(to, liquidity);

        _update(balance0, balance1, _reserve0, _reserve1);
        emit Mint(msg.sender, amount0, amount1);
    }

    // GangSwap (P6): liquidity can never be removed. Kept (reverting, deliberately not `view`) so the V2 interface and
    // selector stay; the compiler's "unreachable code" warning for the `lock`-free body is expected.
    function burn(address) external returns (uint, uint) {
        revert('GangSwap: BURN_DISABLED');
    }

    // this low-level function should be called from a contract which performs important safety checks
    function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data) external lock {
        require(data.length == 0, 'GangSwap: NO_FLASH_SWAP'); // GangSwap (P4)
        require(amount0Out > 0 || amount1Out > 0, 'GangSwap: INSUFFICIENT_OUTPUT_AMOUNT');
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        require(amount0Out < _reserve0 && amount1Out < _reserve1, 'GangSwap: INSUFFICIENT_LIQUIDITY');

        uint balance0;
        uint balance1;
        { // scope for _token{0,1}, avoids stack too deep errors
        address _token0 = token0;
        address _token1 = token1;
        require(to != _token0 && to != _token1, 'GangSwap: INVALID_TO');
        if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out); // optimistically transfer tokens
        if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out); // optimistically transfer tokens
        (balance0, balance1) = _balances();
        }
        uint amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, 'GangSwap: INSUFFICIENT_INPUT_AMOUNT');
        { // scope for reserve{0,1}Adjusted, avoids stack too deep errors
        uint balance0Adjusted = (balance0.mul(10000).sub(amount0In.mul(100)));
        uint balance1Adjusted = (balance1.mul(10000).sub(amount1In.mul(100)));
        require(balance0Adjusted.mul(balance1Adjusted) >= uint(_reserve0).mul(_reserve1).mul(10000**2), 'GangSwap: K');
        }

        (balance0, balance1) = _takeFees(amount0In, amount1In, balance0, balance1);
        _update(balance0, balance1, _reserve0, _reserve1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    // GangSwap (P3): the 1% fee (rounded down) leaves the pool, so k only grows by rounding. Quote fee -> feeAccrued
    // (GangSwapFees claims it); token fee -> 0xdead. Returns the balances net of the fee.
    function _takeFees(uint amount0In, uint amount1In, uint balance0, uint balance1) private returns (uint, uint) {
        uint fee0 = amount0In / 100;
        uint fee1 = amount1In / 100;
        uint feeQuote = quoteIs0 ? fee0 : fee1;
        uint feeToken = quoteIs0 ? fee1 : fee0;
        if (feeQuote > 0) feeAccrued = feeAccrued.add(feeQuote);
        if (feeToken > 0) _safeTransfer(quoteIs0 ? token1 : token0, DEAD, feeToken);
        if (feeQuote > 0 || feeToken > 0) emit FeeTaken(feeQuote, feeToken);
        return (balance0.sub(fee0), balance1.sub(fee1));
    }

    // force balances to match reserves
    function skim(address to) external lock {
        (uint balance0, uint balance1) = _balances();
        _safeTransfer(token0, to, balance0.sub(reserve0));
        _safeTransfer(token1, to, balance1.sub(reserve1));
    }

    // force reserves to match balances
    function sync() external lock {
        (uint balance0, uint balance1) = _balances();
        _update(balance0, balance1, reserve0, reserve1);
    }
}

contract GangSwapFactory is IPancakeFactory {
    bytes32 public constant INIT_CODE_PAIR_HASH = keccak256(abi.encodePacked(type(GangSwapPair).creationCode));

    // GangSwap (§6.2): only the migrator creates pairs (at graduation); GangSwapFees claims the quote fees. No owner.
    address public migrator;
    address public fees;

    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;

    event PairCreated(address indexed token0, address indexed token1, address pair, uint);

    constructor(address _migrator, address _fees) public {
        require(_migrator != address(0) && _fees != address(0), 'GangSwap: ZERO_ADDRESS');
        migrator = _migrator;
        fees = _fees;
    }

    function allPairsLength() external view returns (uint) {
        return allPairs.length;
    }

    function createPair(address tokenA, address tokenB, address quote, uint virtualReserve) external returns (address pair) {
        require(msg.sender == migrator, 'GangSwap: FORBIDDEN');
        require(quote == tokenA || quote == tokenB, 'GangSwap: BAD_QUOTE');
        require(tokenA != tokenB, 'GangSwap: IDENTICAL_ADDRESSES');
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'GangSwap: ZERO_ADDRESS');
        require(getPair[token0][token1] == address(0), 'GangSwap: PAIR_EXISTS'); // single check is sufficient
        bytes memory bytecode = type(GangSwapPair).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        IPancakePair(pair).initialize(token0, token1, quote == token0, virtualReserve);
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair; // populate mapping in the reverse direction
        allPairs.push(pair);
        emit PairCreated(token0, token1, pair, allPairs.length);
    }
}
