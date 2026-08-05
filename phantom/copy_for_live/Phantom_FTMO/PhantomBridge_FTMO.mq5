//+------------------------------------------------------------------+
//|  PhantomBridge_FTMO.mq5                                           |
//|  PHANTOM FTMO prop-account signal bridge                          |
//|  Copyright 2025-2026, Phantom Trading Systems                     |
//+------------------------------------------------------------------+
//|  PURPOSE                                                          |
//|    Reads newline-delimited JSON signals written by the Python     |
//|    PHANTOM engine (signals_vantage_live.jsonl in MT5              |
//|    Common\Files by default) and mirrors them on a LIVE FTMO       |
//|    challenge / funded account with FTMO-specific guardrails.      |
//|    This is a LIVE-ONLY build (no replay/backtest mode).           |
//|                                                                   |
//|  SIGNAL ACTIONS HANDLED                                           |
//|    meta      - captures signal_account_size (log only)            |
//|    open      - opens a market position (buy or sell)              |
//|    modify    - updates stop-loss (breakeven / trailing)           |
//|    close     - closes position at market (stop, tp, or forced)    |
//|    heartbeat - file-liveness ping; no trade action taken          |
//|    pause_entries  - Python soft-pause: blocks new opens           |
//|    resume_entries - clears Python pause; can clear manual halts    |
//|    hard_stop      - flatten all + hard disable via Python          |
//|    flatten_all    - immediate flatten command from Python          |
//|                                                                   |
//|  FTMO KEY BEHAVIOURS                                              |
//|    [FTMO-1]  Absolute total loss floor.                           |
//|              g_ftmo_total_floor = InpAccountSize *                |
//|              (1 - InpMaxTotalLossPct/100). This floor NEVER moves  |
//|              (no trailing peak). Breach => flatten + permanent     |
//|              disable until InpManualResume=true.                  |
//|    [FTMO-2]  Absolute daily loss floor on the INITIAL balance.    |
//|              g_ftmo_daily_limit_abs = InpAccountSize *            |
//|              (InpMaxDailyLossPct/100). Measured as realised +      |
//|              floating P&L since the last Prague midnight.          |
//|    [FTMO-3]  Prague CET/CEST auto-detected daily reset.           |
//|              MT5 server time is GMT+3 (fixed). Prague offset is    |
//|              auto-detected (+1 CET winter / +2 CEST summer) using  |
//|              the EU last-Sunday-of-March/October DST rules.        |
//|              Daily counters reset at Prague midnight.             |
//|    [FTMO-4]  Min trading days tracking.                           |
//|              Unique Prague calendar days on which at least one     |
//|              open executed are tracked and persisted (default 4). |
//|    [FTMO-5]  90% buffer triage with partial close + BE.           |
//|              When realised+floating loss hits InpBufferPct% of     |
//|              EITHER the daily OR the total limit, triage fires:    |
//|              close all losers, lock winner profit (partial close   |
//|              allowed) until net recovers, set breakeven on the     |
//|              survivors, and block new opens for the Prague day.    |
//|    [FTMO-6]  Flat risk sizing (no tiered compounding).            |
//|              Lots = InpRiskPerTrade% of current equity per trade,  |
//|              capped by remaining headroom above the total floor.   |
//|    [FTMO-7]  No replay mode - live only.                          |
//|    [FTMO-8]  Per-login state isolation (ftmo variant files).      |
//|              phantom_state_ftmo_<login>.json and the ftmo pending  |
//|              queues keep FTMO state separate from other accounts.  |
//|                                                                   |
//|  STATE FILES (Common\Files)                                       |
//|    signals_vantage_live.jsonl               - signal input        |
//|    phantom_state_ftmo_<login>.json          - FTMO state + cursor  |
//|    phantom_pending_open_ftmo_<login>.jsonl  - durable open retry   |
//|    phantom_pending_action_ftmo_<login>.jsonl- queued modify/close  |
//|    phantom_bridge_ftmo_log.csv              - audit log            |
//+------------------------------------------------------------------+
#property strict
#property description "PHANTOM FTMO bridge - mirrors Python signals with FTMO daily/total floors + 90% buffer triage"

#include <Trade/Trade.mqh>
CTrade trade;

//==== FORWARD DECLARATIONS ====
void   LogCSV(const string line);
void   ProcessLine(const string raw);
void   Notify(const string title, const string body);
double NormalizePrice(const double p);
double NormalizeLots(double lots);
double NormalizeLotsUp(double lots);
int    FindId(const string id);
void   UnmapId(const string id);
void   SaveState();
void   LoadState();
double ComputeLotsForSignal(const string dir,const double entry,const double stop);
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
// FTMO-specific
int      PragueUTCOffset(const datetime server_time);
datetime ServerToPrague(const datetime server_time);
string   PragueDate(const datetime server_time);
void     CheckPragueRollover();
bool     CheckFTMOBuffers();
void     ExecuteTriage(const string trigger_type, const double daily_pnl_before);
void     SetBreakevenStop(const ulong ticket, const string id);
double   GetTotalFloatingPnL();
void     ExecuteFlattenAll(const string why);
void     RegisterTradingDay();
bool     IsTradingDayKnown(const string d);

//==== INPUTS ====
//=== FTMO ACCOUNT ===
input double  InpAccountSize              = 0.0;         // REQUIRED: initial account size (e.g. 70000 or 140000). Refuses to start if 0.
input string  InpAccountCurrency          = "GBP";       // account currency (logging only)

//=== FTMO RULES ===
input double  InpMaxTotalLossPct          = 10.0;        // FTMO max total loss % of InpAccountSize (absolute floor)
input double  InpMaxDailyLossPct          = 5.0;         // FTMO max daily loss % of InpAccountSize (absolute)
input int     InpMinTradingDays           = 4;           // min unique Prague trading days
input double  InpBufferPct                = 90.0;        // triage fires at this % of each limit (90 = 90%)

//=== RISK SIZING ===
input double  InpRiskPerTrade             = 0.5;         // % of current equity risked per trade
input double  InpMaxLotSize               = 2.0;         // hard lot cap
input double  InpMinLotSize               = 0.01;        // hard lot floor

