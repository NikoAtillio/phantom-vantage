#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

WINEPREFIX_PATH="${WINEPREFIX:-/Users/niko/Library/Application Support/net.metaquotes.wine.metatrader5}"
COMMON_ROOT_DEFAULT="${WINEPREFIX_PATH}/drive_c/users/user/AppData/Roaming/MetaQuotes/Terminal/Common/Files"

SOURCE_FILE="${SOURCE_FILE:-${COMMON_ROOT_DEFAULT}/signals_vantage_live.jsonl}"
DEST_FILE="${DEST_FILE:-${REPO_ROOT}/phantom/copy_for_live/Phantom_Vantage/signals_vantage_live.jsonl}"
STATE_DIR="${STATE_DIR:-${REPO_ROOT}/.runtime_state}"
CURSOR_FILE="${STATE_DIR}/signals_mirror.cursor"
WEEK_MARKER_FILE="${STATE_DIR}/signals_mirror.week"

# Sunday reset (1=Mon ... 7=Sun)
RESET_WEEKDAY="${RESET_WEEKDAY:-7}"
MIRROR_TZ="${MIRROR_TZ:-Europe/London}"

mkdir -p "${STATE_DIR}"
mkdir -p "$(dirname "${DEST_FILE}")"

if [[ ! -f "${SOURCE_FILE}" ]]; then
  echo "Source signal file not found: ${SOURCE_FILE}" >&2
  exit 2
fi

src_size() {
  stat -f "%z" "$1"
}

now_weekday="$(TZ="${MIRROR_TZ}" date +%u)"
now_week="$(TZ="${MIRROR_TZ}" date +%G-%V)"

source_bytes="$(src_size "${SOURCE_FILE}")"

if [[ "${now_weekday}" == "${RESET_WEEKDAY}" ]]; then
  last_reset_week=""
  if [[ -f "${WEEK_MARKER_FILE}" ]]; then
    last_reset_week="$(cat "${WEEK_MARKER_FILE}" 2>/dev/null || true)"
  fi

  if [[ "${last_reset_week}" != "${now_week}" ]]; then
    : > "${DEST_FILE}"
    printf "%s" "${source_bytes}" > "${CURSOR_FILE}"
    printf "%s" "${now_week}" > "${WEEK_MARKER_FILE}"
    echo "Mirror weekly reset complete (${MIRROR_TZ} week ${now_week})."
    echo "Source bytes: ${source_bytes}; destination truncated and cursor moved to EOF."
    exit 0
  fi
fi

cursor=0
if [[ -f "${CURSOR_FILE}" ]]; then
  cursor="$(cat "${CURSOR_FILE}" 2>/dev/null || echo 0)"
fi

if ! [[ "${cursor}" =~ ^[0-9]+$ ]]; then
  cursor=0
fi

if (( cursor > source_bytes )); then
  # Source rotated/truncated. Start fresh mirror from start of current source.
  cursor=0
  : > "${DEST_FILE}"
fi

appended=0
if (( cursor < source_bytes )); then
  start_byte=$((cursor + 1))
  tail -c +"${start_byte}" "${SOURCE_FILE}" >> "${DEST_FILE}"
  appended=$((source_bytes - cursor))
fi

printf "%s" "${source_bytes}" > "${CURSOR_FILE}"

echo "Mirror sync complete."
echo "Source: ${SOURCE_FILE}"
echo "Destination: ${DEST_FILE}"
echo "Appended bytes: ${appended}"
echo "Cursor: ${source_bytes}"
