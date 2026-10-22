#!/usr/bin/env bash
# Stocks track · Chapel (chainId 97) deploy helper.
# BAN: never broadcasts to chain 56 / mainnet.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
export PATH="${HOME}/.foundry/bin:${PATH}"

RPC="${CHAPEL_RPC_URL:-${BSC_TESTNET_RPC_URL:-https://bsc-testnet-rpc.publicnode.com}}"
CID="$(cast chain-id --rpc-url "$RPC")"
if [[ "$CID" == "56" ]]; then
  echo "REFUSE: RPC resolved to mainnet chainId 56" >&2
  exit 2
fi
if [[ "$CID" != "97" ]]; then
  echo "REFUSE: expected Chapel chainId 97, got $CID" >&2
  exit 2
fi

ARGS=(script/stocks/DeployChapel.s.sol --rpc-url "$RPC")
if [[ "${1:-}" == "--broadcast" ]]; then
  if [[ -z "${CHAPEL_PRIVATE_KEY:-${TESTNET_PRIVATE_KEY:-${CHAPEL_TEST_PRIVATE_KEY:-}}}" ]]; then
    echo "REFUSE: set CHAPEL_PRIVATE_KEY or TESTNET_PRIVATE_KEY (not DEPLOYER_PRIVATE_KEY)" >&2
    exit 3
  fi
  if [[ -n "${DEPLOYER_PRIVATE_KEY:-}" && -z "${CHAPEL_PRIVATE_KEY:-${TESTNET_PRIVATE_KEY:-}}" ]]; then
    echo "REFUSE: DEPLOYER_PRIVATE_KEY alone is not allowed for Chapel broadcast" >&2
    exit 3
  fi
  ARGS+=(--broadcast)
  echo "Broadcasting to Chapel (97) only…"
else
  echo "Dry-run (no broadcast) against chainId $CID …"
fi

forge script "${ARGS[@]}"
