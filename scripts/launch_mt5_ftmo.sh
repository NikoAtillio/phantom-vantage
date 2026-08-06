#!/usr/bin/env bash
set -euo pipefail

FTMO_PREFIX="${WINEPREFIX_FTMO:-${HOME}/Library/Application Support/net.metaquotes.wine.metatrader5-ftmo}"
MT5_EXE="${FTMO_PREFIX}/drive_c/Program Files/MetaTrader 5/terminal64.exe"
RUNTIME_ROOT="${RUNTIME_ROOT:-${HOME}/Library/Application Support/phantom-vantage-runtime}"
LOG_DIR="${RUNTIME_ROOT}/logs"
LOG_FILE="${LOG_DIR}/mt5_ftmo_terminal.log"

if [[ ! -f "${MT5_EXE}" ]]; then
  echo "FTMO terminal executable not found:" >&2
  echo "  ${MT5_EXE}" >&2
  echo "Run scripts/clone_mt5_prefix.sh first." >&2
  exit 2
fi

mkdir -p "${LOG_DIR}"

if [[ "${1:-}" == "--foreground" ]]; then
  echo "Launching FTMO MT5 in foreground (terminal will stay attached)..."
  WINEPREFIX="${FTMO_PREFIX}" wine "${MT5_EXE}"
  exit 0
fi

echo "Launching FTMO MT5 detached..."
echo "Log: ${LOG_FILE}"
nohup env WINEPREFIX="${FTMO_PREFIX}" wine "${MT5_EXE}" >"${LOG_FILE}" 2>&1 < /dev/null &
PID=$!
disown "${PID}" 2>/dev/null || true
echo "FTMO MT5 started (PID ${PID}). You can close this terminal safely."
