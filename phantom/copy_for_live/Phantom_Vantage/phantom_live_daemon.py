r"""
phantom_live_daemon.py — PHANTOM p2 Live Signal Daemon (VPS edition)
====================================================================
Runs continuously on a Windows VPS alongside MT5.

Architecture
------------
  1. On startup: run the full engine over all historical CSV data →
     write the complete signal file once (all historical events).
  2. Poll loop: every --poll-seconds check if any CSV was updated
     (by file mtime).  On a new M5 bar, re-run the engine, diff the
     resulting event stream against the already-written set, and
     APPEND only genuinely new events.
  3. Heartbeat: every 5 minutes write a heartbeat event so the EA
     can detect a dead writer.

Bug fixes vs the original draft
---------------------------------
  FIX-1  Dedup uses a per-event content fingerprint (sha256 of the
         canonical JSON fields) instead of signal-id alone.
         open/modify/close for the same trade now each have a unique
         fingerprint, so trailing-stop updates and forced closes are
         never silently dropped.
  FIX-2  Control events (pause_entries, resume_entries, hard_stop)
         are deduped by their CONTENT hash (action + reason +
         resume_after).  Identical back-to-back control events from
         successive reruns are suppressed; new ones pass through.
  FIX-3  All runtime dependencies (pandas, numpy, the engine module)
         are validated at startup with a clear error if missing.
  FIX-4  Signal file is written with true append mode (open 'a' +
      fsync) so the file only ever grows and the EA cursor at
      byte offset 731939 is always valid (fixes err=5004).

Usage (Windows VPS)
-------------------
  python phantom_live_daemon.py ^
    --instrument US100 ^
    --m1    "C:\...\phantom_live\US100_M1.csv" ^
    --m5    "C:\...\phantom_live\US100_M5.csv" ^
    --m15   "C:\...\phantom_live\US100_M15.csv" ^
    --h1    "C:\...\phantom_live\US100_H1.csv" ^
    --h4    "C:\...\phantom_live\US100_H4.csv" ^
    --daily "C:\...\phantom_live\US100_Daily.csv" ^
    --weekly "C:\...\phantom_live\US100_Weekly.csv" ^
    --capital 10000 ^
    --signal-filename signals_vantage_live.jsonl ^
    --poll-seconds 15
"""

import argparse
import glob
import hashlib
import json
import os
import platform
import shutil
import sys
import tempfile
import time
import traceback
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional, Set

# ── dependency guard ─────────────────────────────────────────────────────────
_MISSING = []
try:
    import pandas as pd
except ImportError:
    _MISSING.append("pandas")
try:
    import numpy as np
except ImportError:
    _MISSING.append("numpy")
if _MISSING:
    sys.exit(
        f"[daemon] FATAL: missing packages: {', '.join(_MISSING)}\n"
        f"  Run:  pip install {' '.join(_MISSING)}"
    )

# ── engine import ─────────────────────────────────────────────────────────────
try:
    import PhantomEA_Vantage as engine
except ImportError as exc:
    sys.exit(
        f"[daemon] FATAL: cannot import PhantomEA_Vantage — {exc}\n"
        f"  Make sure PhantomEA_Vantage.py is in the same directory as this script."
    )

# ─────────────────────────────────────────────────────────────────────────────
# FINGERPRINT HELPERS
# ─────────────────────────────────────────────────────────────────────────────

def _event_fingerprint(event: dict) -> str:
    """
    FIX-1 / FIX-2: Produce a stable sha256 fingerprint for dedup.

        For trade events:
            open:
                key = action + id
                This avoids duplicate opens when reruns slightly change numeric
                payload values for an already-seen trade id.

            modify:
                key = action + id + signal_ts + reason
                Keep one modify per timestamp/reason for a given trade id.

            close:
                For reason == eod:
                    key = action + id + reason
                    eod reruns often drift in exit price; this collapses them.
                Otherwise:
                    key = action + id + signal_ts + reason

    For control events (pause_entries, resume_entries, hard_stop):
        key = action + reason + resume_after (+ signal_ts if present)
        This allows deliberate operator toggles (e.g. repeated weekend
        manual resume actions) to be emitted again while still suppressing
        duplicate rerun noise when signal_ts is absent.

    For meta / heartbeat:
        key = action only (they are always re-emitted on restart, so
        we intentionally deduplicate them to one-per-session).
    """
    action = event.get("action", "")

    if action in ("open",):
        parts = [
            action,
            str(event.get("id", "")),
        ]
    elif action in ("modify",):
        parts = [
            action,
            str(event.get("id", "")),
            str(event.get("signal_ts", "")),
            str(event.get("reason", "")),
        ]
    elif action in ("close",):
        reason = str(event.get("reason", "")).lower()
        if reason == "eod":
            parts = [
                action,
                str(event.get("id", "")),
                reason,
            ]
        else:
            parts = [
                action,
                str(event.get("id", "")),
                str(event.get("signal_ts", "")),
                str(event.get("reason", "")),
            ]
    elif action in ("pause_entries", "resume_entries", "hard_stop"):
        # FIX-2: control events are content-deduped, but keep optional
        # signal_ts so deliberate manual toggles can re-emit cleanly.
        parts = [
            action,
            str(event.get("reason", "")),
            str(event.get("resume_after", "")),
            str(event.get("flatten_all", "")),
            str(event.get("signal_ts", "")),
        ]
    else:
        # meta, heartbeat, unknown: one per session
        parts = [action]

    raw = "|".join(parts)
    return hashlib.sha256(raw.encode()).hexdigest()[:16]


