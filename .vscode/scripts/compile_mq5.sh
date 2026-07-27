#!/usr/bin/env bash
set -euo pipefail
FILE="$1"
if [ -z "${FILE:-}" ]; then
  echo "Usage: compile_mq5.sh <file.mq5>"
  exit 2
fi

# Default Wine prefix used on this machine (adjust if different)
WINEPREFIX="${WINEPREFIX:-/Users/niko/Library/Application Support/net.metaquotes.wine.metatrader5}"

ME_CANDIDATES=(
  "$WINEPREFIX/drive_c/Program Files/MetaTrader 5/MetaEditor.exe"
  "$WINEPREFIX/drive_c/Program Files/MetaTrader 5/MetaEditor64.exe"
  "$WINEPREFIX/drive_c/Program Files (x86)/MetaTrader 5/MetaEditor.exe"
)

FOUND_ME=""
for p in "${ME_CANDIDATES[@]}"; do
  if [ -x "$p" ]; then
    FOUND_ME="$p"
    break
  fi
done

if [ -z "$FOUND_ME" ]; then
  echo "MetaEditor not found in standard locations, searching under WINEPREFIX..."
  FOUND_ME=$(find "$WINEPREFIX/drive_c" -type f -iname "metaeditor*.exe" 2>/dev/null | head -n1 || true)
fi

if [ -z "$FOUND_ME" ]; then
  echo "MetaEditor executable not found under WINEPREFIX=$WINEPREFIX"
  echo "Please set the WINEPREFIX environment variable or update this script with the correct path."
  exit 3
fi

echo "Using MetaEditor: $FOUND_ME"

# Prefer wine64 if available
WINE_BIN="$(command -v wine64 || command -v wine || true)"
if [ -z "$WINE_BIN" ]; then
  echo "wine not found in PATH. Install Wine or run this script on a system where Wine is available."
  exit 4
fi

echo "Running: $WINE_BIN \"$FOUND_ME\" /compile:\"$FILE\""
"$WINE_BIN" "$FOUND_ME" /compile:"$FILE"
