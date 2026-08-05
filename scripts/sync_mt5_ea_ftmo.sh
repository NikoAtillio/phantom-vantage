#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${1:-}" ]]; then
  echo "Usage: $0 <source.mq5>" >&2
  exit 2
fi

FTMO_PREFIX="${WINEPREFIX_FTMO:-${HOME}/Library/Application Support/net.metaquotes.wine.metatrader5-ftmo}"
WINEPREFIX="${FTMO_PREFIX}" bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sync_mt5_ea.sh" "$1"
