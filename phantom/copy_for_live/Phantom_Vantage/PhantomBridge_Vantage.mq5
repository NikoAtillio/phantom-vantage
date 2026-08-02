//+------------------------------------------------------------------+
//|  PhantomBridge_Vantage.mq5                                       |
//|  PHANTOM VANTAGE account signal bridge                         |
//|  Copyright 2025-2026, Phantom Trading Systems                     |
//+------------------------------------------------------------------+
//|  PURPOSE                                                          |
//|    Reads newline-delimited JSON signals written by the Python     |
//|    PHANTOM VANTAGE engine (signals_vantage_live.jsonl in          |
//|    MT5 Common\Files by default) and executes them on a live/demo  |
//|    CASH account. Supports two run modes:                          |
//|      Replay  (InpReplayMode=true)  – bar-by-bar backtest replay   |
//|      Live    (InpReplayMode=false) – real-time file polling        |
//|                                                                    |
//|  SIGNAL ACTIONS HANDLED                                           |
//|    meta      – captures signal_account_size for lot scaling        |
//|    open      – opens a market position (buy or sell)               |
//|    modify    – updates stop-loss (breakeven / trailing)            |
//|    close     – closes position at market (stop, tp, or forced)     |
//|    heartbeat – file-liveness ping; no trade action taken           |
//|    pause_entries  – Python soft-pause: blocks new opens            |
//|    resume_entries – clears Python pause; can clear manual halts     |
//|    hard_stop      – flatten all + hard disable via Python           |
//|    flatten_all    – immediate flatten command from Python           |
//|                                                                    |
//|  KEY BEHAVIOURS                                                    |
//|    [CASH-1]  Forced BROKER_CASH — no broker auto-detect.           |
//|              FTMO/hybrid mode enum and DetectMode() removed.       |
//|    [CASH-2]  Tiered risk sizing from current equity.               |
//|              Risk % tapers automatically as the account grows:     |
//|              <2x -> 3.95%, <4x -> 3.10%, <7x -> 2.40%,             |
//|              <10x -> 1.85%, >=10x -> 1.40% (all configurable).     |
//|    [CASH-3]  Trailing max-loss floor from peak equity.             |
//|              If equity drops 15% below the running high-water      |
//|              mark, all positions are flattened and the EA is       |
//|              hard-paused until InpManualResume=true is set.        |
//|              Peak is saved to disk on every new equity high.       |
//|    [CASH-4]  Lot cap via InpCashLotCapMult.                        |
//|              Computed lots are capped at N × the natural           |
//|              entry-day base lots (default 10×) to prevent          |
//|              runaway sizing on a compounded account.               |
//|    [CASH-5]  Withdrawal-aware peak re-anchoring.                   |
//|              OnTradeTransaction detects BALANCE deals with a       |
//|              negative amount (withdrawals) and shifts the          |
//|              high-water mark down by that amount, keeping the      |
//|              trailing floor coherent after capital removal.        |
//|    [CASH-6]  Daily loss floor from day-start balance.              |
//|              At midnight server time the day-start balance is      |
//|              snapped.  A loss of InpDailyLossPct% (default 4.5%)  |
//|              triggers a full flatten + daily halt.  Auto-resumes   |
//|              at the next server-day rollover.                      |
//|    [CASH-7]  Circuit breaker at % of daily loss allowance.         |
//|              Soft-stop fires at InpCircuitBreakerPct% (default     |
//|              80%) of the daily limit; stops new opens but does     |
//|              not flatten.  Clears on next server day.              |
//|    [CASH-8]  FTMO-only controls removed.                           |
//|              InpFtmoRiskPct, InpFtmoMaxLeverage, InpMaxLossPct,    |
//|              profit-target gating, min-trading-days gating, and    |
//|              the BROKER_FTMO / BROKER_AUTO enum values are all     |
//|              absent from this build.                               |
//|    [CASH-9]  No profit-target or min-trading-days gating.          |
//|              The EA trades every valid signal regardless of P&L    |
//|              position; there is no "close early on profit target"  |
//|              or "must trade N days per week" constraint.           |
//|    [CASH-10] Per-login state isolation.                            |
//|              peak_equity, start_cap, and disabled_perm are         |
//|              persisted to phantom_state_<login>.json in            |
//|              Common\Files, keyed by MT5 account login number.      |
//|              Multiple accounts on the same machine do not share    |
//|              state.  State is not loaded during backtests.         |
//|    [SYNC-1]  Durable retry queues for transient failures.           |
//|              Failed opens (requote/off quotes/timeout/no conn)      |
//|              are persisted and retried from per-login JSONL files.  |
//|    [SYNC-2]  Deferred modify/close intents.                         |
//|              If modify/close arrives before mapping exists, action  |
//|              is queued and replayed after open/map reconciliation.  |
//|    [SYNC-3]  Position-map reconciliation in live mode.              |
//|              Rebuilds signal-id <-> ticket map from broker state,   |
//|              retries pending queues, and alerts on orphan mappings. |
//|    [SYNC-4]  Freshness guards in live mode.                         |
//|              Ignores stale signals by age and raises heartbeat/stale |
//|              cursor alerts if file progress stops while exposed.     |
//|                                                                    |
//|  SAFETY ADDITIONS (current)                                        |
//|    [SAFE-1]  Consecutive-loss hard stop moved to Python control.    |
//|              Bridge tracks/logs consecutive losses, but hard stop   |
//|              enforcement now comes from pause_entries/hard_stop.    |
//|    [SAFE-2]  Risk buffer cap in lot sizing.                        |
//|              risk_amt is capped to the remaining equity above      |
//|              the trailing floor; SIZE_BLOCK is logged if the       |
//|              buffer is exhausted and 0.0 lots returned.            |
//|    [SAFE-3]  Peak equity saved on every new high (not just on      |
//|              guardrail events), preventing stale floor on restart. |
//|    [SAFE-4]  Day-start balance refreshed on every server-day       |
//|              rollover, keeping withdrawal detection anchored to     |
//|              the most recent day rather than init time.            |
//|    [SAFE-5]  Replay TP close arming + fallback close.              |
//|              In replay signal-pricing mode, TP exits are armed via  |
//|              PositionModify and force-closed at expiry if needed.   |
//|    [SAFE-6]  Immediate EOD-close guard.                            |
//|              Suppresses near-instant EOD closes that arrive right   |
//|              after open and are within configurable entry tolerance.|
//|                                                                    |
//|  LOT SIZING MODES (InpUsePythonSizing)                            |
//|    false          - EA computes lots via tiered CASH model          |
//|                      using live equity, entry/stop distance,       |
//|                      tick value, and lot cap.                      |
//|    true           - trust signal qty scaled by                      |
//|                      (live_equity / signal_account_size).          |
//|    Replay + InpReplayUseSignalPricing=true - raw signal qty used    |
//|                      directly; synthetic P&L ledger computed.      |
//|                                                                    |
//|  STATE FILES (Common\Files)                                        |
//|    signals_vantage_live.jsonl       - signal input (default value)  |
//|    phantom_state_<login>.json       - peak/cap/disable + cursor     |
//|    phantom_pending_open_<login>.jsonl   - durable open retry queue  |
//|    phantom_pending_action_<login>.jsonl - queued modify/close       |
//|    phantom_bridge_log.csv           - trade + guardrail audit log   |
//+------------------------------------------------------------------+
#property strict
#property description "PHANTOM VANTAGE CASH bridge - reads signals_vantage_live.jsonl and mirrors Python signals"

#include <Trade/Trade.mqh>
CTrade trade;

//==== FORWARD DECLARATIONS ====
void   LogCSV(const string line);
void   ProcessLine(const string raw);
void   Notify(const string title, const string body);
double NormalizePrice(const double p);
double NormalizeLots(double lots);
int    FindId(const string id);
void   UnmapId(const string id);
bool   StampModelMode();
void   DetectStraddles(const datetime bar_time);
void   SaveState();
void   LoadState();
double TieredRiskPct(const double equity);  // [CASH-2]
double ComputeLotsForSignal(const string dir,const double entry,const double stop,const double qty,const double sacct);
void   HandlePauseEntries(const string js);
void   HandleResumeEntries(const string js);
void   MaybeAutoResumePythonPause();
void   HandleHardStop(const string js);
void   HandleFlattenAll(const string js);
void   HandleOpen(const string js);
void   HandleModify(const string js);
void   HandleClose(const string js);
void   PrimeLiveFilePos();
string SignalGroupFromId(const string id);
void   RebuildMapsFromOpenPositions();
void   RetryPendingOpens();
void   RetryPendingActions();
void   ReconcileBridgeState();
void   LoadPendingActionQueue();
void   SavePendingActionQueue();
void   UpsertPendingAction(const string kind, const string id, const string raw);
void   RemovePendingActionsById(const string id);
bool   IsSignalTooOldForLive(const string js, const string action, const string id);
string ExplainInvalidOpenStops(const bool is_long, const double ref_price, const double sl, const double tp, const double minDist);
string ExplainTradeRetcodeHuman(const int rc);

//==== INPUTS ====
input string  InpSignalFile          = "signals_vantage_live.jsonl"; // live file in Common\Files
input long    InpMagicNumber         = 920025;                  // unique per account/instrument
input string  InpSymbolOverride      = "US100";                // live/demo target symbol
input bool    InpReplayMode          = false;                   // true=backtest replay, false=live polling
input bool    InpReplayUseSignalPricing = false;                 // in replay, use signal qty/entry/exit for parity ledger
input bool    InpLiveSkipHistoryOnFreshAttach = true;            // live: if state file has filepos=0, start at EOF to avoid replaying old signals

// --- broker mode --- [CASH-1] Hardcoded Cash, no auto-detect
enum ENUM_BROKER_MODE { BROKER_CASH=2 };
input ENUM_BROKER_MODE InpBrokerMode = BROKER_CASH;            // FORCED: Cash mode only

// --- account baseline ---
input double  InpStartCapOverride    = 10000.0;                 // fixed risk-base anchor (initial deposit)

// --- shared guardrails ---
input double  InpDailyLossPct        = 4.5;                     // [CASH-6] daily loss limit, % off day-start balance
input double  InpCircuitBreakerPct   = 80.0;                    // [CASH-7] soft stop: 80% of daily limit amount
// [CASH-9] No profit_target or min_trading_days inputs

// --- CASH tiered risk inputs --- [CASH-2]
input double  InpTier1Mult           = 2.0;                     // < this multiple -> tier-1 risk
input double  InpTier1RiskPct        = 3.95;
input double  InpTier2Mult           = 4.0;
input double  InpTier2RiskPct        = 3.10;
input double  InpTier3Mult           = 7.0;
input double  InpTier3RiskPct        = 2.40;
input double  InpTier4Mult           = 10.0;
input double  InpTier4RiskPct        = 1.85;
input double  InpTier5RiskPct        = 1.40;                    // >= tier-4 multiple (fallback for >10x)

// --- CASH trailing max-loss floor --- [CASH-3]
input double  InpCashTrailMaxLossPct = 15.0;                    // trailing drawdown floor, % of peak equity

// --- CASH lot cap --- [CASH-4]
input double  InpCashLotCapMult      = 10.0;                    // lot cap = this x natural daily-base lots

// --- manual resume after a hard pause (trailing-floor breach) ---
input bool    InpManualResume        = false;                   // TRUE = clear hard-pause and resume

// --- lot scaling / safety ---
input double  InpMetaAccountFallback = 10000.0;                 // used only if a signal lacks signal_account_size
input double  InpMaxLots             = 50.0;                    // absolute hard safety cap
input double  InpMinLots             = 0.01;
input bool    InpUsePythonSizing     = true;                    // TRUE = trust signal qty; FALSE = EA computes tiered lots
input int     InpIgnoreInstantEodSeconds = 180;                 // ignore EOD close if it arrives within N seconds of open
input double  InpIgnoreInstantEodEntryTolPts = 15.0;            // and close price is within N points of entry/fill
input bool    InpStackLimitSameSignalOnly = true;               // enforce stack_max per signal group (entry window), not across unrelated trades

// --- notifications ---
input bool    InpNotifyPush          = true;
input bool    InpNotifyEmail         = false;
input bool    InpNotifyAlert         = true;
input int     InpReconcileIntervalSec = 60;                    // periodic live-position reconciliation interval
input int     InpOrphanAlertMinutes   = 15;                    // alert if a live ticket stays unmapped this long
input int     InpStaleCursorMinutes    = 15;                    // alert if signal file stops advancing while positions are open
input int     InpMaxSignalAgeMinutes   = 60;                    // live guard: ignore actions older than this age (0=disabled)

// --- logging ---
input bool    InpLogToCSV            = true;
input string  InpLogFile             = "phantom_bridge_log.csv";
input bool    InpEnableStraddleAudit = true;

