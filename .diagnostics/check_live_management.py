#!/usr/bin/env python3
import json
from pathlib import Path

COMMON = Path('/Users/niko/Library/Application Support/net.metaquotes.wine.metatrader5/drive_c/users/user/AppData/Roaming/MetaQuotes/Terminal/Common/Files')
SIG = COMMON / 'signals_vantage_live.jsonl'
LOG = COMMON / 'phantom_bridge_log.csv'


def load_latest_open(signal_path: Path):
    latest = None
    related = []
    if not signal_path.exists():
        return None, related
    for line in signal_path.read_text(errors='ignore').splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if obj.get('action') == 'open':
            latest = obj
    if latest is None:
        return None, related
    tid = latest.get('id', '')
    for line in signal_path.read_text(errors='ignore').splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if obj.get('id') == tid:
            related.append(obj)
    return latest, related


def read_bridge_matches(log_path: Path, trade_id: str):
    if not log_path.exists():
        return [], []
    id_lines = []
    lifecycle = []
    keys = ('INIT;', 'DEINIT;', 'MAP_REBUILD', 'SIGNAL_TARGET', 'FILE_POLL', 'OPEN_PENDING', 'MODIFY_PENDING', 'CLOSE_PENDING', 'OPEN_BLOCKED', 'MODIFY;', 'CLOSE;')
    for line in log_path.read_text(errors='ignore').splitlines():
        if trade_id in line:
            id_lines.append(line)
        if any(k in line for k in keys):
            lifecycle.append(line)
    return id_lines[-40:], lifecycle[-80:]


def pending_summary(common: Path):
    rows = []
    for pat in ('phantom_pending_action_*.jsonl', 'phantom_pending_open_*.jsonl'):
        for p in sorted(common.glob(pat)):
            try:
                txt = p.read_text(errors='ignore').splitlines()
            except Exception:
                txt = []
            rows.append((p.name, len(txt), txt[-3:]))
    return rows


def main():
    latest, related = load_latest_open(SIG)
    print('signals_file_exists', SIG.exists())
    print('bridge_log_exists', LOG.exists())
    if latest is None:
        print('latest_open', 'none')
        return

    tid = latest.get('id')
    print('latest_open_id', tid)
    print('latest_open_dir', latest.get('dir'))
    print('latest_open_entry_ts', latest.get('entry_ts'))
    print('latest_open_entry', latest.get('entry'))

    print('related_signal_events_count', len(related))
    for o in related[-10:]:
        ts = o.get('signal_ts') or o.get('entry_ts')
        print('signal_event', o.get('action'), ts, o.get('reason', ''))

    id_lines, lifecycle = read_bridge_matches(LOG, tid)
    print('bridge_lines_for_id_count', len(id_lines))
    for ln in id_lines[-20:]:
        print('bridge_id_line', ln)

    print('bridge_recent_lifecycle_count', len(lifecycle))
    for ln in lifecycle[-20:]:
        print('bridge_lifecycle_line', ln)

    pend = pending_summary(COMMON)
    print('pending_files_count', len(pend))
    for name, n, tail in pend:
        print('pending_file', name, 'lines', n)
        for t in tail:
            print('pending_tail', t)


if __name__ == '__main__':
    main()
