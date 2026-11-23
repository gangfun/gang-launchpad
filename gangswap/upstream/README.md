# Upstream sources (do not edit)

Verified mainnet sources from Sourcify (BSC, chain 56), line endings normalised to LF:

- `PancakeFactory.sol`: PancakeFactory `0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73` (contains `PancakePair`), solc `=0.5.16`
- `PancakeRouter.sol`: PancakeRouter `0x10ED43C718714eb63d5aA57B78B54704E256024E`, solc `=0.6.6`

PancakeSwap V2 is a fork of Uniswap V2 (GPL-3.0). `../src/GangSwapPair.sol` and `../src/GangSwapRouter.sol` are
derived from these files and stay under GPL-3.0. `../check-diff.sh` shows every change against them.
