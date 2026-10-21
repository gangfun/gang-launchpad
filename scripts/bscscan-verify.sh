#!/usr/bin/env bash
# One-click Etherscan API V2 verify (BSC chainId 56) for live v4 Launchpad / Migrator / GANG.
# Idempotent: exits 0 if already verified or verify succeeds.
# NEVER prints API key values.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CHAIN_ID=56
COMPILER=0.8.28
OPT_RUNS=200
LAUNCHPAD=0x86854E8ee7D438ca9B52407DCF92D1616385dDcc
MIGRATOR=0xb2bBe5CDB61dABEef32dFd8E65B8F252D6a86D17
GANG=0xDA519ED3Ed0880C96610390467b1A8Eb43f16ab2
OWNER=0x4EEdcDF5fab775e10C0D09951b6F59Ab81ba19d3
FEE_VAULT=0x3464aa1097Aa46502Db847E4c6d0A2D52a871Af4
AGENT_ID=0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F
FACTORY=0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73
WBNB=0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c

load_key() {
  # Etherscan API V2 unified key (BSC chainId 56). Accept legacy BSCSCAN_API_KEY alias.
  if [[ -n "${ETHERSCAN_API_KEY:-}" ]]; then
    export ETHERSCAN_API_KEY
    echo "key_source=env:ETHERSCAN_API_KEY" >&2
    return 0
  fi
  if [[ -n "${BSCSCAN_API_KEY:-}" ]]; then
    export ETHERSCAN_API_KEY="$BSCSCAN_API_KEY"
    echo "key_source=env:BSCSCAN_API_KEY→ETHERSCAN_API_KEY" >&2
    return 0
  fi
  local f
  for f in \
    "${HOME}/gang/.env" \
    "/Users/lazy/gang/.env" \
    "${ROOT}/.env" \
    "/opt/gang/.env" \
    "/opt/gang-launchpad/.env"
  do
    if [[ -f "$f" ]]; then
      # shellcheck disable=SC1090
      set -a
      # Only export known key names; do not source whole file (may have unrelated secrets usage)
      local line k v
      while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
          ETHERSCAN_API_KEY=*|BSCSCAN_API_KEY=*)
            k="${line%%=*}"
            v="${line#*=}"
            v="${v%\"}"; v="${v#\"}"
            v="${v%\'}"; v="${v#\'}"
            if [[ -n "$v" ]]; then
              export ETHERSCAN_API_KEY="$v"
              echo "key_source=file:${f} name=${k}" >&2
              set +a
              return 0
            fi
            ;;
        esac
      done < "$f"
      set +a
    fi
  done
  return 1
}

if ! load_key; then
  echo "ETHERSCAN_API_KEY: MISSING (Etherscan API V2; also accepts BSCSCAN_API_KEY alias)" >&2
  echo "Drop key into ~/gang/.env as ETHERSCAN_API_KEY=... then re-run: ./scripts/bscscan-verify.sh" >&2
  exit 2
fi

if ! command -v forge >/dev/null || ! command -v cast >/dev/null; then
  echo "forge/cast required in PATH" >&2
  exit 3
fi

echo "Building…"
forge build >/dev/null

verify_one() {
  local addr="$1" contract="$2" ctor_sig="$3"
  shift 3
  local args
  args="$(cast abi-encode "$ctor_sig" "$@")"
  echo "=== verify ${contract} @ ${addr} ==="
  # Already verified? forge returns non-zero sometimes; treat common messages as OK
  set +e
  out="$(forge verify-contract \
    "$addr" \
    "$contract" \
    --chain-id "$CHAIN_ID" \
    --compiler-version "$COMPILER" \
    --num-of-optimizations "$OPT_RUNS" \
    --watch \
    --verifier etherscan \
    --verifier-url "https://api.etherscan.io/v2/api?chainid=56" \
    --etherscan-api-key "$ETHERSCAN_API_KEY" \
    --constructor-args "$args" 2>&1)"
  rc=$?
  set -e
  echo "$out" | sed -E 's/(api[_-]?key[=: ]+)[^[:space:]]+/\1***REDACTED***/gi'
  if [[ $rc -eq 0 ]]; then
    echo "OK ${contract}"
    return 0
  fi
  if echo "$out" | grep -qiE 'already verified|Contract source code already verified'; then
    echo "OK ${contract} (already verified)"
    return 0
  fi
  echo "FAIL ${contract} rc=${rc}" >&2
  return 1
}

fail=0
verify_one "$LAUNCHPAD" "src/Launchpad.sol:Launchpad" \
  "constructor(address,address,address)" "$OWNER" "$FEE_VAULT" "$AGENT_ID" || fail=1
verify_one "$MIGRATOR" "src/Migrator.sol:Migrator" \
  "constructor(address,address,address)" "$FACTORY" "$WBNB" "$LAUNCHPAD" || fail=1
verify_one "$GANG" "src/LaunchToken.sol:LaunchToken" \
  "constructor(string,string)" "Gang" "GANG" || fail=1

if [[ $fail -ne 0 ]]; then
  echo "One or more verifies failed. See output above." >&2
  exit 1
fi
echo "All three contracts verified (or already verified)."
exit 0
