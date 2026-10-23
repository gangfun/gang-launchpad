#!/usr/bin/env bash
# HISTORICAL. LaunchpadV2 was broadcast on 2026-10-23.
# Do not re-run against mainnet. Addresses: docs/MAINNET-LAUNCHPAD-V2-ADDRESSES-2026-10-23.md
# LaunchpadV2 (+REFPOOL) mainnet Deploy+Wire. Asia/Shanghai.
# REUSES Burner/feeVault/GANG. FORBIDDEN: Soft/U/S txs.
# Gate: CONFIRM_MAINNET_BROADCAST=YES
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT_DIR="${ROOT}/.."
LOG="${OUT_DIR}/_deploy_launchpad_v2.log"
ADDR_MD="${OUT_DIR}/MAINNET-LAUNCHPAD-V2-ADDRESSES-2026-10-23.md"
STATUS_MD="${OUT_DIR}/MAINNET-LAUNCHPAD-V2-STATUS-2026-10-23.md"

export PATH="${HOME}/.foundry/bin:/usr/local/bin:${PATH}"
LEGACY_OWNER="0x4EEdcDF5fab775e10C0D09951b6F59Ab81ba19d3"
MIN_BNB_WEI="50000000000000000"  # 0.05 hard floor (single stack)
WARN_BNB_WEI="80000000000000000" # 0.08 warn
DEFAULT_KEEPER="0xB6f1F1BFb92476Abb0998B425dE0deC5F927cFc7"
DEFAULT_RPC="https://bsc-dataseed.binance.org"

DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run|-n) DRY_RUN=1 ;;
    -h|--help) echo "Usage: $0 [--dry-run]"; exit 0 ;;
  esac
done

_load_env() {
  local f
  for f in "${GANG_ENV:-}" "${HOME}/gang/.env" "${ROOT}/.env"; do
    [[ -z "$f" || ! -f "$f" ]] && continue
    echo "Loading env from: $f"
    set -a; # shellcheck disable=SC1090
    source "$f"; set +a
    return 0
  done
  return 1
}
_load_env || true

BSC_RPC_URL="${BSC_RPC_URL:-$DEFAULT_RPC}"
KEEPER="${KEEPER:-$DEFAULT_KEEPER}"
export BSC_RPC_URL KEEPER
[[ -n "${DEV_WALLET:-}" ]] && export DEV_WALLET
[[ -n "${BSCSCAN_API_KEY:-}" ]] && export BSCSCAN_API_KEY

if [[ -z "${DEPLOYER_PRIVATE_KEY:-}" ]]; then
  echo "ERROR: missing DEPLOYER_PRIVATE_KEY (LazyOS ~/gang/.env)"
  exit 2
fi

DERIVED="$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY")"
OWNER="${OWNER:-$DERIVED}"
export OWNER
echo "OWNER=$OWNER"
if [[ "$(echo "$DERIVED" | tr A-F a-f)" != "$(echo "$LEGACY_OWNER" | tr A-F a-f)" ]]; then
  echo "ERROR: deployer $DERIVED != LEGACY_OWNER $LEGACY_OWNER"
  exit 3
fi

BAL_WEI="$(cast balance "$OWNER" --rpc-url "$BSC_RPC_URL")"
BAL_ETH="$(cast --to-unit "$BAL_WEI" ether)"
echo "balance=${BAL_ETH} BNB"
python3 - <<PY
b=int("$BAL_WEI"); m=int("$MIN_BNB_WEI");
import sys
if b<m:
  print(f"ERROR: need >=0.05 BNB, have {b}"); sys.exit(4)
if b<int("$WARN_BNB_WEI"):
  print("WARN: balance <0.08 BNB — tight for V2 deploy+wire")
PY

echo "=== forge build --skip test ==="
forge build --skip test

ARGS=(script/DeployWireMainnetV2.s.sol:DeployWireMainnetV2 --rpc-url "$BSC_RPC_URL" --chain 56 -vvvv)
if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "=== DRY RUN ==="
  forge script "${ARGS[@]}" 2>&1 | tee "$LOG"
  echo "Dry-run OK. Broadcast: CONFIRM_MAINNET_BROADCAST=YES $0"
  exit 0
