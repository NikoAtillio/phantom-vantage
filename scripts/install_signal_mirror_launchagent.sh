#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

LABEL="${LABEL:-com.niko.phantom-signal-mirror}"
START_INTERVAL="${START_INTERVAL:-15}"
LAUNCH_AGENTS_DIR="${HOME}/Library/LaunchAgents"
PLIST_PATH="${LAUNCH_AGENTS_DIR}/${LABEL}.plist"

RUNTIME_ROOT="${RUNTIME_ROOT:-${HOME}/Library/Application Support/phantom-vantage-runtime}"
LOG_DIR="${RUNTIME_ROOT}/logs"
BIN_DIR="${RUNTIME_ROOT}/bin"
STATE_DIR="${RUNTIME_ROOT}/state"
SIGNAL_DIR="${RUNTIME_ROOT}/signals"
STDOUT_LOG="${LOG_DIR}/signal_mirror.out.log"
STDERR_LOG="${LOG_DIR}/signal_mirror.err.log"
RUNTIME_SCRIPT="${BIN_DIR}/mirror_live_signals_runtime.sh"

SOURCE_FILE="${SOURCE_FILE:-${HOME}/Library/Application Support/net.metaquotes.wine.metatrader5/drive_c/users/user/AppData/Roaming/MetaQuotes/Terminal/Common/Files/signals_vantage_live.jsonl}"
RUNTIME_MIRROR_FILE="${RUNTIME_MIRROR_FILE:-${SIGNAL_DIR}/signals_vantage_live.jsonl}"
REPO_MIRROR_FILE="${REPO_ROOT}/phantom/copy_for_live/Phantom_Vantage/signals_vantage_live.jsonl"

RESET_WEEKDAY="${RESET_WEEKDAY:-7}"
MIRROR_TZ="${MIRROR_TZ:-Europe/London}"

mkdir -p "${LAUNCH_AGENTS_DIR}" "${LOG_DIR}" "${BIN_DIR}" "${STATE_DIR}" "${SIGNAL_DIR}"

cat > "${RUNTIME_SCRIPT}" <<EOF
#!/usr/bin/env bash
set -euo pipefail

SOURCE_FILE="${SOURCE_FILE}"
DEST_FILE="${RUNTIME_MIRROR_FILE}"
STATE_DIR="${STATE_DIR}"
CURSOR_FILE="\${STATE_DIR}/signals_mirror.cursor"
WEEK_MARKER_FILE="\${STATE_DIR}/signals_mirror.week"
RESET_WEEKDAY="${RESET_WEEKDAY}"
MIRROR_TZ="${MIRROR_TZ}"

mkdir -p "\${STATE_DIR}" "\$(dirname "\${DEST_FILE}")"

if [[ ! -f "\${SOURCE_FILE}" ]]; then
  echo "Source signal file not found: \${SOURCE_FILE}" >&2
  exit 2
fi

src_size() {
  stat -f "%z" "\$1"
}

now_weekday="\$(TZ="\${MIRROR_TZ}" date +%u)"
now_week="\$(TZ="\${MIRROR_TZ}" date +%G-%V)"
source_bytes="\$(src_size "\${SOURCE_FILE}")"

if [[ "\${now_weekday}" == "\${RESET_WEEKDAY}" ]]; then
  last_reset_week=""
  if [[ -f "\${WEEK_MARKER_FILE}" ]]; then
    last_reset_week="\$(cat "\${WEEK_MARKER_FILE}" 2>/dev/null || true)"
  fi
  if [[ "\${last_reset_week}" != "\${now_week}" ]]; then
    : > "\${DEST_FILE}"
    printf "%s" "\${source_bytes}" > "\${CURSOR_FILE}"
    printf "%s" "\${now_week}" > "\${WEEK_MARKER_FILE}"
    exit 0
  fi
fi

cursor=0
if [[ -f "\${CURSOR_FILE}" ]]; then
  cursor="\$(cat "\${CURSOR_FILE}" 2>/dev/null || echo 0)"
fi
if ! [[ "\${cursor}" =~ ^[0-9]+$ ]]; then
  cursor=0
fi

if (( cursor > source_bytes )); then
  cursor=0
  : > "\${DEST_FILE}"
fi

if (( cursor < source_bytes )); then
  start_byte=\$((cursor + 1))
  tail -c +"\${start_byte}" "\${SOURCE_FILE}" >> "\${DEST_FILE}"
fi

printf "%s" "\${source_bytes}" > "\${CURSOR_FILE}"
EOF

chmod +x "${RUNTIME_SCRIPT}"

mkdir -p "$(dirname "${REPO_MIRROR_FILE}")"
if [[ -e "${REPO_MIRROR_FILE}" && ! -L "${REPO_MIRROR_FILE}" ]]; then
  mv "${REPO_MIRROR_FILE}" "${REPO_MIRROR_FILE}.pre_link_backup"
fi
ln -sfn "${RUNTIME_MIRROR_FILE}" "${REPO_MIRROR_FILE}"

cat > "${PLIST_PATH}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>

  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${RUNTIME_SCRIPT}</string>
  </array>

  <key>RunAtLoad</key>
  <true/>

  <key>StartInterval</key>
  <integer>${START_INTERVAL}</integer>

  <key>WorkingDirectory</key>
  <string>${RUNTIME_ROOT}</string>

  <key>StandardOutPath</key>
  <string>${STDOUT_LOG}</string>

  <key>StandardErrorPath</key>
  <string>${STDERR_LOG}</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/${LABEL}" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "${PLIST_PATH}"
launchctl kickstart -k "gui/$(id -u)/${LABEL}"

echo "Installed and started LaunchAgent: ${LABEL}"
echo "Plist: ${PLIST_PATH}"
echo "Mirror interval: ${START_INTERVAL}s"
echo "Runtime mirror: ${RUNTIME_MIRROR_FILE}"
echo "Repo mirror symlink: ${REPO_MIRROR_FILE}"
