#!/usr/bin/env bash
set -euo pipefail

# Copy MT5 export files from Wine WINEPREFIX to the current repo.
# This script should be run after MT5 backtests complete.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="${WORKSPACE_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
WINEPREFIX_PATH="${WINEPREFIX:-/Users/niko/Library/Application Support/net.metaquotes.wine.metatrader5}"

# Allow explicit override; otherwise auto-discover Common/Files under WINEPREFIX.
MT5_COMMON_FILES="${MT5_COMMON_FILES:-}"
if [[ -z "${MT5_COMMON_FILES}" ]]; then
    MT5_COMMON_FILES="$(find "${WINEPREFIX_PATH}/drive_c" \
      -type d \
      -path '*/AppData/Roaming/MetaQuotes/Terminal/Common/Files' \
      2>/dev/null | head -n 1 || true)"
fi

if [[ -z "${MT5_COMMON_FILES}" || ! -d "${MT5_COMMON_FILES}" ]]; then
    echo "Could not locate MT5 Common/Files under WINEPREFIX=${WINEPREFIX_PATH}" >&2
    echo "Set MT5_COMMON_FILES explicitly and retry." >&2
    exit 2
fi

# Create timestamp for file naming
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# Function to copy file if it exists
copy_if_exists() {
    local source="$1"
    local dest_name="$2"
    
    if [ -f "$source" ]; then
        dest="${WORKSPACE_ROOT}/${dest_name}_${TIMESTAMP}.csv"
        cp "$source" "$dest"
        echo "Copied: ${dest_name} -> $(basename "$dest")"
        return 0
    else
        echo "Not found: ${source}"
        return 1
    fi
}

echo "Copying MT5 exports from Common Files..."
echo "Source: ${MT5_COMMON_FILES}"
echo "Destination repo: ${WORKSPACE_ROOT}"
echo ""

FOUND_ANY=0
copy_if_exists "${MT5_COMMON_FILES}/phantom_mt5_tester_export.csv" "phantom_mt5_tester_export" && FOUND_ANY=1 || true
copy_if_exists "${MT5_COMMON_FILES}/phantom_mt5_export.csv" "phantom_mt5_export" && FOUND_ANY=1 || true

echo ""
echo "Also updating latest symlinks..."
[ -f "${WORKSPACE_ROOT}/phantom_mt5_tester_export_latest.csv" ] && rm "${WORKSPACE_ROOT}/phantom_mt5_tester_export_latest.csv"
[ -f "${WORKSPACE_ROOT}/phantom_mt5_export_latest.csv" ] && rm "${WORKSPACE_ROOT}/phantom_mt5_export_latest.csv"

if [ -f "${WORKSPACE_ROOT}/phantom_mt5_tester_export_${TIMESTAMP}.csv" ]; then
    ln -s "phantom_mt5_tester_export_${TIMESTAMP}.csv" "${WORKSPACE_ROOT}/phantom_mt5_tester_export_latest.csv"
    echo "Updated: phantom_mt5_tester_export_latest.csv symlink"
fi

if [ -f "${WORKSPACE_ROOT}/phantom_mt5_export_${TIMESTAMP}.csv" ]; then
    ln -s "phantom_mt5_export_${TIMESTAMP}.csv" "${WORKSPACE_ROOT}/phantom_mt5_export_latest.csv"
    echo "Updated: phantom_mt5_export_latest.csv symlink"
fi

echo ""
echo "Done! Export files are ready for analysis."

if [[ "${FOUND_ANY}" -eq 0 ]]; then
    echo "Warning: no export files were found in MT5 Common/Files." >&2
fi
