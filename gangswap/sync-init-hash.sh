#!/usr/bin/env bash
# Rewrites GangSwapRouter's hard-coded pair init code hash to match the current build of GangSwapPair (any edit to
# src/GangSwapPair.sol, even a comment, changes it: solc 0.5.16 embeds a metadata hash of the source). Run after editing
# the pair, then rebuild; test_routerInitCodeHashMatchesFactory and the deploy script both check the result.
set -euo pipefail
cd "$(dirname "$0")"
forge build >/dev/null
bytecode=$(python3 -I -c "import json;print(json.load(open('out/GangSwapPair.sol/GangSwapPair.json'))['bytecode']['object'])")
hash=$(cast keccak "$bytecode")
hash=${hash#0x}
sed -i.bak -E "s/hex'[0-9a-f]{64}' \/\/ init code hash/hex'${hash}' \/\/ init code hash/" src/GangSwapRouter.sol
rm -f src/GangSwapRouter.sol.bak
forge build >/dev/null
echo "GangSwapRouter init code hash: 0x${hash}"
