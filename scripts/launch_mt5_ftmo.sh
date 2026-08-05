#!/usr/bin/env bash
set -euo pipefail

FTMO_PREFIX="${WINEPREFIX_FTMO:-${HOME}/Library/Application Support/net.metaquotes.wine.metatrader5-ftmo}"
MT5_EXE="${FTMO_PREFIX}/drive_c/Program Files/MetaTrader 5/terminal64.exe"

if [[ ! -f "${MT5_EXE}" ]]; then
  echo "FTMO terminal executable not found:" >&2
  echo "  ${MT5_EXE}" >&2
  echo "Run scripts/clone_mt5_prefix.sh first." >&2
  exit 2
fi

WINEPREFIX="${FTMO_PREFIX}" wine "${MT5_EXE}"
