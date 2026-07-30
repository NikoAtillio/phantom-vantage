#!/usr/bin/env bash
set -euo pipefail

PY="/Users/niko/Documents/projects/phantom-vantage/.venv/bin/python"
SRC="/Users/niko/Documents/projects/phantom-vantage/phantom/copy_for_live/Phantom_Vantage/PhantomEA_Vantage.py"
BASE="$HOME/Library/Application Support/net.metaquotes.wine.metatrader5/drive_c/users/user/AppData/Roaming/MetaQuotes/Terminal/Common/Files/phantom_live"
OUTDIR="/Users/niko/Documents/projects/phantom-vantage/.diagnostics/tol_sweep"
mkdir -p "$OUTDIR"

for TOL in 0.0023 0.0024 0.0025; do
  TAG="${TOL/./}"
  TMP="$OUTDIR/PhantomEA_shadow_tol_${TAG}.py"
  LOG="$OUTDIR/oneshot_tol_${TAG}.log"

  cp "$SRC" "$TMP"
  perl -0pi -e "s/conf_tol=DEFAULTS\['conf_tol'\],/conf_tol=${TOL},/" "$TMP"

  "$PY" "$TMP" \
    --instrument US100 \
    --m1 "$BASE/US100_M1.csv" \
    --m5 "$BASE/US100_M5.csv" \
    --m15 "$BASE/US100_M15.csv" \
    --h1 "$BASE/US100_H1.csv" \
    --h4 "$BASE/US100_H4.csv" \
    --daily "$BASE/US100_Daily.csv" \
    --weekly "$BASE/US100_Weekly.csv" \
    --capital 10000 \
    --output-dir "$OUTDIR" \
    --start-date 2026-07-20 \
    --signal-filename "signals_shadow_tol_${TAG}.jsonl" \
    --debug > "$LOG" 2>&1

  echo "=== tol=${TOL} ==="
  grep -E "Trades\s+:|Skipped\s+:|Test Span|Final Cap|Win %|PF" "$LOG" || true
  echo "log=$LOG"
  echo

done