fi
if [[ "${CONFIRM_MAINNET_BROADCAST:-}" != "YES" ]]; then
  echo "Refuse broadcast without CONFIRM_MAINNET_BROADCAST=YES (or use --dry-run)"
  exit 5
fi

VERIFY=()
if [[ -n "${BSCSCAN_API_KEY:-}" ]]; then
  VERIFY=(--verify --etherscan-api-key "$BSCSCAN_API_KEY")
fi

echo "=== BROADCAST DeployWireMainnetV2 ==="
forge script "${ARGS[@]}" --broadcast "${VERIFY[@]}" 2>&1 | tee "$LOG"

_extract() { grep -E "$1" "$LOG" | grep -oE '0x[a-fA-F0-9]{40}' | head -1 || true; }
PAD="$(_extract 'V2_LAUNCHPAD')"
MIG="$(_extract 'V2_MIGRATOR')"
REG="$(_extract 'V2_QUOTE_REGISTRY')"
DIV="$(_extract 'V2_DIVIDEND_VAULT')"
BUCKET="$(_extract 'V2_PLATFORM_BUCKET')"
HANDLER="$(_extract 'V2_POSTGRAD_HANDLER')"
BURNER="0x2aC14C462901F990ae7647D6AcafEaf50Cc8f8dF"
FEE="0x3464aa1097Aa46502Db847E4c6d0A2D52a871Af4"
GANG="0x0c6302401aa5325C2E36F170f52C00B1d220B405"

# Prefer broadcast JSON creations if log scrape thin
JSON="${ROOT}/broadcast/DeployWireMainnetV2.s.sol/56/run-latest.json"
if [[ -f "$JSON" ]]; then
  echo "broadcast json: $JSON"
fi

TS="$(TZ=Asia/Shanghai date '+%Y-%m-%d %H:%M:%S')"
cat > "$ADDR_MD" <<MD
# LaunchpadV2 主网地址（REFPOOL · any pair · ≈15 BNB）

- 时间：${TS} Asia/Shanghai
- OWNER：\`${OWNER}\`
- 口径：any pair + REFPOOL；毕业 ≈15 BNB 等值；BAW + 1% walletCap；复用 Burner/feeVault/GANG
- **未改** Soft \`0x4E6f…\` / U \`0xF81C…\` / S \`0x60ae…\`

## 新部署

| 合约 | 地址 |
|---|---|
| LaunchpadV2 | \`${PAD:-TBD}\` |
| MigratorV2 | \`${MIG:-TBD}\` |
| QuoteRegistry | \`${REG:-TBD}\` |
| DividendVault (minShare 10_000) | \`${DIV:-TBD}\` |
| PlatformFeeBucket | \`${BUCKET:-TBD}\` |
| PostGradTaxHandler | \`${HANDLER:-TBD}\` |

## 复用（现网）

| 合约 | 地址 |
|---|---|
| BuybackBurner | \`${BURNER}\` |
| feeVault | \`${FEE}\` |
| GANG | \`${GANG}\` |

## 日志

- \`${LOG}\`
MD

cat > "$STATUS_MD" <<MD
# LaunchpadV2 主网状态

**Updated:** ${TS} Asia/Shanghai  
**CONFIRM_MAINNET_BROADCAST=YES** | OWNER→${OWNER}

## DONE
- Deploy+Wire LaunchpadV2 (REFPOOL)
- Soft/U/S **untouched**

## 新址
见 \`MAINNET-LAUNCHPAD-V2-ADDRESSES-2026-10-23.md\`

## NEXT
- FE create → V2（并行）
- Indexer 加 V2 startBlock + legacy Soft/U/S
- Keeper：旧 Soft dual / U PostGrad **不停**；另加 V2 Bucket/PostGrad
- BscScan verify（若本轮未带 API key）
MD

echo "Wrote $ADDR_MD"
echo "PAD=${PAD:-?} MIG=${MIG:-?} DIV=${DIV:-?}"
# Post-check: legacy Soft code unchanged tip — just balance owner still owns Soft
cast call 0x4E6f13c8A453c1b8b4E20b590082bb233a5b80d7 "owner()(address)" --rpc-url "$BSC_RPC_URL" || true
echo "DONE broadcast batch"
