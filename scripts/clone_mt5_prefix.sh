#!/usr/bin/env bash
set -euo pipefail

SRC_PREFIX="${1:-${HOME}/Library/Application Support/net.metaquotes.wine.metatrader5}"
DST_PREFIX="${2:-${HOME}/Library/Application Support/net.metaquotes.wine.metatrader5-ftmo}"

if [[ ! -d "${SRC_PREFIX}" ]]; then
  echo "Source Wine prefix not found: ${SRC_PREFIX}" >&2
  echo "Usage: $0 [source_prefix] [dest_prefix]" >&2
  exit 2
fi

if [[ "${SRC_PREFIX}" == "${DST_PREFIX}" ]]; then
  echo "Source and destination prefixes must be different." >&2
  exit 2
fi

echo "Cloning MT5 Wine prefix"
echo "  from: ${SRC_PREFIX}"
echo "    to: ${DST_PREFIX}"

mkdir -p "${DST_PREFIX}"
rsync -a --delete --exclude='drive_c/users/*/AppData/Local/Temp/**' "${SRC_PREFIX}/" "${DST_PREFIX}/"

MT5_EXE="${DST_PREFIX}/drive_c/Program Files/MetaTrader 5/terminal64.exe"
if [[ ! -f "${MT5_EXE}" ]]; then
  echo "Clone completed, but terminal64.exe was not found at:" >&2
  echo "  ${MT5_EXE}" >&2
  exit 3
fi

echo
echo "Clone complete."
echo "Launch FTMO terminal with:"
echo "  WINEPREFIX=\"${DST_PREFIX}\" wine \"${MT5_EXE}\""
echo
echo "Compile/sync to FTMO prefix with:"
echo "  WINEPREFIX=\"${DST_PREFIX}\" bash scripts/sync_mt5_ea.sh <path-to-ea.mq5>"
