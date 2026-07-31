#!/usr/bin/env python3
import json
import shutil
import subprocess
from datetime import datetime, timedelta
from pathlib import Path

REPO = Path('/Users/niko/Documents/projects/phantom-vantage')
PY = REPO / '.venv/bin/python'
ENGINE = REPO / 'phantom/copy_for_live/Phantom_Vantage/PhantomEA_Vantage.py'
COMMON = Path('/Users/niko/Library/Application Support/net.metaquotes.wine.metatrader5/drive_c/users/user/AppData/Roaming/MetaQuotes/Terminal/Common/Files')
LIVE = COMMON / 'phantom_live'
OUTDIR = REPO / '.diagnostics'
SIGNALS_DIR = REPO / 'signals'

files = {
    'm1': 'US100_M1.csv',
    'm5': 'US100_M5.csv',
    'm15': 'US100_M15.csv',
    'h1': 'US100_H1.csv',
    'h4': 'US100_H4.csv',
    'daily': 'US100_Daily.csv',
    'weekly': 'US100_Weekly.csv',
}

def last_ts(path: Path):
    last = ''
    with path.open('r', errors='ignore') as fh:
        for line in fh:
            s = line.strip()
            if s:
                last = s
    if not last:
        return None
    parts = last.replace('\t', ',').split(',')
    if len(parts) < 2:
        return None
    ds, ts = parts[0].strip(), parts[1].strip()
    if ':' not in ts:
        return None
    try:
        return datetime.strptime(f"{ds} {ts}", '%Y.%m.%d %H:%M:%S')
    except Exception:
        return None

latest = None
for k, name in files.items():
    ts = last_ts(LIVE / name)
    print(f"{k}: {name} -> {ts}")
    if ts and (latest is None or ts > latest):
        latest = ts

if latest is None:
    raise SystemExit('No parseable latest timestamp found in phantom_live CSVs')

start_date = (latest - timedelta(days=14)).date().isoformat()
end_date = (latest + timedelta(days=1)).date().isoformat()
stamp = latest.strftime('%Y%m%d_%H%M')
signal_name = f'signals_vantage_replay_last2w_{stamp}.jsonl'
log = OUTDIR / f"regenerate_{signal_name.replace('.jsonl', '')}.log"

cmd = [
    str(PY), str(ENGINE),
    '--instrument', 'US100',
    '--m1', str(LIVE / files['m1']),
    '--m5', str(LIVE / files['m5']),
    '--m15', str(LIVE / files['m15']),
    '--h1', str(LIVE / files['h1']),
    '--h4', str(LIVE / files['h4']),
    '--daily', str(LIVE / files['daily']),
    '--weekly', str(LIVE / files['weekly']),
    '--capital', '10000',
    '--output-dir', str(OUTDIR),
    '--start-date', start_date,
    '--end-date', end_date,
    '--signal-filename', signal_name,
    '--debug',
]

print('LATEST', latest.strftime('%Y-%m-%d %H:%M:%S'))
print('START_DATE', start_date)
print('END_DATE', end_date)
print('SIGNAL_NAME', signal_name)
print('LOG', log)

with log.open('w') as lf:
    proc = subprocess.run(cmd, stdout=lf, stderr=subprocess.STDOUT, text=True)
if proc.returncode != 0:
    raise SystemExit(f'Generator failed, see {log}')

repo_signal = SIGNALS_DIR / signal_name
common_signal = COMMON / signal_name
shutil.copy2(repo_signal, common_signal)

print('REPO_SIGNAL', repo_signal)
print('COMMON_SIGNAL', common_signal)

# quick summary for user
rows = 0
opens = 0
min_ts = None
max_ts = None
for ln in repo_signal.read_text(errors='ignore').splitlines():
    s = ln.strip()
    if not s:
        continue
    rows += 1
    o = json.loads(s)
    if o.get('action') == 'open':
        opens += 1
    ts = o.get('signal_ts') or o.get('entry_ts')
    if ts:
        min_ts = ts if min_ts is None or ts < min_ts else min_ts
        max_ts = ts if max_ts is None or ts > max_ts else max_ts

print('SUMMARY rows', rows, 'opens', opens, 'range', min_ts, '->', max_ts)