//==== STATE ====
string   g_symbol;
int      g_digits;
double   g_point;
double   g_volstep, g_volmin, g_volmax;
int      g_stopslevel;

ulong    g_filepos     = 0;
int      g_lineidx     = 0;
bool     g_meta_seen   = false;
double   g_meta_acct   = 5000.0;
// [CASH-1] g_mode is always BROKER_CASH
ENUM_BROKER_MODE g_mode = BROKER_CASH;

// guardrail state
bool     g_halted_today   = false;
bool     g_disabled_perm  = false;
bool     g_python_paused  = false;    // Python issued pause_entries; blocks new opens
datetime g_python_pause_until = 0;    // parsed from pause_entries.resume_after
int      g_cumulative_losses = 0;
datetime g_halt_serverday = 0;
double   g_day_start_equity = 0.0;
double   g_day_start_balance = 0.0;
double   g_last_balance = 0.0;       // [CASH-5] tracks balance to detect withdrawals
datetime g_current_day    = 0;

// account baseline + peak tracking
double   g_start_cap      = 0.0;     // fixed original account size (risk/guardrail base)
double   g_peak_equity    = 0.0;     // [CASH-3] high-water mark for trailing floor
long     g_login          = 0;       // [CASH-10] per-account state isolation
string   g_state_file     = "";      // phantom_state_<login>.json
string   g_pending_open_file = "";   // durable queue for transient open failures
string   g_pending_action_file = "";  // durable queue for deferred modify/close intents

// signal_id -> position ticket map
string   g_ids[];
ulong    g_tickets[];
double   g_last_sl[];
double   g_sig_entry[];
double   g_sig_qty[];
int      g_sig_dir[];
datetime g_open_server_ts[];
double   g_open_fill[];

double   g_synth_net = 0.0;
int      g_synth_trades = 0;
int      g_synth_wins = 0;

datetime g_last_bar = 0;

// replay event store
string   g_replay_raw[];
datetime g_replay_ts[];
int      g_replay_next = 0;
bool     g_replay_loaded = false;

// pending replay TP closes
string   g_pending_ids[];
ulong    g_pending_tickets[];
double   g_pending_tp[];
double   g_pending_sl[];
int      g_pending_dir[];
datetime g_pending_expiry[];

// seen open IDs
string   g_open_once_ids[];

// Pending OPEN retries (durable across restart)
string   g_pending_open_ids[];
string   g_pending_open_raw[];
int      g_pending_open_attempts[];
datetime g_pending_open_first_ts[];
datetime g_pending_open_last_try[];

// Deferred modify while waiting for pending open execution
string   g_deferred_mod_ids[];
double   g_deferred_mod_sl[];

// Pending modify/close actions persisted across reconnects
string   g_pending_action_ids[];
string   g_pending_action_kind[];
string   g_pending_action_raw[];
int      g_pending_action_attempts[];
datetime g_pending_action_first_ts[];
datetime g_pending_action_last_try[];

datetime g_last_reconcile_check = 0;
datetime g_last_signal_progress = 0;
datetime g_unmapped_first_seen = 0;
bool     g_orphan_alerted = false;
bool     g_stale_cursor_alerted = false;

int FindPendingOpen(const string id)
{
   for(int i=0; i<ArraySize(g_pending_open_ids); i++)
      if(g_pending_open_ids[i] == id) return i;
   return -1;
}

int FindDeferredMod(const string id)
{
   for(int i=0; i<ArraySize(g_deferred_mod_ids); i++)
      if(g_deferred_mod_ids[i] == id) return i;
   return -1;
}

void RemoveDeferredModById(const string id)
{
   int idx = FindDeferredMod(id);
   if(idx < 0) return;
   int last = ArraySize(g_deferred_mod_ids) - 1;
   g_deferred_mod_ids[idx] = g_deferred_mod_ids[last];
   g_deferred_mod_sl[idx] = g_deferred_mod_sl[last];
   ArrayResize(g_deferred_mod_ids, last);
   ArrayResize(g_deferred_mod_sl, last);
}

void SavePendingOpenQueue()
{
   if(InpReplayMode) return;
   if(g_pending_open_file == "") return;

   int h = FileOpen(g_pending_open_file, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h == INVALID_HANDLE) return;

   for(int i=0; i<ArraySize(g_pending_open_raw); i++)
      FileWrite(h, g_pending_open_raw[i]);

   FileClose(h);
}

void LoadPendingOpenQueue()
{
   if(InpReplayMode) return;
   if(g_pending_open_file == "") return;
   if(!FileIsExist(g_pending_open_file, FILE_COMMON)) return;

   int h = FileOpen(g_pending_open_file, FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h == INVALID_HANDLE) return;

   while(!FileIsEnding(h)){
      string line = FileReadString(h);
      StringTrimLeft(line);
      StringTrimRight(line);
      if(StringLen(line) < 2) continue;

      string id = JGetStr(line, "id");
      if(id == "") continue;
      if(FindPendingOpen(id) >= 0) continue;

      int n = ArraySize(g_pending_open_ids);
      ArrayResize(g_pending_open_ids, n + 1);
      ArrayResize(g_pending_open_raw, n + 1);
      ArrayResize(g_pending_open_attempts, n + 1);
      ArrayResize(g_pending_open_first_ts, n + 1);
      ArrayResize(g_pending_open_last_try, n + 1);

      g_pending_open_ids[n] = id;
      g_pending_open_raw[n] = line;
      g_pending_open_attempts[n] = 0;
      g_pending_open_first_ts[n] = TimeCurrent();
      g_pending_open_last_try[n] = 0;
   }

   FileClose(h);
   LogCSV("PENDING_OPEN_LOADED;count="+IntegerToString(ArraySize(g_pending_open_ids)));
}

void RemovePendingOpenAt(const int idx)
{
   int last = ArraySize(g_pending_open_ids) - 1;
   if(idx < 0 || idx > last) return;

   g_pending_open_ids[idx] = g_pending_open_ids[last];
   g_pending_open_raw[idx] = g_pending_open_raw[last];
   g_pending_open_attempts[idx] = g_pending_open_attempts[last];
   g_pending_open_first_ts[idx] = g_pending_open_first_ts[last];
   g_pending_open_last_try[idx] = g_pending_open_last_try[last];

   ArrayResize(g_pending_open_ids, last);
   ArrayResize(g_pending_open_raw, last);
   ArrayResize(g_pending_open_attempts, last);
   ArrayResize(g_pending_open_first_ts, last);
   ArrayResize(g_pending_open_last_try, last);

   SavePendingOpenQueue();
}

void UpsertPendingOpen(const string id, const string raw)
{
   if(id == "" || raw == "") return;

   int idx = FindPendingOpen(id);
   if(idx < 0){
      int n = ArraySize(g_pending_open_ids);
      ArrayResize(g_pending_open_ids, n + 1);
      ArrayResize(g_pending_open_raw, n + 1);
      ArrayResize(g_pending_open_attempts, n + 1);
      ArrayResize(g_pending_open_first_ts, n + 1);
      ArrayResize(g_pending_open_last_try, n + 1);

      g_pending_open_ids[n] = id;
      g_pending_open_raw[n] = raw;
      g_pending_open_attempts[n] = 0;
      g_pending_open_first_ts[n] = TimeCurrent();
      g_pending_open_last_try[n] = 0;
   }
   else {
      g_pending_open_raw[idx] = raw;
   }

   SavePendingOpenQueue();
}

void CancelPendingOpenById(const string id, const string why)
{
   int idx = FindPendingOpen(id);
   if(idx < 0) return;
   LogCSV("OPEN_PENDING_CANCEL;"+id+";reason="+why);
   RemovePendingOpenAt(idx);
}

bool IsTransientOpenRetcode(const int rc)
{
   if(rc == 10031) return true; // no connection
   if(rc == 10012) return true; // timeout
   if(rc == 10020) return true; // price changed
   if(rc == 10021) return true; // price off
   if(rc == 10024) return true; // too many requests
   if(rc == 10004) return true; // requote
   return false;
}

int FindPendingAction(const string kind, const string id)
{
   for(int i=0; i<ArraySize(g_pending_action_ids); i++)
      if(g_pending_action_kind[i] == kind && g_pending_action_ids[i] == id) return i;
   return -1;
}

void RemovePendingActionAt(const int idx)
{
   int last = ArraySize(g_pending_action_ids) - 1;
   if(idx < 0 || idx > last) return;

   g_pending_action_ids[idx] = g_pending_action_ids[last];
   g_pending_action_kind[idx] = g_pending_action_kind[last];
   g_pending_action_raw[idx] = g_pending_action_raw[last];
   g_pending_action_attempts[idx] = g_pending_action_attempts[last];
   g_pending_action_first_ts[idx] = g_pending_action_first_ts[last];
   g_pending_action_last_try[idx] = g_pending_action_last_try[last];

   ArrayResize(g_pending_action_ids, last);
   ArrayResize(g_pending_action_kind, last);
   ArrayResize(g_pending_action_raw, last);
   ArrayResize(g_pending_action_attempts, last);
   ArrayResize(g_pending_action_first_ts, last);
   ArrayResize(g_pending_action_last_try, last);

   SavePendingActionQueue();
}

void SavePendingActionQueue()
{
   if(InpReplayMode) return;
   if(g_pending_action_file == "") return;

   int h = FileOpen(g_pending_action_file, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h == INVALID_HANDLE) return;

   for(int i=0; i<ArraySize(g_pending_action_raw); i++)
      FileWrite(h, g_pending_action_raw[i]);

   FileClose(h);
}

void LoadPendingActionQueue()
{
   if(InpReplayMode) return;
   if(g_pending_action_file == "") return;
   if(!FileIsExist(g_pending_action_file, FILE_COMMON)) return;

   int h = FileOpen(g_pending_action_file, FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h == INVALID_HANDLE) return;

   while(!FileIsEnding(h)){
      string line = FileReadString(h);
      StringTrimLeft(line);
      StringTrimRight(line);
      if(StringLen(line) < 2) continue;

      string id = JGetStr(line, "id");
      string kind = JGetStr(line, "action");
      if(id == "" || (kind != "modify" && kind != "close")) continue;
      if(FindPendingAction(kind, id) >= 0) continue;

      int n = ArraySize(g_pending_action_ids);
      ArrayResize(g_pending_action_ids, n + 1);
      ArrayResize(g_pending_action_kind, n + 1);
      ArrayResize(g_pending_action_raw, n + 1);
      ArrayResize(g_pending_action_attempts, n + 1);
      ArrayResize(g_pending_action_first_ts, n + 1);
      ArrayResize(g_pending_action_last_try, n + 1);

      g_pending_action_ids[n] = id;
      g_pending_action_kind[n] = kind;
      g_pending_action_raw[n] = line;
      g_pending_action_attempts[n] = 0;
      g_pending_action_first_ts[n] = TimeCurrent();
      g_pending_action_last_try[n] = 0;
   }

   FileClose(h);
   LogCSV("PENDING_ACTION_LOADED;count="+IntegerToString(ArraySize(g_pending_action_ids)));
}

void UpsertPendingAction(const string kind, const string id, const string raw)
{
   if(id == "" || raw == "") return;

   int idx = FindPendingAction(kind, id);
   if(idx < 0){
      int n = ArraySize(g_pending_action_ids);
      ArrayResize(g_pending_action_ids, n + 1);
      ArrayResize(g_pending_action_kind, n + 1);
      ArrayResize(g_pending_action_raw, n + 1);
      ArrayResize(g_pending_action_attempts, n + 1);
      ArrayResize(g_pending_action_first_ts, n + 1);
      ArrayResize(g_pending_action_last_try, n + 1);

      g_pending_action_ids[n] = id;
      g_pending_action_kind[n] = kind;
      g_pending_action_raw[n] = raw;
      g_pending_action_attempts[n] = 0;
      g_pending_action_first_ts[n] = TimeCurrent();
      g_pending_action_last_try[n] = 0;
   }
   else {
      g_pending_action_raw[idx] = raw;
   }

   SavePendingActionQueue();
}

void RemovePendingActionsById(const string id)
{
   for(int i=ArraySize(g_pending_action_ids)-1; i>=0; i--){
      if(g_pending_action_ids[i] == id)
         RemovePendingActionAt(i);
   }
}

bool IsLikelyMarketActive()
{
   MqlDateTime st;
   TimeToStruct(TimeCurrent(), st);
   if(st.day_of_week == 0 || st.day_of_week == 6) return false;
   return (st.hour >= 6 && st.hour <= 22);
}

void ClearSignalMaps()
{
   ArrayResize(g_ids, 0);
   ArrayResize(g_tickets, 0);
   ArrayResize(g_last_sl, 0);
   ArrayResize(g_sig_entry, 0);
   ArrayResize(g_sig_qty, 0);
   ArrayResize(g_sig_dir, 0);
   ArrayResize(g_open_server_ts, 0);
   ArrayResize(g_open_fill, 0);
}

