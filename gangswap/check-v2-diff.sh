#!/usr/bin/env bash
# Compare v1 and v2 source files after normalizing v2 contract and interface names.
# Pass "upstream" to compare the v2 pair, factory and router with PancakeSwap instead.
set -euo pipefail
cd "$(dirname "$0")"
if [[ "${1:-}" == upstream ]]; then
  norm() {
    sed -E -e 's/GangSwapV2/GangSwap/g; s/PancakePair/GangSwapPair/g; s/PancakeERC20/GangSwapERC20/g' \
      -e 's/PancakeFactory is/GangSwapFactory is/g; s/contract Pancake(Factory|Router)/contract GangSwap\1/g' \
      -e "s/'(Pancake|GangSwap)(Router|Library)?: /'X: /g; s/'Pancake LPs'/'GangSwap LPs'/; s/'Cake-LP'/'GS-LP'/" "$1"
  }
  compare_upstream() {
    diff -u --label "$1" --label "$2" <(norm "$1") <(norm "$2") || [[ "$?" == 1 ]]
  }
  compare_upstream upstream/PancakeFactory.sol src/v2/GangSwapV2Pair.sol
  compare_upstream upstream/PancakeRouter.sol src/v2/GangSwapV2Router.sol
  exit
fi

for part in Pair Router Boost Fees Migrator interfaces; do
  if [[ "$part" == interfaces ]]; then
    before=src/interfaces/IGangSwap.sol
    after=src/v2/interfaces/IGangSwapV2.sol
  else
    before="src/GangSwap${part}.sol"
    after="src/v2/GangSwapV2${part}.sol"
  fi
  diff -u --label "$before" --label "$after" "$before" <(sed 's/GangSwapV2/GangSwap/g' "$after") || [[ "$?" == 1 ]]
done