def _round_str(v, decimals: int = 5) -> str:
    """Convert a float to a rounded string for fingerprinting."""
    if v is None:
        return "None"
    try:
        return f"{float(v):.{decimals}f}"
    except (TypeError, ValueError):
        return str(v)


# ─────────────────────────────────────────────────────────────────────────────
# MT5 COMMON/FILES PATH DISCOVERY
# ─────────────────────────────────────────────────────────────────────────────

def _find_mt5_common_files() -> List[str]:
    """Return every MT5 Common\\Files directory visible on this machine."""
    candidates: List[str] = []

    if platform.system() == "Windows":
        # Standard Windows path: AppData\Roaming\MetaQuotes\Terminal\Common\Files
        appdata = os.environ.get("APPDATA", "")
        if appdata:
            pattern = os.path.join(
                appdata, "MetaQuotes", "Terminal", "Common", "Files"
            )
            candidates.append(pattern)
        # Also scan all profiles (multi-user VPS)
        profiles_root = os.path.join(os.environ.get("SYSTEMDRIVE", "C:") + "\\", "Users")
        candidates += glob.glob(
            os.path.join(profiles_root, "*", "AppData", "Roaming",
                         "MetaQuotes", "Terminal", "Common", "Files")
        )
    else:
        # macOS / Linux: Wine prefix
        wp = (
            os.environ.get("WINEPREFIX")
            or os.path.expanduser(
                "~/Library/Application Support/net.metaquotes.wine.metatrader5"
            )
        )
        candidates += glob.glob(
            os.path.join(wp, "drive_c", "users", "*",
                         "AppData", "Roaming", "MetaQuotes", "Terminal",
                         "Common", "Files")
        )
        candidates += glob.glob(
            os.path.join(wp, "drive_c", "Users", "*",
                         "AppData", "Roaming", "MetaQuotes", "Terminal",
                         "Common", "Files")
        )

    seen: Set[str] = set()
    result: List[str] = []
    for p in candidates:
        if not os.path.isdir(p):
            continue
        # Canonicalize to avoid duplicate writes when users/ and Users/ both resolve.
        canon = os.path.realpath(p).casefold()
        if canon in seen:
            continue
        seen.add(canon)
        result.append(os.path.realpath(p))
    return result


def _resolve_common_file(path: str) -> str:
    """
    Resolve helper paths prefixed with common:// to MT5 Common/Files absolute paths.
    Example: common://phantom_live/cash_daily_resume.flag
    """
    raw = str(path or "").strip()
    prefix = "common://"
    if not raw.lower().startswith(prefix):
        return raw

    rel = raw[len(prefix):].lstrip("/\\")
    roots = _find_mt5_common_files()
    if not roots:
        return rel

    candidates = [os.path.join(root, rel) for root in roots]
    for candidate in candidates:
        if os.path.exists(candidate):
            return candidate
    return candidates[0]


def _resolve_common_file_candidates(path: str) -> List[str]:
    """Return all concrete file candidates for a plain path or common:// path."""
    raw = str(path or "").strip()
    if not raw:
        return []

    prefix = "common://"
    if not raw.lower().startswith(prefix):
        return [raw]

    rel = raw[len(prefix):].lstrip("/\\")
    roots = _find_mt5_common_files()
    if not roots:
        return [rel]
    return [os.path.join(root, rel) for root in roots]


def _manual_resume_flag_paths(args: argparse.Namespace) -> List[str]:
    """Return all concrete manual resume flag paths (plain + common:// expanded)."""
    paths: List[str] = []
    total_flag = str(getattr(args, "cash_manual_resume_file", "") or "").strip()
    if total_flag:
        paths.append(total_flag)
    paths.extend(
        _resolve_common_file_candidates(
            str(getattr(args, "cash_daily_resume_file", "") or "").strip()
        )
    )

    seen: Set[str] = set()
    out: List[str] = []
    for p in paths:
        if not p:
            continue
        canon = os.path.realpath(p).casefold()
        if canon in seen:
            continue
        seen.add(canon)
        out.append(p)
    return out


