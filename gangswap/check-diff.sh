#!/usr/bin/env bash
# Shows every change GangSwap makes to the verified PancakeSwap V2 sources (spec §10 item 1). Renames
# (Pancake -> GangSwap in contract names, LP name/symbol and revert strings) are normalised away first, so what's left
# is the behaviour diff a reviewer must read. Usage: gangswap/check-diff.sh [pair|router]
set -euo pipefail
cd "$(dirname "$0")"
norm() {
  sed -E -e "s/'Pancake(Router|Library)?: /'X: /g" -e "s/'GangSwap(Router|Library)?: /'X: /g" \
    -e 's/PancakePair/GangSwapPair/g; s/PancakeFactory is/GangSwapFactory is/g; s/contract PancakeFactory/contract GangSwapFactory/g' \
    -e 's/PancakeERC20/GangSwapERC20/g; s/contract PancakeRouter/contract GangSwapRouter/g' \
    -e "s/'Pancake LPs'/'GangSwap LPs'/; s/'Cake-LP'/'GS-LP'/" "$1"
}
which="${1:-all}"
if [[ "$which" == pair || "$which" == all ]]; then
  diff -u <(norm upstream/PancakeFactory.sol) <(norm src/GangSwapPair.sol) --label upstream/PancakeFactory.sol --label src/GangSwapPair.sol || true
fi
if [[ "$which" == router || "$which" == all ]]; then
  diff -u <(norm upstream/PancakeRouter.sol) <(norm src/GangSwapRouter.sol) --label upstream/PancakeRouter.sol --label src/GangSwapRouter.sol || true
fi
