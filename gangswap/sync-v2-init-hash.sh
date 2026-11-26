#!/usr/bin/env bash
# Rewrites GangSwapV2Router's hard-coded pair init code hash to match the current build of GangSwapV2Pair (any edit to
# src/v2/GangSwapV2Pair.sol, even a comment, changes it: solc 0.5.16 embeds a metadata hash of the source). Run after editing
# the pair, then rebuild; test_routerInitCodeHashMatchesFactory and the deploy script both check the result.
set -euo pipefail
cd "$(dirname "$0")"
forge build >/dev/null
bytecode=$(python3 -I -c "import json;print(json.load(open('out/GangSwapV2Pair.sol/GangSwapV2Pair.json'))['bytecode']['object'])")
hash=$(cast keccak "$bytecode")
hash=${hash#0x}
sed -i.bak -E "s/hex'[0-9a-f]{64}' \/\/ init code hash/hex'${hash}' \/\/ init code hash/" src/v2/GangSwapV2Router.sol
rm -f src/v2/GangSwapV2Router.sol.bak
forge build >/dev/null
echo "GangSwapV2Router init code hash: 0x${hash}"
