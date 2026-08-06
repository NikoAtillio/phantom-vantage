#!/usr/bin/env bash
set -euo pipefail

FTMO_PREFIX="${WINEPREFIX_FTMO:-${HOME}/Library/Application Support/net.metaquotes.wine.metatrader5-ftmo}"
ME_EXE="${FTMO_PREFIX}/drive_c/Program Files/MetaTrader 5/MetaEditor64.exe"

if [[ ! -f "${ME_EXE}" ]]; then
  echo "FTMO MetaEditor executable not found:" >&2
  echo "  ${ME_EXE}" >&2
  exit 2
fi

WINEPREFIX="${FTMO_PREFIX}" wine "${ME_EXE}"