//=== BROKER / SIGNAL ===
input string  InpSymbolOverride           = "US100.cash"; // FTMO instrument
input long    InpMagicNumber              = 920026;       // unique per account/instrument
input string  InpSignalFile               = "signals_vantage_live.jsonl"; // shared signal file in Common\Files
input int     InpMaxSignalAgeMinutes      = 60;           // ignore actions older than this (0=disabled)
input bool    InpLiveSkipHistoryOnFreshAttach = true;     // if state filepos=0, start at EOF (skip old signals)
input bool    InpManualResume             = false;        // TRUE = clear permanent hard-disable and resume

//=== OPERATIONAL ===
input bool    InpNotifyPush               = true;
input bool    InpNotifyEmail              = false;
input bool    InpNotifyAlert              = true;
input int     InpReconcileIntervalSec     = 60;           // periodic live-position reconciliation interval
input int     InpOrphanAlertMinutes       = 15;           // alert if a live ticket stays unmapped this long
input int     InpStaleCursorMinutes       = 15;           // alert if signal file stops advancing while exposed
input int     InpIgnoreInstantEodSeconds  = 180;          // ignore EOD close if within N seconds of open
input double  InpIgnoreInstantEodEntryTolPts = 15.0;      // and close price within N points of entry/fill
input bool    InpStackLimitSameSignalOnly = true;         // enforce stack_max per signal group (entry window)

//=== LOGGING ===
input bool    InpLogToCSV                 = true;
input string  InpLogFile                  = "phantom_bridge_ftmo_log.csv";

//==== SYMBOL STATE ====
string   g_symbol;
int      g_digits;
double   g_point;
double   g_volstep, g_volmin, g_volmax;
int      g_stopslevel;

//==== CURSOR / META ====
ulong    g_filepos     = 0;
bool     g_meta_seen   = false;
double   g_meta_acct   = 0.0;

//==== FTMO FLOORS (computed at OnInit from InpAccountSize) ====
double   g_ftmo_total_floor            = 0.0;   // InpAccountSize * (1 - InpMaxTotalLossPct/100)
double   g_ftmo_daily_limit_abs        = 0.0;   // InpAccountSize * (InpMaxDailyLossPct/100)
double   g_ftmo_daily_buffer_abs       = 0.0;   // g_ftmo_daily_limit_abs * (InpBufferPct/100)
double   g_ftmo_total_buffer_threshold = 0.0;   // g_ftmo_total_floor + g_ftmo_daily_limit_abs*(1 - InpBufferPct/100)

//==== DAILY TRACKING (Prague) ====
double   g_today_realised_pnl = 0.0;    // sum of closed trade P&L since last Prague midnight
double   g_day_start_equity   = 0.0;    // equity snapshot at Prague midnight (reference)
string   g_current_prague_date = "";    // "YYYY-MM-DD" of current Prague calendar day
int      g_prague_offset      = 0;      // last computed Prague UTC offset (+1 / +2)

//==== TRADING DAYS SET (persisted) ====
string   g_trading_days[];              // dynamic array of "YYYY-MM-DD"

//==== TRIAGE STATE ====
bool     g_triage_block_active = false; // blocks new opens for rest of Prague day
string   g_triage_last_trigger = "";    // "daily" / "total" / "daily+total"
datetime g_last_triage_time    = 0;

//==== PERMANENT DISABLE ====
bool     g_disabled_perm  = false;      // total floor breached => hard stop

//==== PYTHON PAUSE ====
bool     g_python_paused  = false;
datetime g_python_pause_until = 0;
int      g_cumulative_losses = 0;

//==== ACCOUNT / STATE FILE ====
long     g_login          = 0;
string   g_state_file     = "";
string   g_pending_open_file = "";
string   g_pending_action_file = "";

//==== signal_id -> position ticket map ====
string   g_ids[];
ulong    g_tickets[];
double   g_last_sl[];
double   g_sig_entry[];
double   g_sig_qty[];
int      g_sig_dir[];
datetime g_open_server_ts[];
double   g_open_fill[];

//==== seen open IDs ====
string   g_open_once_ids[];

//==== Pending OPEN retries (durable across restart) ====
string   g_pending_open_ids[];
string   g_pending_open_raw[];
int      g_pending_open_attempts[];
datetime g_pending_open_first_ts[];
datetime g_pending_open_last_try[];

//==== Deferred modify while waiting for pending open ====
string   g_deferred_mod_ids[];
double   g_deferred_mod_sl[];

//==== Pending modify/close actions persisted across reconnects ====
string   g_pending_action_ids[];
string   g_pending_action_kind[];
string   g_pending_action_raw[];
int      g_pending_action_attempts[];
datetime g_pending_action_first_ts[];
datetime g_pending_action_last_try[];

datetime g_last_reconcile_check = 0;
datetime g_last_signal_progress = 0;
datetime g_unmapped_first_seen  = 0;
bool     g_orphan_alerted       = false;
bool     g_stale_cursor_alerted = false;

//==== JSON (minimal flat parser) — declared early for queue loaders ====
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

//==== PENDING OPEN QUEUE ====
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
   if(g_pending_open_file == "") return;
   int h = FileOpen(g_pending_open_file, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h == INVALID_HANDLE) return;
   for(int i=0; i<ArraySize(g_pending_open_raw); i++)
      FileWrite(h, g_pending_open_raw[i]);
   FileClose(h);
}

void LoadPendingOpenQueue()
{
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

//==== PENDING ACTION QUEUE ====
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
   if(g_pending_action_file == "") return;
   int h = FileOpen(g_pending_action_file, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h == INVALID_HANDLE) return;
   for(int i=0; i<ArraySize(g_pending_action_raw); i++)
      FileWrite(h, g_pending_action_raw[i]);
   FileClose(h);
}

void LoadPendingActionQueue()
{
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

//==== HELPERS: id map ====
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
   PrintFormat("PhantomBridge FTMO map rebuild | mapped=%d open_total=%d", mapped, open_total);
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
   double lo = MathMax(g_volmin, InpMinLotSize);
   double hi = MathMin(g_volmax, InpMaxLotSize);
   lots = MathMax(lots, lo);
   lots = MathMin(lots, hi);
   double steps = MathRound(lots/g_volstep);
   lots = steps*g_volstep;
   if(lots < lo) lots = lo;
   return NormalizeDouble(lots, 2);
}