void ReconcileBridgeState()
{
   if(InpReplayMode) return;

   datetime nowt = TimeCurrent();
   int interval = InpReconcileIntervalSec;
   if(ArraySize(g_pending_open_ids) > 0 || ArraySize(g_pending_action_ids) > 0)
      interval = MathMin(interval, 15);
   if(g_last_reconcile_check > 0 && (nowt - g_last_reconcile_check) < interval)
      return;
   g_last_reconcile_check = nowt;

   int live_total = 0;
   int mapped_total = 0;
   int unmapped_total = 0;
   int commentless_total = 0;

   for(int i=PositionsTotal()-1; i>=0; i--){
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;

      live_total++;
      string id = PositionGetString(POSITION_COMMENT);
      StringTrimLeft(id);
      StringTrimRight(id);
      if(id == ""){
         commentless_total++;
         continue;
      }
      if(FindId(id) >= 0) mapped_total++;
      else unmapped_total++;
   }

   if(live_total == 0){
      if(ArraySize(g_ids) > 0){
         ClearSignalMaps();
         LogCSV("RECONCILE_CLEAR;reason=no_live_positions");
      }

      // No live positions remain, so queued modify/close actions cannot resolve.
      // Drop them with an explicit audit trail to avoid stale queue buildup.
      for(int i=ArraySize(g_pending_action_ids)-1; i>=0; i--){
         LogCSV("DROP_STALE_PENDING;"+g_pending_action_kind[i]+";"+g_pending_action_ids[i]+
                ";reason=reconcile_clear_no_live_positions");
         RemovePendingActionAt(i);
      }

      g_unmapped_first_seen = 0;
      g_orphan_alerted = false;
      g_stale_cursor_alerted = false;
      return;
   }

   bool mismatch = (mapped_total != live_total) || (unmapped_total > 0) || (commentless_total > 0);
   if(mismatch){
      ClearSignalMaps();
      RebuildMapsFromOpenPositions();
      RetryPendingOpens();
      RetryPendingActions();

      bool alert_window = IsLikelyMarketActive() && AccountInfoInteger(ACCOUNT_TRADE_ALLOWED);
      if(alert_window && InpOrphanAlertMinutes > 0){
         if(g_unmapped_first_seen == 0) g_unmapped_first_seen = nowt;
         int orphan_age = (int)(nowt - g_unmapped_first_seen);
         if(orphan_age >= (InpOrphanAlertMinutes * 60) && !g_orphan_alerted){
            g_orphan_alerted = true;
            string msg = "Live position mapping is still inconsistent after " + IntegerToString(InpOrphanAlertMinutes) + " minutes. Check the chart and log before trading new signals.";
            LogCSV("ORPHAN_ALERT;live_total="+IntegerToString(live_total)+
                   ";mapped_total="+IntegerToString(mapped_total)+
                   ";unmapped_total="+IntegerToString(unmapped_total)+
                   ";commentless_total="+IntegerToString(commentless_total));
            Notify("PHANTOM MAP ALERT", msg);
         }
      }
      else {
         // Do not age or fire orphan alerts while market is inactive.
         g_unmapped_first_seen = 0;
         g_orphan_alerted = false;
      }
   }
   else {
      g_unmapped_first_seen = 0;
      g_orphan_alerted = false;
   }

   RetryPendingActions();
}

void RetryPendingActions()
{
   if(InpReplayMode) return;
   if(ArraySize(g_pending_action_ids) <= 0) return;

   datetime nowt = TimeCurrent();
   for(int i=ArraySize(g_pending_action_ids)-1; i>=0; i--){
      string kind = g_pending_action_kind[i];
      string id = g_pending_action_ids[i];

      // If there is no mapped live position for this id, keep only fresh entries.
      // Older orphaned actions are dropped to prevent permanent queue residue.
      int idx = FindId(id);
      if(idx < 0){
         if(InpMaxSignalAgeMinutes > 0){
            int age_sec = (int)(nowt - g_pending_action_first_ts[i]);
            int max_sec = InpMaxSignalAgeMinutes * 60;
            if(age_sec > max_sec){
               LogCSV("DROP_STALE_PENDING;"+kind+";"+id+
                      ";age_sec="+IntegerToString(age_sec)+
                      ";reason=no_live_position_and_expired");
               RemovePendingActionAt(i);
            }
         }
         continue;
      }

      if(g_pending_action_last_try[i] > 0 && (nowt - g_pending_action_last_try[i]) < 15)
         continue;

      ulong tk = g_tickets[idx];
      if(!PositionSelectByTicket(tk)) continue;

      g_pending_action_last_try[i] = nowt;
      g_pending_action_attempts[i]++;

      if(kind == "modify"){
         double desired = JGetNum(g_pending_action_raw[i], "new_stop");
         LogCSV("MODIFY_RETRY_PENDING;"+id+";attempt="+IntegerToString(g_pending_action_attempts[i]));
         HandleModify(g_pending_action_raw[i]);

         if(PositionSelectByTicket(tk)){
            double cur_sl = PositionGetDouble(POSITION_SL);
            if(desired > 0.0 && MathAbs(cur_sl - desired) <= (g_point * 0.5))
               RemovePendingActionAt(i);
         }
      }
      else if(kind == "close"){
         LogCSV("CLOSE_RETRY_PENDING;"+id+";attempt="+IntegerToString(g_pending_action_attempts[i]));
         HandleClose(g_pending_action_raw[i]);
         if(!PositionSelectByTicket(tk) || FindId(id) < 0)
            RemovePendingActionAt(i);
      }
   }
}

bool HasOpenFired(const string id)
{
   for(int i=0; i<ArraySize(g_open_once_ids); i++)
      if(g_open_once_ids[i] == id) return true;
   return false;
}

void MarkOpenFired(const string id)
{
   if(id == "" || HasOpenFired(id)) return;
   int n = ArraySize(g_open_once_ids);
   ArrayResize(g_open_once_ids, n + 1);
   g_open_once_ids[n] = id;
}

int FindPending(const string id)
{
   for(int i=0; i<ArraySize(g_pending_ids); i++)
      if(g_pending_ids[i] == id) return i;
   return -1;
}

void RemovePendingAt(const int idx)
{
   int last = ArraySize(g_pending_ids) - 1;
   if(idx < 0 || idx > last) return;

   g_pending_ids[idx]     = g_pending_ids[last];
   g_pending_tickets[idx] = g_pending_tickets[last];
   g_pending_tp[idx]      = g_pending_tp[last];
   g_pending_sl[idx]      = g_pending_sl[last];
   g_pending_dir[idx]     = g_pending_dir[last];
   g_pending_expiry[idx]  = g_pending_expiry[last];

   ArrayResize(g_pending_ids, last);
   ArrayResize(g_pending_tickets, last);
   ArrayResize(g_pending_tp, last);
   ArrayResize(g_pending_sl, last);
   ArrayResize(g_pending_dir, last);
   ArrayResize(g_pending_expiry, last);
}

void ArmReplayTpClose(const string id, const ulong tk, const int dir_sig, const double tp_price, const double sl_price)
{
   int idx = FindPending(id);
   if(idx < 0){
      int n = ArraySize(g_pending_ids);
      ArrayResize(g_pending_ids, n + 1);
      ArrayResize(g_pending_tickets, n + 1);
      ArrayResize(g_pending_tp, n + 1);
      ArrayResize(g_pending_sl, n + 1);
      ArrayResize(g_pending_dir, n + 1);
      ArrayResize(g_pending_expiry, n + 1);
      idx = n;
   }

   g_pending_ids[idx] = id;
   g_pending_tickets[idx] = tk;
   g_pending_tp[idx] = tp_price;
   g_pending_sl[idx] = sl_price;
   g_pending_dir[idx] = dir_sig;
   g_pending_expiry[idx] = g_last_bar + PeriodSeconds(PERIOD_M5);

   LogCSV("CLOSE_TP_ARM;"+id+
          ";tp="+DoubleToString(tp_price,g_digits)+
          ";sl="+DoubleToString(sl_price,g_digits)+
          ";expiry="+TimeToString(g_pending_expiry[idx], TIME_DATE|TIME_SECONDS));
}

void ProcessPendingReplayTpCloses()
{
   if(!InpReplayMode) return;
   if(!InpReplayUseSignalPricing) return;

   for(int i=ArraySize(g_pending_ids)-1; i>=0; i--){
      string id = g_pending_ids[i];
      ulong tk = g_pending_tickets[i];

      if(!PositionSelectByTicket(tk)){
         LogCSV("CLOSE_TP_FILLED;"+id);
         UnmapId(id);
         RemovePendingAt(i);
         continue;
      }

      if(TimeCurrent() < g_pending_expiry[i]) continue;

      if(trade.PositionClose(tk)){
         LogCSV("CLOSE_TP_FALLBACK_MKT;"+id+
                ";fill="+DoubleToString(trade.ResultPrice(),g_digits));
         UnmapId(id);
      }
      else {
         LogCSV("CLOSE_TP_FALLBACK_MKT_FAIL;"+id+
                ";ret="+IntegerToString(trade.ResultRetcode())+
                ";"+trade.ResultRetcodeDescription());
      }

      RemovePendingAt(i);
   }
}

//==== TESTER MODE STAMP ====
bool StampModelMode()
{
   bool in_tester = (bool)MQLInfoInteger(MQL_TESTER);
   if(!in_tester){
      LogCSV("MODEL_MODE;tester=false;mode=LIVE_OR_DEMO");
      return true;
   }

   MqlTick ticks[];
   int copied = CopyTicks(g_symbol, ticks, COPY_TICKS_ALL, 0, 32);
   bool has_ticks = (copied > 0);

   string mode = has_ticks ? "TICK_DRIVEN_LIKELY" : "UNKNOWN_OR_OHLC";
   LogCSV("MODEL_MODE;tester=true;copied_ticks="+IntegerToString(copied)+";mode="+mode);

   if(!has_ticks){
      LogCSV("MODEL_MODE_WARN;low_confidence_modelling;use_every_tick_real_for_straddle_trust");
      Print("WARNING: Low-confidence tester tick context. Use 'Every tick based on real ticks' for reliable TP/SL ordering.");
   }
   return has_ticks;
}

//==== STRADDLE AUDIT (LOG-ONLY) ====
void DetectStraddles(const datetime bar_time)
{
   if(!InpEnableStraddleAudit) return;
   if(!InpReplayMode) return;
   if(!InpReplayUseSignalPricing) return;
   if(ArraySize(g_pending_ids) <= 0) return;

   double bhigh = iHigh(g_symbol, PERIOD_M5, 1);
   double blow  = iLow(g_symbol, PERIOD_M5, 1);
   if(bhigh <= 0.0 || blow <= 0.0 || bhigh < blow) return;

   for(int p=0; p<ArraySize(g_pending_ids); p++){
      string id = g_pending_ids[p];
      double tp = g_pending_tp[p];
      double sl = g_pending_sl[p];
      int dir = g_pending_dir[p];

      if(tp <= 0.0 || sl <= 0.0) continue;

      bool tp_in = (tp >= blow && tp <= bhigh);
      bool sl_in = (sl >= blow && sl <= bhigh);
      if(!(tp_in && sl_in)) continue;

      string d = (dir > 0) ? "long" : ((dir < 0) ? "short" : "unknown");
      LogCSV("STRADDLE_DETECTED;"+id+
             ";bar_ts="+TimeToString(bar_time, TIME_DATE|TIME_SECONDS)+
             ";bar_high="+DoubleToString(bhigh,g_digits)+
             ";bar_low="+DoubleToString(blow,g_digits)+
             ";tp="+DoubleToString(tp,g_digits)+
             ";sl="+DoubleToString(sl,g_digits)+
             ";dir="+d+
             ";policy_hint=sl_first");
   }
}

//==== HELPERS ====
int FindId(const string id)
{
   for(int i=0;i<ArraySize(g_ids);i++) if(g_ids[i]==id) return i;
   return -1;
}

void MapId(const string id, const ulong ticket)
{
   int idx=FindId(id);
   if(idx<0){
      int n=ArraySize(g_ids);
      ArrayResize(g_ids,n+1);
      ArrayResize(g_tickets,n+1);
      ArrayResize(g_last_sl,n+1);
      ArrayResize(g_sig_entry,n+1);
      ArrayResize(g_sig_qty,n+1);
      ArrayResize(g_sig_dir,n+1);
      ArrayResize(g_open_server_ts,n+1);
      ArrayResize(g_open_fill,n+1);
      g_ids[n]=id;
      g_tickets[n]=ticket;
      g_last_sl[n]=0.0;
      g_sig_entry[n]=0.0;
      g_sig_qty[n]=0.0;
      g_sig_dir[n]=0;
      g_open_server_ts[n]=0;
      g_open_fill[n]=0.0;
   }
   else {
      g_tickets[idx]=ticket;
   }
}

