#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

RUNTIME_ROOT="${RUNTIME_ROOT:-${HOME}/Library/Application Support/phantom-vantage-runtime}"
RUNTIME_STRAT_DIR="${RUNTIME_ROOT}/Phantom_Vantage"
LAUNCH_AGENT_LABEL="${LAUNCH_AGENT_LABEL:-com.niko.phantom-live-daemon}"

SRC_STRAT_DIR="${REPO_ROOT}/phantom/copy_for_live/Phantom_Vantage"
FILES=(
  "phantom_live_daemon.py"
  "PhantomEA_Vantage.py"
)

RESTART=0
if [[ "${1:-}" == "--restart" ]]; then
  RESTART=1
fi

mkdir -p "${RUNTIME_STRAT_DIR}" "${RUNTIME_ROOT}/logs" "${RUNTIME_ROOT}/signals" "${RUNTIME_ROOT}/tmp"

echo "Runtime root: ${RUNTIME_ROOT}"
echo "LaunchAgent label: ${LAUNCH_AGENT_LABEL}"

for f in "${FILES[@]}"; do
  src="${SRC_STRAT_DIR}/${f}"
  dst="${RUNTIME_STRAT_DIR}/${f}"

  if [[ ! -f "${src}" ]]; then
    echo "Missing source file: ${src}" >&2
    exit 2
  fi

  cp "${src}" "${dst}"
  echo "Synced: ${src} -> ${dst}"
done

if [[ "${RESTART}" -eq 1 ]]; then
  launchctl kickstart -k "gui/$(id -u)/${LAUNCH_AGENT_LABEL}"
  echo "Restarted launchd service: ${LAUNCH_AGENT_LABEL}"
else
  echo "Sync complete. Restart service to apply changes:"
  echo "  launchctl kickstart -k gui/$(id -u)/${LAUNCH_AGENT_LABEL}"
fi
