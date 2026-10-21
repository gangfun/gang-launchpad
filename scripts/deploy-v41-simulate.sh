#!/usr/bin/env bash
# Simulate Launchpad v4.1 deploy (slippage source already in tip). NEVER broadcasts.
# Banner: DO NOT broadcast until Lazy written OK.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "============================================================"
echo "  DEPLOY v4.1 SIMULATE ONLY — DO NOT BROADCAST"
echo "  「全部弄不要问」≠ approval to redeploy mainnet Launchpad"
echo "  Wait for Lazy written OK before any --broadcast"
echo "============================================================"

if [[ "${1:-}" == "--broadcast" ]] || [[ "${ALLOW_BROADCAST:-}" == "1" ]]; then
  echo "REFUSED: this script never broadcasts. Use forge script manually only after Lazy written OK." >&2
  exit 99
fi

BSC_RPC="${BSC_RPC:-${BSC_RPC_URL:-https://bsc-dataseed.binance.org}}"
# Anvil default account #0 — local sim identity only
ANVIL_PK="${ANVIL_PK:-0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80}"
FEE_VAULT="${FEE_VAULT:-0x3464aa1097Aa46502Db847E4c6d0A2D52a871Af4}"
# Do NOT set OWNER here: Deploy.s.sol defaults OWNER to deployer. Forcing Lazy's
# owner with anvil pk makes setMigrator revert (OwnableUnauthorizedAccount).

if ! command -v forge >/dev/null; then
  echo "forge required" >&2
  exit 3
fi

export DEPLOYER_PRIVATE_KEY="$ANVIL_PK"
export FEE_VAULT
unset OWNER || true
export PLATFORM_NAME="${PLATFORM_NAME:-Gang}"
export PLATFORM_SYMBOL="${PLATFORM_SYMBOL:-GANG}"

echo "RPC=${BSC_RPC}"
echo "FEE_VAULT=${FEE_VAULT}"
echo "OWNER=<defaults to deployer/anvil for sim; real deploy set OWNER=0x4EEd… with matching DEPLOYER key>"
echo "Running forge script WITHOUT --broadcast (fork sim)…"

forge script script/Deploy.s.sol \
  --fork-url "$BSC_RPC" \
  -vvv

echo
echo "SIMULATE done. Gas estimate is in forge output above."
echo "To ACTUALLY deploy later (Lazy written OK required):"
echo "  export FEE_VAULT=0x3464aa1097Aa46502Db847E4c6d0A2D52a871Af4"
echo "  export OWNER=0x4EEdcDF5fab775e10C0D09951b6F59Ab81ba19d3"
echo "  # DEPLOYER_PRIVATE_KEY must control OWNER (or be OWNER)"
echo "  forge script script/Deploy.s.sol --rpc-url \$BSC_RPC --broadcast --verify"
echo "Then cutover per DEPLOY-V41-READY-2026-10-22.md"