void UnmapId(const string id)
{
   int idx=FindId(id);
   if(idx<0) return;
   int last=ArraySize(g_ids)-1;
   g_ids[idx]=g_ids[last];
   g_tickets[idx]=g_tickets[last];
   g_last_sl[idx]=g_last_sl[last];
   g_sig_entry[idx]=g_sig_entry[last];
   g_sig_qty[idx]=g_sig_qty[last];
   g_sig_dir[idx]=g_sig_dir[last];
   g_open_server_ts[idx]=g_open_server_ts[last];
   g_open_fill[idx]=g_open_fill[last];
   ArrayResize(g_ids,last);
   ArrayResize(g_tickets,last);
   ArrayResize(g_last_sl,last);
   ArrayResize(g_sig_entry,last);
   ArrayResize(g_sig_qty,last);
   ArrayResize(g_sig_dir,last);
   ArrayResize(g_open_server_ts,last);
   ArrayResize(g_open_fill,last);
}

void RebuildMapsFromOpenPositions()
{
   int mapped = 0;
   int open_total = 0;

   for(int i=PositionsTotal()-1; i>=0; i--){
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;

      open_total++;

      string id = PositionGetString(POSITION_COMMENT);
      StringTrimLeft(id);
      StringTrimRight(id);
      if(id == ""){
         LogCSV("MAP_REBUILD_SKIP;ticket="+IntegerToString((long)tk)+";reason=no_comment");
         continue;
      }

      MapId(id, tk);
      int idx = FindId(id);
      if(idx < 0) continue;

      g_last_sl[idx] = PositionGetDouble(POSITION_SL);
      g_sig_entry[idx] = PositionGetDouble(POSITION_PRICE_OPEN);
      g_sig_qty[idx] = PositionGetDouble(POSITION_VOLUME);
      g_sig_dir[idx] = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      g_open_server_ts[idx] = (datetime)PositionGetInteger(POSITION_TIME);
      g_open_fill[idx] = PositionGetDouble(POSITION_PRICE_OPEN);
            LogCSV("MAP_REBUILD_ID;id="+id+
               ";ticket="+IntegerToString((long)tk)+
               ";type="+IntegerToString((int)PositionGetInteger(POSITION_TYPE))+
               ";vol="+DoubleToString(g_sig_qty[idx],2)+
               ";open="+DoubleToString(g_open_fill[idx],g_digits)+
               ";sl="+DoubleToString(g_last_sl[idx],g_digits));
      mapped++;
   }

   LogCSV("MAP_REBUILD;mapped="+IntegerToString(mapped)+";open_total="+IntegerToString(open_total));
   PrintFormat("PhantomBridge map rebuild | mapped=%d open_total=%d", mapped, open_total);
}

double NormalizePrice(const double p){ return NormalizeDouble(p,g_digits); }

double MinStopDistance()
{
   double stop_dist = (g_stopslevel > 0) ? (g_stopslevel * g_point) : 0.0;
   int freeze_level = (int)SymbolInfoInteger(g_symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   double freeze_dist = (freeze_level > 0) ? (freeze_level * g_point) : 0.0;
   return MathMax(stop_dist, freeze_dist);
}

double NormalizeLots(double lots)
{
   if(lots<=0) return 0.0;
   lots = MathMax(lots, g_volmin);
   lots = MathMin(lots, MathMin(g_volmax, InpMaxLots));
   double steps = MathRound(lots/g_volstep);
   lots = steps*g_volstep;
   if(lots < g_volmin) lots = g_volmin;
   return NormalizeDouble(lots, 2);
}

double ClampStopDistance(const double price, double sl, const bool is_long)
{
   double minDist = MinStopDistance();
   if(minDist<=0.0) return NormalizePrice(sl);
   if(is_long){ if(price-sl < minDist) sl = price-minDist; }
   else       { if(sl-price < minDist) sl = price+minDist; }
   return NormalizePrice(sl);
}

string SignalGroupFromId(const string id)
{
   int p = StringFind(id, "#");
   if(p > 0) return StringSubstr(id, 0, p);
   return id;
}

//==== JSON (minimal flat parser) ====
string JGetStr(const string js, const string key)
{
   string pat="\""+key+"\"";
   int k=StringFind(js,pat);
   if(k<0) return "";
   int c=StringFind(js,":",k);
   if(c<0) return "";
   int i=c+1;
   while(i<StringLen(js) && (StringGetCharacter(js,i)==' ')) i++;
   if(i>=StringLen(js)) return "";
   ushort ch=StringGetCharacter(js,i);
   if(ch=='\"'){
      int e=StringFind(js,"\"",i+1);
      if(e<0) return "";
      return StringSubstr(js,i+1,e-(i+1));
   }
   else {
      int e=i;
      while(e<StringLen(js)){
         ushort cc=StringGetCharacter(js,e);
         if(cc==','||cc=='}'||cc==' ') break;
         e++;
      }
      return StringSubstr(js,i,e-i);
   }
}

double JGetNum(const string js,const string key,const double def=0.0)
{
   string s=JGetStr(js,key);
   if(s=="") return def;
   return StringToDouble(s);
}

datetime ParseSignalTime(const string js)
{
   string ts = JGetStr(js, "signal_ts");
   if(ts == "") ts = JGetStr(js, "entry_ts");
   if(ts == "") return (datetime)0;
   StringReplace(ts, "T", " ");
   int z = StringFind(ts, "Z");
   if(z >= 0) ts = StringSubstr(ts, 0, z);
   return StringToTime(ts);
}

bool IsSignalTooOldForLive(const string js, const string action, const string id)
{
   if(InpReplayMode) return false;
   if(InpMaxSignalAgeMinutes <= 0) return false;

   datetime ts = ParseSignalTime(js);
   if(ts <= 0) return false;

   int age_sec = (int)(TimeCurrent() - ts);
   if(age_sec < 0) return false;

   if(age_sec > (InpMaxSignalAgeMinutes * 60)){
      string stale_msg = action+"_SKIP_STALE;"+id+
                         ";age_sec="+IntegerToString(age_sec)+
                         ";max_min="+IntegerToString(InpMaxSignalAgeMinutes)+
                         ";ts="+TimeToString(ts, TIME_DATE|TIME_SECONDS);
      LogCSV(stale_msg);
      PrintFormat("PhantomBridge STALE SKIP | %s", stale_msg);
      return true;
   }

   return false;
}

string ExplainInvalidOpenStops(const bool is_long, const double ref_price, const double sl, const double tp, const double minDist)
{
   bool sl_ok = true;
   bool tp_ok = true;

   if(is_long){
      sl_ok = (sl < (ref_price - minDist));
      tp_ok = (tp > (ref_price + minDist));
      if(!sl_ok && !tp_ok) return "buy_invalid_sl_and_tp_side_or_distance";
      if(!sl_ok) return "buy_invalid_sl_side_or_distance";
      if(!tp_ok) return "buy_invalid_tp_side_or_distance";
      return "buy_stops_rejected_by_broker_rule";
   }

   sl_ok = (sl > (ref_price + minDist));
   tp_ok = (tp < (ref_price - minDist));
   if(!sl_ok && !tp_ok) return "sell_invalid_sl_and_tp_side_or_distance";
   if(!sl_ok) return "sell_invalid_sl_side_or_distance";
   if(!tp_ok) return "sell_invalid_tp_side_or_distance";
   return "sell_stops_rejected_by_broker_rule";
}

string ExplainTradeRetcodeHuman(const int rc)
{
   if(rc == 10004) return "Order requoted by broker. Price moved; retry.";
   if(rc == 10006) return "Order rejected by broker.";
   if(rc == 10012) return "Order timed out before broker confirmation.";
   if(rc == 10014) return "Invalid lot size for this symbol/account.";
   if(rc == 10015) return "Invalid requested price.";
   if(rc == 10016) return "Invalid stops: SL or TP side/distance is not allowed.";
   if(rc == 10017) return "Trading is disabled for this account or symbol.";
   if(rc == 10018) return "Market is closed for this symbol.";
   if(rc == 10019) return "Insufficient margin to open/modify position.";
   if(rc == 10020) return "Price changed during submission. Retry at fresh price.";
   if(rc == 10021) return "No current quote available (price off).";
   if(rc == 10024) return "Too many requests sent too quickly.";
   if(rc == 10025) return "No change needed (request equals current values).";
   if(rc == 10027) return "Auto-trading blocked by terminal/client settings.";
   if(rc == 10030) return "Invalid order fill policy for this symbol.";
   if(rc == 10031) return "No broker connection.";
   if(rc == 10034) return "Order/position volume limit exceeded.";
   if(rc == 10038) return "Invalid close volume for position.";
   return "Broker rejected request (see retcode description).";
}

bool LoadAllEvents()
{
   if(g_replay_loaded) return true;

   int h=FileOpen(InpSignalFile, FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h==INVALID_HANDLE) return false;

   ArrayResize(g_replay_raw, 0);
   ArrayResize(g_replay_ts, 0);
   g_replay_next = 0;

   while(!FileIsEnding(h)){
      string line = FileReadString(h);
      StringTrimLeft(line);
      StringTrimRight(line);
      if(StringLen(line) < 2) continue;

      int n = ArraySize(g_replay_raw);
      ArrayResize(g_replay_raw, n + 1);
      ArrayResize(g_replay_ts, n + 1);
      g_replay_raw[n] = line;
      g_replay_ts[n] = ParseSignalTime(line);
   }

   FileClose(h);
   g_replay_loaded = true;
   LogCSV("LOAD_EVENTS;count=" + IntegerToString(ArraySize(g_replay_raw)));
   PrintFormat("PhantomBridge CASH replay loaded %d events", ArraySize(g_replay_raw));
   return true;
}

void ReplayDueEvents(const datetime bar_time)
{
   if(!g_replay_loaded && !LoadAllEvents()) return;

   static datetime s_last_valid_ts = 0;

   while(g_replay_next < ArraySize(g_replay_raw)){
      datetime ts = g_replay_ts[g_replay_next];

      if(ts <= 0){
         ts = s_last_valid_ts;
      }
      else {
         s_last_valid_ts = ts;
      }

      if(ts > bar_time) break;
      ProcessLine(g_replay_raw[g_replay_next]);
      g_replay_next++;
   }
}

//==== NOTIFY ====
void Notify(const string title, const string body)
{
   string msg=title+" | "+body;
   if(InpNotifyAlert){
      Alert(msg);
      Print(msg);
   }
   else {
      Print(msg);
   }
   if(InpNotifyPush)  SendNotification(StringSubstr(msg,0,255));
   if(InpNotifyEmail) SendMail(title, body);
}

//==== CSV LOG ====
void LogCSV(const string line)
{
   if(!InpLogToCSV) return;
   int h=FileOpen(InpLogFile, FILE_READ|FILE_WRITE|FILE_CSV|FILE_ANSI|FILE_COMMON, ';');
   if(h==INVALID_HANDLE) return;
   FileSeek(h,0,SEEK_END);
   FileWrite(h, TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS), line);
   FileClose(h);
}

// [CASH-1] DetectMode() removed — g_mode is always BROKER_CASH

//==== GUARDRAILS (CASH: rolling equity + trailing peak) ====
datetime ServerDay()
{
   datetime t=TimeCurrent();
   MqlDateTime st;
   TimeToStruct(t,st);
   st.hour=0;
   st.min=0;
   st.sec=0;
   return StructToTime(st);
}

void ResetDayIfNeeded()
{
   datetime d=ServerDay();
   if(d!=g_current_day){
      g_current_day=d;
      g_day_start_equity=AccountInfoDouble(ACCOUNT_EQUITY);
      g_day_start_balance=AccountInfoDouble(ACCOUNT_BALANCE);
      g_last_balance=AccountInfoDouble(ACCOUNT_BALANCE);
      if(g_halted_today && g_halt_serverday!=d){
         g_halted_today=false;
         Notify("PHANTOM CASH resumed","New server day "+TimeToString(d,TIME_DATE)+". Daily halt cleared; trading resumed.");
         SaveState();
      }
   }
}

//==== TIERED RISK (CASH/exponential mode) ==== [CASH-2]
// Returns risk-per-trade % based on current equity as a multiple of start_cap.
// Tiers taper risk as account grows to lock in compounded gains.
double TieredRiskPct(const double equity)
{
   double base = (g_start_cap>0.0) ? g_start_cap : 1.0;
   double mult = equity / base;
   if(mult < InpTier1Mult) return InpTier1RiskPct;   // <2x  -> 3.95%
   if(mult < InpTier2Mult) return InpTier2RiskPct;   // <4x  -> 3.10%
   if(mult < InpTier3Mult) return InpTier3RiskPct;   // <7x  -> 2.40%
   if(mult < InpTier4Mult) return InpTier4RiskPct;   // <10x -> 1.85%
   return InpTier5RiskPct;                            // >=10x -> 1.40%
}

