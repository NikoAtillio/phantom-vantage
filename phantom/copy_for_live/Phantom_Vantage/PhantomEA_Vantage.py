"""
PHANTOM p2 - Multi-Timeframe Backtest Engine
====
Improvements over p1:
  1. Instrument config objects  — per-instrument session windows, ATR multipliers, TP targets
  2. Adaptive TP                — 1.3R (XAU/US100) or 1.5R (BTC) instead of fixed 2R
  3. Session gate               — hard block outside high-liquidity hours (instrument-specific)
  4. Cluster cap                — max 3 concurrent entries per 4h window
  5. Zone confirmation delay    — require N bars holding zone before entry
  6. Trend regime filter        — Daily EMA50 vs EMA200; counter-trend at 0.5x size
  7. Breakeven at 0.8R          — move stop to entry once trade reaches +0.8R
  8. Circuit breaker            — pause 24h after 5 consecutive losses
  9. Confidence position sizing — 1.5x size when session + cluster + regime all aligned
 10. Instrument ATR multipliers — XAU: 2.0x, US100: 1.5x, BTC: 1.8x

Usage
    python phantom_p2.py --instrument XAU \\
        --m1 path/M1.csv --m5 path/M5.csv --h1 path/H1.csv --h4 path/H4.csv \\
        --daily path/Daily.csv \\
        [--capital 5000]

    Instrument choices: XAU | US100 | BTC
"""

import argparse
import os
import sys
import re
import warnings
from typing import Optional
import numpy as np
import pandas as pd
try:
    import pytz
except ImportError:
    pytz = None

import json
import glob
from datetime import datetime
from collections import Counter

warnings.filterwarnings('ignore')

ENGINE_VERSION = 'phantom_us100_v5_fund'   # CASH build (Option B split): equity-compounding base, tiered risk, 15% trailing-peak floor, x10 lot cap, 1:200 leverage
NOTIONAL_CAP = 400_000   # cap lot-sizing notional base at £400k (matches ~35-40 lot live MT5 behaviour)
MAX_LOT_CAP  = 50        # Hard per-order cap (Vantage NAS100 limit)

# Signal emission to MT5: write newline-delimited JSON into a file
# placed in a local `signals/` folder and -- when available -- into the
# MetaTrader `Common/Files` directory found under the Wine prefix.
EMIT_SIGNALS = True
EMIT_HEARTBEATS = False
EMIT_EOD_CLOSE_SIGNALS = True
SIGNAL_FILENAME = 'signals_vantage.jsonl'
GENERIC_SIGNAL_ALIAS = 'phantom_signals.jsonl'
WRITE_GENERIC_SIGNAL_ALIAS = False
SIGNAL_SCHEMA_VERSION = 1
_SIGNAL_SEQ = {'n': 0}
_EVENT_BUFFER = []
_MT5_COMMON_FILES_CACHE = None

# Time policy for raw CSV loading.
# None: treat CSV timestamps as already broker/server time (MT5 export default).
# Set to a timezone string only for non-broker datasets that require conversion.
CSV_SOURCE_TZ = None

# Timezone guardrail settings.
TZ_GUARD_ENABLED = True
TZ_GUARD_MIN_OPENS = 3
TZ_GUARD_SEPARATION_RATIO = 5.0
TZ_GUARD_MAX_MEAN_ABS_ERR = 2.0

def _find_mt5_common_files():
    """Return candidate MT5 Common/Files paths under the Wine prefix."""
    global _MT5_COMMON_FILES_CACHE
    if _MT5_COMMON_FILES_CACHE is not None:
        return _MT5_COMMON_FILES_CACHE

    wp = os.environ.get('WINEPREFIX') or '/Users/niko/Library/Application Support/net.metaquotes.wine.metatrader5'
    patterns = [
        os.path.join(wp, 'drive_c', 'users', '*', 'AppData', 'Roaming', 'MetaQuotes', 'Terminal', 'Common', 'Files'),
        os.path.join(wp, 'drive_c', 'Users', '*', 'AppData', 'Roaming', 'MetaQuotes', 'Terminal', 'Common', 'Files'),
    ]
    matches = []
    for pattern in patterns:
        matches.extend(glob.glob(pattern, recursive=True))
    # De-duplicate while preserving order.
    seen = set()
    unique_matches = []
    for path in matches:
        if path not in seen and os.path.isdir(path):
            seen.add(path)
            unique_matches.append(path)
    _MT5_COMMON_FILES_CACHE = unique_matches
    return _MT5_COMMON_FILES_CACHE

def _signal_file_path() -> str:
    return os.path.join(os.getcwd(), 'signals', SIGNAL_FILENAME)

def _safe_signal_token(value: Optional[str], default: str) -> str:
    if value is None:
        return default
    token = str(value).strip()
    if token == '':
        return default
    token = token.replace('-', '')
    token = re.sub(r'[^A-Za-z0-9_]+', '_', token)
    token = token.strip('_').lower()
    return token or default

def _build_signal_filename(engine: str,
                           instrument: str,
                           start_date: Optional[str],
                           end_date: Optional[str]) -> str:
    eng = _safe_signal_token(engine, 'engine')
    inst = _safe_signal_token(instrument, 'instrument')
    start = _safe_signal_token(start_date, 'full')
    end = _safe_signal_token(end_date, 'full')
    return f"signals_{eng}_{inst}_{start}_{end}.jsonl"

def _configure_signal_filename(args) -> str:
    global SIGNAL_FILENAME
    global WRITE_GENERIC_SIGNAL_ALIAS
    WRITE_GENERIC_SIGNAL_ALIAS = bool(getattr(args, 'write_generic_signal_alias', False))
    if getattr(args, 'signal_filename', None):
        raw = os.path.basename(str(args.signal_filename).strip())
        safe = re.sub(r'[^A-Za-z0-9._-]+', '_', raw)
        if not safe.lower().endswith('.jsonl'):
            safe += '.jsonl'
        SIGNAL_FILENAME = safe
    else:
        SIGNAL_FILENAME = 'signals_vantage.jsonl'
    return SIGNAL_FILENAME

def evaluate_tz_alignment_from_signals(m5_df: pd.DataFrame,
                    signal_file: Optional[str] = None,
                    min_opens: int = TZ_GUARD_MIN_OPENS):
    """
    Estimate hour offset between signal timestamps and loaded M5 bars.
    Compares signal open `entry` prices against raw M5 closes across offsets.
    Returns a dict with enough context for deterministic guardrail decisions.
    """
    if signal_file is None:
        signal_file = _signal_file_path()
    if not os.path.exists(signal_file):
        return {'status': 'no-signal-file'}
    if not isinstance(m5_df.index, pd.DatetimeIndex) or 'close' not in m5_df.columns:
        return {'status': 'invalid-m5'}

    opens = []
    try:
        with open(signal_file, 'r', encoding='utf-8') as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                o = json.loads(line)
                if o.get('action') != 'open':
                    continue
                ts = o.get('entry_ts')
                entry = o.get('entry')
                if ts is None or entry is None:
                    continue
                try:
                    ts_pd = pd.Timestamp(ts)
                    if ts_pd.tzinfo is not None:
                        ts_pd = ts_pd.tz_convert(None)
                    opens.append((ts_pd, float(entry)))
                except Exception:
                    continue
    except Exception as ex:
        return {'status': 'signal-read-error', 'error': str(ex)}

    if len(opens) < min_opens:
        return {'status': 'insufficient-opens', 'n_opens': len(opens)}

    close_series = m5_df['close']
    if getattr(close_series.index, 'tz', None) is not None:
        close_series = close_series.copy()
        close_series.index = close_series.index.tz_convert(None)

    scores = []
    for h in range(-12, 13):
        errs = []
        for ts_pd, entry in opens:
            shifted = ts_pd + pd.Timedelta(hours=h)
            if shifted in close_series.index:
                errs.append(abs(float(close_series.loc[shifted]) - entry))
        if errs:
            scores.append({
                'offset_h': h,
                'mean_abs_err': float(np.mean(errs)),
                'max_abs_err': float(np.max(errs)),
                'n': len(errs),
            })

    if not scores:
        return {'status': 'no-overlap', 'n_opens': len(opens)}

    scores.sort(key=lambda s: s['mean_abs_err'])
    best = scores[0]
    runner = scores[1] if len(scores) > 1 else None
    ratio = (runner['mean_abs_err'] / best['mean_abs_err']) if (runner and best['mean_abs_err'] > 0) else (np.inf if runner else np.inf)

    return {
        'status': 'ok',
        'n_opens': len(opens),
        'best': best,
        'runner': runner,
        'ratio': float(ratio),
        'top': scores[:5],
    }

def enforce_tz_guard(alignment: dict,
                    stage: str,
                    enforce: bool,
                    min_opens: int = TZ_GUARD_MIN_OPENS,
                    separation_ratio: float = TZ_GUARD_SEPARATION_RATIO,
                    max_mean_abs_err: float = TZ_GUARD_MAX_MEAN_ABS_ERR):
    """
    Deterministic timezone guard.
    Hard-fail only when evidence is sufficient and offset is clearly non-zero.
    """
    status = alignment.get('status')
    if status != 'ok':
        print(f"[tz-guard] {stage}: skipped ({status})")
        return

    best = alignment['best']
    runner = alignment.get('runner')
    ratio = alignment.get('ratio', np.inf)
    n_opens = alignment.get('n_opens', 0)
    best_h = int(best['offset_h'])
    best_err = float(best['mean_abs_err'])
    runner_txt = f"{runner['offset_h']}h/{runner['mean_abs_err']:.4f}" if runner else 'n/a'

    print(
        f"[tz-guard] {stage}: best={best_h:+d}h mean_err={best_err:.4f} "
        f"runner={runner_txt} ratio={ratio:.2f} opens={n_opens}"
    )

    ratio_ok = (np.isinf(ratio) or ratio >= separation_ratio)
    strong_evidence = (
        n_opens >= min_opens and
        ratio_ok and
        best_err <= max_mean_abs_err
    )
    if not strong_evidence:
        print(
            f"[tz-guard] {stage}: warning only (evidence not strong enough: "
            f"opens>={min_opens}, ratio>={separation_ratio}, best_err<={max_mean_abs_err})"
        )
        return

    if best_h != 0:
        msg = (
            f"[tz-guard] {stage}: FAIL offset={best_h:+d}h (non-zero with strong evidence). "
            f"Top offsets={alignment.get('top')}"
        )
        if enforce:
            raise RuntimeError(msg)
        print(msg)
    else:
        print(f"[tz-guard] {stage}: PASS (offset 0h)")

def reset_signal_file():
    """Clear the in-memory buffer at run start."""
    if not EMIT_SIGNALS:
        return
    _EVENT_BUFFER.clear()

def _next_signal_id(entry_ts) -> str:
    _SIGNAL_SEQ['n'] += 1
    ts = entry_ts.isoformat() if hasattr(entry_ts, 'isoformat') else str(entry_ts)
    return f"{ts}#{_SIGNAL_SEQ['n']}"

def emit_event(event: dict):
    """Buffer a versioned event line in memory (flushed once at run end)."""
    if not EMIT_SIGNALS:
        return
    payload = {'v': SIGNAL_SCHEMA_VERSION}
    payload.update(event)
    s = payload.copy()
    for k, v in s.items():
        if hasattr(v, 'isoformat'):
            s[k] = v.isoformat()
    _EVENT_BUFFER.append(json.dumps(s, default=str, ensure_ascii=False))

def flush_signals():
    """Write the entire buffered event stream once, to local + MT5 paths."""
    if not EMIT_SIGNALS:
        return 0
    local_dir = os.path.join(os.getcwd(), 'signals')
    os.makedirs(local_dir, exist_ok=True)
    blob = '\n'.join(_EVENT_BUFFER) + ('\n' if _EVENT_BUFFER else '')
    targets = [os.path.join(local_dir, SIGNAL_FILENAME)]
    for mt5_dir in _find_mt5_common_files():
        targets.append(os.path.join(mt5_dir, SIGNAL_FILENAME))
    if WRITE_GENERIC_SIGNAL_ALIAS and SIGNAL_FILENAME != GENERIC_SIGNAL_ALIAS:
        targets.append(os.path.join(local_dir, GENERIC_SIGNAL_ALIAS))
        for mt5_dir in _find_mt5_common_files():
            targets.append(os.path.join(mt5_dir, GENERIC_SIGNAL_ALIAS))
    # de-duplicate while preserving order
    seen = set()
    uniq_targets = []
    for target in targets:
        if target in seen:
            continue
        seen.add(target)
        uniq_targets.append(target)
    written = 0
    for target in uniq_targets:
        try:
            with open(target, 'w', encoding='utf-8') as f:
                f.write(blob)
            written += 1
        except Exception:
            pass
    return written

def emit_run_meta(capital, cash_enabled, instrument):
    """Emit the run header so the EA can detect the active account context."""
    emit_event({
        'action': 'meta',
        'engine': ENGINE_VERSION,
        'instrument': instrument,
        'signal_account_size': float(capital),
        'cash': bool(cash_enabled),
        'cash_daily_dd_pct': float(CASH_CONFIG['max_daily_loss_pct']),
        'atr_trail_mult': float(ACTIVE_SCENARIO_CFG.get('atr_trail', 0.8)),
    })

# Aligned profile: match MT5 high-risk sizing and peak-hour boost.
HIGH_RISK_PCT_MULT = 2.0
HIGH_PEAK_SESSION_BOOST = 1.2
HIGH_PEAK_HOURS_UTC = {14, 15, 16, 17}