// Round UP to the nearest volume step (used for partial-close sizing).
double NormalizeLotsUp(double lots)
{
   if(lots<=0) return 0.0;
   if(g_volstep<=0) return NormalizeDouble(lots,2);
   double steps = MathCeil(lots/g_volstep);
   double v = steps*g_volstep;
   if(v < g_volmin) v = g_volmin;
   return NormalizeDouble(v, 2);
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
      PrintFormat("PhantomBridge FTMO STALE SKIP | %s", stale_msg);
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

//==== PRAGUE DST AUTO-DETECTION ==== [FTMO-3]
// MT5 server time is GMT+3 (fixed). Prague is CET (UTC+1) in winter, CEST (UTC+2) in summer.
// EU DST: CEST from last Sunday of March 01:00 UTC to last Sunday of October 01:00 UTC.

// Day-of-month of the last Sunday for a 31-day month (March=3, October=10).
int LastSundayDay(const int year, const int month)
{
   MqlDateTime d;
   d.year = year;
   d.mon  = month;
   d.day  = 31;      // both March and October have 31 days
   d.hour = 12;
   d.min  = 0;
   d.sec  = 0;
   datetime last = StructToTime(d);
   MqlDateTime o;
   TimeToStruct(last, o);
   int dow = o.day_of_week; // 0=Sunday ... 6=Saturday
   return 31 - dow;
}

datetime MakeStamp(const int year,const int month,const int day,const int hour,const int minute)
{
   MqlDateTime d;
   d.year = year;
   d.mon  = month;
   d.day  = day;
   d.hour = hour;
   d.min  = minute;
   d.sec  = 0;
   return StructToTime(d);
}

// Returns the UTC offset for Prague in hours (+1 for CET, +2 for CEST).
int PragueUTCOffset(const datetime server_time)
{
   datetime utc = server_time - 3*3600;   // server is GMT+3
   MqlDateTime u;
   TimeToStruct(utc, u);
   int year = u.year;

   int lsm = LastSundayDay(year, 3);
   int lso = LastSundayDay(year, 10);

   datetime cest_start = MakeStamp(year, 3,  lsm, 1, 0);   // 01:00 UTC last Sun March
   datetime cet_start  = MakeStamp(year, 10, lso, 1, 0);   // 01:00 UTC last Sun October

   if(utc >= cest_start && utc < cet_start) return 2;      // CEST
   return 1;                                               // CET
}

// Returns Prague datetime from server time.
datetime ServerToPrague(const datetime server_time)
{
   int offset = PragueUTCOffset(server_time);
   return server_time - 3*3600 + offset*3600;   // server -> UTC -> Prague
}

// Returns "YYYY-MM-DD" Prague date string.
string PragueDate(const datetime server_time)
{
   datetime prague = ServerToPrague(server_time);
   MqlDateTime d;
   TimeToStruct(prague, d);
   string mm = (d.mon < 10 ? "0" : "") + IntegerToString(d.mon);
   string dd = (d.day < 10 ? "0" : "") + IntegerToString(d.day);
   return IntegerToString(d.year) + "-" + mm + "-" + dd;
}

//==== TRADING DAYS SET ==== [FTMO-4]
bool IsTradingDayKnown(const string d)
{
   for(int i=0;i<ArraySize(g_trading_days);i++)
      if(g_trading_days[i]==d) return true;
   return false;
}

void RegisterTradingDay()
{
   string d = PragueDate(TimeCurrent());
   if(!IsTradingDayKnown(d)){
      int n = ArraySize(g_trading_days);
      ArrayResize(g_trading_days, n+1);
      g_trading_days[n] = d;
      LogCSV("FTMO_TRADING_DAY_REGISTERED | date="+d+" total_days="+IntegerToString(n+1));
      SaveState();
   }
   LogCSV("FTMO_TRADING_DAYS_COUNT | count="+IntegerToString(ArraySize(g_trading_days))+
          " required="+IntegerToString(InpMinTradingDays));
}

//==== STATE PERSISTENCE (per-login, JSON) ==== [FTMO-8]
void SaveState()
{
   if(g_state_file=="") return;
   int h=FileOpen(g_state_file, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h==INVALID_HANDLE) return;

   // build trading_days JSON array
   string days = "[";
   for(int i=0;i<ArraySize(g_trading_days);i++){
      if(i>0) days += ",";
      days += "\""+g_trading_days[i]+"\"";
   }
   days += "]";

   string js="{\"login\":"+IntegerToString(g_login)+
             ",\"account_size_initial\":"+DoubleToString(InpAccountSize,2)+
             ",\"total_floor\":"+DoubleToString(g_ftmo_total_floor,2)+
             ",\"daily_limit_abs\":"+DoubleToString(g_ftmo_daily_limit_abs,2)+
             ",\"today_realised_pnl\":"+DoubleToString(g_today_realised_pnl,2)+
             ",\"current_prague_date\":\""+g_current_prague_date+"\""+
             ",\"trading_days\":"+days+
             ",\"triage_block_active\":"+(g_triage_block_active?"1":"0")+
             ",\"triage_last_trigger\":\""+g_triage_last_trigger+"\""+
             ",\"disabled_perm\":"+(g_disabled_perm?"1":"0")+
             ",\"filepos\":"+IntegerToString((long)g_filepos)+
             ",\"last_heartbeat_ts\":\""+TimeToString(TimeCurrent(),TIME_DATE|TIME_SECONDS)+"\"}";
   FileWrite(h, js);
   FileClose(h);
}

// Parse the "trading_days" JSON array out of the raw state string.
void ParseTradingDays(const string js)
{
   ArrayResize(g_trading_days, 0);
   int k = StringFind(js, "\"trading_days\"");
   if(k < 0) return;
   int lb = StringFind(js, "[", k);
   if(lb < 0) return;
   int rb = StringFind(js, "]", lb);
   if(rb < 0) return;
   string inner = StringSubstr(js, lb+1, rb-lb-1);
   int pos = 0;
   while(true){
      int q1 = StringFind(inner, "\"", pos);
      if(q1 < 0) break;
      int q2 = StringFind(inner, "\"", q1+1);
      if(q2 < 0) break;
      string d = StringSubstr(inner, q1+1, q2-q1-1);
      if(StringLen(d) >= 8){
         int n = ArraySize(g_trading_days);
         ArrayResize(g_trading_days, n+1);
         g_trading_days[n] = d;
      }
      pos = q2+1;
   }
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

   g_today_realised_pnl = JGetNum(js,"today_realised_pnl",0.0);
   string cpd = JGetStr(js,"current_prague_date");
   if(cpd != "") g_current_prague_date = cpd;
   ParseTradingDays(js);
   g_triage_block_active = (JGetNum(js,"triage_block_active",0.0) >= 0.5);
   string tlt = JGetStr(js,"triage_last_trigger");
   if(tlt != "") g_triage_last_trigger = tlt;
   g_disabled_perm = (JGetNum(js,"disabled_perm",0.0) >= 0.5);
   double fp = JGetNum(js,"filepos",0.0);
   if(fp>0.0) g_filepos=(ulong)fp;

   LogCSV("STATE_LOADED;today_realised="+DoubleToString(g_today_realised_pnl,2)+
          ";prague_date="+g_current_prague_date+
          ";trading_days="+IntegerToString(ArraySize(g_trading_days))+
          ";triage_block="+(g_triage_block_active?"1":"0")+
          ";disabled_perm="+(g_disabled_perm?"1":"0")+
          ";filepos="+IntegerToString((long)g_filepos));
}

//==== FLATTEN ====
void FlattenAll(const string why)
{
   for(int i=PositionsTotal()-1;i>=0;i--){
      ulong tk=PositionGetTicket(i);
      if(tk==0) continue;
      if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetInteger(POSITION_MAGIC)!=InpMagicNumber) continue;
      if(PositionGetString(POSITION_SYMBOL)!=g_symbol) continue;
      trade.PositionClose(tk);
   }
   LogCSV("FLATTEN;"+why);
}

