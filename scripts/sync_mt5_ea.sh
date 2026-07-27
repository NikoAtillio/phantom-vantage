#!/usr/bin/env bash
set -euo pipefail

SOURCE="${1:-}"
if [[ -z "${SOURCE}" ]]; then
  echo "Usage: sync_mt5_ea.sh <source.mq5>"
  exit 2
fi

if [[ ! -f "${SOURCE}" ]]; then
  echo "Source file not found: ${SOURCE}"
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WINEPREFIX="${WINEPREFIX:-/Users/niko/Library/Application Support/net.metaquotes.wine.metatrader5}"
MT5_ROOT="${WINEPREFIX}/drive_c/Program Files/MetaTrader 5"
EXPERTS_ROOT="${MT5_ROOT}/MQL5/Experts"
INDICATORS_ROOT="${MT5_ROOT}/MQL5/Indicators"

BASENAME="$(basename "${SOURCE}")"
STEM="${BASENAME%.mq5}"

ROOT_SOURCE="${EXPERTS_ROOT}/${BASENAME}"
ROOT_EX5="${EXPERTS_ROOT}/${STEM}.ex5"
SOURCE_EX5="$(dirname "${SOURCE}")/${STEM}.ex5"
PHANTOM_ROOT="${EXPERTS_ROOT}/phantom"
PHANTOM_SOURCE="${PHANTOM_ROOT}/${BASENAME}"
PHANTOM_EX5="${PHANTOM_ROOT}/${STEM}.ex5"
INDICATOR_SOURCE="${INDICATORS_ROOT}/${BASENAME}"
INDICATOR_EX5="${INDICATORS_ROOT}/${STEM}.ex5"

IS_INDICATOR=0
if grep -Eq '^#property[[:space:]]+indicator_' "${SOURCE}"; then
  IS_INDICATOR=1
fi

get_mtime() {
  local f="$1"
  if [[ ! -e "$f" ]]; then
    echo 0
    return
  fi
  if stat -f "%m" "$f" >/dev/null 2>&1; then
    stat -f "%m" "$f"
  else
    stat -c "%Y" "$f"
  fi
}

mkdir -p "${EXPERTS_ROOT}"
cp "${SOURCE}" "${ROOT_SOURCE}"
mkdir -p "${PHANTOM_ROOT}"
cp "${SOURCE}" "${PHANTOM_SOURCE}"
if [[ "${IS_INDICATOR}" == "1" ]]; then
  mkdir -p "${INDICATORS_ROOT}"
  cp "${SOURCE}" "${INDICATOR_SOURCE}"
fi

echo "Synced source to MT5 folder:"
echo "  ${ROOT_SOURCE}"
echo "  ${PHANTOM_SOURCE}"
if [[ "${IS_INDICATOR}" == "1" ]]; then
  echo "  ${INDICATOR_SOURCE}"
fi

if [[ "${NO_COMPILE:-0}" == "1" ]]; then
  echo "NO_COMPILE=1 set; skipping MetaEditor compile."
  exit 0
fi

SOURCE_MTIME="$(get_mtime "${PHANTOM_SOURCE}")"
PRE_MAX_MTIME=0
for candidate in "${PHANTOM_EX5}" "${ROOT_EX5}" "${SOURCE_EX5}"; do
  c_mtime="$(get_mtime "${candidate}")"
  if [[ "${c_mtime}" -gt "${PRE_MAX_MTIME}" ]]; then
    PRE_MAX_MTIME="${c_mtime}"
  fi
done

"${WORKSPACE_ROOT}/.vscode/scripts/compile_mq5.sh" "${PHANTOM_SOURCE}"

COMPILED_EX5=""
BEST_MTIME=0
for candidate in "${PHANTOM_EX5}" "${ROOT_EX5}" "${SOURCE_EX5}"; do
  if [[ -f "${candidate}" ]]; then
    c_mtime="$(get_mtime "${candidate}")"
    if [[ "${c_mtime}" -ge "${SOURCE_MTIME}" && "${c_mtime}" -ge "${BEST_MTIME}" ]]; then
      COMPILED_EX5="${candidate}"
      BEST_MTIME="${c_mtime}"
    fi
  fi
done

if [[ -z "${COMPILED_EX5}" ]]; then
  echo "Compile did not produce a fresh EX5 after source sync."
  echo "Source: ${PHANTOM_SOURCE} (mtime=${SOURCE_MTIME})"
  echo "Candidates checked:"
  for candidate in "${PHANTOM_EX5}" "${ROOT_EX5}" "${SOURCE_EX5}"; do
    if [[ -f "${candidate}" ]]; then
      echo "  ${candidate} (mtime=$(get_mtime "${candidate}"))"
    else
      echo "  ${candidate} (missing)"
    fi
  done
  echo "Pre-compile max candidate mtime: ${PRE_MAX_MTIME}"
  exit 5
fi

if [[ "${COMPILED_EX5}" != "${ROOT_EX5}" ]]; then
  cp "${COMPILED_EX5}" "${ROOT_EX5}"
fi

if [[ "${COMPILED_EX5}" != "${PHANTOM_EX5}" ]]; then
  cp "${COMPILED_EX5}" "${PHANTOM_EX5}"
fi

if [[ "${IS_INDICATOR}" == "1" ]]; then
  if [[ "${COMPILED_EX5}" != "${INDICATOR_EX5}" ]]; then
    cp "${COMPILED_EX5}" "${INDICATOR_EX5}"
  fi
fi

echo "Synced compiled EX5 to:"
echo "  ${ROOT_EX5}"
echo "  ${PHANTOM_EX5}"
if [[ "${IS_INDICATOR}" == "1" ]]; then
  echo "  ${INDICATOR_EX5}"
fi