//==== STATE PERSISTENCE (per-login, JSON) ==== [CASH-10]
void SaveState()
{
   if(g_state_file=="") return;
   int h=FileOpen(g_state_file, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h==INVALID_HANDLE) return;
   string js="{\"login\":"+IntegerToString(g_login)+
             ",\"start_cap\":"+DoubleToString(g_start_cap,2)+
             ",\"peak_equity\":"+DoubleToString(g_peak_equity,2)+
             ",\"filepos\":"+IntegerToString((long)g_filepos)+
             ",\"disabled_perm\":"+(g_disabled_perm?"1":"0")+"}";
   FileWrite(h, js);
   FileClose(h);
}

void LoadState()
{
   if(g_state_file=="") return;
   if(!FileIsExist(g_state_file, FILE_COMMON)) return;
   int h=FileOpen(g_state_file, FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h==INVALID_HANDLE) return;
   string js="";
   while(!FileIsEnding(h)) js+=FileReadString(h);
   FileClose(h);
   double sc = JGetNum(js,"start_cap",0.0);
   double pk = JGetNum(js,"peak_equity",0.0);
   double dp = JGetNum(js,"disabled_perm",0.0);
      double fp = JGetNum(js,"filepos",0.0);
   if(sc>0.0) g_start_cap=sc;
   if(pk>0.0) g_peak_equity=pk;
   g_disabled_perm = (dp>=0.5);
      if(fp>0.0 && !InpReplayMode) g_filepos=(ulong)fp;
   LogCSV("STATE_LOADED;start_cap="+DoubleToString(g_start_cap,2)+
          ";peak="+DoubleToString(g_peak_equity,2)+
         ";filepos="+IntegerToString((long)g_filepos)+
          ";disabled_perm="+(g_disabled_perm?"1":"0"));
}

void FlattenAll(const string why)
{
   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong tk=PositionGetTicket(i);
      if(tk==0) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL)!=g_symbol) continue;
      trade.PositionClose(tk);
   }
   LogCSV("FLATTEN;"+why);
}

// [CASH-3/6/7] CASH guardrail — daily floor off day-start balance, max-loss trailing off peak
bool GuardrailBlock()
{
   if(g_disabled_perm){
      LogCSV("GUARDRAIL_BLOCK;reason=HARD_PAUSE");
      return true;
   }

   ResetDayIfNeeded();
   if(g_halted_today){
      LogCSV("GUARDRAIL_BLOCK;reason=DAILY_HALT");
      return true;
   }

   double eq = AccountInfoDouble(ACCOUNT_EQUITY);

   // [CASH-3] Update peak high-water mark (drives trailing floor)
   if(eq > g_peak_equity){ g_peak_equity = eq; SaveState(); }

   // ---- daily loss amount: CASH = % off day-start balance ---- [CASH-6]
   double daily_amount  = g_day_start_balance * (InpDailyLossPct/100.0);
   double daily_floor   = g_day_start_balance - daily_amount;
   double daily_loss    = g_day_start_equity - eq;
   double breaker_level = daily_amount * (InpCircuitBreakerPct/100.0);  // [CASH-7]

   // ---- circuit breaker: soft stop at 80% of daily amount ---- [CASH-7]
   if(daily_loss >= breaker_level && daily_loss < daily_amount){
      LogCSV("CIRCUIT_BREAKER;loss="+DoubleToString(daily_loss,2)+
             ";level="+DoubleToString(breaker_level,2)+";amount="+DoubleToString(daily_amount,2));
      g_halted_today=true;
      g_halt_serverday=ServerDay();
      Notify("PHANTOM CASH breaker","Hit "+DoubleToString(InpCircuitBreakerPct,0)+"% of daily loss limit (loss="+
             DoubleToString(daily_loss,2)+"). Stop opening; auto-resume next server day.");
      SaveState();
      return true;
   }

   // ---- hard daily floor breach ----
   if(eq <= daily_floor){
      FlattenAll("MAX_DAILY_LOSS");
      g_halted_today=true;
      g_halt_serverday=ServerDay();
      Notify("PHANTOM CASH halted","Daily loss floor breached (eq="+DoubleToString(eq,2)+
             " <= floor="+DoubleToString(daily_floor,2)+"). Flattened & halted; auto-resume next day.");
      SaveState();
      return true;
   }

   // ---- max loss floor: TRAILING 15% off peak equity ---- [CASH-3]
   double peak_before = g_peak_equity;
   double max_floor = g_peak_equity * (1.0 - InpCashTrailMaxLossPct/100.0);

   if(eq <= max_floor){
      FlattenAll("MAX_LOSS_TRAILING");
      g_halt_serverday=ServerDay();
      if(InpReplayMode){
         // In replay we treat trailing-floor breaches as day halts so the backtest
         // can continue next server day without requiring a manual resume toggle.
         g_halted_today=true;
         g_peak_equity=eq;
         Notify("PHANTOM CASH paused","Trailing max-loss floor breached (eq="+DoubleToString(eq,2)+
                " <= floor="+DoubleToString(max_floor,2)+
              ", peak="+DoubleToString(peak_before,2)+
                "). Flattened & day-paused in replay; auto-resume next day.");
      }
      else{
         g_disabled_perm=true;
         Notify("PHANTOM CASH DISABLED","Trailing max-loss floor breached (eq="+DoubleToString(eq,2)+
                " <= floor="+DoubleToString(max_floor,2)+
              ", peak="+DoubleToString(peak_before,2)+
                "). Flattened & HARD-PAUSED until manual resume.");
      }
      SaveState();
      return true;
   }

   return false;
}

//==== LOT SIZING (CASH: tiered risk on equity) ====
// [CASH-1/2/4] Only CASH logic retained; FTMO branches removed
double ComputeLotsForSignal(const string dir,const double entry,const double stop,const double qty,const double sacct)
{
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);

   // price risk per unit
   double stop_dist = MathAbs(entry - stop);
   if(stop_dist <= 0.0 || entry <= 0.0){
      double base_sa = (sacct>0.0)?sacct:InpMetaAccountFallback;
      return qty * (eq / base_sa);
   }

   // [CASH-2] Tiered risk off current equity
   double risk_pct  = TieredRiskPct(eq);
   double risk_base = eq;
   double risk_amt  = risk_base * (risk_pct/100.0);

   // Cap risk by remaining distance to trailing max-loss floor [CASH-3]
   double max_floor = g_peak_equity * (1.0 - InpCashTrailMaxLossPct/100.0);
   double remaining_total = MathMax(0.0, eq - max_floor);
   risk_amt = MathMin(risk_amt, remaining_total);
   if(risk_amt<=0.0){
      LogCSV("SIZE_BLOCK;reason=total_buffer_exhausted;eq="+DoubleToString(eq,2)+
             ";floor="+DoubleToString(max_floor,2));
      return 0.0;
   }

   // value of a 1.0-lot move of stop_dist in account currency
   double tick_val  = SymbolInfoDouble(g_symbol,SYMBOL_TRADE_TICK_VALUE);
   double tick_size = SymbolInfoDouble(g_symbol,SYMBOL_TRADE_TICK_SIZE);
   double loss_per_lot;
   if(tick_val>0.0 && tick_size>0.0) loss_per_lot = (stop_dist/tick_size)*tick_val;
   else                              loss_per_lot = stop_dist * SymbolInfoDouble(g_symbol,SYMBOL_TRADE_CONTRACT_SIZE);
   if(loss_per_lot<=0.0) loss_per_lot = stop_dist;

   double lots = risk_amt / loss_per_lot;

   // [CASH-4] Lot cap: InpCashLotCapMult x the natural "daily-base" lot size
   // daily-base = lots implied by tier-1 risk on start_cap (the entry-day natural size)
   double daily_base_risk = g_start_cap * (InpTier1RiskPct/100.0);
   double daily_base_lots = daily_base_risk / loss_per_lot;
   double cap_lots = daily_base_lots * InpCashLotCapMult;
   if(cap_lots>0.0) lots = MathMin(lots, cap_lots);

   LogCSV("SIZE;mode=CASH"+
          ";risk_pct="+DoubleToString(risk_pct,2)+
          ";risk_amt="+DoubleToString(risk_amt,2)+
          ";remaining_total="+DoubleToString(remaining_total,2)+
          ";loss_per_lot="+DoubleToString(loss_per_lot,2)+
          ";lots_raw="+DoubleToString(lots,4)+
          ";lot_cap="+DoubleToString(cap_lots,4));
   return lots;
}

//==== ACTION HANDLERS ====
void HandleMeta(const string js)
{
   g_meta_seen=true;
   g_meta_acct=JGetNum(js,"signal_account_size",InpMetaAccountFallback);
   LogCSV("META;acct="+DoubleToString(g_meta_acct,2));
}