void ExecuteFlattenAll(const string why)
{
   FlattenAll(why);
}

//==== TOTAL FLOATING P&L ACROSS MANAGED POSITIONS ====
double GetTotalFloatingPnL()
{
   double total = 0.0;
   for(int i = 0; i < PositionsTotal(); i++){
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      total += PositionGetDouble(POSITION_PROFIT)
             + PositionGetDouble(POSITION_SWAP);
   }
   return total;
}

//==== PRAGUE DAY ROLLOVER ==== [FTMO-3]
void CheckPragueRollover()
{
   datetime nowt = TimeCurrent();

   // DST transition detection (once per rollover check)
   int off = PragueUTCOffset(nowt);
   if(g_prague_offset != 0 && off != g_prague_offset){
      LogCSV("FTMO_DST_CHANGE | old_offset=+"+IntegerToString(g_prague_offset)+
             " new_offset=+"+IntegerToString(off)+
             " prague_time="+TimeToString(ServerToPrague(nowt), TIME_DATE|TIME_SECONDS));
   }
   g_prague_offset = off;

   string prague_today = PragueDate(nowt);
   if(prague_today != g_current_prague_date){
      g_today_realised_pnl  = 0.0;
      g_day_start_equity    = AccountInfoDouble(ACCOUNT_EQUITY);
      g_triage_block_active = false;
      g_triage_last_trigger = "";
      g_current_prague_date = prague_today;
      LogCSV("FTMO_DAY_ROLLOVER | date="+prague_today+
             " equity="+DoubleToString(g_day_start_equity,2)+
             " prague_offset=+"+IntegerToString(off));
      SaveState();
   }
}

//==== BREAKEVEN STOP ==== [FTMO-5]
void SetBreakevenStop(const ulong ticket, const string id)
{
   if(!PositionSelectByTicket(ticket)) return;
   double entry = PositionGetDouble(POSITION_PRICE_OPEN);
   double current_sl = PositionGetDouble(POSITION_SL);
   double tp = PositionGetDouble(POSITION_TP);
   ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   double be_sl = NormalizePrice(entry);

   // Only move SL toward BE (never worsen the existing protection).
   if(ptype == POSITION_TYPE_BUY  && current_sl >= be_sl)                 return; // already >= BE
   if(ptype == POSITION_TYPE_SELL && current_sl > 0 && current_sl <= be_sl) return; // already <= BE

   // Respect broker minimum stop distance relative to current market.
   double ref = (ptype == POSITION_TYPE_BUY) ? SymbolInfoDouble(g_symbol,SYMBOL_BID)
                                             : SymbolInfoDouble(g_symbol,SYMBOL_ASK);
   double minDist = MinStopDistance();
   bool ok_side = (ptype == POSITION_TYPE_BUY) ? (be_sl < ref - minDist)
                                               : (be_sl > ref + minDist);
   if(!ok_side){
      LogCSV("TRIAGE_BE_SKIP | ticket="+IntegerToString((long)ticket)+" id="+id+
             ";reason=be_too_close_to_market;entry="+DoubleToString(entry,g_digits)+
             ";ref="+DoubleToString(ref,g_digits));
      return;
   }

   if(trade.PositionModify(ticket, be_sl, tp)){
      LogCSV("TRIAGE_BE_SET | ticket="+IntegerToString((long)ticket)+" id="+id+
             " entry="+DoubleToString(entry,g_digits));
   }
   else {
      LogCSV("TRIAGE_BE_FAIL | ticket="+IntegerToString((long)ticket)+" id="+id+
             ";ret="+IntegerToString((int)trade.ResultRetcode()));
   }
}