CASH_CONFIG = {
    # CASH build guardrails (FTMO challenge logic stripped). The risk base now
    # COMPOUNDS off live equity (not a fixed start_cap), risk-per-trade is tiered
    # by account growth, and the max-loss floor TRAILS the equity peak.
    'max_daily_loss_pct': 4.5,        # daily loss limit: 4.5% off the day-START balance
    'circuit_breaker_pct': 90.0,      # soft halt at 90% of the daily amount -> auto-resume next day
    'soft_stop_ratio': 0.9,           # == circuit_breaker_pct/100 (pause before the daily hard floor)
    'total_soft_stop_enabled': False,  # LENIENT: disable total-soft-stop; only hard floor applies
    'trail_max_loss_pct': 15.0,       # C2: max-loss floor TRAILS 15% below the rolling equity peak
    'manual_resume_file': 'tmp/cash_resume.flag',
    'daily_resume_file': 'tmp/cash_daily_resume.flag',
    'master_control_file': '',
    'hard_close_on_trigger': True,
    'cash_max_leverage': 200.0,       # C4: cash leverage cap (default 1:200)
    'lot_cap_mult': 10.0,             # C3: per-order lot cap = daily-base lots x10
    # C1: tiered risk-per-trade by equity multiple of start_cap (mult = equity/start_cap)
    # (<2x -> 3.95%, <4x -> 3.10%, <7x -> 2.40%, <10x -> 1.85%, >=10x -> 1.40%)
    'risk_tiers': [
        (2.0, 3.95),
        (4.0, 3.10),
        (7.0, 2.40),
        (10.0, 1.85),
    ],
    'risk_tier_top_pct': 1.40,        # applied at >=10x
}
# NOTE (build-spec): profit_target_pct and min_trading_days are REMOVED in this
# CASH build. There is no FTMO challenge target / minimum-trading-days logic.

def tiered_risk_pct(equity: float, start_cap: float) -> float:
    """C1: risk-per-trade fraction based on how far equity has compounded above
    the original start capital.  Returns a FRACTION (e.g. 0.0395 for 3.95%)."""
    base = max(float(start_cap), 1.0)
    mult = max(0.0, float(equity)) / base
    for thresh, pct in CASH_CONFIG['risk_tiers']:
        if mult < thresh:
            return pct / 100.0
    return CASH_CONFIG['risk_tier_top_pct'] / 100.0

# ════
# INSTRUMENT CONFIG
# Each instrument gets its own session window, ATR multiplier, TP ratio,
# confirmation bars, and weekend policy.
# ════
INSTRUMENT_CONFIG = {
    'XAU': dict(
        # Session: tightened to 08:00–19:00 UTC; exclude 11:00 lunch lull
        session_start   = 8,
        session_end     = 19,
        session_exclude_hours = [11],
        allow_weekend   = False,
        weekend_size    = 0.0,
        # TP at 1.3R — daily range ~1.43%, 1.3R is achievable within session
        tp_mult         = 1.3,
        # ATR stop: 2.0x H4 ATR — XAU needs wider stop due to intraday noise
        atr_stop_mult   = 2.0,
        # Confirmation: require 2 H4 bars (8h) holding zone before entry
        min_confirm_bars= 2,
        confirm_tf_mins = 240,   # H4 = 240 min bars
        # Regime: Daily EMA50 vs EMA200
        regime_ema_fast = 50,
        regime_ema_slow = 200,
        # Asian session (03–07 UTC) allowed at reduced size
        soft_session_start = 3,
        soft_session_size  = 0.5,
    ),
    'US100': dict(
        # Session: Pre-market through NY close (13:00–21:00 UTC), weekdays only
        session_start   = 13,
        session_end     = 21,
        allow_weekend   = False,
        weekend_size    = 0.0,
        # TP at 1.3R — daily range ~1.93%, 1.3R is well within reach
        tp_mult         = 1.3,
        # ATR stop: 1.5x H4 ATR — US100 is cleaner, tighter stop works
        atr_stop_mult   = 1.5,
        # Confirmation: require 1 H1 bar (1h) holding zone before entry
        min_confirm_bars= 1,
        confirm_tf_mins = 60,    # H1 = 60 min bars
        regime_ema_fast = 50,
        regime_ema_slow = 200,
        # Trend-state logic now governs directional conviction, so the legacy
        # long-bias score offset is zeroed (build-spec: REMOVE / zero it).
        dir_score_offset = {'long': 0, 'short': 0},
        soft_session_start = None,
        soft_session_size  = 0.0,
    ),
    'BTC': dict(
        # Session tightened to 08:00–18:00 UTC; weekends allowed at 0.5x size
        session_start   = 8,
        session_end     = 18,
        allow_weekend   = True,
        weekend_size    = 0.5,   # 50% size on Sat/Sun
        # TP at 1.5R — BTC daily range ~3–5%, 2R is achievable but 1.5R is safer
        tp_mult         = 1.5,
        # ATR stop: 1.8x H4 ATR — keep p1 value, BTC volatility is already priced in
        atr_stop_mult   = 1.8,
        # Confirmation: require 2 H4 bars (8h) holding zone before entry
        min_confirm_bars= 2,
        confirm_tf_mins = 240,
        # Phase 3 test: allow BTC setups more time before stop exits.
        min_hold_hours  = 4,
        regime_ema_fast = 50,
        regime_ema_slow = 200,
        soft_session_start = None,
        soft_session_size  = 0.0,
    ),
}

# ════
# SCENARIO CONFIG
# ════
DEFAULTS = {
    'capital'       : 70_000,
    'max_concurrent': 3,
    'cooldown_min'  : 20,
    'lockout_min'   : 60,
    'conf_tol'      : 0.002,     # 0.20% zone proximity
    'h4_pivot_bars' : 2,
    'h4_lookback'   : 50,
    'circuit_breaker_losses': 8, # pause after N consecutive losses
    'circuit_breaker_hours' : 12,
    'consecutive_loss_hard_stop': 15,
    'breakeven_r'   : 0.8,       # move stop to entry at this R level
    'confidence_mult': 7.5,      # top-confidence sizing (boosted from 6.6)
    'confidence_medium_mult': 1.6, # medium-confidence sizing
    'confidence_min' : 0.6,      # counter-trend / trendless floor (raised from 0.3)
    'confidence_max' : 9.0,      # hard ceiling on confidence sizing
    'high_conf_stack_threshold': 1.5,  # keep 3-stack gate stable while raising top-end sizing
    'confidence_mode': 'inverted', # flat | inverted | score
    'confidence_score_min': 7,
    # Volatility throttle: damp only the boosted confidence component when
    # H4 ATR is elevated vs its rolling mean.
    'vol_throttle_enabled': True,
    'vol_throttle_lookback': 96,
    'vol_throttle_ratio_start': 1.2,
    'vol_throttle_ratio_end': 1.8,
    'vol_throttle_min_factor': 0.65,
}

SCENARIOS = {
    'B': dict(
        entry_tf    = 'm5',
        risk_pct    = 0.007,
        score_min   = 3,
        h4_min      = 1,
        h1_min      = 1,
        ltf_min     = 1,
        ltf_cap     = 3,
        vol_filter  = False,
        timeout_bars= None,
        atr_trail   = 0.8,
    ),
}

ACTIVE_SCENARIO_LETTER = 'B'
ACTIVE_SCENARIO_ID = f"{ENGINE_VERSION.upper()}{ACTIVE_SCENARIO_LETTER}"
ACTIVE_SCENARIO_CFG = SCENARIOS[ACTIVE_SCENARIO_LETTER]

# ════
# DATA LOADING
# ════
def load_csv(path: str) -> pd.DataFrame:
    """Load MetaTrader-style tab-separated OHLCV file."""
    df = pd.read_csv(path, sep='\t', header=0)
    df.columns = [c.strip('<>').lower() for c in df.columns]
    if 'date' in df.columns and 'time' in df.columns:
        date_str = df['date'].astype(str).str.strip()
        time_str = df['time'].astype(str).str.strip()
        df['datetime'] = pd.to_datetime(date_str + ' ' + time_str, errors='coerce')
        # Broker export default: keep naive timestamps as-is (broker/server clock).
        # Optional conversion path for non-broker datasets.
        if CSV_SOURCE_TZ is not None:
            if pytz is None:
                raise RuntimeError('CSV_SOURCE_TZ set but pytz is unavailable')
            src_tz = pytz.timezone(CSV_SOURCE_TZ)
            df['datetime'] = (df['datetime']
                    .dt.tz_localize(None)
                    .dt.tz_localize(src_tz, ambiguous='NaT', nonexistent='NaT')
                    .dt.tz_convert('UTC')
                    .dt.tz_localize(None))
    elif 'date' in df.columns:
        # Daily exports often omit a separate time column.
        date_str = df['date'].astype(str).str.strip()
        df['datetime'] = pd.to_datetime(date_str, errors='coerce')
    elif 'datetime' in df.columns:
        datetime_str = df['datetime'].astype(str).str.strip()
        df['datetime'] = pd.to_datetime(datetime_str, errors='coerce')
    else:
        raise ValueError(f"Cannot find datetime columns in {path}")
    df = df.dropna(subset=['datetime'])
    df = df.set_index('datetime').sort_index()
    for col in ['open', 'high', 'low', 'close', 'tickvol']:
        if col in df.columns:
            df[col] = pd.to_numeric(df[col], errors='coerce')
    df.dropna(subset=['open', 'high', 'low', 'close'], inplace=True)
    if 'tickvol' not in df.columns:
        df['tickvol'] = 1.0
    return df

# ════
# INDICATORS
# ════
def calc_atr(df: pd.DataFrame, n: int = 14) -> pd.Series:
    h, l, c = df['high'], df['low'], df['close']
    tr = pd.concat(
        [h - l, (h - c.shift()).abs(), (l - c.shift()).abs()], axis=1
    ).max(axis=1)
    return tr.ewm(span=n, adjust=False).mean()

def calc_ema(s: pd.Series, n: int) -> pd.Series:
    return s.ewm(span=n, adjust=False).mean()

def calc_rsi(s: pd.Series, n: int = 14) -> pd.Series:
    d  = s.diff()
    g  = d.clip(lower=0).ewm(span=n, adjust=False).mean()
    ls = (-d).clip(lower=0).ewm(span=n, adjust=False).mean()
    return 100 - 100 / (1 + g / ls.replace(0, np.nan))

def add_indicators(df: pd.DataFrame) -> pd.DataFrame:
    df = df.copy()
    df['atr']    = calc_atr(df)
    df['ema20']  = calc_ema(df['close'], 20)
    df['ema50']  = calc_ema(df['close'], 50)
    df['ema200'] = calc_ema(df['close'], 200)
    df['rsi']    = calc_rsi(df['close'])
    df['vol_ma'] = df['tickvol'].rolling(20).mean()
    return df

# ════
# NEW TREND-LAYER INDICATORS  (A — shared, identical in CASH + Cash files)
# Applied to Weekly / Daily / H4 frames via add_trend_layers().
# ════
def calc_adx(df: pd.DataFrame, n: int = 14) -> pd.Series:
    """Wilder ADX(14). Used as the ADX>=22 trend-strength gate in compute_trend_state()."""
    h, l, c = df['high'], df['low'], df['close']
    up_move   = h.diff()
    down_move = -l.diff()
    plus_dm  = np.where((up_move > down_move) & (up_move > 0), up_move, 0.0)
    minus_dm = np.where((down_move > up_move) & (down_move > 0), down_move, 0.0)
    plus_dm  = pd.Series(plus_dm,  index=df.index)
    minus_dm = pd.Series(minus_dm, index=df.index)
    tr = pd.concat(
        [h - l, (h - c.shift()).abs(), (l - c.shift()).abs()], axis=1
    ).max(axis=1)
    # True Wilder smoothing: alpha = 1/n
    atr_w   = tr.ewm(alpha=1.0 / n, adjust=False).mean()
    plus_di = 100.0 * plus_dm.ewm(alpha=1.0 / n, adjust=False).mean() / atr_w.replace(0, np.nan)
    minus_di = 100.0 * minus_dm.ewm(alpha=1.0 / n, adjust=False).mean() / atr_w.replace(0, np.nan)
    di_sum = (plus_di + minus_di).replace(0, np.nan)
    dx = 100.0 * (plus_di - minus_di).abs() / di_sum
    adx = dx.ewm(alpha=1.0 / n, adjust=False).mean()
    return adx

def add_structure(df: pd.DataFrame) -> pd.DataFrame:
    """Add ma21/50/200 SMAs plus a 5-bar ma50 slope (per-TF structure)."""
    df = df.copy()
    df['ma21']  = df['close'].rolling(21).mean()
    df['ma50']  = df['close'].rolling(50).mean()
    df['ma200'] = df['close'].rolling(200).mean()
    df['ma50_slope'] = df['ma50'] - df['ma50'].shift(5)
    return df

def add_anchored_vwap(df: pd.DataFrame) -> pd.DataFrame:
    """Add weekly- and monthly-anchored VWAP (resets each calendar week / month)."""
    df = df.copy()
    if not isinstance(df.index, pd.DatetimeIndex):
        df['vwap_w'] = np.nan
        df['vwap_m'] = np.nan
        return df
    typical = (df['high'] + df['low'] + df['close']) / 3.0
    vol = df['tickvol'].astype(float)
    vol = vol.where(vol > 0, 1.0)            # guard against zero-volume bars
    pv = typical * vol
    wk_anchor = df.index.to_period('W')
    mo_anchor = df.index.to_period('M')
    df['vwap_w'] = (pv.groupby(wk_anchor).cumsum()
                    / vol.groupby(wk_anchor).cumsum())
    df['vwap_m'] = (pv.groupby(mo_anchor).cumsum()
                    / vol.groupby(mo_anchor).cumsum())
    return df

