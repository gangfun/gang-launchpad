#!/usr/bin/env bash
# Daily permissionless collectFees (+ optional flushBuyback) for Launchpad v4.1.
# Default: dry-run. Broadcast ONLY with --broadcast + KEEPER_PRIVATE_KEY.
# No contract role. Never commit keys. VPS: /opt/gang/keeper/.env
set -euo pipefail
export PATH="/root/.foundry/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

LAUNCHPAD="${LAUNCHPAD:-0x315Ba2e8952D06094CC636b2B84229FA32fb23A7}"
EXPECTED_KEEPER="${EXPECTED_KEEPER:-0xb6f1f1bfb92476abb0998b425de0dec5f927cfc7}"
BSC_RPC="${BSC_RPC:-${BSC_RPC_URL:-https://bsc-dataseed.binance.org}}"
KEEPER_ENV="${KEEPER_ENV:-/opt/gang/keeper/.env}"
MAX_ACCRUED_ETHER="${MAX_ACCRUED_ETHER:-0.2}"
BROADCAST=0
LOG_DIR=""

usage() {
  cat <<U
Usage: $0 [--broadcast] [--max-accrued <ether>] [--log-dir <path>]

Default dry-run. --broadcast needs KEEPER_PRIVATE_KEY (env or \$KEEPER_ENV).
Sender must match EXPECTED_KEEPER (${EXPECTED_KEEPER}).
Refuse auto-broadcast if accruedFees > max (default ${MAX_ACCRUED_ETHER} BNB).
U
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --broadcast) BROADCAST=1; shift ;;
    --max-accrued) MAX_ACCRUED_ETHER="$2"; shift 2 ;;
    --log-dir) LOG_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage; exit 1 ;;
  esac
done

command -v cast >/dev/null || { echo "cast required" >&2; exit 3; }
command -v python3 >/dev/null || { echo "python3 required" >&2; exit 3; }

if [[ -z "${KEEPER_PRIVATE_KEY:-}" && -f "$KEEPER_ENV" ]]; then
  set -a
  # shellcheck disable=SC1091
  source <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$KEEPER_ENV" || true)
  set +a
  BSC_RPC="${BSC_RPC:-${BSC_RPC_URL:-https://bsc-dataseed.binance.org}}"
fi

ts() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }
log_line() {
  echo "$1"
  if [[ -n "$LOG_DIR" ]]; then
    mkdir -p "$LOG_DIR"
    echo "$1" >>"$LOG_DIR/keeper-collectfees.log"
  fi
}

# cast call --json → ["123"] or "0xabc…"; never the "123 [1.23e2]" pretty form
u256() {
  cast call "$1" "$2" --rpc-url "$BSC_RPC" --json \
    | python3 -c 'import sys,json; v=json.load(sys.stdin); print(v[0] if isinstance(v,list) else v)'
}
addr() {
  cast call "$1" "$2" --rpc-url "$BSC_RPC" --json \
    | python3 -c 'import sys,json; v=json.load(sys.stdin); print(v[0] if isinstance(v,list) else v)'
}
wei_to_ether() { cast --from-wei "$1" ether; }
gt_wei() { python3 -c "import sys; sys.exit(0 if int(sys.argv[1]) > int(sys.argv[2]) else 1)" "$1" "$2"; }

ACCRUED="$(u256 "$LAUNCHPAD" "accruedFees()(uint256)")"
PENDING="$(u256 "$LAUNCHPAD" "pendingBuyback()(uint256)")"
FEE_VAULT="$(addr "$LAUNCHPAD" "feeVault()(address)")"
MAX_WEI="$(cast --to-wei "$MAX_ACCRUED_ETHER" ether)"

log_line "$(ts) launchpad=${LAUNCHPAD} expected_keeper=${EXPECTED_KEEPER}"
log_line "$(ts) feeVault=${FEE_VAULT} accrued=$(wei_to_ether "$ACCRUED")BNB pending=$(wei_to_ether "$PENDING")BNB max=${MAX_ACCRUED_ETHER}BNB"

if [[ "$ACCRUED" == "0" && "$PENDING" == "0" ]]; then
  log_line "$(ts) skip: nothing to settle"
  exit 0
fi

OVER_MAX=0
if [[ "$ACCRUED" != "0" ]] && gt_wei "$ACCRUED" "$MAX_WEI"; then
  OVER_MAX=1
  log_line "$(ts) WARN: accrued over max — auto settle blocked"
fi

if [[ "$BROADCAST" -eq 0 ]]; then
  log_line "$(ts) DRY-RUN only. VPS: $0 --broadcast --log-dir /opt/gang/keeper/logs"
  exit 0
fi

if [[ "$OVER_MAX" -eq 1 ]]; then
  exit 5
fi

if [[ -z "${KEEPER_PRIVATE_KEY:-}" ]]; then
  echo "ERROR: --broadcast but KEEPER_PRIVATE_KEY missing" >&2
  exit 4
fi

SENDER="$(cast wallet address --private-key "$KEEPER_PRIVATE_KEY")"
if [[ "$(echo "$SENDER" | tr 'A-F' 'a-f')" != "$(echo "$EXPECTED_KEEPER" | tr 'A-F' 'a-f')" ]]; then
  echo "ERROR: key address ${SENDER} != EXPECTED_KEEPER ${EXPECTED_KEEPER}" >&2
  exit 6
fi

log_line "$(ts) sender=${SENDER} balance=$(wei_to_ether "$(cast balance "$SENDER" --rpc-url "$BSC_RPC")")BNB"

if [[ "$ACCRUED" != "0" ]]; then
  log_line "$(ts) BROADCAST collectFees…"
  cast send "$LAUNCHPAD" "collectFees()" --rpc-url "$BSC_RPC" --private-key "$KEEPER_PRIVATE_KEY"
fi

PENDING="$(u256 "$LAUNCHPAD" "pendingBuyback()(uint256)")"
if [[ "$PENDING" != "0" ]]; then
  log_line "$(ts) BROADCAST flushBuyback…"
  cast send "$LAUNCHPAD" "flushBuyback()" --rpc-url "$BSC_RPC" --private-key "$KEEPER_PRIVATE_KEY"
else
  log_line "$(ts) pendingBuyback=0 — no flush"
fi

log_line "$(ts) done accrued=$(wei_to_ether "$(u256 "$LAUNCHPAD" "accruedFees()(uint256)")")BNB pending=$(wei_to_ether "$(u256 "$LAUNCHPAD" "pendingBuyback()(uint256)")")BNB"
