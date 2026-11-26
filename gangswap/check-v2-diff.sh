#!/usr/bin/env bash
# Compare v1 and v2 source files after normalizing v2 contract and interface names.
set -euo pipefail
cd "$(dirname "$0")"
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