bool PositionExistsForSignal(const string id, ulong &out_ticket)
{
   out_ticket = 0;
   for(int pi = PositionsTotal()-1; pi >= 0; pi--){
      ulong cand = PositionGetTicket(pi);
      if(cand == 0) continue;
      if(!PositionSelectByTicket(cand)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if(PositionGetString(POSITION_COMMENT) == id){
         out_ticket = cand;
         return true;
      }
   }
   return false;
}

void HandleOpen(const string js)
{
   string id  = JGetStr(js,"id");
   if(id=="") id = JGetStr(js,"entry_ts");

   if(IsSignalTooOldForLive(js, "OPEN", id))
      return;

   if(GuardrailBlock()){
      LogCSV("OPEN_BLOCKED_GUARDRAIL");
      return;
   }

   if(g_python_paused){
      LogCSV("OPEN_BLOCKED_PYTHON_PAUSE;"+JGetStr(js,"id"));
      return;
   }

   if(HasOpenFired(id)){
      LogCSV("OPEN_DUP_SKIP;"+id);
      return;
   }
   string entry_ts = JGetStr(js,"entry_ts");
   string sig_group = (entry_ts!="") ? entry_ts : SignalGroupFromId(id);
   string dir = JGetStr(js,"dir");
   bool is_long = (dir=="long");
   int stack_max = (int)MathRound(JGetNum(js,"stack_max",0.0));
   if(stack_max<=0){
      // Legacy fallback if signal does not carry stack_max.
      stack_max = 3;
   }
   if(stack_max<1) stack_max=1;
   if(stack_max>4) stack_max=4;

   int open_same_dir = 0;
   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong tk=PositionGetTicket(i);
      if(tk==0) continue;
      if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL)!=g_symbol) continue;
      bool pos_long = (PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY);
      if(pos_long!=is_long) continue;

      if(InpStackLimitSameSignalOnly){
         string pos_id = PositionGetString(POSITION_COMMENT);
         string pos_group = SignalGroupFromId(pos_id);
         if(pos_group == sig_group) open_same_dir++;
      }
      else {
         open_same_dir++;
      }
   }
   if(open_same_dir>=stack_max){
      LogCSV("OPEN_BLOCKED_STACK_MAX;"+id+
             ";dir="+dir+
             ";group="+sig_group+
             ";open_same_dir="+IntegerToString(open_same_dir)+
             ";stack_max="+IntegerToString(stack_max));
      return;
   }

   double entry = JGetNum(js,"entry");
   double stop  = JGetNum(js,"stop");
   double tp    = JGetNum(js,"tp");
   double qty   = JGetNum(js,"qty");
   double sacct = JGetNum(js,"signal_account_size", g_meta_acct);
   if(sacct<=0) sacct=InpMetaAccountFallback;
   double live_eq = AccountInfoDouble(ACCOUNT_EQUITY);

   double lots;
   if(InpReplayMode && InpReplayUseSignalPricing){
      lots = qty;
   }
   else if(InpUsePythonSizing){
      lots = qty * (live_eq / sacct);
   }
   else {
      // [CASH-2] EA computes lots per tiered risk model
      lots = ComputeLotsForSignal(dir, entry, stop, qty, sacct);
   }
   lots = NormalizeLots(lots);
   if(lots<=0){
      LogCSV("OPEN_SKIP_ZEROLOT;"+id);
      return;
   }

   {
      ulong existing_tk = 0;
      if(PositionExistsForSignal(id, existing_tk)){
         MapId(id, existing_tk);
         MarkOpenFired(id);
         int eidx = FindId(id);
         if(eidx >= 0){
            g_last_sl[eidx]        = stop;
            g_sig_entry[eidx]      = entry;
            g_sig_qty[eidx]        = qty;
            g_sig_dir[eidx]        = is_long ? 1 : -1;
            g_open_server_ts[eidx] = TimeCurrent();
            g_open_fill[eidx]      = PositionGetDouble(POSITION_PRICE_OPEN);
         }
         LogCSV("OPEN_ALREADY_EXISTS;"+id+
                ";ticket="+IntegerToString((long)existing_tk)+
                ";fill="+DoubleToString(PositionGetDouble(POSITION_PRICE_OPEN),g_digits));
         CancelPendingOpenById(id, "already_open");
         return;
      }
   }

   double price = is_long ? SymbolInfoDouble(g_symbol,SYMBOL_ASK)
                    : SymbolInfoDouble(g_symbol,SYMBOL_BID);
   double minDist = MinStopDistance();
   double sl = ClampStopDistance(price, stop, is_long);
   double tpx = NormalizePrice(tp);

   double open_sl = InpReplayMode ? 0.0 : sl;
   double open_tp = InpReplayMode ? 0.0 : tpx;

   trade.SetExpertMagicNumber(InpMagicNumber);
   bool ok;
   if(is_long) ok=trade.Buy(lots,g_symbol,0.0,open_sl,open_tp,id);
   else        ok=trade.Sell(lots,g_symbol,0.0,open_sl,open_tp,id);

   if(ok){
      ulong tk=trade.ResultOrder();
      ulong resolved=0;
      for(int pi=PositionsTotal()-1; pi>=0; pi--){
         ulong cand=PositionGetTicket(pi);
         if(cand==0) continue;
         if(!PositionSelectByTicket(cand)) continue;
         if(PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber) continue;
         if(PositionGetString(POSITION_SYMBOL)!=g_symbol) continue;
         if(PositionGetString(POSITION_COMMENT)==id){ resolved=cand; break; }
      }
      if(resolved!=0) tk=resolved;
      MapId(id,tk);
      MarkOpenFired(id);
      int idx=FindId(id);
      if(idx>=0){
         g_last_sl[idx]=sl;
         g_sig_entry[idx]=entry;
         g_sig_qty[idx]=qty;
         g_sig_dir[idx]=is_long ? 1 : -1;
         g_open_server_ts[idx]=TimeCurrent();
         g_open_fill[idx]=(trade.ResultPrice()>0.0) ? trade.ResultPrice() : entry;
      }
      LogCSV("OPEN;"+id+";dir="+dir+";lots="+DoubleToString(lots,2)+
             ";want_entry="+DoubleToString(entry,g_digits)+
             ";fill="+DoubleToString(trade.ResultPrice(),g_digits)+
             ";sl="+DoubleToString(sl,g_digits)+";tp="+DoubleToString(tpx,g_digits)+
             ";sacct="+DoubleToString(sacct,2)+";live_eq="+DoubleToString(live_eq,2));

      int dmx = FindDeferredMod(id);
      if(dmx >= 0){
         string djs = "{\"id\":\""+id+"\",\"new_stop\":"+DoubleToString(g_deferred_mod_sl[dmx], g_digits)+"}";
         LogCSV("MODIFY_DEFER_APPLY;"+id+";new_stop="+DoubleToString(g_deferred_mod_sl[dmx], g_digits));
         RemoveDeferredModById(id);
         HandleModify(djs);
      }

      RetryPendingActions();

      CancelPendingOpenById(id, "open_success");
   }
   else {
      int rc = (int)trade.ResultRetcode();
      LogCSV("OPEN_FAIL;"+id+";ret="+IntegerToString(rc)+";"+trade.ResultRetcodeDescription());
      string human_rc = ExplainTradeRetcodeHuman(rc);
      if(rc == 10016){
         string why = ExplainInvalidOpenStops(is_long, price, open_sl, open_tp, minDist);
         string human = "Order rejected: invalid stop placement.";
         if(why == "buy_invalid_sl_side_or_distance")
            human = "Buy rejected: SL must be below market and far enough away.";
         else if(why == "buy_invalid_tp_side_or_distance")
            human = "Buy rejected: TP must be above market and far enough away.";
         else if(why == "buy_invalid_sl_and_tp_side_or_distance")
            human = "Buy rejected: both SL and TP are invalid for current price.";
         else if(why == "sell_invalid_sl_side_or_distance")
            human = "Sell rejected: SL must be above market and far enough away.";
         else if(why == "sell_invalid_tp_side_or_distance")
            human = "Sell rejected: TP must be below market and far enough away.";
         else if(why == "sell_invalid_sl_and_tp_side_or_distance")
            human = "Sell rejected: both SL and TP are invalid for current price.";
         LogCSV("OPEN_FAIL_EXPLAIN;"+id+
                ";why="+why+
                ";human="+human+
                ";dir="+(is_long?"buy":"sell")+
                ";ref="+DoubleToString(price,g_digits)+
                ";sl="+DoubleToString(open_sl,g_digits)+
                ";tp="+DoubleToString(open_tp,g_digits)+
                ";minDist="+DoubleToString(minDist,g_digits));
      }
      else {
         LogCSV("OPEN_FAIL_EXPLAIN;"+id+
                ";why=retcode_"+IntegerToString(rc)+
                ";human="+human_rc);
      }

      if(!InpReplayMode && (rc == 10004 || rc == 10020)){
         for(int retry = 1; retry <= 2; retry++){
            Sleep(600);

            ulong retry_tk = 0;
            if(PositionExistsForSignal(id, retry_tk)){
               MapId(id, retry_tk);
               MarkOpenFired(id);
               int ridx = FindId(id);
               if(ridx >= 0){
                  g_last_sl[ridx]        = sl;
                  g_sig_entry[ridx]      = entry;
                  g_sig_qty[ridx]        = qty;
                  g_sig_dir[ridx]        = is_long ? 1 : -1;
                  g_open_server_ts[ridx] = TimeCurrent();
                  g_open_fill[ridx]      = PositionGetDouble(POSITION_PRICE_OPEN);
               }
               LogCSV("OPEN_RETRY_FOUND_EXISTING;"+id+
                      ";retry="+IntegerToString(retry)+
                      ";ticket="+IntegerToString((long)retry_tk));
               CancelPendingOpenById(id, "found_on_retry");
               return;
            }

            price = is_long ? SymbolInfoDouble(g_symbol, SYMBOL_ASK)
                            : SymbolInfoDouble(g_symbol, SYMBOL_BID);
            sl = ClampStopDistance(price, stop, is_long);
            double open_sl_retry = InpReplayMode ? 0.0 : sl;

            if(is_long) ok = trade.Buy(lots, g_symbol, 0.0, open_sl_retry, open_tp, id);
            else        ok = trade.Sell(lots, g_symbol, 0.0, open_sl_retry, open_tp, id);

            rc = (int)trade.ResultRetcode();
            LogCSV("OPEN_RETRY;"+id+
                   ";attempt="+IntegerToString(retry)+
                   ";ret="+IntegerToString(rc)+
                   ";price="+DoubleToString(price,g_digits));

            if(ok){
               ulong tk2 = trade.ResultOrder();
               ulong resolved2 = 0;
               for(int pi=PositionsTotal()-1; pi>=0; pi--){
                  ulong cand=PositionGetTicket(pi);
                  if(cand==0) continue;
                  if(!PositionSelectByTicket(cand)) continue;
                  if(PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber) continue;
                  if(PositionGetString(POSITION_SYMBOL)!=g_symbol) continue;
                  if(PositionGetString(POSITION_COMMENT)==id){ resolved2=cand; break; }
               }
               if(resolved2!=0) tk2=resolved2;
               MapId(id,tk2);
               MarkOpenFired(id);
               int idx2=FindId(id);
               if(idx2>=0){
                  g_last_sl[idx2]        = sl;
                  g_sig_entry[idx2]      = entry;
                  g_sig_qty[idx2]        = qty;
                  g_sig_dir[idx2]        = is_long ? 1 : -1;
                  g_open_server_ts[idx2] = TimeCurrent();
                  g_open_fill[idx2]      = (trade.ResultPrice()>0.0) ? trade.ResultPrice() : entry;
               }
               LogCSV("OPEN_RETRY_SUCCESS;"+id+
                      ";attempt="+IntegerToString(retry)+
                      ";dir="+dir+";lots="+DoubleToString(lots,2)+
                      ";fill="+DoubleToString(trade.ResultPrice(),g_digits)+
                      ";sl="+DoubleToString(sl,g_digits)+
                      ";tp="+DoubleToString(open_tp,g_digits));
               RetryPendingActions();
               CancelPendingOpenById(id, "retry_success");
               return;
            }

            if(rc != 10004 && rc != 10020) break;
         }
      }

      if(IsTransientOpenRetcode(rc) && !InpReplayMode){
         UpsertPendingOpen(id, js);
         LogCSV("OPEN_PENDING;"+id+";ret="+IntegerToString(rc));
      }
   }
}

void HandleModify(const string js)
{
   string id = JGetStr(js,"id");
   if(IsSignalTooOldForLive(js, "MODIFY", id))
      return;

   double new_stop = JGetNum(js,"new_stop");
   int idx=FindId(id);
   if(idx<0){
      int pidx = FindPendingOpen(id);
      if(pidx >= 0){
         UpsertPendingAction("modify", id, js);
         LogCSV("MODIFY_DEFER_PENDING_OPEN;"+id+";new_stop="+DoubleToString(new_stop, g_digits));
         return;
      }
      UpsertPendingAction("modify", id, js);
      LogCSV("MODIFY_PENDING;"+id+";new_stop="+DoubleToString(new_stop, g_digits));
      return;
   }

   ulong tk=g_tickets[idx];
   if(!PositionSelectByTicket(tk)){
      LogCSV("MODIFY_NO_POS;"+id);
      UnmapId(id);
      return;
   }

   bool is_long = (PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY);
   double cur_price = is_long ? SymbolInfoDouble(g_symbol,SYMBOL_BID)
                    : SymbolInfoDouble(g_symbol,SYMBOL_ASK);
   double minDist = MinStopDistance();

   bool sl_valid_side = is_long ? (new_stop < (cur_price - minDist))
                    : (new_stop > (cur_price + minDist));
   if(!sl_valid_side){
      LogCSV("MODIFY_SKIP_LATE;"+id+
             ";reason=invalid_sl_side"+
             ";ref="+DoubleToString(cur_price,g_digits)+
             ";sl="+DoubleToString(new_stop,g_digits)+
             ";minDist="+DoubleToString(minDist,g_digits));
      return;
   }

   double sl = ClampStopDistance(cur_price, new_stop, is_long);
   double tp = PositionGetDouble(POSITION_TP);

   if(MathAbs(sl - g_last_sl[idx]) < g_point*0.5) return;

   if(InpReplayMode){
      g_last_sl[idx]=sl;
      LogCSV("MODIFY_AUDIT;"+id+";new_sl="+DoubleToString(sl,g_digits));
      return;
   }

   if(trade.PositionModify(tk, sl, tp)){
      g_last_sl[idx]=sl;
      LogCSV("MODIFY;"+id+";new_sl="+DoubleToString(sl,g_digits));
   }
   else {
      int rc=(int)trade.ResultRetcode();
      if(rc==10016){
         double retry_price = is_long ? SymbolInfoDouble(g_symbol,SYMBOL_BID)
                    : SymbolInfoDouble(g_symbol,SYMBOL_ASK);
         bool retry_valid_side = is_long ? (new_stop < (retry_price - minDist))
                    : (new_stop > (retry_price + minDist));
         if(!retry_valid_side){
            LogCSV("MODIFY_SKIP_LATE;"+id+
                   ";reason=invalid_sl_side_refresh"+
                   ";ref="+DoubleToString(retry_price,g_digits)+
                   ";sl="+DoubleToString(new_stop,g_digits)+
                   ";minDist="+DoubleToString(minDist,g_digits));
            return;
         }

         double retry_sl = ClampStopDistance(retry_price, new_stop, is_long);
         if(MathAbs(retry_sl - sl) >= g_point*0.5 && trade.PositionModify(tk, retry_sl, tp)){
            g_last_sl[idx]=retry_sl;
            LogCSV("MODIFY_RETRY;"+id+";new_sl="+DoubleToString(retry_sl,g_digits));
            return;
         }
         rc=(int)trade.ResultRetcode();
      }

      if(rc==10025 || rc==10027){
         g_last_sl[idx]=sl;
      }
      else {
         LogCSV("MODIFY_FAIL;"+id+";ret="+IntegerToString(rc)+";"+trade.ResultRetcodeDescription());
         LogCSV("MODIFY_FAIL_EXPLAIN;"+id+
                ";why=retcode_"+IntegerToString(rc)+
                ";human="+ExplainTradeRetcodeHuman(rc));
      }
   }
}

