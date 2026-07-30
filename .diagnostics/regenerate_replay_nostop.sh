#!/usr/bin/env bash
set -euo pipefail

PY="/Users/niko/Documents/projects/phantom-vantage/.venv/bin/python"
SCRIPT="/Users/niko/Documents/projects/phantom-vantage/phantom/copy_for_live/Phantom_Vantage/PhantomEA_Vantage.py"
DATA="/Users/niko/Documents/projects/phantom-vantage/data/US100"
OUTDIR="/Users/niko/Documents/projects/phantom-vantage/.diagnostics"
COMMON="/Users/niko/Library/Application Support/net.metaquotes.wine.metatrader5/drive_c/users/user/AppData/Roaming/MetaQuotes/Terminal/Common/Files"
SIGNAL="signals_vantage_replay_20230101_20260101_nostop.jsonl"
LOG="$OUTDIR/regenerate_replay_20230101_20260101_nostop.log"

"$PY" "$SCRIPT" \
  --instrument US100 \
  --m1 "$DATA/US100.cash_M1_2023.05.24-2026.03.31" \
  --m5 "$DATA/US100.cash_M5_2021.01.21-2026.03.31" \
  --m15 "$DATA/US100.cash_M15_2021.01.21-2026.03.31" \
  --h1 "$DATA/US100.cash_H1_2021.01.21-2026.03.31" \
  --h4 "$DATA/US100.cash_H4_2021.01.21-2026.03.31" \
  --daily "$DATA/US100.cash_Daily_2021.01.21-2026.03.31" \
  --weekly "$DATA/US100.cash_Weekly_2021.01.17-2026.03.31" \
  --capital 10000 \
  --output-dir "$OUTDIR" \
  --start-date 2023-01-01 \
  --end-date 2026-01-02 \
  --cash-trail-max-loss-pct 80 \
  --signal-filename "$SIGNAL" \
  --debug > "$LOG" 2>&1

cp "/Users/niko/Documents/projects/phantom-vantage/signals/$SIGNAL" "$COMMON/$SIGNAL"

echo "LOG=$LOG"
echo "SIGNAL_REPO=/Users/niko/Documents/projects/phantom-vantage/signals/$SIGNAL"
echo "SIGNAL_COMMON=$COMMON/$SIGNAL"