//==== TRIAGE EXECUTION ==== [FTMO-5]
void ExecuteTriage(const string trigger_type, const double daily_pnl_before)
{
   // Step 1: Collect all managed positions.
   ulong  t_ticket[];
   string t_id[];
   double t_float[];
   double t_vol[];
   int    n = 0;

   for(int i=0;i<PositionsTotal();i++){
      ulong tk = PositionGetTicket(i);
      if(tk==0) continue;
      if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      ArrayResize(t_ticket, n+1);
      ArrayResize(t_id, n+1);
      ArrayResize(t_float, n+1);
      ArrayResize(t_vol, n+1);
      t_ticket[n] = tk;
      t_id[n]     = PositionGetString(POSITION_COMMENT);
      t_float[n]  = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      t_vol[n]    = PositionGetDouble(POSITION_VOLUME);
      n++;
   }

   double net_before = g_today_realised_pnl;
   for(int i=0;i<n;i++) net_before += t_float[i];

   // running realised floor used for triage decisions (local; OnTradeTransaction keeps
   // g_today_realised_pnl authoritative to avoid double-counting).
   double R = g_today_realised_pnl;

   int losers_closed  = 0;
   int winners_closed = 0;
   int winners_be     = 0;

   // Step 2/3: Close ALL losers (worst-first).
   // Simple insertion sort of loser indices ascending by float (most negative first).
   int loser_idx[];
   int ln = 0;
   for(int i=0;i<n;i++){
      if(t_float[i] < 0.0){
         ArrayResize(loser_idx, ln+1);
         // insert keeping ascending float order
         int p = ln;
         while(p>0 && t_float[loser_idx[p-1]] > t_float[i]){
            loser_idx[p] = loser_idx[p-1];
            p--;
         }
         loser_idx[p] = i;
         ln++;
      }
   }
   for(int i=0;i<ln;i++){
      int li = loser_idx[i];
      ulong tk = t_ticket[li];
      if(!PositionSelectByTicket(tk)) continue;
      double f = t_float[li];
      if(trade.PositionClose(tk)){
         R += f;
         losers_closed++;
         LogCSV("TRIAGE_CLOSE_LOSING | ticket="+IntegerToString((long)tk)+
                " id="+t_id[li]+" float_pnl="+DoubleToString(f,2));
         UnmapId(t_id[li]);
      }
      else {
         LogCSV("TRIAGE_CLOSE_LOSING_FAIL | ticket="+IntegerToString((long)tk)+
                " id="+t_id[li]+";ret="+IntegerToString((int)trade.ResultRetcode()));
      }
   }

   // Step 4: Build winners list (best-first is not required for locking; we lock
   // smallest-first per spec to preserve larger runners when possible).
   int winner_idx[];
   int wn = 0;
   double winner_float_sum = 0.0;
   for(int i=0;i<n;i++){
      if(t_float[i] > 0.0){
         winner_float_sum += t_float[i];
         ArrayResize(winner_idx, wn+1);
         // insert keeping ascending float order (smallest profit first)
         int p = wn;
         while(p>0 && t_float[winner_idx[p-1]] > t_float[i]){
            winner_idx[p] = winner_idx[p-1];
            p--;
         }
         winner_idx[p] = i;
         wn++;
      }
   }

   double net_after = R + winner_float_sum;

   // Track which winners survive (to BE afterwards).
   bool closed_flag[];
   ArrayResize(closed_flag, wn);
   for(int i=0;i<wn;i++) closed_flag[i]=false;

   if(net_after >= 0.0){
      // Step 5: locked realised + winner floats already non-negative -> just protect winners with BE.
      LogCSV("TRIAGE_NET_OK | net_after="+DoubleToString(net_after,2)+
             ";R="+DoubleToString(R,2)+";winner_float_sum="+DoubleToString(winner_float_sum,2));
   }
   else {
      // Step 6: lock winner profit smallest-first until realised floor R recovers to >= 0.
      for(int i=0;i<wn && R < 0.0;i++){
         int wi = winner_idx[i];
         ulong tk = t_ticket[wi];
         if(!PositionSelectByTicket(tk)) continue;
         double P = t_float[wi];
         double V = t_vol[wi];
         double need = -R;                     // deficit to cover

         if(P <= need){
            // full close does not overshoot -> close entirely
            if(trade.PositionClose(tk)){
               R += P;
               winners_closed++;
               closed_flag[i] = true;
               LogCSV("TRIAGE_CLOSE_WINNER | ticket="+IntegerToString((long)tk)+
                      " id="+t_id[wi]+" float_pnl="+DoubleToString(P,2));
               UnmapId(t_id[wi]);
            }
            else {
               LogCSV("TRIAGE_CLOSE_WINNER_FAIL | ticket="+IntegerToString((long)tk)+
                      " id="+t_id[wi]+";ret="+IntegerToString((int)trade.ResultRetcode()));
            }
         }
         else {
            // full close would overshoot -> partial close to cover deficit, BE the remainder
            double frac = need / P;
            double lots_close = NormalizeLotsUp(V * frac);
            if(lots_close >= V - (g_volstep*0.5)){
               // rounding pushed us to a full close
               if(trade.PositionClose(tk)){
                  R += P;
                  winners_closed++;
                  closed_flag[i] = true;
                  LogCSV("TRIAGE_CLOSE_WINNER | ticket="+IntegerToString((long)tk)+
                         " id="+t_id[wi]+" float_pnl="+DoubleToString(P,2)+";via=partial_rounded_full");
                  UnmapId(t_id[wi]);
               }
            }
            else {
               if(trade.PositionClosePartial(tk, lots_close)){
                  double realised_part = P * (lots_close / V);
                  R += realised_part;
                  double remaining = V - lots_close;
                  LogCSV("TRIAGE_PARTIAL_CLOSE_WINNER | ticket="+IntegerToString((long)tk)+
                         " id="+t_id[wi]+
                         " lots_closed="+DoubleToString(lots_close,2)+
                         " remaining="+DoubleToString(remaining,2)+
                         " realised_part="+DoubleToString(realised_part,2));
                  SetBreakevenStop(tk, t_id[wi]);
                  winners_be++;
                  closed_flag[i] = true; // handled (partial + BE); do not BE again below
               }
               else {
                  LogCSV("TRIAGE_PARTIAL_CLOSE_FAIL | ticket="+IntegerToString((long)tk)+
                         " id="+t_id[wi]+";ret="+IntegerToString((int)trade.ResultRetcode()));
               }
            }
            break; // deficit covered (or attempted) by this single winner
         }
      }
   }

   // Step 5/6 cleanup: set BE on every surviving winner not already handled.
   for(int i=0;i<wn;i++){
      if(closed_flag[i]) continue;
      int wi = winner_idx[i];
      ulong tk = t_ticket[wi];
      if(!PositionSelectByTicket(tk)) continue; // gone
      SetBreakevenStop(tk, t_id[wi]);
      winners_be++;
   }

   // Step 7: block new opens for the rest of the Prague day.
   g_triage_block_active = true;
   g_triage_last_trigger = trigger_type;
   g_last_triage_time    = TimeCurrent();
   LogCSV("TRIAGE_BLOCK_NEW_OPENS | reason="+trigger_type+
          " until_prague_midnight="+g_current_prague_date);

   double net_final = R;
   for(int i=0;i<PositionsTotal();i++){
      ulong tk = PositionGetTicket(i);
      if(tk==0) continue;
      if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      net_final += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }

   // Step 8: summary.
   LogCSV("TRIAGE_SUMMARY | trigger="+trigger_type+
          " losers_closed="+IntegerToString(losers_closed)+
          " winners_closed="+IntegerToString(winners_closed)+
          " winners_be="+IntegerToString(winners_be)+
          " net_pnl_before="+DoubleToString(net_before,2)+
          " net_pnl_after="+DoubleToString(net_final,2));

   Notify("PHANTOM FTMO TRIAGE", "Buffer triage fired ("+trigger_type+
          "). Losers closed="+IntegerToString(losers_closed)+
          ", winners closed="+IntegerToString(winners_closed)+
          ", BE set="+IntegerToString(winners_be)+
          ". New opens blocked until Prague midnight.");

   SaveState();
}