void HandleClose(const string js)
{
   string id = JGetStr(js,"id");
   if(IsSignalTooOldForLive(js, "CLOSE", id))
      return;

   double exit_sig = JGetNum(js,"exit");
   string reason = JGetStr(js,"reason");
   string reason_l = reason;
   StringToLower(reason_l);
   int idx=FindId(id);
   if(idx<0){
      if(FindPendingOpen(id) >= 0){
         CancelPendingOpenById(id, "close_before_open");
         RemovePendingActionsById(id);
         LogCSV("CLOSE_CANCELLED_PENDING_OPEN;"+id+";reason="+reason);
         return;
      }
      UpsertPendingAction("close", id, js);
      LogCSV("CLOSE_PENDING;"+id+";reason="+reason);
      return;
   }

   // Guard against speculative same-cycle EOD close lines that can trail an OPEN immediately.
   if(reason_l=="eod" && InpIgnoreInstantEodSeconds>0 && exit_sig>0.0){
      datetime opened_at = g_open_server_ts[idx];
      if(opened_at>0){
         int age_sec = (int)(TimeCurrent() - opened_at);
         if(age_sec < 0) age_sec = 0;
         double ref_entry = (g_open_fill[idx]>0.0) ? g_open_fill[idx] : g_sig_entry[idx];
         double tol = MathMax(g_point, InpIgnoreInstantEodEntryTolPts * g_point);
         if(ref_entry>0.0){
            double d = MathAbs(exit_sig - ref_entry);
            if(age_sec <= InpIgnoreInstantEodSeconds && d <= tol){
               LogCSV("CLOSE_EOD_GUARD_SKIP;"+id+
                      ";age_sec="+IntegerToString(age_sec)+
                      ";entry_ref="+DoubleToString(ref_entry,g_digits)+
                      ";exit_sig="+DoubleToString(exit_sig,g_digits)+
                      ";dist="+DoubleToString(d,g_digits)+
                      ";tol="+DoubleToString(tol,g_digits));
               return;
            }
         }
      }
   }

   if(InpReplayMode && InpReplayUseSignalPricing && exit_sig>0.0){
      double entry_sig = g_sig_entry[idx];
      double qty_sig = g_sig_qty[idx];
      int dir_sig = g_sig_dir[idx];
      if(qty_sig>0.0 && dir_sig!=0){
         double pnl_sig = (dir_sig>0) ? (exit_sig-entry_sig)*qty_sig : (entry_sig-exit_sig)*qty_sig;
         g_synth_net += pnl_sig;
         g_synth_trades++;
         if(pnl_sig>0.0) g_synth_wins++;
         LogCSV("CLOSE_SYNTH;"+id+
                ";entry="+DoubleToString(entry_sig,g_digits)+
                ";exit="+DoubleToString(exit_sig,g_digits)+
                ";qty="+DoubleToString(qty_sig,6)+
                ";pnl="+DoubleToString(pnl_sig,2));
      }
   }

   ulong tk=g_tickets[idx];
   if(!PositionSelectByTicket(tk)){
      LogCSV("CLOSE_ALREADY;"+id);
      UnmapId(id);
      return;
   }

   double pnl_live = PositionGetDouble(POSITION_PROFIT);

   if(InpReplayMode && InpReplayUseSignalPricing && reason=="tp" && exit_sig>0.0){
      double sl_sig = g_last_sl[idx];
      int dir_sig = g_sig_dir[idx];
      bool is_long = (PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY);
      double ref_px = is_long ? SymbolInfoDouble(g_symbol,SYMBOL_BID)
                    : SymbolInfoDouble(g_symbol,SYMBOL_ASK);
      double minDist = MinStopDistance();

      double tp_arm = NormalizePrice(exit_sig);
      if(minDist>0.0){
         if(is_long){
            if(tp_arm-ref_px < minDist) tp_arm = NormalizePrice(ref_px+minDist);
         }
         else {
            if(ref_px-tp_arm < minDist) tp_arm = NormalizePrice(ref_px-minDist);
         }
      }

      double sl_arm = 0.0;
      if(sl_sig>0.0){
         sl_arm = ClampStopDistance(ref_px, sl_sig, is_long);
      }

      bool tp_valid_side = is_long ? (tp_arm>ref_px) : (tp_arm<ref_px);
      if(!tp_valid_side){
         LogCSV("CLOSE_TP_ARM_SKIP_LATE;"+id+
                ";reason=invalid_tp_side"+
                ";ref="+DoubleToString(ref_px,g_digits)+
                ";tp="+DoubleToString(tp_arm,g_digits));
      }
      else {
         if(trade.PositionModify(tk, sl_arm, tp_arm)){
            ArmReplayTpClose(id, tk, dir_sig, tp_arm, sl_arm);
            return;
         }
         LogCSV("CLOSE_TP_ARM_FAIL;"+id+
                ";ret="+IntegerToString(trade.ResultRetcode())+
                ";"+trade.ResultRetcodeDescription());
      }
   }

   if(trade.PositionClose(tk)){
      LogCSV("CLOSE;"+id+";fill="+DoubleToString(trade.ResultPrice(),g_digits));

      // Consecutive-loss hard stop is now owned by Python (pause_entries / hard_stop signals).
      // EA only tracks the count for logging purposes.
      if(pnl_live < 0.0) g_cumulative_losses++;
      else g_cumulative_losses = 0;
      LogCSV("CLOSE_LOSS_COUNT;consec="+IntegerToString(g_cumulative_losses));
   }
   else {
      LogCSV("CLOSE_FAIL;"+id+";ret="+IntegerToString(trade.ResultRetcode()));
      LogCSV("CLOSE_FAIL_EXPLAIN;"+id+
             ";why=retcode_"+IntegerToString((int)trade.ResultRetcode())+
             ";human="+ExplainTradeRetcodeHuman((int)trade.ResultRetcode()));
   }
   UnmapId(id);
}

void RetryPendingOpens()
{
   if(InpReplayMode) return;
   if(ArraySize(g_pending_open_ids) <= 0) return;

   for(int i=ArraySize(g_pending_open_ids)-1; i>=0; i--){
      string id = g_pending_open_ids[i];

      if(FindId(id) >= 0){
         RemovePendingOpenAt(i);
         continue;
      }

      datetime nowt = TimeCurrent();
      if(g_pending_open_last_try[i] > 0 && (nowt - g_pending_open_last_try[i]) < 3)
         continue;

      g_pending_open_last_try[i] = nowt;
      g_pending_open_attempts[i]++;
      LogCSV("OPEN_RETRY;"+id+";attempt="+IntegerToString(g_pending_open_attempts[i]));
      HandleOpen(g_pending_open_raw[i]);

      if(FindId(id) >= 0 && FindPendingOpen(id) >= 0){
         CancelPendingOpenById(id, "retry_success");
      }
   }
}

//==== PYTHON GUARDRAIL RECEIVERS ====
void HandlePauseEntries(const string js)
{
   g_python_paused = true;
   string reason = JGetStr(js, "reason");
   string resume = JGetStr(js, "resume_after");
   g_python_pause_until = 0;
   if(resume != ""){
      string rts = resume;
      StringReplace(rts, "T", " ");
      int z = StringFind(rts, "Z");
      if(z >= 0) rts = StringSubstr(rts, 0, z);
      g_python_pause_until = StringToTime(rts);
   }
   LogCSV("PYTHON_PAUSE_ENTRIES;reason="+reason+";resume_after="+resume);
   Notify("PHANTOM PAUSE", "Python paused new entries: "+reason+". Resumes: "+resume);
}

void HandleResumeEntries(const string js)
{
   string reason = JGetStr(js, "reason");
   bool changed = false;

   if(g_python_paused){
      g_python_paused = false;
      g_python_pause_until = 0;
      changed = true;
   }

   // Manual resume from either daemon master control or chart UI should
   // restart bridge entry flow without requiring input toggles.
   if(reason == "manual_master_resume" || reason == "manual_chart_resume"){
      if(g_disabled_perm){
         g_disabled_perm = false;
         g_peak_equity = AccountInfoDouble(ACCOUNT_EQUITY);
         LogCSV("MANUAL_RESUME_CLEAR_HARD_PAUSE;peak="+DoubleToString(g_peak_equity,2));
         changed = true;
      }
      if(g_halted_today){
         g_halted_today = false;
         g_halt_serverday = 0;
         LogCSV("MANUAL_RESUME_CLEAR_DAILY_HALT");
         changed = true;
      }
      SaveState();
   }

   LogCSV("PYTHON_RESUME_ENTRIES;reason="+reason);
   if(changed)
      Notify("PHANTOM RESUME", "Python resumed entries: "+reason);
}

void MaybeAutoResumePythonPause()
{
   if(!g_python_paused) return;
   if(g_python_pause_until <= 0) return;

   datetime nowt = TimeCurrent();
   if(nowt < g_python_pause_until) return;

   g_python_paused = false;
   LogCSV("PYTHON_RESUME_AUTO;reason=resume_after_elapsed;resume_at="+
          TimeToString(g_python_pause_until, TIME_DATE|TIME_SECONDS));
   Notify("PHANTOM RESUME", "Auto-resumed entries at resume_after schedule.");
   g_python_pause_until = 0;
}

void HandleHardStop(const string js)
{
   string reason = JGetStr(js, "reason");
   FlattenAll("PYTHON_HARD_STOP:"+reason);
   g_disabled_perm = true;
   g_python_paused  = true;
   SaveState();
   LogCSV("PYTHON_HARD_STOP;reason="+reason);
   Notify("PHANTOM HARD STOP", "Python hard_stop received: "+reason+
          ". All positions flattened & EA hard-paused.");
}

void HandleFlattenAll(const string js)
{
   string reason = JGetStr(js, "reason");
   if(reason == "") reason = "manual_flatten";
   FlattenAll("FLATTEN_ALL:"+reason);
   LogCSV("FLATTEN_ALL;reason="+reason);
   Notify("PHANTOM FLATTEN", "Flatten-all received: "+reason+
          ". All bridge-managed positions closed.");
}

//==== LINE DISPATCH ====
void ProcessLine(const string raw)
{
   string js=raw;
   StringTrimLeft(js);
   StringTrimRight(js);
   if(StringLen(js)<2) return;

   string action=JGetStr(js,"action");
   if(action=="meta")           HandleMeta(js);
   else if(action=="open")      HandleOpen(js);
   else if(action=="modify")    HandleModify(js);
   else if(action=="close")     HandleClose(js);
   else if(action=="heartbeat")      { /* liveness only */ }
   else if(action=="pause_entries")  HandlePauseEntries(js);
   else if(action=="resume_entries") HandleResumeEntries(js);
   else if(action=="hard_stop")      HandleHardStop(js);
   else if(action=="flatten_all")    HandleFlattenAll(js);
}