def _snapshot_manual_resume_flags(args: argparse.Namespace) -> Dict[str, float]:
    """Snapshot current resume flag mtimes so pre-existing files do not retrigger forever."""
    mtimes: Dict[str, float] = {}
    for p in _manual_resume_flag_paths(args):
        if not os.path.exists(p):
            continue
        try:
            mtimes[p] = os.path.getmtime(p)
        except OSError:
            continue
    return mtimes


def _manual_resume_override_changed(args: argparse.Namespace, seen_mtimes: Dict[str, float]) -> bool:
    """
    Edge-triggered manual resume detection.

    Returns True only when a resume flag file is newly created or its mtime changes.
    A stale always-present flag no longer forces reruns on every poll.
    """
    triggered = False
    active: Set[str] = set()

    for p in _manual_resume_flag_paths(args):
        if not os.path.exists(p):
            continue
        active.add(p)
        try:
            cur = os.path.getmtime(p)
        except OSError:
            continue
        prev = seen_mtimes.get(p)
        if prev is None or cur != prev:
            triggered = True
        seen_mtimes[p] = cur

    # Drop deleted flags from the seen map.
    for p in list(seen_mtimes.keys()):
        if p not in active:
            seen_mtimes.pop(p, None)

    return triggered


def _read_master_control_mode(path: str) -> str:
    """Read master control mode from file. Returns 'PAUSE', 'RESUME', or ''."""
    candidates = _resolve_common_file_candidates(path)
    if not candidates:
        return ""

    # Prefer the newest existing control file when multiple MT5 profiles exist.
    existing: List[str] = [p for p in candidates if os.path.exists(p)]
    if not existing:
        return ""
    existing.sort(key=lambda p: os.path.getmtime(p), reverse=True)

    for p in existing:
        try:
            with open(p, "r", encoding="utf-8") as f:
                raw = (f.read() or "").strip()
        except OSError:
            continue
        if not raw:
            continue
        token = raw.split()[0].strip().upper()
        if token in ("PAUSE", "RESUME"):
            return token
    return ""


# ─────────────────────────────────────────────────────────────────────────────
# ATOMIC FILE WRITE
# ─────────────────────────────────────────────────────────────────────────────

def _atomic_append_lines(path: str, lines: List[str]) -> None:
    """
    FIX-5: Append lines to `path` using true append mode.
    Replaces the old read→tmp→replace strategy which caused a brief
    file-shrink window that MT5 detected as ERR_FILE_NOT_FOUND (5004).
    Opening in 'a' mode means the file only ever grows, so the Bridge
    EA cursor is always pointing to a valid position.
    """
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    blob = "".join(line + "\n" for line in lines)
    with open(path, "a", encoding="utf-8") as f:
        f.write(blob)
        f.flush()
        os.fsync(f.fileno())


# ─────────────────────────────────────────────────────────────────────────────
# ENGINE RUNNER
# ─────────────────────────────────────────────────────────────────────────────

def _run_engine(args: argparse.Namespace) -> List[dict]:
    """
    Run PhantomEA_Vantage.main() in-process with the given data paths
    and return the buffered event list.

    We monkey-patch EMIT_SIGNALS=True and intercept _EVENT_BUFFER
    directly so no file I/O happens inside the engine call.
    """
    # Patch engine globals
    engine.EMIT_SIGNALS = True
    engine.EMIT_HEARTBEATS = False
    engine.EMIT_EOD_CLOSE_SIGNALS = False
    engine.SIGNAL_FILENAME = args.signal_filename
    engine._EVENT_BUFFER.clear()
    engine._SIGNAL_SEQ["n"] = 0

    # Build a minimal argparse Namespace that matches engine.main() expectations
    eng_args = argparse.Namespace(
        instrument=args.instrument,
        m1=args.m1,
        m5=args.m5,
        m15=args.m15,
        h1=args.h1,
        h4=args.h4,
        daily=args.daily,
        weekly=args.weekly,
        capital=args.capital,
        output_dir=args.output_dir,
        spread_bps=0.0,
        slippage_bps=0.0,
        commission_per_trade=0.0,
        start_date=None,
        end_date=None,
        debug=False,
        debug_file=None,
        signal_filename=args.signal_filename,
        write_generic_signal_alias=False,
        cash_max_leverage=200.0,
        cash_trail_max_loss_pct=15.0,
        cash_lot_cap_mult=10.0,
        cash_soft_stop_ratio=0.8,
        cash_manual_resume_file="tmp/cash_resume.flag",
        cash_daily_resume_file="common://phantom_live/cash_daily_resume.flag",
        cash_master_control_file=str(getattr(args, "cash_master_control_file", "common://phantom_live/master_control.flag") or ""),
        cash_hard_close=True,
        cash_hard_stop_pause_days=0,
    )

    # Redirect stdout during engine run to avoid polluting daemon logs
    old_stdout = sys.stdout
    sys.stdout = open(os.devnull, "w")
    try:
        # Re-use engine internals directly (avoids re-loading data every poll)
        _engine_main_no_flush(eng_args)
    finally:
        sys.stdout.close()
        sys.stdout = old_stdout

    # Collect the buffered events
    events: List[dict] = []
    for raw in engine._EVENT_BUFFER:
        try:
            events.append(json.loads(raw))
        except json.JSONDecodeError:
            pass

    return events