//==== FTMO BUFFER / FLOOR CHECK ==== [FTMO-1/2/5]
// Returns true if a hard stop (permanent disable) fired this cycle.
bool CheckFTMOBuffers()
{
   double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
   double float_pnl = GetTotalFloatingPnL();
   double daily_pnl = g_today_realised_pnl + float_pnl;

   double daily_remaining = g_ftmo_daily_limit_abs - MathAbs(daily_pnl); // <0 means in breach
   double headroom        = equity - g_ftmo_total_floor;

   // Equity status heartbeat (every reconcile / poll cycle).
   LogCSV("FTMO_EQUITY_STATUS | equity="+DoubleToString(equity,2)+
          " daily_pnl="+DoubleToString(daily_pnl,2)+
          " daily_limit=-"+DoubleToString(g_ftmo_daily_limit_abs,2)+
          " daily_remaining="+DoubleToString(daily_remaining,2)+
          " total_floor="+DoubleToString(g_ftmo_total_floor,2)+
          " headroom="+DoubleToString(headroom,2)+
          " days_traded="+IntegerToString(ArraySize(g_trading_days)));

   if(g_disabled_perm) return true;

   // Hard stop: absolute total floor breached (the actual floor, not the buffer).
   if(equity <= g_ftmo_total_floor){
      LogCSV("FTMO_HARD_STOP | equity="+DoubleToString(equity,2)+
             " total_floor="+DoubleToString(g_ftmo_total_floor,2));
      ExecuteFlattenAll("FTMO_HARD_STOP");
      g_disabled_perm = true;
      Notify("PHANTOM FTMO HARD STOP", "Absolute total loss floor breached (equity="+
             DoubleToString(equity,2)+" <= floor="+DoubleToString(g_ftmo_total_floor,2)+
             "). Flattened & permanently disabled until manual resume.");
      SaveState();
      return true;
   }

   bool trigger = false;
   string trigger_type = "";

   // Daily buffer check (realised + floating loss reaches 90% of the daily limit).
   if(daily_pnl <= -(g_ftmo_daily_buffer_abs)){
      trigger = true;
      trigger_type = "daily";
      LogCSV("FTMO_DAILY_BUFFER_TRIGGER | daily_pnl="+DoubleToString(daily_pnl,2)+
             " buffer=-"+DoubleToString(g_ftmo_daily_buffer_abs,2));
   }

   // Total buffer check (equity approaches the absolute total floor).
   if(equity <= g_ftmo_total_buffer_threshold){
      trigger = true;
      trigger_type = (trigger_type == "daily") ? "daily+total" : "total";
      LogCSV("FTMO_TOTAL_BUFFER_TRIGGER | equity="+DoubleToString(equity,2)+
             " threshold="+DoubleToString(g_ftmo_total_buffer_threshold,2));
   }

   if(trigger && !g_triage_block_active){
      ExecuteTriage(trigger_type, daily_pnl);
   }
   return false;
}

//==== LOT SIZING (flat risk model) ==== [FTMO-6]
double ComputeLotsForSignal(const string dir,const double entry,const double stop)
{
   double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
   double risk_amt = equity * (InpRiskPerTrade / 100.0);

   // Cap risk to remaining headroom above the total floor.
   double headroom = equity - g_ftmo_total_floor;
   if(headroom <= 0.0){
      LogCSV("SIZE_BLOCK | reason=below_total_floor;equity="+DoubleToString(equity,2)+
             ";floor="+DoubleToString(g_ftmo_total_floor,2));
      return 0.0;
   }
   risk_amt = MathMin(risk_amt, headroom * 0.5); // never risk more than 50% of remaining headroom

   double stop_dist = MathAbs(entry - stop);
   if(stop_dist <= 0.0 || entry <= 0.0){
      LogCSV("SIZE_FALLBACK_MINLOT | reason=no_stop_distance;entry="+DoubleToString(entry,g_digits)+
             ";stop="+DoubleToString(stop,g_digits));
      return NormalizeLots(InpMinLotSize);
   }

   double tick_val  = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_size = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_SIZE);
   double loss_per_lot;
   if(tick_val>0.0 && tick_size>0.0) loss_per_lot = (stop_dist / tick_size) * tick_val;
   else                              loss_per_lot = stop_dist * SymbolInfoDouble(g_symbol,SYMBOL_TRADE_CONTRACT_SIZE);
   if(loss_per_lot<=0.0) loss_per_lot = stop_dist;

   double lots = risk_amt / loss_per_lot;
   lots = MathMax(InpMinLotSize, MathMin(lots, InpMaxLotSize));
   lots = NormalizeLots(lots);

   LogCSV("SIZE;mode=FTMO_FLAT"+
          ";risk_pct="+DoubleToString(InpRiskPerTrade,2)+
          ";risk_amt="+DoubleToString(risk_amt,2)+
          ";headroom="+DoubleToString(headroom,2)+
          ";loss_per_lot="+DoubleToString(loss_per_lot,2)+
          ";lots="+DoubleToString(lots,2));
   return lots;
}