//==== FILE READ ====
void PumpFileLive(const string source)
{
   long start_pos = (long)g_filepos;
   int act_meta = 0;
   int act_open = 0;
   int act_modify = 0;
   int act_close = 0;
   int act_heartbeat = 0;
   int act_pause = 0;
   int act_resume = 0;
   int act_hard_stop = 0;
   int act_flatten = 0;
   int act_other = 0;
   ResetLastError();
   int h=FileOpen(InpSignalFile, FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h==INVALID_HANDLE){
      int err = GetLastError();
      PrintFormat("PhantomBridge live poll miss | source=%s file=%s start=%d err=%d", source, InpSignalFile, start_pos, err);
      return;
   }

   // If daemon rotated/rebuilt a shorter file, clamp stale saved cursor.
   FileSeek(h,0,SEEK_END);
   long eof_pos = (long)FileTell(h);
   if((long)g_filepos > eof_pos){
      g_filepos = (ulong)eof_pos;
      LogCSV("FILEPOS_CLAMP;source="+source+
             ";file="+InpSignalFile+
             ";old_start="+IntegerToString(start_pos)+
             ";new_start="+IntegerToString((long)g_filepos)+
             ";eof="+IntegerToString(eof_pos));
      SaveState();
      start_pos = (long)g_filepos;
   }

   FileSeek(h,(long)g_filepos,SEEK_SET);
   int lines_read = 0;
   int lines_processed = 0;
   while(!FileIsEnding(h)){
      string line=FileReadString(h);
      if(StringLen(line)>0){
         lines_read++;
         string action = JGetStr(line, "action");
         if(action == "meta") act_meta++;
         else if(action == "open") act_open++;
         else if(action == "modify") act_modify++;
         else if(action == "close") act_close++;
         else if(action == "heartbeat") act_heartbeat++;
         else if(action == "pause_entries") act_pause++;
         else if(action == "resume_entries") act_resume++;
         else if(action == "hard_stop") act_hard_stop++;
         else if(action == "flatten_all") act_flatten++;
         else act_other++;
         ProcessLine(line);
         lines_processed++;
      }
   }
   g_filepos=(ulong)FileTell(h);
   long end_pos = (long)g_filepos;
   FileClose(h);
   SaveState();

   if(lines_read > 0){
      g_last_signal_progress = TimeCurrent();
      g_stale_cursor_alerted = false;
   }

   RetryPendingOpens();
   RetryPendingActions();

   LogCSV("FILE_POLL;source="+source+
          ";file="+InpSignalFile+
          ";start="+IntegerToString(start_pos)+
          ";end="+IntegerToString(end_pos)+
          ";lines="+IntegerToString(lines_read)+
          ";processed="+IntegerToString(lines_processed));
   PrintFormat("PhantomBridge live poll | source=%s file=%s start=%d end=%d lines=%d processed=%d",
               source, InpSignalFile, start_pos, end_pos, lines_read, lines_processed);

   if(lines_read > 0){
      string action_mix =
         "meta="+IntegerToString(act_meta)+
         ",open="+IntegerToString(act_open)+
         ",modify="+IntegerToString(act_modify)+
         ",close="+IntegerToString(act_close)+
         ",heartbeat="+IntegerToString(act_heartbeat)+
         ",pause="+IntegerToString(act_pause)+
         ",resume="+IntegerToString(act_resume)+
         ",hard_stop="+IntegerToString(act_hard_stop)+
         ",flatten="+IntegerToString(act_flatten)+
         ",other="+IntegerToString(act_other);

      PrintFormat("PhantomBridge signal update | source=%s cursor=%d->%d +%d line(s) [%s]",
                  source, start_pos, end_pos, lines_read, action_mix);
   }

   if(lines_read == 0 && InpStaleCursorMinutes > 0 && IsLikelyMarketActive() && AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) && PositionsTotal() > 0){
      if(g_last_signal_progress > 0 && (TimeCurrent() - g_last_signal_progress) >= (InpStaleCursorMinutes * 60) && !g_stale_cursor_alerted){
         g_stale_cursor_alerted = true;
         LogCSV("STALE_CURSOR_ALERT;file="+InpSignalFile+
                ";idle_min="+IntegerToString(InpStaleCursorMinutes)+
                ";open_total="+IntegerToString(PositionsTotal()));
         Notify("PHANTOM HEARTBEAT ALERT", "Heartbeat has not advanced for " + IntegerToString(InpStaleCursorMinutes) + " minutes while the market appears active. Check the writer/daemon before relying on new signals.");
      }
   }
}

void PrimeLiveFilePos()
{
   if(InpReplayMode) return;
   if(!InpLiveSkipHistoryOnFreshAttach) return;
   if(g_filepos > 0) return;

   ResetLastError();
   int h = FileOpen(InpSignalFile, FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h == INVALID_HANDLE){
      int err = GetLastError();
      PrintFormat("PhantomBridge live prime miss | file=%s err=%d", InpSignalFile, err);
      return;
   }

   FileSeek(h, 0, SEEK_END);
   g_filepos = (ulong)FileTell(h);
   FileClose(h);

   LogCSV("LIVE_PRIME_EOF;file="+InpSignalFile+
          ";filepos="+IntegerToString((long)g_filepos));
   PrintFormat("PhantomBridge live prime | file=%s filepos=%d", InpSignalFile, (long)g_filepos);
}

//==== EVENTS ====
int OnInit()
{
   bool in_tester = (bool)MQLInfoInteger(MQL_TESTER);

   g_symbol = (InpSymbolOverride!="") ? InpSymbolOverride : _Symbol;
   if(!SymbolSelect(g_symbol,true)){
      string alts[]={"NAS100","USTEC","USTECH","US100.cash","NAS100.cash","ND100m","ND100M","US100"};
      for(int i=0;i<ArraySize(alts);i++){
         if(SymbolSelect(alts[i],true)){
            g_symbol=alts[i];
            break;
         }
      }
   }

   g_digits=(int)SymbolInfoInteger(g_symbol,SYMBOL_DIGITS);
   g_point =SymbolInfoDouble(g_symbol,SYMBOL_POINT);
   g_volstep=SymbolInfoDouble(g_symbol,SYMBOL_VOLUME_STEP);
   g_volmin =SymbolInfoDouble(g_symbol,SYMBOL_VOLUME_MIN);
   g_volmax =SymbolInfoDouble(g_symbol,SYMBOL_VOLUME_MAX);
   g_stopslevel=(int)SymbolInfoInteger(g_symbol,SYMBOL_TRADE_STOPS_LEVEL);

   // [CASH-1] No DetectMode() — always CASH
   g_mode=BROKER_CASH;
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetTypeFillingBySymbol(g_symbol);

   g_current_day=ServerDay();
   g_day_start_equity=AccountInfoDouble(ACCOUNT_EQUITY);
   g_day_start_balance=AccountInfoDouble(ACCOUNT_BALANCE);
   g_last_balance=AccountInfoDouble(ACCOUNT_BALANCE);

   // --- account baseline + per-login state --- [CASH-10]
   g_login = AccountInfoInteger(ACCOUNT_LOGIN);
   g_state_file = "phantom_state_"+IntegerToString(g_login)+".json";
   g_pending_open_file = "phantom_pending_open_"+IntegerToString(g_login)+".jsonl";
   g_pending_action_file = "phantom_pending_action_"+IntegerToString(g_login)+".jsonl";
   if(in_tester){
      g_state_file = "";
      g_pending_open_file = "";
      g_pending_action_file = "";
      g_disabled_perm = false;
      g_halted_today = false;
   }
   g_start_cap = (InpStartCapOverride>0.0) ? InpStartCapOverride : 0.0;
   g_peak_equity = AccountInfoDouble(ACCOUNT_EQUITY);
   LoadState();
   if(g_start_cap<=0.0) g_start_cap = AccountInfoDouble(ACCOUNT_BALANCE);
   if(g_peak_equity<=0.0) g_peak_equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(in_tester){
      g_disabled_perm = false;
      g_halted_today = false;
   }

   // manual resume after a trailing-floor hard pause
   if(g_disabled_perm && InpManualResume){
      g_disabled_perm=false;
      g_peak_equity=AccountInfoDouble(ACCOUNT_EQUITY); // re-anchor high-water mark on resume
      Notify("PHANTOM CASH resumed","Manual resume flag set. Hard-pause cleared; peak re-anchored at "+
             DoubleToString(g_peak_equity,2)+".");
   }

   PrimeLiveFilePos();
   SaveState();
   g_last_signal_progress = TimeCurrent();
   g_stale_cursor_alerted = false;

   g_replay_loaded = false;
   g_replay_next = 0;
   ArrayResize(g_ids, 0);
   ArrayResize(g_tickets, 0);
   ArrayResize(g_last_sl, 0);
   ArrayResize(g_replay_raw, 0);
   ArrayResize(g_replay_ts, 0);
   ArrayResize(g_open_once_ids, 0);
   ArrayResize(g_sig_entry, 0);
   ArrayResize(g_sig_qty, 0);
   ArrayResize(g_sig_dir, 0);
   ArrayResize(g_open_server_ts, 0);
   ArrayResize(g_open_fill, 0);
   ArrayResize(g_pending_ids, 0);
   ArrayResize(g_pending_tickets, 0);
   ArrayResize(g_pending_tp, 0);
   ArrayResize(g_pending_sl, 0);
   ArrayResize(g_pending_dir, 0);
   ArrayResize(g_pending_expiry, 0);
   ArrayResize(g_deferred_mod_ids, 0);
   ArrayResize(g_deferred_mod_sl, 0);
   ArrayResize(g_pending_action_ids, 0);
   ArrayResize(g_pending_action_kind, 0);
   ArrayResize(g_pending_action_raw, 0);
   ArrayResize(g_pending_action_attempts, 0);
   ArrayResize(g_pending_action_first_ts, 0);
   ArrayResize(g_pending_action_last_try, 0);

   LoadPendingOpenQueue();
   LoadPendingActionQueue();

   g_synth_net = 0.0;
   g_synth_trades = 0;
   g_synth_wins = 0;

   RebuildMapsFromOpenPositions();
   RetryPendingActions();

   // [CASH-3/6] Init risk summary — daily off balance, max-loss trailing off peak
   double init_daily_amount = g_day_start_balance * (InpDailyLossPct/100.0);
   double init_daily_floor  = g_day_start_balance - init_daily_amount;
   double init_max_floor    = g_peak_equity * (1.0 - InpCashTrailMaxLossPct/100.0);

   PrintFormat("PhantomBridge CASH init | symbol=%s digits=%d step=%.2f stops=%d mode=CASH replay=%s",
               g_symbol,g_digits,g_volstep,g_stopslevel,
               (InpReplayMode?"true":"false"));
   PrintFormat("PHANTOM_RISK_INIT | mode=CASH start_cap=%.2f daily_floor=%.2f max_floor=%.2f day_start_balance=%.2f peak_equity=%.2f",
       g_start_cap, init_daily_floor, init_max_floor, g_day_start_balance, g_peak_equity);
   LogCSV("RISK_INIT;mode=CASH"+
      ";start_cap="+DoubleToString(g_start_cap,2)+
      ";daily_floor="+DoubleToString(init_daily_floor,2)+
      ";max_floor="+DoubleToString(init_max_floor,2)+
      ";day_start_balance="+DoubleToString(g_day_start_balance,2)+
      ";peak_equity="+DoubleToString(g_peak_equity,2));

   LogCSV("INIT;symbol="+g_symbol+";mode=CASH");
   LogCSV("TICKINFO;tv="+DoubleToString(SymbolInfoDouble(g_symbol,SYMBOL_TRADE_TICK_VALUE),5)+
          ";ts="+DoubleToString(SymbolInfoDouble(g_symbol,SYMBOL_TRADE_TICK_SIZE),5)+
          ";csize="+DoubleToString(SymbolInfoDouble(g_symbol,SYMBOL_TRADE_CONTRACT_SIZE),2));
      PrintFormat("PhantomBridge signal target | file=%s mode=%s filepos=%d",
          InpSignalFile,
          (InpReplayMode?"replay":"live"),
          (long)g_filepos);
      LogCSV("SIGNAL_TARGET;file="+InpSignalFile+
         ";mode="+(InpReplayMode?"replay":"live")+
         ";filepos="+IntegerToString((long)g_filepos));
   StampModelMode();

   if(!InpReplayMode){
      EventSetTimer(5);
      PrintFormat("PhantomBridge live polling armed | signal_file=%s timer=5s", InpSignalFile);
   }
   return INIT_SUCCEEDED;
}

void OnTick()
{
   MaybeAutoResumePythonPause();
   ProcessPendingReplayTpCloses();

   datetime bt=iTime(g_symbol,PERIOD_M5,0);
   if(bt==g_last_bar) return;
   g_last_bar=bt;

   DetectStraddles(bt);

   // [CASH-1] Always run ResetDayIfNeeded for CASH mode
   ResetDayIfNeeded();
   if(InpReplayMode){
      ReplayDueEvents(bt);
   }
   else {
      PumpFileLive("OnTick");
      ReconcileBridgeState();
   }
}

void OnTimer()
{
   if(!InpReplayMode){
      MaybeAutoResumePythonPause();
      PumpFileLive("OnTimer");
      ReconcileBridgeState();
   }
}

//==== WITHDRAWAL DETECTION ==== [CASH-5]
// A balance-reducing BALANCE deal (manual withdrawal) should not be treated as
// strategy drawdown; re-anchor peak equity downward by withdrawn amount.
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(!HistoryDealSelect(trans.deal)) return;

   long dtype = HistoryDealGetInteger(trans.deal, DEAL_TYPE);
   if(dtype != DEAL_TYPE_BALANCE) return;

   double amt = HistoryDealGetDouble(trans.deal, DEAL_PROFIT);
   if(amt >= 0.0) return;  // deposit, not withdrawal

   double withdrawal = -amt;
   double eq_now = AccountInfoDouble(ACCOUNT_EQUITY);

   // [CASH-5] Move the high-water mark down by the withdrawal amount, but never
   // below current equity so the trailing floor remains coherent after re-basing.
   g_peak_equity = MathMax(eq_now, g_peak_equity - withdrawal);
   g_last_balance = AccountInfoDouble(ACCOUNT_BALANCE);

   LogCSV("WITHDRAWAL_REANCHOR;amt="+DoubleToString(withdrawal,2)+
          ";peak_equity="+DoubleToString(g_peak_equity,2)+
          ";equity="+DoubleToString(eq_now,2));
   SaveState();
}

void OnDeinit(const int reason)
{
   if(!InpReplayMode){
      EventKillTimer();
   }
   if(InpReplayMode && InpReplayUseSignalPricing){
      LogCSV("SYNTH_SUMMARY;trades="+IntegerToString(g_synth_trades)+
             ";wins="+IntegerToString(g_synth_wins)+
             ";net="+DoubleToString(g_synth_net,2));
   }
   LogCSV("DEINIT;reason="+IntegerToString(reason));
}