def _engine_main_no_flush(args: argparse.Namespace) -> None:
    """
    Run the engine pipeline (load → indicators → zones → scenario)
    without calling flush_signals() at the end.
    We capture events from _EVENT_BUFFER ourselves.
    """
    inst_cfg = engine.INSTRUMENT_CONFIG[args.instrument]

    # Apply CASH config overrides
    engine.CASH_CONFIG["soft_stop_ratio"] = max(0.0, min(float(args.cash_soft_stop_ratio), 1.0))
    engine.CASH_CONFIG["manual_resume_file"] = str(args.cash_manual_resume_file)
    engine.CASH_CONFIG["daily_resume_file"] = _resolve_common_file(str(args.cash_daily_resume_file))
    engine.CASH_CONFIG["master_control_file"] = _resolve_common_file(str(getattr(args, "cash_master_control_file", "") or ""))
    engine.CASH_CONFIG["hard_close_on_trigger"] = bool(args.cash_hard_close)
    engine.CASH_CONFIG["hard_stop_pause_days"] = max(0, int(args.cash_hard_stop_pause_days))
    engine.CASH_CONFIG["cash_max_leverage"] = max(1.0, float(args.cash_max_leverage))
    engine.CASH_CONFIG["trail_max_loss_pct"] = max(0.1, float(args.cash_trail_max_loss_pct))
    engine.CASH_CONFIG["lot_cap_mult"] = max(1.0, float(args.cash_lot_cap_mult))

    engine.reset_signal_file()
    engine.emit_run_meta(args.capital, True, args.instrument)

    # Load data
    m1     = engine.apply_start_date(engine.add_indicators(engine.load_csv(args.m1)), None, None)
    m5     = engine.apply_start_date(engine.add_indicators(engine.load_csv(args.m5)), None, None)
    m15    = engine.apply_start_date(engine.add_indicators(engine.load_csv(args.m15)), None, None)
    h1     = engine.apply_start_date(engine.add_indicators(engine.load_csv(args.h1)), None, None)
    h4     = engine.apply_start_date(engine.add_indicators(engine.load_csv(args.h4)), None, None)
    daily  = engine.apply_start_date(engine.add_indicators(engine.load_csv(args.daily)), None, None)
    weekly = engine.apply_start_date(engine.load_csv(args.weekly), None, None)

    weekly = engine.add_trend_layers(weekly)
    daily  = engine.add_daily_regime(daily, inst_cfg)
    daily  = engine.add_trend_layers(daily)
    h4     = engine.add_trend_layers(h4)

    zone_ts, zone_px, zone_dir = engine.build_h4_zones(
        h4,
        pivot_bars=engine.DEFAULTS["h4_pivot_bars"],
        lookback=engine.DEFAULTS["h4_lookback"],
    )

    daily_idx    = daily.index.values
    daily_regime = daily["regime"].values

    wk_idx   = weekly.index.values
    wk_c     = weekly["close"].values
    wk_ma21  = weekly["ma21"].values
    wk_ma50  = weekly["ma50"].values
    wk_ma200 = weekly["ma200"].values
    wk_slope = weekly["ma50_slope"].values
    wk_vww   = weekly["vwap_w"].values
    wk_vwm   = weekly["vwap_m"].values
    wk_adx   = weekly["adx"].values

    dl_c     = daily["close"].values
    dl_ma21  = daily["ma21"].values
    dl_ma50  = daily["ma50"].values
    dl_ma200 = daily["ma200"].values
    dl_slope = daily["ma50_slope"].values
    dl_vww   = daily["vwap_w"].values
    dl_vwm   = daily["vwap_m"].values
    dl_adx   = daily["adx"].values

    arrays = dict(
        h4_idx=h4.index.values,     h4_c=h4["close"].values,
        h4_e20=h4["ema20"].values,   h4_e50=h4["ema50"].values,
        h4_rsi=h4["rsi"].values,     h4_atr_arr=h4["atr"].values,
        h4_atr_ma_arr=h4["atr"].rolling(
            window=max(2, int(engine.DEFAULTS.get("vol_throttle_lookback", 96))),
            min_periods=2,
        ).mean().values,
        h4_ma21=h4["ma21"].values,   h4_ma50=h4["ma50"].values,
        h4_ma200=h4["ma200"].values, h4_slope=h4["ma50_slope"].values,
        h4_vww=h4["vwap_w"].values,  h4_vwm=h4["vwap_m"].values,
        h4_adx=h4["adx"].values,
        h1_idx=h1.index.values,     h1_c=h1["close"].values,
        h1_e20=h1["ema20"].values,   h1_e50=h1["ema50"].values,
        h1_rsi=h1["rsi"].values,
        m15_idx=m15.index.values,    m15_atr_arr=m15["atr"].values,
        m5_idx=m5.index.values,     m5_c=m5["close"].values,
        m5_e20=m5["ema20"].values,   m5_e50=m5["ema50"].values,
        m5_rsi=m5["rsi"].values,
        m5_vol=m5["tickvol"].values, m5_vol_ma=m5["vol_ma"].values,
        m1_idx=m1.index.values,     m1_c=m1["close"].values,
        m1_e20=m1["ema20"].values,   m1_e50=m1["ema50"].values,
        m1_rsi=m1["rsi"].values,
    )

    cfg      = engine.ACTIVE_SCENARIO_CFG
    sc_id    = engine.ACTIVE_SCENARIO_ID
    candles  = m1 if cfg["entry_tf"] == "m1" else m5

    engine.run_scenario(
        candles=candles,
        zone_ts=zone_ts, zone_px=zone_px, zone_dir=zone_dir,
        daily_idx=daily_idx, daily_regime=daily_regime,
        wk_idx=wk_idx, wk_c=wk_c, wk_ma21=wk_ma21, wk_ma50=wk_ma50,
        wk_ma200=wk_ma200, wk_slope=wk_slope, wk_vww=wk_vww,
        wk_vwm=wk_vwm, wk_adx=wk_adx,
        dl_c=dl_c, dl_ma21=dl_ma21, dl_ma50=dl_ma50, dl_ma200=dl_ma200,
        dl_slope=dl_slope, dl_vww=dl_vww, dl_vwm=dl_vwm, dl_adx=dl_adx,
        cfg=cfg,
        inst_cfg=inst_cfg,
        capital=args.capital,
        max_concurrent=engine.DEFAULTS["max_concurrent"],
        cooldown_min=engine.DEFAULTS["cooldown_min"],
        lockout_min=engine.DEFAULTS["lockout_min"],
        conf_tol=engine.DEFAULTS["conf_tol"],
        spread_bps=0.0,
        slippage_bps=0.0,
        commission_per_trade=0.0,
        zone_lookback_bars=engine.DEFAULTS["h4_lookback"],
        label=f"LIVE {sc_id} | {args.instrument}",
        debug=False,
        debug_path=None,
        **arrays,
    )