def add_trend_layers(df: pd.DataFrame) -> pd.DataFrame:
    """Bundle the new shared trend layers (ADX + structure + anchored VWAP)
    onto a Weekly / Daily / H4 frame that already has base indicators."""
    df = add_structure(df)
    df = add_anchored_vwap(df)
    df['adx'] = calc_adx(df)
    return df

def add_daily_regime(daily: pd.DataFrame, inst_cfg: dict) -> pd.DataFrame:
    """Add trend regime to daily bars: 'bull' or 'bear'."""
    daily = daily.copy()
    fast = inst_cfg['regime_ema_fast']
    slow = inst_cfg['regime_ema_slow']
    daily['regime_ema_fast'] = calc_ema(daily['close'], fast)
    daily['regime_ema_slow'] = calc_ema(daily['close'], slow)
    daily['regime'] = np.where(
        daily['regime_ema_fast'] > daily['regime_ema_slow'], 'bull', 'bear'
    )
    return daily

# ════
# NEW TREND-STATE LOGIC  (B — shared, identical in CASH + Cash files)
# Replaces the retired dual-SMA bias layer (get_htf_bias / get_ltf_bias /
# compute_bias_conf_adj) with an ADX-gated, structure-driven trend state.
# ════
def _tf_dir(close, ma21, ma50, ma200, ma50_slope) -> int:
    """Per-timeframe direction: 2-of-3 structure vote (price vs ma21/50/200)
    confirmed by the 5-bar ma50 slope.  Returns +1 (up) / -1 (down) / 0 (mixed)."""
    if any(v is None or (isinstance(v, float) and np.isnan(v))
           for v in (close, ma21, ma50, ma200, ma50_slope)):
        return 0
    bull_votes = (close > ma21) + (close > ma50) + (close > ma200)
    struct = 1 if bull_votes >= 2 else -1           # 2-of-3 vote
    slope = 1 if ma50_slope > 0 else (-1 if ma50_slope < 0 else 0)
    # Direction only when structure and slope agree; otherwise treat as mixed.
    if struct == slope:
        return struct
    return 0

def _rsi_conf(rv: float, direction: str) -> float:
    """Graded RSI confidence (replaces the binary rv>50 / rv<50 used previously).
    45-55 = dead zone (0.0); momentum-with-trade grades up:
      mild >55/<45 -> 0.5, strong >=60/<=40 -> 0.75, very strong >=70/<=30 -> 1.0."""
    if rv is None or (isinstance(rv, float) and np.isnan(rv)):
        return 0.0
    if direction == 'long':
        if rv >= 70: return 1.0
        if rv >= 60: return 0.75
        if rv > 55:  return 0.5
        return 0.0           # dead zone (45-55) or against (<45)
    else:
        if rv <= 30: return 1.0
        if rv <= 40: return 0.75
        if rv < 45:  return 0.5
        return 0.0           # dead zone (45-55) or against (>55)

# Trend-state tuning knobs (target ~60% WR — see build-spec VALIDATION rows).
ADX_TREND_GATE  = 22.0   # apply trend logic only when ADX >= this
TF_ALIGN_WEIGHT = 0.18   # conf_mult weight per net aligned timeframe

def compute_trend_state(direction: str,
                        price: float,
                        adx: float,
                        wk_dir: int,
                        dl_dir: int,
                        h4_dir: int,
                        vwap_w: float,
                        vwap_m: float,
                        counter_trend: bool):
    """Unified trend-state gate. Returns (conf_mult, hard_skip, with_trend).

    conf_mult  : confidence size multiplier, clamped to [confidence_min, confidence_max] (default 9.0).
    hard_skip  : True only when (ADX>=gate) AND counter-trend regime
                 AND all three structural timeframes oppose the trade.
    with_trend : True when the majority of timeframes align with the trade
                 (drives stacking limits).

    When ADX < gate the market is treated as trendless: trade at minimum
    confidence size (no stacking, never hard-skipped) so choppy low-ADX
    regimes (e.g. the 2021 bleed months) only ever risk min-size.
    """
    dir_sign = 1 if direction == 'long' else -1
    dirs = [wk_dir, dl_dir, h4_dir]
    agree   = sum(1 for d in dirs if d == dir_sign)
    against = sum(1 for d in dirs if d == -dir_sign)
    tf_align = agree - against

    adx_ok = (adx is not None) and (not np.isnan(adx)) and (adx >= ADX_TREND_GATE)

    if not adx_ok:
        # Trendless regime: force minimum-size, no stacking, no hard skip.
        return DEFAULTS['confidence_min'], False, False

    # Anchored-VWAP confluence: small nudge when price sits on the trade side
    # of both the weekly and monthly VWAP (or against it).
    vwap_align = 0
    if not (vwap_w is None or np.isnan(vwap_w)):
        vwap_align += 1 if ((price > vwap_w) == (direction == 'long')) else -1
    if not (vwap_m is None or np.isnan(vwap_m)):
        vwap_align += 1 if ((price > vwap_m) == (direction == 'long')) else -1

    conf_mult = 1.0 + TF_ALIGN_WEIGHT * (tf_align + 0.5 * vwap_align)
    conf_cap = float(DEFAULTS.get('confidence_max', 2.0))
    conf_mult = max(DEFAULTS['confidence_min'], min(conf_cap, conf_mult))

    with_trend = agree >= 2 and agree > against
    hard_skip = counter_trend and (against == 3)
    return conf_mult, hard_skip, with_trend

def apply_start_date(df: pd.DataFrame, start_date: Optional[str], end_date: Optional[str] = None) -> pd.DataFrame:
    """Optionally filter a dataframe to rows within a UTC date range."""
    if not isinstance(df.index, pd.DatetimeIndex):
        return df

    def _align_ts(ts: pd.Timestamp) -> pd.Timestamp:
        idx_tz = df.index.tz
        if idx_tz is None:
            return ts.tz_localize(None) if ts.tzinfo else ts
        if ts.tzinfo is None:
            return ts.tz_localize(idx_tz)
        return ts.tz_convert(idx_tz)

    if start_date:
        ts = _align_ts(pd.Timestamp(start_date))
        df = df[df.index >= ts]
    if end_date:
        ts_end = _align_ts(pd.Timestamp(end_date))
        df = df[df.index <= ts_end]
    return df

# ════
# FAST LOOKUP HELPERS
# ════
def fast_val(idx_arr: np.ndarray, vals: np.ndarray, ts) -> float:
    i = np.searchsorted(idx_arr, ts, side='right') - 1
    return float(vals[i]) if i >= 0 else np.nan

def score_tf(idx_arr, c_arr, e20_arr, e50_arr, rsi_arr, ts, direction: str) -> float:
    """Score 0–3 for a single timeframe.
    The RSI leg is now graded via _rsi_conf() (replaces the old binary rv>50/<50),
    so a timeframe contributes up to 1.0 from RSI confidence instead of a hard 0/1."""
    i = np.searchsorted(idx_arr, ts, side='right') - 1
    if i < 0:
        return 0.0
    c, e20, e50, rv = c_arr[i], e20_arr[i], e50_arr[i], rsi_arr[i]
    score = 0.0
    if direction == 'long':
        if c > e20:   score += 1
        if e20 > e50: score += 1
    else:
        if c < e20:   score += 1
        if e20 < e50: score += 1
    score += _rsi_conf(rv, direction)
    return score

# ════
# ZONE DETECTION
# ════
def build_h4_zones(h4: pd.DataFrame, pivot_bars: int = 2, lookback: int = 50):
    """Detect H4 pivot highs/lows as supply/demand zones."""
    highs = h4['high'].values
    lows  = h4['low'].values
    idx   = h4.index.values
    n     = len(h4)
    zone_ts, zone_px, zone_dir = [], [], []

    for i in range(pivot_bars, n - pivot_bars):
        # A pivot is only known after pivot_bars future candles have printed.
        confirmed_at = idx[i + pivot_bars]
        # Pivot high → supply zone (short entry)
        if all(highs[i] >= highs[i - j] for j in range(1, pivot_bars + 1)) and \
           all(highs[i] >= highs[i + j] for j in range(1, pivot_bars + 1)):
            zone_ts.append(confirmed_at)
            zone_px.append(highs[i])
            zone_dir.append('short')
        # Pivot low → demand zone (long entry)
        if all(lows[i] <= lows[i - j] for j in range(1, pivot_bars + 1)) and \
           all(lows[i] <= lows[i + j] for j in range(1, pivot_bars + 1)):
            zone_ts.append(confirmed_at)
            zone_px.append(lows[i])
            zone_dir.append('long')

    return (
        np.array(zone_ts),
        np.array(zone_px, dtype=float),
        np.array(zone_dir),
    )

# ════
# SESSION & REGIME HELPERS
# ════
def get_session_size_mult(ts: pd.Timestamp, inst_cfg: dict) -> float:
    """
    Returns a size multiplier based on session rules:
      1.0  = full session
      0.5  = soft session (XAU Asian) or weekend (BTC)
      0.0  = blocked (out of session)
    """
    hour = ts.hour
    dow  = ts.dayofweek  # 0=Mon, 6=Sun

    # Optional hard exclusion list for known weak hours.
    exclude_hours = inst_cfg.get('session_exclude_hours', [])
    if hour in exclude_hours:
        return 0.0

    in_core_session = inst_cfg['session_start'] <= hour < inst_cfg['session_end']

    # Weekend handling
    if dow >= 5:
        if not inst_cfg['allow_weekend']:
            return 0.0
        return inst_cfg['weekend_size'] if in_core_session else 0.0

    # Core session
    if in_core_session:
        return 1.0

    # Soft session (XAU Asian hours)
    soft_start = inst_cfg.get('soft_session_start')
    if soft_start is not None and soft_start <= hour < inst_cfg['session_start']:
        return inst_cfg.get('soft_session_size', 0.0)

    return 0.0

def get_regime(daily_idx, daily_regime, ts) -> str:
    """Look up the daily regime at timestamp ts."""
    i = np.searchsorted(daily_idx, ts, side='right') - 1
    if i < 0:
        return 'bull'  # default to bull if no data yet
    return daily_regime[i]

def get_regime_size_mult(regime: str, direction: str) -> float:
    """
    With-trend: 1.0x size.
    Counter-trend: 0.5x size (don't block, just reduce).
    """
    if regime == 'bull' and direction == 'long':
        return 1.0
    if regime == 'bear' and direction == 'short':
        return 1.0
    return 0.5  # counter-trend

# ════
# ZONE CONFIRMATION DELAY
# ════
def zone_is_confirmed(ts: pd.Timestamp, zone_ts_val, inst_cfg: dict) -> bool:
    """
    Returns True if enough time has passed since the zone was formed
    for it to be considered confirmed (price has held the zone for N bars).
    min_confirm_bars * confirm_tf_mins = minimum minutes since zone formation.
    """
    min_minutes = inst_cfg['min_confirm_bars'] * inst_cfg['confirm_tf_mins']
    zone_time = pd.Timestamp(zone_ts_val)
    elapsed = (ts - zone_time).total_seconds() / 60
    return elapsed >= min_minutes

# ════
# CLUSTER TRACKING
# ════
class ClusterTracker:
    """Tracks how many trades have been entered in each 4h window."""
    def __init__(self, max_per_window: int = 3):
        self.max_per_window = max_per_window
        self._counts: dict = {}

    def _window_key(self, ts: pd.Timestamp) -> pd.Timestamp:
        return ts.floor('4h')

    def can_enter(self, ts: pd.Timestamp) -> bool:
        key = self._window_key(ts)
        return self._counts.get(key, 0) < self.max_per_window

    def register(self, ts: pd.Timestamp):
        key = self._window_key(ts)
        self._counts[key] = self._counts.get(key, 0) + 1

    def count_in_window(self, ts: pd.Timestamp) -> int:
        return self._counts.get(self._window_key(ts), 0)

# ════
# CIRCUIT BREAKER
# ════
class CircuitBreaker:
    """Pauses trading for N hours after M consecutive losses."""
    def __init__(self, max_losses: int = 5, pause_hours: int = 24, hard_stop_losses: int = 10):
        self.max_losses   = max_losses
        self.pause_hours  = pause_hours
        self.hard_stop_losses = hard_stop_losses
        self._consec      = 0
        self._cumulative_losses = 0
        self._hard_stopped = False
        self._paused_until: pd.Timestamp = pd.Timestamp.min

    def is_paused(self, ts: pd.Timestamp) -> bool:
        return ts < self._paused_until

    def record(self, win: bool, ts: pd.Timestamp):
        if win:
            self._consec = 0
        else:
            self._consec += 1
            self._cumulative_losses += 1
            if self._consec >= self.hard_stop_losses:
                self._hard_stopped = True
                return
            if self._consec >= self.max_losses:
                self._paused_until = ts + pd.Timedelta(hours=self.pause_hours)
                # Keep the loss streak so the 10-loss hard stop is truly consecutive,
                # not cumulative across wins.

    @property
    def consecutive_losses(self) -> int:
        return self._consec

    @property
    def cumulative_losses(self) -> int:
        return self._cumulative_losses

    @property
    def hard_stopped(self) -> bool:
        return self._hard_stopped

    def manual_reset_hard_stop(self):
        """Manual intervention reset after a hard-stop pause window."""
        self._hard_stopped = False
        self._consec = 0
        self._cumulative_losses = 0

