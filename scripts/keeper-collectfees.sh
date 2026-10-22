#!/usr/bin/env bash
# Daily permissionless collectFees (+ optional flushBuyback) for Launchpad v4.1.
# Default: dry-run (read-only). Broadcast ONLY with --broadcast and KEEPER_PRIVATE_KEY.
# No contract role. Never commit keys. VPS env: /opt/gang/keeper/.env
set -euo pipefail
export PATH="/root/.foundry/bin:/usr/local/bin:$PATH"

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

Default is dry-run: reads accruedFees / pendingBuyback, prints plan.
--broadcast requires KEEPER_PRIVATE_KEY (env or sourced from \$KEEPER_ENV).
Derived sender must match EXPECTED_KEEPER (${EXPECTED_KEEPER}).
If accruedFees > max (default ${MAX_ACCRUED_ETHER} BNB), refuse broadcast.
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

if ! command -v cast >/dev/null; then
  echo "cast required (foundry)" >&2
  exit 3
fi

if [[ -z "${KEEPER_PRIVATE_KEY:-}" && -f "$KEEPER_ENV" ]]; then
  set -a
  # shellcheck disable=SC1091
  source <(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' "$KEEPER_ENV" || true)
  set +a
fi

ts() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }

log_line() {
  local line="$1"
  echo "$line"
  if [[ -n "$LOG_DIR" ]]; then
    mkdir -p "$LOG_DIR"
    echo "$line" >>"$LOG_DIR/keeper-collectfees.log"
  fi
}

# cast may print "123 [1.23e2]" — keep first token only
wei_only() { awk '{print $1}' <<<"$1"; }
wei_to_ether() { cast --from-wei "$(wei_only "$1")" ether; }
gt_wei() { python3 -c "import sys; sys.exit(0 if int(sys.argv[1]) > int(sys.argv[2]) else 1)" "$(wei_only "$1")" "$(wei_only "$2")"; }

ACCRUED="$(wei_only "$(cast call "$LAUNCHPAD" "accruedFees()(uint256)" --rpc-url "$BSC_RPC")")"
PENDING="$(wei_only "$(cast call "$LAUNCHPAD" "pendingBuyback()(uint256)" --rpc-url "$BSC_RPC")")"
FEE_VAULT="$(wei_only "$(cast call "$LAUNCHPAD" "feeVault()(address)" --rpc-url "$BSC_RPC")")"
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
  log_line "$(ts) DRY-RUN only. VPS: KEEPER_ENV=${KEEPER_ENV} $0 --broadcast [--log-dir /opt/gang/keeper/logs]"
  exit 0
fi

if [[ "$OVER_MAX" -eq 1 ]]; then
  exit 5
fi

if [[ -z "${KEEPER_PRIVATE_KEY:-}" ]]; then
  echo "ERROR: --broadcast set but KEEPER_PRIVATE_KEY missing (env or ${KEEPER_ENV})." >&2
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

PENDING="$(wei_only "$(cast call "$LAUNCHPAD" "pendingBuyback()(uint256)" --rpc-url "$BSC_RPC")")"
if [[ "$PENDING" != "0" ]]; then
  log_line "$(ts) BROADCAST flushBuyback…"
  cast send "$LAUNCHPAD" "flushBuyback()" --rpc-url "$BSC_RPC" --private-key "$KEEPER_PRIVATE_KEY"
else
  log_line "$(ts) pendingBuyback=0 — no flush"
fi

log_line "$(ts) done accrued=$(wei_to_ether "$(wei_only "$(cast call "$LAUNCHPAD" "accruedFees()(uint256)" --rpc-url "$BSC_RPC")")")BNB pending=$(wei_to_ether "$(wei_only "$(cast call "$LAUNCHPAD" "pendingBuyback()(uint256)" --rpc-url "$BSC_RPC")")")BNB"