# ─────────────────────────────────────────────────────────────────────────────
# SIGNAL FILE WRITER
# ─────────────────────────────────────────────────────────────────────────────

class SignalWriter:
    """
    Manages the signal file with fingerprint-based dedup (FIX-1, FIX-2).

    Tracks which fingerprints have already been written.  On each poll
    cycle, converts the engine's full event list to JSON lines, computes
    fingerprints, and appends only those that haven't been written yet.
    """

    def __init__(self, signal_filename: str, output_dir: str):
        self.signal_filename = signal_filename
        self.output_dir = output_dir
        os.makedirs(output_dir, exist_ok=True)
        self.local_path = os.path.join(output_dir, signal_filename)
        self.fp_cache_path = self.local_path + ".fps"
        self._written_fps: Set[str] = set()   # fingerprints already on disk
        self._open_state: Dict[str, Dict[str, float]] = {}
        self._latest_stop_by_id: Dict[str, float] = {}
        self._last_heartbeat = 0.0

        # Persist dedup state across daemon restarts.
        self._load_fp_cache()
        if not self._written_fps:
            self._bootstrap_fp_cache_from_signal_file()

    def has_existing_signal_stream(self) -> bool:
        """True if any known target signal file already exists and has content."""
        for target in [self.local_path] + self.mt5_paths:
            try:
                if os.path.getsize(target) > 0:
                    return True
            except OSError:
                continue
        return False

    @property
    def mt5_paths(self) -> List[str]:
        return [
            os.path.join(d, self.signal_filename)
            for d in _find_mt5_common_files()
        ]

    def _serialise_event(self, event: dict) -> str:
        """Convert an event dict to a canonical JSON line."""
        out = {}
        for k, v in event.items():
            if hasattr(v, "isoformat"):
                out[k] = v.isoformat()
            else:
                out[k] = v
        return json.dumps(out, default=str, ensure_ascii=False)

    def _load_fp_cache(self) -> None:
        try:
            with open(self.fp_cache_path, "r", encoding="utf-8") as f:
                for ln in f:
                    fp = ln.strip()
                    if fp:
                        self._written_fps.add(fp)
            if self._written_fps:
                print(f"[daemon] loaded {len(self._written_fps)} fingerprints from cache")
        except FileNotFoundError:
            return
        except OSError as exc:
            print(f"[daemon] WARN: failed to read fingerprint cache: {exc}")

    def _save_fp_cache(self) -> None:
        os.makedirs(os.path.dirname(os.path.abspath(self.fp_cache_path)), exist_ok=True)
        tmp = self.fp_cache_path + ".tmp"
        try:
            with open(tmp, "w", encoding="utf-8") as f:
                for fp in sorted(self._written_fps):
                    f.write(fp + "\n")
            os.replace(tmp, self.fp_cache_path)
        except OSError as exc:
            print(f"[daemon] WARN: failed to write fingerprint cache: {exc}")
            try:
                if os.path.exists(tmp):
                    os.remove(tmp)
            except OSError:
                pass

    def _bootstrap_fp_cache_from_signal_file(self) -> None:
        try:
            with open(self.local_path, "r", encoding="utf-8") as f:
                for ln in f:
                    ln = ln.strip()
                    if not ln:
                        continue
                    try:
                        ev = json.loads(ln)
                    except json.JSONDecodeError:
                        continue
                    self._written_fps.add(_event_fingerprint(ev))
                    self._ingest_canonical_state(ev)
            if self._written_fps:
                print(f"[daemon] bootstrapped {len(self._written_fps)} fingerprints from signal file")
                self._save_fp_cache()
        except FileNotFoundError:
            return
        except OSError as exc:
            print(f"[daemon] WARN: failed to bootstrap fingerprints: {exc}")

    def _ingest_canonical_state(self, ev: dict) -> None:
        action = str(ev.get("action", ""))
        trade_id = str(ev.get("id", ""))
        if not trade_id:
            return

        if action == "open":
            self._open_state[trade_id] = {
                "entry": float(ev.get("entry", 0.0) or 0.0),
                "stop": float(ev.get("stop", 0.0) or 0.0),
                "tp": float(ev.get("tp", 0.0) or 0.0),
                "qty": float(ev.get("qty", 0.0) or 0.0),
            }
            stop_val = float(ev.get("stop", 0.0) or 0.0)
            if stop_val > 0.0:
                self._latest_stop_by_id[trade_id] = stop_val
        elif action == "modify":
            stop_val = float(ev.get("new_stop", 0.0) or 0.0)
            if stop_val > 0.0:
                self._latest_stop_by_id[trade_id] = stop_val
        elif action == "close":
            self._open_state.pop(trade_id, None)
            self._latest_stop_by_id.pop(trade_id, None)

    def _canonicalize_event(self, ev: dict) -> dict:
        out = dict(ev)
        action = str(out.get("action", ""))
        trade_id = str(out.get("id", ""))
        if not trade_id:
            return out

        if action == "open":
            if trade_id in self._open_state:
                # Keep first emitted open payload authoritative for this id.
                st = self._open_state[trade_id]
                if st.get("entry", 0.0) > 0.0:
                    out["entry"] = st["entry"]
                if st.get("stop", 0.0) > 0.0:
                    out["stop"] = st["stop"]
                if st.get("tp", 0.0) > 0.0:
                    out["tp"] = st["tp"]
                if st.get("qty", 0.0) > 0.0:
                    out["qty"] = st["qty"]
            else:
                self._ingest_canonical_state(out)

        elif action == "modify":
            stop_val = float(out.get("new_stop", 0.0) or 0.0)
            if stop_val > 0.0:
                self._latest_stop_by_id[trade_id] = stop_val

        elif action == "close":
            reason = str(out.get("reason", "")).lower()
            if reason == "tp":
                st = self._open_state.get(trade_id)
                if st is not None and float(st.get("tp", 0.0) or 0.0) > 0.0:
                    out["exit"] = float(st.get("tp", 0.0))
            elif reason == "stop":
                stop_val = float(self._latest_stop_by_id.get(trade_id, 0.0) or 0.0)
                if stop_val > 0.0:
                    out["exit"] = stop_val

        return out

    def write_initial(self, events: List[dict]) -> int:
        """
        Write the full historical event stream on first startup.
        Resets the dedup set so a clean run always starts fresh.
        """
        self._written_fps.clear()
        self._open_state.clear()
        self._latest_stop_by_id.clear()
        lines: List[str] = []
        for ev in events:
            canon_ev = self._canonicalize_event(ev)
            line = self._serialise_event(canon_ev)
            fp   = _event_fingerprint(canon_ev)
            lines.append(line)
            self._written_fps.add(fp)
            self._ingest_canonical_state(canon_ev)

        # Overwrite (not append) on initial write
        blob = "\n".join(lines) + ("\n" if lines else "")
        for target in [self.local_path] + self.mt5_paths:
            os.makedirs(os.path.dirname(os.path.abspath(target)), exist_ok=True)
            tmp = target + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                f.write(blob)
            try:
                os.replace(tmp, target)
            except OSError:
                shutil.copy2(tmp, target)
                try:
                    os.remove(tmp)
                except OSError:
                    pass

        print(f"[daemon] initial write: {len(lines)} events → {self.local_path}")
        self._save_fp_cache()
        return len(lines)

    def append_new(self, events: List[dict]) -> int:
        """
        Compute fingerprints for all events; append only those not yet written.
        FIX-1: trade events (modify/close) get a per-event fingerprint,
                so multiple modify events for the same id are each unique.
        FIX-2: identical control events from successive reruns are suppressed.
        """
        new_lines: List[str] = []
        for ev in events:
            canon_ev = self._canonicalize_event(ev)
            fp = _event_fingerprint(canon_ev)
            if fp in self._written_fps:
                continue
            self._written_fps.add(fp)
            new_lines.append(self._serialise_event(canon_ev))
            self._ingest_canonical_state(canon_ev)

        if not new_lines:
            return 0

        for target in [self.local_path] + self.mt5_paths:
            _atomic_append_lines(target, new_lines)

        print(
            f"[daemon] {datetime.utcnow().isoformat()} "
            f"appended {len(new_lines)} new event(s)"
        )
        self._save_fp_cache()
        return len(new_lines)

    def maybe_heartbeat(self, interval_s: float = 300.0) -> None:
        """Append a heartbeat line when the interval has elapsed."""
        now = time.monotonic()
        if now - self._last_heartbeat < interval_s:
            return
        self._last_heartbeat = now
        hb = json.dumps({
            "v": engine.SIGNAL_SCHEMA_VERSION,
            "action": "heartbeat",
            "ts": datetime.utcnow().isoformat(),
        })
        for target in [self.local_path] + self.mt5_paths:
            _atomic_append_lines(target, [hb])
        print(f"[daemon] heartbeat written")