//==== ACTION HANDLERS ====
void HandleMeta(const string js)
{
   g_meta_seen=true;
   g_meta_acct=JGetNum(js,"signal_account_size",0.0);
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

void HandleOpen(const string js)
{
   string id  = JGetStr(js,"id");
   if(id=="") id = JGetStr(js,"entry_ts");

   if(IsSignalTooOldForLive(js, "OPEN", id))
      return;

   // FTMO gates: triage block and permanent disable take priority.
   if(g_triage_block_active){
      LogCSV("OPEN_BLOCK_TRIAGE | id="+id+" reason=triage_active until="+g_current_prague_date);
      return;
   }
   if(g_disabled_perm){
      LogCSV("OPEN_BLOCK_DISABLED | id="+id+" reason=total_floor_breached");
      return;
   }

   if(g_python_paused){
      LogCSV("OPEN_BLOCKED_PYTHON_PAUSE;"+id);
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
   if(stack_max<=0) stack_max = 3;
   if(stack_max<1)  stack_max = 1;
   if(stack_max>4)  stack_max = 4;

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
   double live_eq = AccountInfoDouble(ACCOUNT_EQUITY);

   // [FTMO-6] Flat-risk EA sizing (signal qty ignored for sizing).
   double lots = ComputeLotsForSignal(dir, entry, stop);
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
   double sl  = ClampStopDistance(price, stop, is_long);
   double tpx = NormalizePrice(tp);

   trade.SetExpertMagicNumber(InpMagicNumber);
   bool ok;
   if(is_long) ok=trade.Buy(lots,g_symbol,0.0,sl,tpx,id);
   else        ok=trade.Sell(lots,g_symbol,0.0,sl,tpx,id);

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
             ";live_eq="+DoubleToString(live_eq,2));

      // [FTMO-4] Register the Prague trading day on a successful open.
      RegisterTradingDay();

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
         string why = ExplainInvalidOpenStops(is_long, price, sl, tpx, minDist);
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
                ";sl="+DoubleToString(sl,g_digits)+
                ";tp="+DoubleToString(tpx,g_digits)+
                ";minDist="+DoubleToString(minDist,g_digits));
      }
      else {
         LogCSV("OPEN_FAIL_EXPLAIN;"+id+
                ";why=retcode_"+IntegerToString(rc)+
                ";human="+human_rc);
      }

      if(rc == 10004 || rc == 10020){
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
               RegisterTradingDay();
               CancelPendingOpenById(id, "found_on_retry");
               return;
            }

            price = is_long ? SymbolInfoDouble(g_symbol, SYMBOL_ASK)
                            : SymbolInfoDouble(g_symbol, SYMBOL_BID);
            sl = ClampStopDistance(price, stop, is_long);

            if(is_long) ok = trade.Buy(lots, g_symbol, 0.0, sl, tpx, id);
            else        ok = trade.Sell(lots, g_symbol, 0.0, sl, tpx, id);

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
                    ";tp="+DoubleToString(tpx,g_digits));
               RegisterTradingDay();
               RetryPendingActions();
               CancelPendingOpenById(id, "retry_success");
               return;
            }
            if(rc != 10004 && rc != 10020) break;
         }
      }

      if(IsTransientOpenRetcode(rc)){
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

   ulong tk=g_tickets[idx];
   if(!PositionSelectByTicket(tk)){
      LogCSV("CLOSE_ALREADY;"+id);
      UnmapId(id);
      return;
   }

   double pnl_live = PositionGetDouble(POSITION_PROFIT);

   if(trade.PositionClose(tk)){
      LogCSV("CLOSE;"+id+";fill="+DoubleToString(trade.ResultPrice(),g_digits));
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

void RetryPendingActions()
{
   if(ArraySize(g_pending_action_ids) <= 0) return;
   datetime nowt = TimeCurrent();
   for(int i=ArraySize(g_pending_action_ids)-1; i>=0; i--){
      string kind = g_pending_action_kind[i];
      string id = g_pending_action_ids[i];
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

void ReconcileBridgeState()
{
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
      for(int i=ArraySize(g_pending_action_ids)-1; i>=0; i--){
         LogCSV("DROP_STALE_PENDING;"+g_pending_action_kind[i]+";"+g_pending_action_ids[i]+
                ";reason=reconcile_clear_no_live_positions");
         RemovePendingActionAt(i);
      }
      g_unmapped_first_seen = 0;
      g_orphan_alerted = false;
      g_stale_cursor_alerted = false;
      CheckFTMOBuffers();
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
         g_unmapped_first_seen = 0;
         g_orphan_alerted = false;
      }
   }
   else {
      g_unmapped_first_seen = 0;
      g_orphan_alerted = false;
   }

   RetryPendingActions();

   // [FTMO-1/2/5] Evaluate floors/buffers after maps are consistent.
   CheckFTMOBuffers();
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

   // Manual resume clears the FTMO permanent hard-disable.
   if(reason == "manual_master_resume" || reason == "manual_chart_resume"){
      if(g_disabled_perm){
         g_disabled_perm = false;
         LogCSV("MANUAL_RESUME_CLEAR_HARD_DISABLE");
         changed = true;
      }
      if(g_triage_block_active){
         g_triage_block_active = false;
         g_triage_last_trigger = "";
         LogCSV("MANUAL_RESUME_CLEAR_TRIAGE_BLOCK");
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
   int act_meta=0, act_open=0, act_modify=0, act_close=0, act_heartbeat=0;
   int act_pause=0, act_resume=0, act_hard_stop=0, act_flatten=0, act_other=0;
   ResetLastError();
   int h=FileOpen(InpSignalFile, FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h==INVALID_HANDLE){
      int err = GetLastError();
      PrintFormat("PhantomBridge FTMO live poll miss | source=%s file=%s start=%d err=%d", source, InpSignalFile, start_pos, err);
      return;
   }

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
      PrintFormat("PhantomBridge FTMO signal update | source=%s cursor=%d->%d +%d line(s) [%s]",
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
   if(!InpLiveSkipHistoryOnFreshAttach) return;
   if(g_filepos > 0) return;
   ResetLastError();
   int h = FileOpen(InpSignalFile, FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h == INVALID_HANDLE){
      int err = GetLastError();
      PrintFormat("PhantomBridge FTMO live prime miss | file=%s err=%d", InpSignalFile, err);
      return;
   }
   FileSeek(h, 0, SEEK_END);
   g_filepos = (ulong)FileTell(h);
   FileClose(h);
   LogCSV("LIVE_PRIME_EOF;file="+InpSignalFile+
          ";filepos="+IntegerToString((long)g_filepos));
   PrintFormat("PhantomBridge FTMO live prime | file=%s filepos=%d", InpSignalFile, (long)g_filepos);
}

//==== EVENTS ====
int OnInit()
{
   // [FTMO] REQUIRED account size — refuse to start otherwise.
   if(InpAccountSize <= 0.0){
      Print("FATAL: InpAccountSize must be set (e.g. 70000 or 140000). Bridge refuses to start.");
      Alert("PhantomBridge FTMO: InpAccountSize is 0. Set the initial account size before attaching.");
      return INIT_FAILED;
   }

   g_symbol = (InpSymbolOverride!="") ? InpSymbolOverride : _Symbol;
   if(!SymbolSelect(g_symbol,true)){
      string alts[]={"US100.cash","US100","NAS100","USTEC","USTECH","NAS100.cash","ND100m","ND100M"};
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

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetTypeFillingBySymbol(g_symbol);

   // --- FTMO floors --- [FTMO-1/2/5]
   g_ftmo_total_floor            = InpAccountSize * (1.0 - InpMaxTotalLossPct/100.0);
   g_ftmo_daily_limit_abs        = InpAccountSize * (InpMaxDailyLossPct/100.0);
   g_ftmo_daily_buffer_abs       = g_ftmo_daily_limit_abs * (InpBufferPct/100.0);
   g_ftmo_total_buffer_threshold = g_ftmo_total_floor + g_ftmo_daily_limit_abs * (1.0 - InpBufferPct/100.0);

   // --- per-login FTMO state files --- [FTMO-8]
   g_login = AccountInfoInteger(ACCOUNT_LOGIN);
   g_state_file = "phantom_state_ftmo_"+IntegerToString(g_login)+".json";
   g_pending_open_file = "phantom_pending_open_ftmo_"+IntegerToString(g_login)+".jsonl";
   g_pending_action_file = "phantom_pending_action_ftmo_"+IntegerToString(g_login)+".jsonl";

   // Prague day + offset
   g_prague_offset = PragueUTCOffset(TimeCurrent());
   g_current_prague_date = PragueDate(TimeCurrent());
   g_day_start_equity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_today_realised_pnl = 0.0;

   ArrayResize(g_trading_days, 0);

   LoadState();

   // manual resume after a permanent hard-disable
   if(g_disabled_perm && InpManualResume){
      g_disabled_perm = false;
      LogCSV("MANUAL_RESUME_CLEAR_HARD_DISABLE_ONINIT");
      Notify("PHANTOM FTMO resumed","Manual resume flag set. Permanent disable cleared.");
   }

   PrimeLiveFilePos();
   SaveState();
   g_last_signal_progress = TimeCurrent();
   g_stale_cursor_alerted = false;

   ArrayResize(g_ids, 0);
   ArrayResize(g_tickets, 0);
   ArrayResize(g_last_sl, 0);
   ArrayResize(g_open_once_ids, 0);
   ArrayResize(g_sig_entry, 0);
   ArrayResize(g_sig_qty, 0);
   ArrayResize(g_sig_dir, 0);
   ArrayResize(g_open_server_ts, 0);
   ArrayResize(g_open_fill, 0);
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

   RebuildMapsFromOpenPositions();
   RetryPendingActions();

   // [FTMO] Init summary line
   LogCSV("FTMO_INIT | account_size="+DoubleToString(InpAccountSize,2)+
          " currency="+InpAccountCurrency+
          " total_floor="+DoubleToString(g_ftmo_total_floor,2)+
          " daily_limit="+DoubleToString(g_ftmo_daily_limit_abs,2)+
          " daily_buffer="+DoubleToString(g_ftmo_daily_buffer_abs,2)+
          " total_buffer_threshold="+DoubleToString(g_ftmo_total_buffer_threshold,2)+
          " min_trading_days="+IntegerToString(InpMinTradingDays)+
          " buffer_pct="+DoubleToString(InpBufferPct,1)+
          " magic="+IntegerToString(InpMagicNumber)+
          " symbol="+g_symbol);

   PrintFormat("PhantomBridge FTMO init | symbol=%s digits=%d step=%.2f stops=%d account_size=%.2f total_floor=%.2f daily_limit=%.2f prague=%s(+%d)",
               g_symbol,g_digits,g_volstep,g_stopslevel,InpAccountSize,
               g_ftmo_total_floor,g_ftmo_daily_limit_abs,g_current_prague_date,g_prague_offset);

   LogCSV("TICKINFO;tv="+DoubleToString(SymbolInfoDouble(g_symbol,SYMBOL_TRADE_TICK_VALUE),5)+
          ";ts="+DoubleToString(SymbolInfoDouble(g_symbol,SYMBOL_TRADE_TICK_SIZE),5)+
          ";csize="+DoubleToString(SymbolInfoDouble(g_symbol,SYMBOL_TRADE_CONTRACT_SIZE),2));
   LogCSV("SIGNAL_TARGET;file="+InpSignalFile+";mode=live;filepos="+IntegerToString((long)g_filepos));

   EventSetTimer(5);
   PrintFormat("PhantomBridge FTMO live polling armed | signal_file=%s timer=5s", InpSignalFile);
   return INIT_SUCCEEDED;
}

void OnTick()
{
   MaybeAutoResumePythonPause();

   // [FTMO-3] Prague rollover, then floor/buffer checks, then poll.
   CheckPragueRollover();
   if(CheckFTMOBuffers()) return; // hard stop this cycle
   PumpFileLive("OnTick");
   ReconcileBridgeState();
}

void OnTimer()
{
   MaybeAutoResumePythonPause();

   // [FTMO-3] Rollover check BEFORE triage; triage BEFORE processing new signal lines.
   CheckPragueRollover();
   if(CheckFTMOBuffers()) return; // hard stop this cycle; skip new signal processing
   PumpFileLive("OnTimer");
   ReconcileBridgeState();
}

//==== REALISED P&L ACCUMULATION ==== [FTMO-2]
// Accumulate closed-trade P&L for managed deals into the Prague-day realised total.
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   if(!HistoryDealSelect(trans.deal)) return;

   long dtype = HistoryDealGetInteger(trans.deal, DEAL_TYPE);
   if(dtype != DEAL_TYPE_BUY && dtype != DEAL_TYPE_SELL) return;

   // Only account for deals on our managed symbol + magic.
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != g_symbol) return;
   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagicNumber) return;

   // Only closing deals carry realised P&L (entry deals have profit 0).
   long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_INOUT && entry != DEAL_ENTRY_OUT_BY) return;

   double realised = HistoryDealGetDouble(trans.deal, DEAL_PROFIT)
                   + HistoryDealGetDouble(trans.deal, DEAL_SWAP)
                   + HistoryDealGetDouble(trans.deal, DEAL_COMMISSION);

   g_today_realised_pnl += realised;

   LogCSV("REALISED_PNL_ACC;deal="+IntegerToString((long)trans.deal)+
          ";amount="+DoubleToString(realised,2)+
          ";today_realised="+DoubleToString(g_today_realised_pnl,2));
   SaveState();
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   LogCSV("DEINIT;reason="+IntegerToString(reason));
}
//+------------------------------------------------------------------+
