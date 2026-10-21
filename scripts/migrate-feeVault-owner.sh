#!/usr/bin/env bash
# Prepare / dry-run feeVault + Ownable2Step owner migration for live Launchpad v4.
# Default: print calldata + cast call simulate. Broadcast ONLY with --broadcast AND keys present.
# Does NOT invent addresses — NEW_FEE_VAULT and NEW_OWNER are required.
set -euo pipefail

LAUNCHPAD="${LAUNCHPAD:-0x86854E8ee7D438ca9B52407DCF92D1616385dDcc}"
BSC_RPC="${BSC_RPC:-${BSC_RPC_URL:-https://bsc-dataseed.binance.org}}"
BROADCAST=0
NEW_FEE_VAULT=""
NEW_OWNER=""

usage() {
  cat <<U
Usage: $0 --new-fee-vault <addr> --new-owner <addr> [--broadcast]

Default is dry-run: prints calldata and (if cast+rpc) read-only checks.
--broadcast requires OWNER_KEY (current owner) for setFeeVault + transferOwnership.
acceptOwnership must be signed by NEW_OWNER (separate key / Safe) — this script
only prints that step unless NEW_OWNER_KEY is also set.
U
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --new-fee-vault) NEW_FEE_VAULT="$2"; shift 2 ;;
    --new-owner) NEW_OWNER="$2"; shift 2 ;;
    --broadcast) BROADCAST=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$NEW_FEE_VAULT" || -z "$NEW_OWNER" ]]; then
  echo "ERROR: --new-fee-vault and --new-owner are required (no invented addresses)." >&2
  usage
  exit 2
fi

# basic address shape check
is_addr() { [[ "$1" =~ ^0x[0-9a-fA-F]{40}$ ]]; }
if ! is_addr "$NEW_FEE_VAULT" || ! is_addr "$NEW_OWNER"; then
  echo "ERROR: addresses must be 0x + 40 hex" >&2
  exit 2
fi

if ! command -v cast >/dev/null; then
  echo "cast required" >&2
  exit 3
fi

SET_FEE="$(cast calldata "setFeeVault(address)" "$NEW_FEE_VAULT")"
XFER="$(cast calldata "transferOwnership(address)" "$NEW_OWNER")"
ACCEPT="$(cast calldata "acceptOwnership()")"

echo "=== Launchpad ${LAUNCHPAD} ==="
echo "NEW_FEE_VAULT=${NEW_FEE_VAULT}"
echo "NEW_OWNER=${NEW_OWNER}"
echo
echo "calldata setFeeVault:        ${SET_FEE}"
echo "calldata transferOwnership:  ${XFER}"
echo "calldata acceptOwnership:    ${ACCEPT}"
echo

echo "--- read-only ---"
cast call "$LAUNCHPAD" "owner()(address)" --rpc-url "$BSC_RPC" || true
cast call "$LAUNCHPAD" "feeVault()(address)" --rpc-url "$BSC_RPC" || true
cast call "$LAUNCHPAD" "pendingOwner()(address)" --rpc-url "$BSC_RPC" || true
echo

if [[ "$BROADCAST" -eq 0 ]]; then
  echo "DRY-RUN only. To broadcast (needs Lazy signature / OWNER_KEY):"
  echo "  $0 --new-fee-vault ${NEW_FEE_VAULT} --new-owner ${NEW_OWNER} --broadcast"
  echo
  echo "Manual cast send (Lazy):"
  echo "  cast send ${LAUNCHPAD} \"setFeeVault(address)\" ${NEW_FEE_VAULT} --rpc-url \$BSC_RPC --private-key \$OWNER_KEY"
  echo "  cast send ${LAUNCHPAD} \"transferOwnership(address)\" ${NEW_OWNER} --rpc-url \$BSC_RPC --private-key \$OWNER_KEY"
  echo "  # then from NEW_OWNER key / Safe:"
  echo "  cast send ${LAUNCHPAD} \"acceptOwnership()\" --rpc-url \$BSC_RPC --private-key \$NEW_OWNER_KEY"
  exit 0
fi

if [[ -z "${OWNER_KEY:-}" ]]; then
  echo "ERROR: --broadcast set but OWNER_KEY missing. Refusing." >&2
  exit 4
fi

echo "BROADCAST setFeeVault…"
cast send "$LAUNCHPAD" "setFeeVault(address)" "$NEW_FEE_VAULT" --rpc-url "$BSC_RPC" --private-key "$OWNER_KEY"
echo "BROADCAST transferOwnership…"
cast send "$LAUNCHPAD" "transferOwnership(address)" "$NEW_OWNER" --rpc-url "$BSC_RPC" --private-key "$OWNER_KEY"
echo "pendingOwner:"
cast call "$LAUNCHPAD" "pendingOwner()(address)" --rpc-url "$BSC_RPC"

if [[ -n "${NEW_OWNER_KEY:-}" ]]; then
  echo "BROADCAST acceptOwnership (NEW_OWNER_KEY present)…"
  cast send "$LAUNCHPAD" "acceptOwnership()" --rpc-url "$BSC_RPC" --private-key "$NEW_OWNER_KEY"
else
  echo "STOP: acceptOwnership requires NEW_OWNER key / Safe — not broadcast."
  echo "  cast send ${LAUNCHPAD} \"acceptOwnership()\" --rpc-url \$BSC_RPC --private-key \$NEW_OWNER_KEY"
fi