# ─────────────────────────────────────────────────────────────────────────────
# FILE MTIME WATCHER
# ─────────────────────────────────────────────────────────────────────────────

class MtimeWatcher:
    """Track file modification times to detect new bars."""

    def __init__(self, paths: List[str]):
        self._paths = paths
        self._mtimes: Dict[str, float] = {}

    def snapshot(self) -> None:
        for p in self._paths:
            try:
                self._mtimes[p] = os.path.getmtime(p)
            except FileNotFoundError:
                self._mtimes[p] = 0.0

    def any_changed(self) -> bool:
        for p in self._paths:
            try:
                cur = os.path.getmtime(p)
            except FileNotFoundError:
                cur = 0.0
            if cur != self._mtimes.get(p, 0.0):
                return True
        return False

    def update(self) -> None:
        self.snapshot()


# ─────────────────────────────────────────────────────────────────────────────
# MAIN DAEMON LOOP
# ─────────────────────────────────────────────────────────────────────────────

def _parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="PHANTOM live signal daemon")
    p.add_argument("--instrument",   required=True, choices=["XAU", "US100", "BTC"])
    p.add_argument("--m1",           required=True)
    p.add_argument("--m5",           required=True)
    p.add_argument("--m15",          required=True)
    p.add_argument("--h1",           required=True)
    p.add_argument("--h4",           required=True)
    p.add_argument("--daily",        required=True)
    p.add_argument("--weekly",       required=True)
    p.add_argument("--capital",      type=float, default=10_000)
    p.add_argument("--output-dir",   default="signals")
    p.add_argument("--signal-filename", default="signals_vantage_live.jsonl")
    p.add_argument("--poll-seconds", type=float, default=15.0,
                   help="How often to poll for file changes (seconds)")
    p.add_argument("--heartbeat-interval", type=float, default=300.0,
                   help="Heartbeat interval in seconds (0 = disabled)")
    # CASH overrides (forwarded to engine)
    p.add_argument("--cash-max-leverage",      type=float, default=200.0)
    p.add_argument("--cash-trail-max-loss-pct",type=float, default=15.0)
    p.add_argument("--cash-lot-cap-mult",      type=float, default=10.0)
    p.add_argument("--cash-soft-stop-ratio",   type=float, default=0.8)
    p.add_argument("--cash-manual-resume-file",default="tmp/cash_resume.flag")
    p.add_argument("--cash-daily-resume-file",default="common://phantom_live/cash_daily_resume.flag")
    p.add_argument("--cash-master-control-file", default="common://phantom_live/master_control.flag")
    p.add_argument("--cash-hard-close",        action="store_true", default=True)
    p.add_argument("--cash-hard-stop-pause-days", type=int, default=0)
    return p.parse_args()


