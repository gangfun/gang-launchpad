#!/usr/bin/env bash
# Fail if production vite build embeds the local indexer URL.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/web"
if [[ ! -d node_modules ]]; then
  npm ci --prefer-offline --no-audit --no-fund
fi
npm run build
if rg -n --hidden -g '!*.map' '127\.0\.0\.1:8787' dist; then
  echo "::error::web/dist contains 127.0.0.1:8787 — production must use /api (see web/.env.production)"
  exit 1
fi
echo "OK: no 127.0.0.1:8787 in web/dist"