# ════
# EXECUTION ADJUSTMENT
# ════
def apply_execution_adjustment(
    px: float, direction: str, side: str,
    spread_bps: float, slippage_bps: float
) -> float:
    half_spread = px * (spread_bps / 10_000) / 2
    slip        = px * (slippage_bps / 10_000)
    adj = half_spread + slip
    if side == 'entry':
        return px + adj if direction == 'long' else px - adj
    return px - adj if direction == 'long' else px + adj

# ════
# BACKTEST ENGINE
# ════
def run_scenario(
    candles: pd.DataFrame,
    h4_idx, h4_c, h4_e20, h4_e50, h4_rsi, h4_atr_arr, h4_atr_ma_arr,
    h4_ma21, h4_ma50, h4_ma200, h4_slope, h4_vww, h4_vwm, h4_adx,
    h1_idx, h1_c, h1_e20, h1_e50, h1_rsi,
    m15_idx, m15_atr_arr,
    wk_idx, wk_c, wk_ma21, wk_ma50, wk_ma200, wk_slope, wk_vww, wk_vwm, wk_adx,
    m5_idx, m5_c, m5_e20, m5_e50, m5_rsi, m5_vol, m5_vol_ma,
    m1_idx, m1_c, m1_e20, m1_e50, m1_rsi,
    zone_ts, zone_px, zone_dir,
    daily_idx, daily_regime,
    dl_c, dl_ma21, dl_ma50, dl_ma200, dl_slope, dl_vww, dl_vwm, dl_adx,
    cfg: dict,
    inst_cfg: dict,
    capital: float,
    max_concurrent: int,
    cooldown_min: int,
    lockout_min: int,
    conf_tol: float,
    spread_bps: float,
    slippage_bps: float,
    commission_per_trade: float,
    label: str,
    zone_lookback_bars: int,
    debug: bool = False,
    debug_path: Optional[str] = None,
) -> pd.DataFrame:

    start_cap = capital
    peak_equity = capital   # track rolling peak for CASH DD tier
    cash_dd_tier = 0        # 0=normal, 1=2-4%, 2=4-6%, 3=6-7.5%, 4=>7.5%

    risk_pct    = cfg['risk_pct'] * HIGH_RISK_PCT_MULT
    score_min   = cfg['score_min']
    h4_min      = cfg['h4_min']
    h1_min      = cfg['h1_min']
    ltf_min     = cfg['ltf_min']
    ltf_cap     = cfg['ltf_cap']
    vol_filter  = cfg['vol_filter']
    timeout_bars= cfg['timeout_bars']

    # Instrument-specific params
    atr_stop    = inst_cfg['atr_stop_mult']
    tp_mult     = inst_cfg['tp_mult']
    atr_trail   = cfg.get('atr_trail', 0.8)  # Trailing stop multiplier
    breakeven_r = DEFAULTS['breakeven_r']

    # p2 components
    cluster     = ClusterTracker(max_per_window=max_concurrent)
    breaker     = CircuitBreaker(
        max_losses  = DEFAULTS['circuit_breaker_losses'],
        pause_hours = DEFAULTS['circuit_breaker_hours'],
        hard_stop_losses = DEFAULTS['consecutive_loss_hard_stop'],
    )

    c_idx = candles.index.values
    c_c   = candles['close'].values
    c_h   = candles['high'].values
    c_l   = candles['low'].values

    positions  = []
    results    = []
    skipped    = {'session': 0, 'cluster': 0, 'confirm': 0, 'circuit': 0,
                  'score': 0, 'concurrent': 0, 'vol': 0, 'chasing': 0,
                  'not_bounce': 0, 'cash': 0, 'trend': 0}
    last_entry = None
    last_loss_exit = None
    debug_rows = [] if debug else None
    debug_tol_mult = 5.0

    # ── CASH sizing/guardrail base ────
    # CASH build: the risk base COMPOUNDS off live equity (see position sizing).
    # The daily loss limit is recomputed each day off that day's START balance,
    # and the max-loss floor TRAILS the rolling equity peak (C2). Nothing here is
    # anchored to a fixed start_cap.
    cash = dict(CASH_CONFIG)

    challenge_start_ts = pd.Timestamp(c_idx[0])
    daily_anchor = challenge_start_ts.normalize()
    daily_start_equity = capital
    cash_hard_stop = False
    cash_hard_stop_reason = None
    cash_hard_stop_until = None
    cash_daily_soft_pause = False
    cash_total_soft_pause = False
    cash_total_manual_resume = False  # latch: True after a manual resume until equity recovers
    cash_hard_stop_pause_days = max(0, int(cash.get('hard_stop_pause_days', 0) or 0))
    master_mode = ''
    master_last_mode = ''

    def load_master_mode() -> str:
        ctl_file = str(cash.get('master_control_file', '') or '').strip()
        if not ctl_file:
            return ''
        try:
            with open(ctl_file, 'r', encoding='utf-8') as f:
                raw = (f.read() or '').strip()
        except OSError:
            return ''
        if not raw:
            return ''
        token = raw.split()[0].strip().upper()
        return token if token in ('PAUSE', 'RESUME') else ''

    def fmt_gbp(value):
        return f"£{value:,.2f}"

    def mark_to_market(open_positions, mark_price):
        unreal = 0.0
        for p in open_positions:
            unreal += (
                (mark_price - p['entry']) * p['qty']
                if p['dir'] == 'long'
                else (p['entry'] - mark_price) * p['qty']
            )
        return unreal

    def close_positions_for_cash(open_positions, ts_pd, signal_px, close_reason='cash_guardrail', log_prefix='HARD-STOP FORCE-CLOSE'):
        nonlocal capital
        closed = []
        for p in open_positions:
            exit_px = apply_execution_adjustment(
                signal_px, p['dir'], 'exit', spread_bps, slippage_bps
            )
            gross_pnl = (
                (exit_px - p['entry']) * p['qty']
                if p['dir'] == 'long'
                else (p['entry'] - exit_px) * p['qty']
            )
            fees = commission_per_trade
            pnl = gross_pnl - fees
            capital += pnl
            risk_cash = max(1e-9, p['initial_risk_price'] * p['qty'])
            print(
                f"  [cash] {log_prefix} {ts_pd} | "
                f"id={p['id']} | dir={p['dir']} | qty={p['qty']:.6f} | "
                f"entry={p['entry']:.2f} | exit={exit_px:.2f} | pnl={fmt_gbp(pnl)}"
            )
            emit_event({'action': 'close', 'id': p['id'], 'signal_ts': ts_pd, 'exit': float(exit_px), 'reason': close_reason})
            closed.append({
                'entry_ts': p['entry_ts'],
                'exit_ts': ts_pd,
                'dir': p['dir'],
                'entry': p['entry'],
                'exit': exit_px,
                'entry_price': p['entry'],
                'exit_price': exit_px,
                'entry_signal_price': p['entry_signal'],
                'exit_signal_price': signal_px,
                'stop_price': p['stop'],
                'stop_price_initial': p['stop_initial'],
                'stop_price_exit': p['stop'],
                'initial_risk_price': p['initial_risk_price'],
                'r_value': pnl / risk_cash,
                'fees': fees,
                'pnl': pnl,
                'win': pnl > 0,
                'exit_reason': close_reason,
                'qty': p['qty'],
                'be_triggered': p.get('be_triggered', False),
                'confidence_mult': p.get('confidence_mult', 1.0),
                'regime': p.get('regime', 'unknown'),
            })
        return closed

    for bar_i, ts in enumerate(c_idx):
        ts_pd = pd.Timestamp(ts)
        price = c_c[bar_i]
        high  = c_h[bar_i]
        low   = c_l[bar_i]

        master_mode = load_master_mode()
        if master_mode != master_last_mode:
            if master_mode == 'PAUSE':
                emit_event({'action': 'pause_entries', 'reason': 'manual_master_pause', 'resume_after': ''})
                print(f"  [cash] master pause active {ts_pd} | entries blocked")
            elif master_mode == 'RESUME':
                emit_event({'action': 'resume_entries', 'reason': 'manual_master_resume'})
                print(f"  [cash] master resume active {ts_pd} | guardrail pauses overridden")
            master_last_mode = master_mode

        if EMIT_HEARTBEATS:
            emit_event({'action': 'heartbeat', 'ts': ts_pd})

        # ── manage open positions ────
        still_open = []
        for p in positions:
            exit_reason = None
            exit_signal_px = None
            modify_reason = 'trail'

            # Trailing stop update (CRITICAL: must come before breakeven check)
            atr_h4_v_now = fast_val(h4_idx, h4_atr_arr, ts)
            if not np.isnan(atr_h4_v_now) and atr_h4_v_now > 0:
                trail_dist = atr_trail * p['atr_e']
                if p['dir'] == 'long':
                    new_trail = price - trail_dist
                    p['stop'] = max(p['stop'], new_trail)
                else:
                    new_trail = price + trail_dist
                    p['stop'] = min(p['stop'], new_trail)

            # Breakeven: move stop to entry once +0.8R is reached
            if not p.get('be_triggered', False):
                current_r = (
                    (price - p['entry']) / p['initial_risk_price']
                    if p['dir'] == 'long'
                    else (p['entry'] - price) / p['initial_risk_price']
                )
                if current_r >= breakeven_r:
                    # Never worsen protection: BE can only tighten risk.
                    if p['dir'] == 'long':
                        p['stop'] = max(p['stop'], p['entry'])
                    else:
                        p['stop'] = min(p['stop'], p['entry'])
                    p['be_triggered'] = True
                    modify_reason = 'breakeven'

            if abs(p['stop'] - p['last_emitted_stop']) > 1e-9:
                emit_event({
                    'action': 'modify',
                    'id': p['id'],
                    'signal_ts': ts_pd,
                    'new_stop': float(p['stop']),
                    'reason': modify_reason,
                })
                p['last_emitted_stop'] = p['stop']

            # Minimum-hold stop filter (instrument-specific, timeframe-aware).
            hold_bars = bar_i - p['entry_bar']
            bar_minutes = 1 if cfg['entry_tf'] == 'm1' else 5
            bars_per_hour = max(1, 60 // bar_minutes)
            min_hold_hours = int(inst_cfg.get('min_hold_hours', 2))
            min_hold_bars = min_hold_hours * bars_per_hour

            # Only exit on stop if hold threshold is met, or trade is at/above breakeven.
            allow_stop_exit = hold_bars >= min_hold_bars
            if not allow_stop_exit:
                # Allow stop exit even under 2h if we're at/past BE or in profit
                current_r = (
                    (price - p['entry']) / p['initial_risk_price']
                    if p['dir'] == 'long'
                    else (p['entry'] - price) / p['initial_risk_price']
                )
                if current_r >= 0.0:  # At or in profit
                    allow_stop_exit = True

            if p['dir'] == 'long':
                if allow_stop_exit and low <= p['stop']:
                    exit_signal_px = p['stop']
                    exit_reason = 'stop'
                elif high >= p['tp']:
                    exit_signal_px = p['tp']
                    exit_reason = 'tp'
            else:
                if allow_stop_exit and high >= p['stop']:
                    exit_signal_px = p['stop']
                    exit_reason = 'stop'
                elif low <= p['tp']:
                    exit_signal_px = p['tp']
                    exit_reason = 'tp'

            # Timeout
            if exit_reason is None and timeout_bars is not None:
                if bar_i - p['entry_bar'] >= timeout_bars:
                    exit_signal_px = price
                    exit_reason = 'timeout'

            if exit_reason:
                exit_px = apply_execution_adjustment(
                    exit_signal_px, p['dir'], 'exit', spread_bps, slippage_bps
                )
                gross_pnl = (
                    (exit_px - p['entry']) * p['qty']
                    if p['dir'] == 'long'
                    else (p['entry'] - exit_px) * p['qty']
                )
                fees = commission_per_trade
                pnl  = gross_pnl - fees
                capital += pnl
                risk_cash = max(1e-9, p['initial_risk_price'] * p['qty'])
                r_value   = pnl / risk_cash
                win       = pnl > 0

                # Update circuit breaker
                prev_consec = breaker.consecutive_losses
                breaker.record(win, ts_pd)
                if not win:
                    last_loss_exit = ts_pd
                    # Emit pause signal when circuit breaker threshold first crossed
                    if (breaker.consecutive_losses >= DEFAULTS['circuit_breaker_losses']
                            and prev_consec < DEFAULTS['circuit_breaker_losses']):
                        resume_ts = ts_pd + pd.Timedelta(hours=DEFAULTS['circuit_breaker_hours'])
                        emit_event({
                            'action': 'pause_entries',
                            'reason': f"consec_loss_{breaker.consecutive_losses}",
                            'resume_after': resume_ts.isoformat(),
                            'consec': breaker.consecutive_losses,
                        })
                    # Emit hard stop when breaker hard-stops
                    if breaker.hard_stopped:
                        emit_event({
                            'action': 'hard_stop',
                            'reason': f"consec_loss_{breaker.consecutive_losses}",
                            'flatten_all': True,
                            'consec': breaker.consecutive_losses,
                        })

                results.append({
                    'entry_ts'           : p['entry_ts'],
                    'exit_ts'            : ts_pd,
                    'dir'                : p['dir'],
                    'entry'              : p['entry'],
                    'exit'               : exit_px,
                    'entry_price'        : p['entry'],
                    'exit_price'         : exit_px,
                    'entry_signal_price' : p['entry_signal'],
                    'exit_signal_price'  : exit_signal_px,
                    'stop_price'         : p['stop'],
                    'stop_price_initial' : p['stop_initial'],
                    'stop_price_exit'    : p['stop'],
                    'initial_risk_price' : p['initial_risk_price'],
                    'r_value'            : r_value,
                    'fees'               : fees,
                    'pnl'                : pnl,
                    'win'                : win,
                    'exit_reason'        : exit_reason,
                    'qty'                : p['qty'],
                    'be_triggered'       : p.get('be_triggered', False),
                    'confidence_mult'    : p.get('confidence_mult', 1.0),
                    'regime'             : p.get('regime', 'unknown'),
                })
                emit_event({'action': 'close', 'id': p['id'], 'signal_ts': ts_pd, 'exit': float(exit_px), 'reason': exit_reason})
            else:
                still_open.append(p)

        positions = still_open

        # CASH daily reset (UTC date boundary)
        if ts_pd.normalize() != daily_anchor:
            daily_anchor = ts_pd.normalize()
            daily_start_equity = capital + mark_to_market(positions, price)
            if cash_daily_soft_pause:
                cash_daily_soft_pause = False
                emit_event({'action': 'resume_entries', 'reason': 'daily_soft_reset'})
                print(
                    f"  [cash] daily soft-stop RESET {ts_pd} | "
                    f"new UTC day, entries resumed"
                )
            if cash_hard_stop and cash_hard_stop_reason == 'daily_loss':
                cash_hard_stop = False
                cash_hard_stop_reason = None
                print(
                    f"  [cash] daily hard-stop RESET {ts_pd} | "
                    f"new UTC day, daily limits refreshed"
                )

        if (
            cash_hard_stop
            and cash_hard_stop_reason not in ('daily_loss', None)
            and cash_hard_stop_until is not None
            and ts_pd >= cash_hard_stop_until
        ):
            cash_hard_stop = False
            cash_hard_stop_reason = None
            cash_hard_stop_until = None
            breaker.manual_reset_hard_stop()
            emit_event({'action': 'resume_entries', 'reason': 'pause_window_elapsed'})
            print(
                f"  [cash] hard-stop AUTO-RESUME {ts_pd} | "
                f"pause window elapsed, trading resumed"
            )

        equity_now = capital + mark_to_market(positions, price)

        # Update rolling equity peak (drives the TRAILING max-loss floor, C2).
        if equity_now > peak_equity:
            peak_equity = equity_now

        # CASH build: FTMO drawdown-tier risk throttle is REMOVED. Risk-per-trade
        # is governed solely by the equity-compounding tiered_risk_pct() (C1) and
        # stacking is governed solely by trend alignment (with_trend).
        cash_dd_tier = 0
        dd_risk_mult = 1.0

        # CASH floors:
        #  • daily floor (4.5%) recomputed each day off that day's START balance
        #    (compounding) — circuit breaker soft-halts at 80% of the daily amount.
        #  • total floor TRAILS 15% below the rolling equity peak (C2) — hard pause
        #    + manual resume.
        daily_loss_cash = daily_start_equity * (cash['max_daily_loss_pct'] / 100.0)
        daily_floor = daily_start_equity - daily_loss_cash
        daily_soft_floor = daily_start_equity - (daily_loss_cash * cash['soft_stop_ratio'])
        trail_loss_cash = peak_equity * (cash['trail_max_loss_pct'] / 100.0)
        total_floor = peak_equity - trail_loss_cash
        total_soft_floor = peak_equity - (trail_loss_cash * cash['soft_stop_ratio'])
        hard_stop_reasons = []
        hard_stop_trigger_reason = None

        if breaker.hard_stopped and not cash_hard_stop:
            hard_stop_reasons.append('consecutive_losses')
            hard_stop_trigger_reason = 'consecutive_losses'
            cash_hard_stop = True
        if equity_now <= daily_floor:
            if not cash_hard_stop:
                hard_stop_reasons.append('daily_loss')
                hard_stop_trigger_reason = 'daily_loss'
            cash_hard_stop = True
        if equity_now <= total_floor:
            if not cash_hard_stop:
                hard_stop_reasons.append('total_loss')
                hard_stop_trigger_reason = 'total_loss'
            cash_hard_stop = True
        if hard_stop_trigger_reason is not None:
            cash_hard_stop_reason = hard_stop_trigger_reason
            if hard_stop_trigger_reason != 'daily_loss' and cash_hard_stop_pause_days > 0:
                cash_hard_stop_until = ts_pd.normalize() + pd.Timedelta(days=cash_hard_stop_pause_days)
                print(
                    f"  [cash] hard-stop PAUSE-UNTIL {cash_hard_stop_until} | "
                    f"reason={hard_stop_trigger_reason}"
                )
        if cash_hard_stop and master_mode != 'RESUME':
            # Only log at the moment of first trigger (hard_stop_reasons non-empty).
            if hard_stop_reasons:
                print(
                    f"  [cash] hard-stop TRIGGERED {ts_pd} | "
                    f"reason={'+'.join(hard_stop_reasons)} | "
                    f"equity={fmt_gbp(equity_now)} | "
                    f"daily_soft={fmt_gbp(daily_soft_floor)} | daily_hard={fmt_gbp(daily_floor)} | "
                    f"total_soft={fmt_gbp(total_soft_floor)} | total_hard={fmt_gbp(total_floor)}"
                )
            if positions and cash.get('hard_close_on_trigger', True):
                results.extend(close_positions_for_cash(positions, ts_pd, price, 'cash_guardrail', 'HARD-STOP FORCE-CLOSE'))
                positions = []
            elif positions and not cash.get('hard_close_on_trigger', True):
                print(
                    f"  [cash] hard-stop active {ts_pd} | hard-close disabled | "
                    f"open_positions={len(positions)}"
                )
            skipped['cash'] += 1
            continue

        if master_mode == 'RESUME' and cash_hard_stop:
            cash_hard_stop = False
            cash_hard_stop_reason = None
            cash_hard_stop_until = None
            breaker.manual_reset_hard_stop()

        # CASH soft stops: pause before hard-loss floors are reached.
        # Daily soft stop resets at next UTC day.
        if master_mode != 'RESUME' and (not cash_daily_soft_pause) and equity_now <= daily_soft_floor:
            cash_daily_soft_pause = True
            resume_ts = (ts_pd + pd.Timedelta(days=1)).normalize()
            emit_event({
                'action': 'pause_entries',
                'reason': 'cash_daily_soft_stop',
                'resume_after': resume_ts.isoformat(),
            })
            print(
                f"  [cash] daily soft-stop active {ts_pd} | "
                f"equity={fmt_gbp(equity_now)} <= daily_soft={fmt_gbp(daily_soft_floor)} | "
                f"daily_hard={fmt_gbp(daily_floor)} | "
                f"total_soft={fmt_gbp(total_soft_floor)} | total_hard={fmt_gbp(total_floor)} | "
                f"NEW ENTRIES BLOCKED - existing {len(positions)} position(s) continue to trailing stop"
            )

        # Total-loss soft stop - skipped entirely when total_soft_stop_enabled is False (lenient mode).
        # Once equity climbs back above the soft floor, clear the manual-resume
        # latch so a fresh breach later will require intervention again.
        if cash_total_manual_resume and equity_now > total_soft_floor:
            cash_total_manual_resume = False
            print(
                f"  [cash] total soft-stop latch cleared {ts_pd} | "
                f"equity={fmt_gbp(equity_now)} > total_soft={fmt_gbp(total_soft_floor)}"
            )
        # Only (re)arm the pause if we are NOT operating under an active manual
        # resume. This prevents the pause from re-triggering on the very next
        # bar while equity is still below the soft floor.
        if (master_mode != 'RESUME' and cash.get('total_soft_stop_enabled', True)
            and (not cash_total_soft_pause) and (not cash_total_manual_resume)
            and equity_now <= total_soft_floor):
            cash_total_soft_pause = True
            print(
                f"  [cash] total soft-stop active {ts_pd} | "
                f"equity={fmt_gbp(equity_now)} <= total_soft={fmt_gbp(total_soft_floor)} | "
                f"total_hard={fmt_gbp(total_floor)} | "
                f"daily_soft={fmt_gbp(daily_soft_floor)} | daily_hard={fmt_gbp(daily_floor)}"
            )

        if cash_total_soft_pause and master_mode != 'RESUME':
            resume_file = str(cash.get('manual_resume_file', '') or '').strip()
            if resume_file and os.path.exists(resume_file):
                cash_total_soft_pause = False
                cash_total_manual_resume = True  # latch until equity recovers
                print(
                    f"  [cash] manual resume detected {ts_pd}: {resume_file} | "
                    f"equity={fmt_gbp(equity_now)} | total_soft={fmt_gbp(total_soft_floor)}"
                )
            else:
                skipped['cash'] += 1
                if debug_rows is not None:
                    debug_rows.append({
                    'ts': ts_pd,
                    'price': price,
                    'event': 'bar_skip',
                    'reason': 'cash_total_soft_pause',
                    })
                continue

        if master_mode == 'RESUME' and cash_total_soft_pause:
            cash_total_soft_pause = False
            cash_total_manual_resume = True

        if cash_daily_soft_pause and master_mode != 'RESUME':
            daily_resume_file = str(cash.get('daily_resume_file', '') or '').strip()
            if daily_resume_file and os.path.exists(daily_resume_file):
                cash_daily_soft_pause = False
                emit_event({'action': 'resume_entries', 'reason': 'manual_daily_soft_resume'})
                try:
                    os.remove(daily_resume_file)
                except OSError:
                    pass
                print(
                    f"  [cash] manual daily resume detected {ts_pd}: {daily_resume_file} | "
                    f"entries resumed"
                )
                continue

            skipped['cash'] += 1
            if debug_rows is not None:
                debug_rows.append({
                    'ts': ts_pd,
                    'price': price,
                    'event': 'bar_skip',
                    'reason': 'cash_daily_soft_pause',
                })
            continue

        if master_mode == 'RESUME' and cash_daily_soft_pause:
            cash_daily_soft_pause = False

        # ── entry logic ────

        # Circuit breaker check
        if master_mode != 'RESUME' and breaker.is_paused(ts_pd):
            skipped['circuit'] += 1
            if debug_rows is not None:
                debug_rows.append({
                    'ts': ts_pd,
                    'price': price,
                    'event': 'bar_skip',
                    'reason': 'circuit',
                })
            continue

        if master_mode == 'PAUSE':
            skipped['cash'] += 1
            if debug_rows is not None:
                debug_rows.append({
                    'ts': ts_pd,
                    'price': price,
                    'event': 'bar_skip',
                    'reason': 'master_pause',
                })
            continue

        # Lockout after a losing exit to avoid immediate revenge entries.
        if last_loss_exit is not None:
            if (ts_pd - last_loss_exit).total_seconds() / 60 < lockout_min:
                if debug_rows is not None:
                    debug_rows.append({
                    'ts': ts_pd,
                    'price': price,
                    'event': 'bar_skip',
                    'reason': 'lockout',
                    })
                continue

        # Cooldown
        if last_entry is not None:
            if (ts_pd - last_entry).total_seconds() / 60 < cooldown_min:
                if debug_rows is not None:
                    debug_rows.append({
                    'ts': ts_pd,
                    'price': price,
                    'event': 'bar_skip',
                    'reason': 'cooldown',
                    })
                continue

        # ── scan zones ────
        atr_h4_v = fast_val(h4_idx, h4_atr_arr, ts)
        if np.isnan(atr_h4_v) or atr_h4_v <= 0:
            continue

        # Only evaluate zones formed in a recent rolling window and before current bar.
        lookback_minutes = max(1, int(zone_lookback_bars)) * 240
        min_zone_ts = ts - np.timedelta64(lookback_minutes, 'm')
        zone_start = np.searchsorted(zone_ts, min_zone_ts, side='left')
        zone_end = np.searchsorted(zone_ts, ts, side='left')

        for z_i in range(zone_start, zone_end):
            z_ts  = zone_ts[z_i]
            z_px  = zone_px[z_i]
            z_dir = zone_dir[z_i]
            z_dist = abs(price - z_px) / z_px

            # Zone proximity check
            if z_dist > conf_tol:
                if debug_rows is not None and z_dist <= conf_tol * debug_tol_mult:
                    debug_rows.append({
                    'ts': ts_pd,
                    'price': price,
                    'event': 'zone_skip',
                    'reason': 'tolerance',
                    'zone_ts': z_ts,
                    'zone_px': z_px,
                    'zone_dir': z_dir,
                    'zone_dist': z_dist,
                    'conf_tol': conf_tol,
                    })
                continue

            # ── NOT-CHASING FILTER: entry must be within 1.5x M15 ATR of zone ──
            m15_atr_v = fast_val(m15_idx, m15_atr_arr, ts)
            if not np.isnan(m15_atr_v) and m15_atr_v > 0:
                if abs(price - z_px) > 1.5 * m15_atr_v:
                    skipped['chasing'] += 1
                    if debug_rows is not None:
                        debug_rows.append({
                            'ts': ts_pd,
                            'price': price,
                            'event': 'zone_skip',
                            'reason': 'chasing',
                            'zone_ts': z_ts,
                            'zone_px': z_px,
                            'zone_dir': z_dir,
                            'zone_dist': z_dist,
                            'm15_atr': m15_atr_v,
                        })
                    continue

            # ── BOUNCE-ONLY FILTER: price approaching from opposite side ────
            # For a long zone (demand), price must be coming from above (bounce into support)
            # For a short zone (supply), price must be coming from below (bounce into resistance)
            if z_dir == 'long' and price < z_px * (1 - conf_tol):
                skipped['not_bounce'] += 1
                if debug_rows is not None:
                    debug_rows.append({
                    'ts': ts_pd,
                    'price': price,
                    'event': 'zone_skip',
                    'reason': 'not_bounce',
                    'zone_ts': z_ts,
                    'zone_px': z_px,
                    'zone_dir': z_dir,
                    'zone_dist': z_dist,
                    })
                continue  # price already broke below — not a bounce
            if z_dir == 'short' and price > z_px * (1 + conf_tol):
                skipped['not_bounce'] += 1
                if debug_rows is not None:
                    debug_rows.append({
                    'ts': ts_pd,
                    'price': price,
                    'event': 'zone_skip',
                    'reason': 'not_bounce',
                    'zone_ts': z_ts,
                    'zone_px': z_px,
                    'zone_dir': z_dir,
                    'zone_dist': z_dist,
                    })
                continue  # price already broke above — not a bounce

            # ── p2 FILTER 1: Session gate ────
            session_mult = get_session_size_mult(ts_pd, inst_cfg)
            if ts_pd.dayofweek < 5 and ts_pd.hour in HIGH_PEAK_HOURS_UTC:
                session_mult *= HIGH_PEAK_SESSION_BOOST
            if session_mult == 0.0:
                skipped['session'] += 1
                if debug_rows is not None:
                    debug_rows.append({
                    'ts': ts_pd,
                    'price': price,
                    'event': 'zone_skip',
                    'reason': 'session',
                    'zone_ts': z_ts,
                    'zone_px': z_px,
                    'zone_dir': z_dir,
                    'zone_dist': z_dist,
                    'session_mult': session_mult,
                    })
                continue

            # ── p2 FILTER 2: Zone confirmation delay ────
            if not zone_is_confirmed(ts_pd, z_ts, inst_cfg):
                skipped['confirm'] += 1
                if debug_rows is not None:
                    debug_rows.append({
                    'ts': ts_pd,
                    'price': price,
                    'event': 'zone_skip',
                    'reason': 'confirm',
                    'zone_ts': z_ts,
                    'zone_px': z_px,
                    'zone_dir': z_dir,
                    'zone_dist': z_dist,
                    })
                continue

            # ── p2 FILTER 3: Cluster cap ────
            if not cluster.can_enter(ts_pd):
                skipped['cluster'] += 1
                if debug_rows is not None:
                    debug_rows.append({
                    'ts': ts_pd,
                    'price': price,
                    'event': 'zone_skip',
                    'reason': 'cluster',
                    'zone_ts': z_ts,
                    'zone_px': z_px,
                    'zone_dir': z_dir,
                    'zone_dist': z_dist,
                    })
                continue

            # ── p2 FILTER 4: Trend regime ────
            regime = get_regime(daily_idx, daily_regime, ts)
            regime_mult = get_regime_size_mult(regime, z_dir)
            counter_trend = regime_mult < 1.0

            # ── NEW: ADX-gated trend state (replaces dual-SMA bias soft gate) ──
            wk_dir = _tf_dir(
                fast_val(wk_idx, wk_c, ts), fast_val(wk_idx, wk_ma21, ts),
                fast_val(wk_idx, wk_ma50, ts), fast_val(wk_idx, wk_ma200, ts),
                fast_val(wk_idx, wk_slope, ts))
            dl_dir = _tf_dir(
                fast_val(daily_idx, dl_c, ts), fast_val(daily_idx, dl_ma21, ts),
                fast_val(daily_idx, dl_ma50, ts), fast_val(daily_idx, dl_ma200, ts),
                fast_val(daily_idx, dl_slope, ts))
            h4_dir = _tf_dir(
                fast_val(h4_idx, h4_c, ts), fast_val(h4_idx, h4_ma21, ts),
                fast_val(h4_idx, h4_ma50, ts), fast_val(h4_idx, h4_ma200, ts),
                fast_val(h4_idx, h4_slope, ts))
            adx_gate_v = fast_val(h4_idx, h4_adx, ts)
            vww_v = fast_val(h4_idx, h4_vww, ts)
            vwm_v = fast_val(h4_idx, h4_vwm, ts)
            bias_adj, hard_skip, with_trend = compute_trend_state(
                z_dir, price, adx_gate_v, wk_dir, dl_dir, h4_dir,
                vww_v, vwm_v, counter_trend)

            # Hard skip: ADX-confirmed counter-trend with all timeframes against.
            # Instead of skipping, cap to minimum confidence + force no stacking.
            if hard_skip:
                skipped['trend'] += 1
                bias_adj = DEFAULTS['confidence_min']   # overwrite bias to min-size
                with_trend = False                       # single entry only
                if debug_rows is not None:
                    debug_rows.append({
                        'ts': ts_pd, 'price': price, 'event': 'zone_cap',
                        'reason': 'trend_hard_skip_min_size', 'zone_ts': z_ts,
                        'zone_px': z_px, 'zone_dir': z_dir, 'zone_dist': z_dist,
                        'adx': adx_gate_v,
                    })
                # do NOT continue - trade proceeds at minimum size

            # ── Multi-timeframe score ────
            h4_score = score_tf(h4_idx, h4_c, h4_e20, h4_e50, h4_rsi, ts, z_dir)
            h1_score = score_tf(h1_idx, h1_c, h1_e20, h1_e50, h1_rsi, ts, z_dir)

            if cfg['entry_tf'] == 'm1':
                ltf_score = score_tf(m1_idx, m1_c, m1_e20, m1_e50, m1_rsi, ts, z_dir)
            else:
                ltf_score = score_tf(m5_idx, m5_c, m5_e20, m5_e50, m5_rsi, ts, z_dir)

            if h4_score < h4_min:
                skipped['score'] += 1
                if debug_rows is not None:
                    debug_rows.append({
                    'ts': ts_pd,
                    'price': price,
                    'event': 'zone_skip',
                    'reason': 'score_h4',
                    'zone_ts': z_ts,
                    'zone_px': z_px,
                    'zone_dir': z_dir,
                    'zone_dist': z_dist,
                    'h4_score': h4_score,
                    'h1_score': h1_score,
                    'ltf_score': ltf_score,
                    })
                continue
            if h1_score < h1_min:
                skipped['score'] += 1
                if debug_rows is not None:
                    debug_rows.append({
                    'ts': ts_pd,
                    'price': price,
                    'event': 'zone_skip',
                    'reason': 'score_h1',
                    'zone_ts': z_ts,
                    'zone_px': z_px,
                    'zone_dir': z_dir,
                    'zone_dist': z_dist,
                    'h4_score': h4_score,
                    'h1_score': h1_score,
                    'ltf_score': ltf_score,
                    })
                continue
            if ltf_score < ltf_min:
                skipped['score'] += 1
                if debug_rows is not None:
                    debug_rows.append({
                    'ts': ts_pd,
                    'price': price,
                    'event': 'zone_skip',
                    'reason': 'score_ltf',
                    'zone_ts': z_ts,
                    'zone_px': z_px,
                    'zone_dir': z_dir,
                    'zone_dist': z_dist,
                    'h4_score': h4_score,
                    'h1_score': h1_score,
                    'ltf_score': ltf_score,
                    })
                continue

            total_score = h4_score + h1_score + ltf_score
            dir_score_offset = inst_cfg.get('dir_score_offset', {})
            effective_score_min = score_min + int(dir_score_offset.get(z_dir, 0))
            if total_score < effective_score_min:
                skipped['score'] += 1
                if debug_rows is not None:
                    debug_rows.append({
                    'ts': ts_pd,
                    'price': price,
                    'event': 'zone_skip',
                    'reason': 'score_total',
                    'zone_ts': z_ts,
                    'zone_px': z_px,
                    'zone_dir': z_dir,
                    'zone_dist': z_dist,
                    'total_score': total_score,
                    'effective_score_min': effective_score_min,
                    })
                continue
            if ltf_score > ltf_cap:
                skipped['score'] += 1
                if debug_rows is not None:
                    debug_rows.append({
                    'ts': ts_pd,
                    'price': price,
                    'event': 'zone_skip',
                    'reason': 'score_cap',
                    'zone_ts': z_ts,
                    'zone_px': z_px,
                    'zone_dir': z_dir,
                    'zone_dist': z_dist,
                    'ltf_score': ltf_score,
                    'ltf_cap': ltf_cap,
                    })
                continue

            # Volume filter (Scenario A only)
            if vol_filter:
                if cfg['entry_tf'] == 'm1':
                    # Align M1 entry timestamp to the latest available M5 bar.
                    i_m5 = np.searchsorted(m5_idx, ts, side='right') - 1
                    vol_ok = (
                    i_m5 >= 0
                    and i_m5 < len(m5_vol)
                    and i_m5 < len(m5_vol_ma)
                    and m5_vol[i_m5] > m5_vol_ma[i_m5]
                    )
                else:
                    i_ltf = np.searchsorted(m5_idx, ts, side='right') - 1
                    vol_ok = (i_ltf >= 0 and
                    m5_vol[i_ltf] > m5_vol_ma[i_ltf])
                if not vol_ok:
                    skipped['vol'] += 1
                    if debug_rows is not None:
                        debug_rows.append({
                            'ts': ts_pd,
                            'price': price,
                            'event': 'zone_skip',
                            'reason': 'vol',
                            'zone_ts': z_ts,
                            'zone_px': z_px,
                            'zone_dir': z_dir,
                            'zone_dist': z_dist,
                        })
                    continue

            # ── p2 CONFIDENCE SCORING ────
            # Phase 2 supports configurable confidence modes.
            cluster_count = cluster.count_in_window(ts_pd)
            in_peak_session = (
                inst_cfg['session_start'] <= ts_pd.hour < inst_cfg['session_end']
                and ts_pd.dayofweek < 5
            )
            confidence_mode = DEFAULTS.get('confidence_mode', 'flat')
            confidence_score_min = int(DEFAULTS.get('confidence_score_min', 7))

            if confidence_mode == 'flat':
                conf_mult = 1.0
            elif confidence_mode == 'inverted':
                # Inverted confidence tiers:
                # first cluster touch = high-confidence premium,
                # later touches = medium-confidence premium.
                conf_mult = (
                    DEFAULTS['confidence_mult']
                    if cluster_count == 0
                    else DEFAULTS.get('confidence_medium_mult', 1.0)
                )
            elif confidence_mode == 'score':
                conf_mult = (
                    DEFAULTS['confidence_mult']
                    if (in_peak_session and total_score >= confidence_score_min)
                    else 1.0
                )
            else:
                conf_mult = 1.0
            # Apply the trend-state confidence multiplier.
            conf_mult = conf_mult * bias_adj

            # Tiered risk: do not compound on low-confidence trades.
            if conf_mult < 0.6:
                conf_mult = min(conf_mult, 1.0)

            # Volatility throttle: if H4 ATR is elevated relative to its recent
            # mean, reduce only the boosted portion above 1.0.
            if DEFAULTS.get('vol_throttle_enabled', True) and conf_mult > 1.0:
                atr_ma_v = fast_val(h4_idx, h4_atr_ma_arr, ts)
                atr_ratio = 1.0
                if not np.isnan(atr_h4_v) and not np.isnan(atr_ma_v) and atr_ma_v > 0:
                    atr_ratio = atr_h4_v / atr_ma_v
                ratio_start = float(DEFAULTS.get('vol_throttle_ratio_start', 1.2))
                ratio_end = max(ratio_start + 1e-9, float(DEFAULTS.get('vol_throttle_ratio_end', 1.8)))
                base_min_factor = max(0.0, min(1.0, float(DEFAULTS.get('vol_throttle_min_factor', 0.65))))
                # Scale throttle aggressiveness with confidence: higher conf = more throttle
                conf_range = max(1e-9, float(DEFAULTS['confidence_max']) - 1.0)
                conf_throttle_scale = min(1.0, max(0.0, (conf_mult - 1.0) / conf_range))
                min_factor = base_min_factor * (1.0 - 0.3 * conf_throttle_scale)
                if atr_ratio > ratio_start:
                    if atr_ratio >= ratio_end:
                        boost_factor = min_factor
                    else:
                        t = (atr_ratio - ratio_start) / (ratio_end - ratio_start)
                        boost_factor = 1.0 - t * (1.0 - min_factor)
                    conf_mult = 1.0 + (conf_mult - 1.0) * boost_factor

            # Final confidence clamp.
            conf_cap = float(DEFAULTS.get('confidence_max', 2.0))
            conf_mult = max(DEFAULTS['confidence_min'], min(conf_cap, conf_mult))

            # Staggered early-stage confidence cap.
            net_profit_now = equity_now - start_cap
            if net_profit_now < 10_000:
                conf_mult = min(conf_mult, float(DEFAULTS.get('confidence_medium_mult', 1.6)))
            elif net_profit_now < 30_000:
                conf_mult = min(conf_mult, 2.5)

            # ── Confidence-gated stacking ────
            n_open_same_dir = sum(1 for p in positions if p['dir'] == z_dir)
            regime_aligned = (regime_mult >= 1.0)

            # CASH build: stacking is governed SOLELY by trend alignment
            # (with_trend) and confidence — no FTMO drawdown-tier override.
            if with_trend and conf_mult >= DEFAULTS.get('high_conf_stack_threshold', 1.5):
                stack_limit = 3               # with-trend + high confidence
            elif with_trend:
                stack_limit = 2               # with-trend, normal confidence
            elif regime_aligned and conf_mult >= DEFAULTS.get('high_conf_stack_threshold', 1.5):
                # Soft tier: allow one additional stack when regime aligns and
                # confidence is high, even if strict with_trend is false.
                stack_limit = 2
            else:
                stack_limit = 1               # not with-trend / trendless: no stacking

            if n_open_same_dir >= stack_limit or len(positions) >= max_concurrent:
                skipped['concurrent'] += 1
                continue

            # ── Position sizing — CASH: equity-COMPOUNDING base + TIERED risk (C1) ──
            # The risk base is live equity (compounds as the account grows), and
            # risk-per-trade % steps down by equity multiple via tiered_risk_pct().
            cash_risk_pct = tiered_risk_pct(equity_now, start_cap)
            notional_base = min(equity_now, NOTIONAL_CAP)
            stop_dist  = atr_stop * atr_h4_v
            remaining_daily = max(0.0, equity_now - daily_floor)
            remaining_total = max(0.0, equity_now - total_floor)
            base_risk  = notional_base * cash_risk_pct
            risk_amt   = min(base_risk, remaining_daily, remaining_total)
            if risk_amt <= 0.0:
                skipped['cash'] += 1
                if debug_rows is not None:
                    debug_rows.append({
                    'ts': ts_pd,
                    'price': price,
                    'event': 'zone_skip',
                    'reason': 'cash',
                    'zone_ts': z_ts,
                    'zone_px': z_px,
                    'zone_dir': z_dir,
                    'zone_dist': z_dist,
                    })
                continue
            stop_px    = price - stop_dist if z_dir == 'long' else price + stop_dist
            tp_px      = (price + tp_mult * stop_dist if z_dir == 'long'
                    else price - tp_mult * stop_dist)

            entry_exec = apply_execution_adjustment(
                price, z_dir, 'entry', spread_bps, slippage_bps
            )
            initial_risk_price = abs(entry_exec - stop_px)
            if initial_risk_price <= 0:
                initial_risk_price = stop_dist if stop_dist > 0 else 1e-9

            # Apply all size multipliers
            size_mult = session_mult * regime_mult * conf_mult
            qty = (risk_amt / initial_risk_price) * size_mult if initial_risk_price > 0 else 0

            # C4: CASH leverage cap — max notional <= equity * cash_max_leverage (1:200)
            max_notional = max(0.0, equity_now * cash['cash_max_leverage'])
            if entry_exec > 0 and max_notional > 0:
                qty = min(qty, max_notional / entry_exec)
            # C3: per-order lot cap = daily-base lots x lot_cap_mult (10).
            # daily-base lots = (start_cap * Tier-1 risk%) / loss-per-unit.
            tier1_pct = CASH_CONFIG['risk_tiers'][0][1] / 100.0
            daily_base_qty = (start_cap * tier1_pct) / initial_risk_price if initial_risk_price > 0 else 0.0
            cash_lot_cap = daily_base_qty * cash['lot_cap_mult']
            if cash_lot_cap > 0:
                qty = min(qty, cash_lot_cap)
            qty = min(qty, MAX_LOT_CAP)

            if qty <= 0:
                if debug_rows is not None:
                    debug_rows.append({
                    'ts': ts_pd,
                    'price': price,
                    'event': 'zone_skip',
                    'reason': 'qty',
                    'zone_ts': z_ts,
                    'zone_px': z_px,
                    'zone_dir': z_dir,
                    'zone_dist': z_dist,
                    })
                continue

            # Register entry
            cluster.register(ts_pd)
            last_entry = ts_pd

            positions.append({
                'id'                : _next_signal_id(ts_pd),
                'last_emitted_stop' : stop_px,
                'entry_ts'          : ts_pd,
                'entry_bar'         : bar_i,
                'dir'               : z_dir,
                'entry'             : entry_exec,
                'entry_signal'      : price,
                'stop'              : stop_px,
                'stop_initial'      : stop_px,
                'tp'                : tp_px,
                'initial_risk_price': initial_risk_price,
                'qty'               : qty,
                'be_triggered'      : False,
                'confidence_mult'   : conf_mult,
                'regime'            : regime,
                'atr_e'             : atr_h4_v,  # Store H4 ATR at entry for trailing stop
            })

            # Dynamic stack_max based on confidence tier (read by EA for per-signal stacking)
            if conf_mult >= 4.0 and with_trend:
                _stack_max = 4
            elif conf_mult >= 2.0 and with_trend:
                _stack_max = 3
            elif with_trend:
                _stack_max = 2
            elif regime_aligned and conf_mult >= DEFAULTS.get('high_conf_stack_threshold', 1.5):
                # Soft tier mirrors stack_limit so bridge enforcement and
                # internal concurrency checks are consistent.
                _stack_max = 2
            else:
                _stack_max = 1  # counter-trend or trendless: single only

            # Emit a JSON signal for MT5 to consume (newline-delimited JSON)
            emit_event({
                'action': 'open',
                'id': positions[-1]['id'],
                'entry_ts': ts_pd,
                'dir': z_dir,
                'entry': float(entry_exec),
                'stop': float(stop_px),
                'tp': float(tp_px),
                'qty': float(qty),
                'regime': regime,
                'conf': float(conf_mult),
                'atr_entry': float(atr_h4_v),
                'signal_account_size': float(capital),
                'stack_max': int(_stack_max),
            })

            if debug_rows is not None:
                debug_rows.append({
                    'ts': ts_pd,
                    'price': price,
                    'event': 'enter',
                    'reason': 'entry',
                    'zone_ts': z_ts,
                    'zone_px': z_px,
                    'zone_dir': z_dir,
                    'zone_dist': z_dist,
                    'session_mult': session_mult,
                    'regime': regime,
                    'regime_mult': regime_mult,
                    'h4_score': h4_score,
                    'h1_score': h1_score,
                    'ltf_score': ltf_score,
                    'total_score': total_score,
                    'confidence_mult': conf_mult,
                    'risk_amt': risk_amt,
                    'qty': qty,
                    'entry_exec': entry_exec,
                })

            # Only take one zone per bar
            break

    # ── close any remaining open positions at last bar ────
    for p in positions:
        exit_signal_px = c_c[-1]
        exit_px = apply_execution_adjustment(
            exit_signal_px, p['dir'], 'exit', spread_bps, slippage_bps
        )
        gross_pnl = (
            (exit_px - p['entry']) * p['qty']
            if p['dir'] == 'long'
            else (p['entry'] - exit_px) * p['qty']
        )
        fees  = commission_per_trade
        pnl   = gross_pnl - fees
        capital += pnl
        risk_cash = max(1e-9, p['initial_risk_price'] * p['qty'])
        r_value   = pnl / risk_cash
        results.append({
            'entry_ts'           : p['entry_ts'],
            'exit_ts'            : pd.Timestamp(c_idx[-1]),
            'dir'                : p['dir'],
            'entry'              : p['entry'],
            'exit'               : exit_px,
            'entry_price'        : p['entry'],
            'exit_price'         : exit_px,
            'entry_signal_price' : p['entry_signal'],
            'exit_signal_price'  : exit_signal_px,
            'stop_price'         : p['stop'],
            'stop_price_initial' : p['stop_initial'],
            'stop_price_exit'    : p['stop'],
            'initial_risk_price' : p['initial_risk_price'],
            'r_value'            : r_value,
            'fees'               : fees,
            'pnl'                : pnl,
            'win'                : pnl > 0,
            'exit_reason'        : 'eod',
            'qty'                : p['qty'],
            'be_triggered'       : p.get('be_triggered', False),
            'confidence_mult'    : p.get('confidence_mult', 1.0),
            'regime'             : p.get('regime', 'unknown'),
        })
        if EMIT_EOD_CLOSE_SIGNALS:
            emit_event({'action': 'close', 'id': p['id'], 'exit': float(exit_px), 'reason': 'eod'})

    df_r = pd.DataFrame(results)
    _print_summary(
        df_r,
        label,
        capital,
        skipped,
        start_cap=start_cap,
    )
    if debug_rows is not None and debug_path:
        debug_df = pd.DataFrame(debug_rows)
        debug_df.to_csv(debug_path, index=False)
    return df_r

# ════
# SIGNAL VALIDATION
# ════
def replay_and_validate(df_internal, start_capital):
    """Replay the emitted JSONL stream and compare it with the internal backtest."""
    local_path = os.path.join(os.getcwd(), 'signals', SIGNAL_FILENAME)
    if not os.path.exists(local_path):
        print('  [validator] no signal file found')
        return False

    event_counts = Counter()
    open_pos = {}
    closed = []

    with open(local_path, 'r', encoding='utf-8') as handle:
        for raw_line in handle:
            line = raw_line.strip()
            if not line:
                continue
            event = json.loads(line)
            action = event.get('action', 'unknown')
            event_counts[action] += 1

            if action == 'open':
                open_pos[event['id']] = {
                    'entry': float(event['entry']),
                    'qty': float(event['qty']),
                    'dir': event['dir'],
                }
            elif action == 'modify':
                if event['id'] in open_pos:
                    open_pos[event['id']]['stop'] = float(event['new_stop'])
            elif action == 'close':
                position = open_pos.pop(event['id'], None)
                if position is None:
                    print(f"  [validator] close for unknown id {event['id']}")
                    return False
                direction = 1 if position['dir'] == 'long' else -1
                closed.append((float(event['exit']) - position['entry']) * position['qty'] * direction)

    if open_pos:
        print(f"  [validator] {len(open_pos)} positions never closed: {list(open_pos)[:3]}")
        return False

    n_replay = len(closed)
    n_internal = len(df_internal)
    net_replay = float(sum(closed))
    if n_internal == 0:
        net_internal_gross = 0.0
    else:
        net_internal_gross = float((df_internal['pnl'] + df_internal['fees']).sum())
    delta = abs(net_replay - net_internal_gross)

    print(
        '  [validator] '
        f"meta={event_counts['meta']} heartbeat={event_counts['heartbeat']} "
        f"open={event_counts['open']} modify={event_counts['modify']} close={event_counts['close']} | "
        f"trades replay={n_replay} internal={n_internal} | "
        f"gross replay=${net_replay:,.2f} internal=${net_internal_gross:,.2f} delta=${delta:,.4f}"
    )

    return (
        event_counts['open'] == n_internal
        and event_counts['close'] == n_internal
        and n_replay == n_internal
        and delta <= 0.01
    )

# ════
# REPORTING
# ════
def _print_summary(df_r: pd.DataFrame, label: str, final_cap: float,
                   skipped: dict, start_cap: float = 5_000,
                   target_hit_ts=None, target_hit_equity=None,
                   target_equity: float = None):
    if df_r is None or len(df_r) == 0:
        print(f"\n{label}: 0 trades"); return

    entry_times = pd.to_datetime(df_r['entry_ts'])
    exit_times = pd.to_datetime(df_r['exit_ts'])
    test_start = entry_times.min()
    test_end = exit_times.max()

    trades = len(df_r)
    wr     = df_r['win'].mean() * 100
    gw     = df_r[df_r['win']]['pnl'].sum()
    gl     = df_r[~df_r['win']]['pnl'].sum()
    pf     = abs(gw / gl) if gl != 0 else float('inf')
    net    = df_r['pnl'].sum()
    ret    = net / start_cap * 100
    eq     = start_cap + df_r['pnl'].cumsum()
    peak   = eq.cummax()
    dd     = ((eq - peak) / peak).min() * 100
    exp    = df_r['pnl'].mean()
    t_pct  = (df_r['exit_reason'] == 'timeout').mean() * 100
    be_pct = df_r.get('be_triggered', pd.Series([False]*trades)).mean() * 100

    # Weekly trade count
    df_r['_week'] = pd.to_datetime(df_r['entry_ts']).dt.to_period('W')
    weeks = df_r['_week'].nunique()
    tpw   = trades / weeks if weeks > 0 else 0

    pf_flag  = '✅' if pf  >= 1.5  else ('⚠️' if pf >= 1.2 else '❌')
    dd_flag  = '✅' if dd  >= -8   else '❌'
    wr_flag  = '✅' if wr  >= 50   else ('⚠️' if wr >= 45 else '❌')
    ret_flag = '✅' if ret > 0     else '❌'

    print(f"\n{'='*56}")
    print(f"  {label}")
    print(f"{'='*56}")
    print(f"  Trades      : {trades}  ({tpw:.1f}/week)")
    print(f"  Win %       : {wr:.1f}%   {wr_flag}")
    print(f"  PF          : {pf:.3f}  {pf_flag}")
    print(f"  Net Return  : {ret:.2f}%  {ret_flag}")
    print(f"  Max DD      : {dd:.2f}%  {dd_flag}")
    print(f"  Expectancy  : ${exp:.2f}/trade")
    print(f"  Final Cap   : ${final_cap:,.2f}")
    print(f"  Test Span   : {test_start} → {test_end} ({test_end - test_start})")
    if target_equity is not None:
        if target_hit_ts is not None:
            elapsed = pd.Timestamp(target_hit_ts) - pd.Timestamp(df_r['entry_ts'].min())
            days = elapsed.days
            hours = elapsed.components.hours
            print(f"  10% Target  : hit at {target_hit_ts} ({days}d {hours}h) | equity ${target_hit_equity:,.2f}")
        else:
            print(f"  10% Target  : not reached | target equity ${target_equity:,.2f}")

    monthly = (
        df_r.assign(month=exit_times.dt.to_period('M').dt.to_timestamp('M'))
           .groupby('month', as_index=False)['pnl']
           .sum()
           .sort_values('month')
    )
    monthly['cumulative'] = monthly['pnl'].cumsum()
    print("  Monthly PnL / Cumulative:")
    for _, row in monthly.iterrows():
        month_label = pd.Timestamp(row['month']).date()
        print(f"    {month_label}: pnl ${row['pnl']:,.2f} | cum ${row['cumulative']:,.2f}")

    print(f"  Breakeven % : {be_pct:.1f}%")
    print(f"  Timeout %   : {t_pct:.1f}%")
    print(f"  Skipped     : {skipped}")

# ════
# MAIN
# ════
def main():
    parser = argparse.ArgumentParser(description=f'Phantom {ENGINE_VERSION} Backtest')
    parser.add_argument('--instrument',  required=True,
                    choices=['XAU', 'US100', 'BTC'],
                    help='Instrument: XAU | US100 | BTC')
    parser.add_argument('--m1',          required=True,  help='Path to M1 CSV')
    parser.add_argument('--m5',          required=True,  help='Path to M5 CSV')
    parser.add_argument('--h1',          required=True,  help='Path to H1 CSV')
    parser.add_argument('--h4',          required=True,  help='Path to H4 CSV')
    parser.add_argument('--daily',       required=True,  help='Path to Daily CSV (for regime filter)')
    parser.add_argument('--weekly',      required=True,  help='Path to Weekly CSV (for 20-week MA bias)')
    parser.add_argument('--m15',         required=True,  help='Path to M15 CSV (for not-chasing filter)')
    parser.add_argument('--capital',     type=float, default=10_000)
    parser.add_argument('--output-dir',  default='.',
                    help='Directory to save trade CSV outputs')
    parser.add_argument('--spread-bps',  type=float, default=0.0,
                    help='Round-trip spread in bps')
    parser.add_argument('--slippage-bps',type=float, default=0.0,
                    help='Adverse slippage per side in bps')
    parser.add_argument('--commission-per-trade', type=float, default=0.0,
                    help='Fixed commission per closed trade')
    parser.add_argument('--start-date', default=None,
                    help='Optional start date filter (YYYY-MM-DD) applied to all timeframes')
    parser.add_argument('--end-date', default=None,
                    help='Optional end date filter (YYYY-MM-DD) applied to all timeframes')
    parser.add_argument('--debug', action='store_true',
                    help='Write debug decision CSV for entries/skips')
    parser.add_argument('--debug-file', default=None,
                    help='Optional debug CSV path (defaults to output-dir)')
    parser.add_argument('--signal-filename', default=None,
                    help='Non-generic signal filename (basename). Default auto-links engine/instrument/date-range.')
    parser.add_argument('--write-generic-signal-alias', action='store_true',
                    help='Also write phantom_signals.jsonl alias for legacy MT5 setups')
    # CASH build: equity-compounding, tiered risk. No FTMO challenge / profit-target flags.
    parser.add_argument('--cash-max-leverage', type=float, default=200.0,
                    help='C4: CASH leverage cap (default 1:200)')
    parser.add_argument('--cash-trail-max-loss-pct', type=float, default=15.0,
                    help='C2: max-loss floor trails this %% below the rolling equity peak')
    parser.add_argument('--cash-lot-cap-mult', type=float, default=10.0,
                    help='C3: per-order lot cap = daily-base lots x this multiplier')
    parser.add_argument('--cash-soft-stop-ratio', type=float, default=0.8,
                    help='Circuit breaker: pause entries at this fraction (80%%) of the daily loss amount')
    parser.add_argument('--cash-manual-resume-file', default='tmp/cash_resume.flag',
                    help='Presence of this file resumes trading after total-loss soft stop')
    parser.add_argument('--cash-daily-resume-file', default='tmp/cash_daily_resume.flag',
                    help='Presence of this file resumes trading after daily soft stop')
    parser.add_argument('--cash-master-control-file', default='',
                    help='Master pause/resume control file with first token PAUSE or RESUME')
    parser.add_argument('--cash-hard-close', dest='cash_hard_close', action='store_true',
                    help='Force-close all open positions immediately when a hard CASH stop triggers')
    parser.add_argument('--no-cash-hard-close', dest='cash_hard_close', action='store_false',
                    help='Disable forced close on hard CASH stop (testing only)')
    parser.add_argument('--cash-hard-stop-pause-days', type=int, default=0,
                    help='Temporarily pause this many days after non-daily hard stops, then auto-resume')
    parser.set_defaults(cash_hard_close=True)
    args = parser.parse_args()

    output_dir = args.output_dir or '.'
    os.makedirs(output_dir, exist_ok=True)

    inst_cfg = INSTRUMENT_CONFIG[args.instrument]

    signal_name = _configure_signal_filename(args)

    # CASH guardrails (FTMO challenge logic stripped — no profit target / min days).
    CASH_CONFIG['soft_stop_ratio'] = max(0.0, min(float(args.cash_soft_stop_ratio), 1.0))
    CASH_CONFIG['manual_resume_file'] = str(args.cash_manual_resume_file)
    CASH_CONFIG['daily_resume_file'] = str(args.cash_daily_resume_file)
    CASH_CONFIG['master_control_file'] = str(args.cash_master_control_file)
    CASH_CONFIG['hard_close_on_trigger'] = bool(args.cash_hard_close)
    CASH_CONFIG['hard_stop_pause_days'] = max(0, int(args.cash_hard_stop_pause_days))
    CASH_CONFIG['cash_max_leverage'] = max(1.0, float(args.cash_max_leverage))     # C4
    CASH_CONFIG['trail_max_loss_pct'] = max(0.1, float(args.cash_trail_max_loss_pct))  # C2
    CASH_CONFIG['lot_cap_mult'] = max(1.0, float(args.cash_lot_cap_mult))          # C3
    reset_signal_file()
    emit_run_meta(args.capital, True, args.instrument)
    print(f"\nPhantom {ENGINE_VERSION.upper()} | Instrument: {args.instrument}")
    print(f"  Signal File: {signal_name}")
    print(
        f"  Session: {inst_cfg['session_start']:02d}:00–{inst_cfg['session_end']:02d}:00 UTC"
        f"  | TP: {inst_cfg['tp_mult']}R"
        f"  | ATR stop: {inst_cfg['atr_stop_mult']}x"
        f"  | Confirm: {inst_cfg['min_confirm_bars']} bars"
    )
    print(
        f"  CASH: Daily Loss {CASH_CONFIG['max_daily_loss_pct']:.1f}% | "
        f"Trailing Max Loss {CASH_CONFIG['trail_max_loss_pct']:.1f}% off peak | "
        f"Leverage 1:{int(CASH_CONFIG['cash_max_leverage'])} | "
        f"Lot Cap x{CASH_CONFIG['lot_cap_mult']:.0f} | "
        f"Circuit Breaker {CASH_CONFIG['soft_stop_ratio']*100:.0f}% | "
        f"Hard Close {'ON' if CASH_CONFIG['hard_close_on_trigger'] else 'OFF'}"
    )

    print("\nLoading data...")
    m1    = apply_start_date(add_indicators(load_csv(args.m1)), args.start_date, args.end_date)
    m5    = apply_start_date(add_indicators(load_csv(args.m5)), args.start_date, args.end_date)
    h1    = apply_start_date(add_indicators(load_csv(args.h1)), args.start_date, args.end_date)
    h4    = apply_start_date(add_indicators(load_csv(args.h4)), args.start_date, args.end_date)
    m15   = apply_start_date(add_indicators(load_csv(args.m15)), args.start_date, args.end_date)
    daily = apply_start_date(add_indicators(load_csv(args.daily)), args.start_date, args.end_date)
    weekly = apply_start_date(load_csv(args.weekly), args.start_date, args.end_date)
    # NEW shared trend layers (ADX + ma21/50/200 structure + anchored VWAP) on W/D/H4.
    weekly = add_trend_layers(weekly)
    daily = add_daily_regime(daily, inst_cfg)
    daily = add_trend_layers(daily)
    h4 = add_trend_layers(h4)
    print(f"  M1:{len(m1)}  M5:{len(m5)}  M15:{len(m15)}  H1:{len(h1)}  H4:{len(h4)}  Daily:{len(daily)}")

    if TZ_GUARD_ENABLED:
        pre = evaluate_tz_alignment_from_signals(m5)
        enforce_tz_guard(pre, stage='pre-run', enforce=False)

    print("\nBuilding H4 pivot zones...")
    zone_ts, zone_px, zone_dir = build_h4_zones(
        h4,
        pivot_bars=DEFAULTS['h4_pivot_bars'],
        lookback=DEFAULTS['h4_lookback'],
    )
    print(f"  {len(zone_ts)} zones found")

    # Regime arrays
    daily_idx    = daily.index.values
    daily_regime = daily['regime'].values
    # NEW: weekly / daily trend-layer arrays (structure + anchored VWAP + ADX)
    wk_idx    = weekly.index.values
    wk_c      = weekly['close'].values
    wk_ma21   = weekly['ma21'].values
    wk_ma50   = weekly['ma50'].values
    wk_ma200  = weekly['ma200'].values
    wk_slope  = weekly['ma50_slope'].values
    wk_vww    = weekly['vwap_w'].values
    wk_vwm    = weekly['vwap_m'].values
    wk_adx    = weekly['adx'].values
    dl_c      = daily['close'].values
    dl_ma21   = daily['ma21'].values
    dl_ma50   = daily['ma50'].values
    dl_ma200  = daily['ma200'].values
    dl_slope  = daily['ma50_slope'].values
    dl_vww    = daily['vwap_w'].values
    dl_vwm    = daily['vwap_m'].values
    dl_adx    = daily['adx'].values

    # Cache numpy arrays
    arrays = dict(
        h4_idx=h4.index.values,   h4_c=h4['close'].values,
        h4_e20=h4['ema20'].values, h4_e50=h4['ema50'].values,
        h4_rsi=h4['rsi'].values,   h4_atr_arr=h4['atr'].values,
        h4_atr_ma_arr=h4['atr'].rolling(
            window=max(2, int(DEFAULTS.get('vol_throttle_lookback', 96))),
            min_periods=2,
        ).mean().values,
        h4_ma21=h4['ma21'].values, h4_ma50=h4['ma50'].values,
        h4_ma200=h4['ma200'].values, h4_slope=h4['ma50_slope'].values,
        h4_vww=h4['vwap_w'].values, h4_vwm=h4['vwap_m'].values,
        h4_adx=h4['adx'].values,
        h1_idx=h1.index.values,   h1_c=h1['close'].values,
        h1_e20=h1['ema20'].values, h1_e50=h1['ema50'].values,
        h1_rsi=h1['rsi'].values,
        m15_idx=m15.index.values,  m15_atr_arr=m15['atr'].values,
        m5_idx=m5.index.values,   m5_c=m5['close'].values,
        m5_e20=m5['ema20'].values, m5_e50=m5['ema50'].values,
        m5_rsi=m5['rsi'].values,
        m5_vol=m5['tickvol'].values, m5_vol_ma=m5['vol_ma'].values,
        m1_idx=m1.index.values,   m1_c=m1['close'].values,
        m1_e20=m1['ema20'].values, m1_e50=m1['ema50'].values,
        m1_rsi=m1['rsi'].values,
    )

    cfg = ACTIVE_SCENARIO_CFG
    sc_id = ACTIVE_SCENARIO_ID
    candles = m1 if cfg['entry_tf'] == 'm1' else m5
    debug_path = None
    if args.debug:
        debug_path = args.debug_file or os.path.join(
            output_dir,
            f'phantom_{ENGINE_VERSION}_debug_{args.instrument}_{sc_id}.csv'
        )
    # Show which timeframe is used for entries and the actual candle ranges
    print(f"\n  Entry TF: {cfg['entry_tf'].upper()} | Candles Range: {candles.index[0]} → {candles.index[-1]}")
    # Also print M1 range to highlight any mismatch between M1 and the entry timeframe
    print(f"  M1 Range: {m1.index[0]} → {m1.index[-1]}")
    print(f"\nRunning Scenario {sc_id}...")
    df_r = run_scenario(
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
        max_concurrent=DEFAULTS['max_concurrent'],
        cooldown_min=DEFAULTS['cooldown_min'],
        lockout_min=DEFAULTS['lockout_min'],
        conf_tol=DEFAULTS['conf_tol'],
        spread_bps=args.spread_bps,
        slippage_bps=args.slippage_bps,
        commission_per_trade=args.commission_per_trade,
        zone_lookback_bars=DEFAULTS['h4_lookback'],
        label=(f"Scenario {sc_id} | {args.instrument} | "
             f"{cfg['entry_tf'].upper()} entry | risk=tiered {CASH_CONFIG['risk_tiers'][0][1]:.2f}%→{CASH_CONFIG['risk_tier_top_pct']:.2f}% (compounding)"),
        debug=args.debug,
        debug_path=debug_path,
        **arrays,
    )
    flush_signals()

    if TZ_GUARD_ENABLED:
        post = evaluate_tz_alignment_from_signals(m5)
        enforce_tz_guard(post, stage='post-run', enforce=True)

    if EMIT_SIGNALS and df_r is not None:
        ok = replay_and_validate(df_r, args.capital)
        print('✅ REPLAY MATCHES INTERNAL BACKTEST' if ok else '❌ REPLAY MISMATCH - DO NOT PROCEED TO MQL5')
        print(f"  Signals saved → {os.path.join(os.getcwd(), 'signals', SIGNAL_FILENAME)}")
        if WRITE_GENERIC_SIGNAL_ALIAS:
            print(f"  Generic alias → {os.path.join(os.getcwd(), 'signals', GENERIC_SIGNAL_ALIAS)}")
    if df_r is not None and len(df_r):
        out = os.path.join(output_dir, f'phantom_{ENGINE_VERSION}_trades_{args.instrument}_{sc_id}.csv')
        df_r.to_csv(out, index=False)
        print(f"  Trades saved → {out}")
        if debug_path:
            print(f"  Debug saved  → {debug_path}")

    print("\nDone.")


if __name__ == '__main__':
    main()