def main() -> None:
    args = _parse_args()

    data_files = [args.m1, args.m5, args.m15, args.h1, args.h4, args.daily, args.weekly]

    print("=" * 60)
    print(f"[daemon] PHANTOM p2 Live Daemon starting")
    print(f"[daemon] instrument  : {args.instrument}")
    print(f"[daemon] capital     : £{args.capital:,.0f}")
    print(f"[daemon] signal file : {args.signal_filename}")
    print(f"[daemon] poll        : {args.poll_seconds}s")
    print(f"[daemon] MT5 paths   : {_find_mt5_common_files() or ['(none found)']}")
    print("=" * 60)

    writer = SignalWriter(args.signal_filename, args.output_dir)
    watcher = MtimeWatcher(data_files)
    resume_flag_mtimes = _snapshot_manual_resume_flags(args)
    master_mode = ""

    # ── INITIAL RUN ───────────────────────────────────────────────────────────
    print("[daemon] running full historical engine pass …")
    events: Optional[List[dict]] = None
    for attempt in range(1, 6):
        try:
            events = _run_engine(args)
            break
        except pd.errors.EmptyDataError:
            # MT5 can briefly expose empty CSVs while exporter rewrites files.
            wait_s = min(5.0, float(attempt))
            print(f"[daemon] startup read race (empty CSV), retry {attempt}/5 in {wait_s:.1f}s")
            time.sleep(wait_s)
        except Exception as exc:
            traceback.print_exc(file=sys.stderr)
            if attempt >= 3:
                sys.exit(f"[daemon] FATAL on initial engine run: {exc}")
            wait_s = min(5.0, float(attempt))
            print(f"[daemon] startup engine error, retry {attempt}/3 in {wait_s:.1f}s: {exc}")
            time.sleep(wait_s)

    if events is None:
        sys.exit("[daemon] FATAL on initial engine run: exhausted retries")

    if writer.has_existing_signal_stream():
        appended = writer.append_new(events)
        print(f"[daemon] startup recovery mode: appended {appended} unseen event(s)")
    else:
        writer.write_initial(events)
    watcher.snapshot()
    print(f"[daemon] initial pass complete. {len(events)} events written. Entering poll loop …\n")

    # ── POLL LOOP ─────────────────────────────────────────────────────────────
    hb_interval = args.heartbeat_interval if args.heartbeat_interval > 0 else 0.0
    engine.EMIT_HEARTBEATS = hb_interval > 0

    while True:
        time.sleep(args.poll_seconds)

        try:
            writer.maybe_heartbeat(hb_interval if hb_interval > 0 else 300.0)

            next_master_mode = _read_master_control_mode(str(getattr(args, "cash_master_control_file", "") or ""))
            control_changed = next_master_mode != master_mode
            if control_changed:
                master_mode = next_master_mode
                if master_mode == "PAUSE":
                    writer.append_new([
                        {
                            "v": 1,
                            "action": "pause_entries",
                            "reason": "manual_master_pause",
                            "resume_after": "",
                            "signal_ts": datetime.utcnow().isoformat(),
                        }
                    ])
                    print(f"[daemon] {datetime.utcnow().isoformat()} — master control set to PAUSE")
                elif master_mode == "RESUME":
                    writer.append_new([
                        {
                            "v": 1,
                            "action": "resume_entries",
                            "reason": "manual_master_resume",
                            "signal_ts": datetime.utcnow().isoformat(),
                        }
                    ])
                    print(f"[daemon] {datetime.utcnow().isoformat()} — master control set to RESUME")

            changed = watcher.any_changed()
            has_override = _manual_resume_override_changed(args, resume_flag_mtimes)
            should_rerun = changed or has_override or control_changed

            if not should_rerun:
                continue

            if control_changed and not changed and not has_override:
                print(f"[daemon] {datetime.utcnow().isoformat()} — master control changed, re-running engine …")
            elif has_override and not changed:
                print(f"[daemon] {datetime.utcnow().isoformat()} — manual resume override detected, re-running engine …")
            else:
                print(f"[daemon] {datetime.utcnow().isoformat()} — data file changed, re-running engine …")

            try:
                events = _run_engine(args)
            except pd.errors.EmptyDataError:
                print("[daemon] transient CSV read race (empty file), skipping this poll")
                continue
            watcher.update()
            appended = writer.append_new(events)
            if appended == 0:
                print("[daemon] no new events (all fingerprints already written)")

        except KeyboardInterrupt:
            print("\n[daemon] interrupted by user. Exiting.")
            sys.exit(0)
        except Exception as exc:
            # Don't crash the daemon on a transient error; log and continue
            print(f"[daemon] ERROR (non-fatal): {exc}")
            traceback.print_exc(file=sys.stderr)
            time.sleep(args.poll_seconds)


if __name__ == "__main__":
    main()
