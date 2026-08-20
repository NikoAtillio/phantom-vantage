//+------------------------------------------------------------------+
//|  PhantomBridge.mq5                                               |
//|  PHANTOM p2 — CASH account signal bridge                         |
//|  Copyright 2025-2026, Phantom Trading Systems                     |
//+------------------------------------------------------------------+
//|  PURPOSE                                                          |
//|    Reads newline-delimited JSON signals written by the Python     |
//|    PHANTOM p2 engine (phantom_signals.jsonl in MT5 Common\Files)  |
//|    and executes them on a live/demo CASH account.  Supports two   |
//|    run modes:                                                      |
//|      Replay  (InpReplayMode=true)  – bar-by-bar backtest replay   |
//|      Live    (InpReplayMode=false) – real-time file polling        |
//|                                                                    |
//|  SIGNAL ACTIONS HANDLED                                           |
//|    meta      – captures signal_account_size for lot scaling        |
//|    open      – opens a market position (buy or sell)               |
//|    modify    – updates stop-loss (breakeven / trailing)            |
//|    close     – closes position at market (stop, tp, or forced)     |
//|    heartbeat – file-liveness ping; no trade action taken           |
//|                                                                    |
//|  KEY BEHAVIOURS                                                    |
//|    [CASH-1]  Forced BROKER_CASH — no broker auto-detect.           |
//|              FTMO/hybrid mode enum and DetectMode() removed.       |
//|    [CASH-2]  Tiered risk sizing from current equity.               |
//|              Risk % tapers automatically as the account grows:     |
//|              <2x → 3.95%, <4x → 3.10%, <7x → 2.40%,              |
//|              <10x → 1.85%, ≥10x → 1.40% (all configurable).       |
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
//|                                                                    |
//|  SAFETY ADDITIONS (v5.2+)                                         |
//|    [SAFE-1]  Consecutive-loss hard stop.                           |
//|              15 straight losing closes (default) triggers a        |
//|              flatten + permanent disable + push notification.      |
//|    [SAFE-2]  Risk buffer cap in lot sizing.                        |
//|              risk_amt is capped to the remaining equity above      |
//|              the trailing floor; SIZE_BLOCK is logged if the       |
//|              buffer is exhausted and 0.0 lots returned.            |
//|    [SAFE-3]  Peak equity saved on every new high (not just on      |
//|              guardrail events), preventing stale floor on restart. |
//|    [SAFE-4]  Day-start balance refreshed on every server-day       |
//|              rollover, keeping withdrawal detection anchored to     |
//|              the most recent day rather than init time.            |
//|                                                                    |
//|  LOT SIZING MODES (InpUsePythonSizing)                            |
//|    false (default) – EA computes lots via tiered CASH model        |
//|                      using live equity, entry/stop distance,       |
//|                      tick value, and lot cap.                      |
//|    true            – trust signal qty scaled by                    |
//|                      (live_equity / signal_account_size).          |
//|    Replay + InpReplayUseSignalPricing=true – raw signal qty used   |
//|                      directly; synthetic P&L ledger computed.      |
//|                                                                    |
//|  STATE FILES (Common\Files)                                        |
//|    phantom_signals.jsonl         – signal input (Python writer)    |
//|    phantom_state_<login>.json    – peak/cap/disable persistence    |
//|    phantom_bridge_log.csv        – trade + guardrail audit log     |
//+------------------------------------------------------------------+
#property strict
#property description "PHANTOM p2 CASH bridge — reads phantom_signals.jsonl and mirrors Python signals"

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

//==== INPUTS ====
input string  InpSignalFile          = "phantom_signals.jsonl"; // file in Common\Files
input long    InpMagicNumber         = 920025;                  // unique per account/instrument
input string  InpSymbolOverride      = "US100";                // live/demo target symbol
input bool    InpReplayMode          = true;                    // true=backtest replay, false=live polling
input bool    InpReplayUseSignalPricing = false;                 // in replay, use signal qty/entry/exit for parity ledger

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
input double  InpMetaAccountFallback = 5000.0;                  // used only if a signal lacks signal_account_size
input double  InpMaxLots             = 50.0;                    // absolute hard safety cap
input double  InpMinLots             = 0.01;
input bool    InpUsePythonSizing     = false;                    // TRUE = trust signal qty; FALSE = EA computes tiered lots

// --- notifications ---
input bool    InpNotifyPush          = true;
input bool    InpNotifyEmail         = false;
input bool    InpNotifyAlert         = true;

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

// signal_id -> position ticket map
string   g_ids[];
ulong    g_tickets[];
double   g_last_sl[];
double   g_sig_entry[];
double   g_sig_qty[];
int      g_sig_dir[];

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
      g_ids[n]=id;
      g_tickets[n]=ticket;
      g_last_sl[n]=0.0;
      g_sig_entry[n]=0.0;
      g_sig_qty[n]=0.0;
      g_sig_dir[n]=0;
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
   ArrayResize(g_ids,last);
   ArrayResize(g_tickets,last);
   ArrayResize(g_last_sl,last);
   ArrayResize(g_sig_entry,last);
   ArrayResize(g_sig_qty,last);
   ArrayResize(g_sig_dir,last);
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
   if(sc>0.0) g_start_cap=sc;
   if(pk>0.0) g_peak_equity=pk;
   g_disabled_perm = (dp>=0.5);
   LogCSV("STATE_LOADED;start_cap="+DoubleToString(g_start_cap,2)+
          ";peak="+DoubleToString(g_peak_equity,2)+
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
   double max_floor = g_peak_equity * (1.0 - InpCashTrailMaxLossPct/100.0);

   if(eq <= max_floor){
      FlattenAll("MAX_LOSS_TRAILING");
      g_disabled_perm=true;
      g_halt_serverday=ServerDay();
      Notify("PHANTOM CASH DISABLED","Trailing max-loss floor breached (eq="+DoubleToString(eq,2)+
             " <= floor="+DoubleToString(max_floor,2)+
             ", peak="+DoubleToString(g_peak_equity,2)+
             "). Flattened & HARD-PAUSED until manual resume.");
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

void HandleOpen(const string js)
{
   if(GuardrailBlock()){
      LogCSV("OPEN_BLOCKED_GUARDRAIL");
      return;
   }

   string id  = JGetStr(js,"id");
   if(id=="") id = JGetStr(js,"entry_ts");
   if(HasOpenFired(id)){
      LogCSV("OPEN_DUP_SKIP;"+id);
      return;
   }
   string dir = JGetStr(js,"dir");
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

   bool is_long = (dir=="long");
   double price = is_long ? SymbolInfoDouble(g_symbol,SYMBOL_ASK)
                    : SymbolInfoDouble(g_symbol,SYMBOL_BID);
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
      }
      LogCSV("OPEN;"+id+";dir="+dir+";lots="+DoubleToString(lots,2)+
             ";want_entry="+DoubleToString(entry,g_digits)+
             ";fill="+DoubleToString(trade.ResultPrice(),g_digits)+
             ";sl="+DoubleToString(sl,g_digits)+";tp="+DoubleToString(tpx,g_digits)+
             ";sacct="+DoubleToString(sacct,2)+";live_eq="+DoubleToString(live_eq,2));
   }
   else {
      LogCSV("OPEN_FAIL;"+id+";ret="+IntegerToString(trade.ResultRetcode())+";"+trade.ResultRetcodeDescription());
   }
}

void HandleModify(const string js)
{
   string id = JGetStr(js,"id");
   double new_stop = JGetNum(js,"new_stop");
   int idx=FindId(id);
   if(idx<0){
      LogCSV("MODIFY_NO_MAP;"+id);
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
      }
   }
}

void HandleClose(const string js)
{
   string id = JGetStr(js,"id");
   double exit_sig = JGetNum(js,"exit");
   string reason = JGetStr(js,"reason");
   int idx=FindId(id);
   if(idx<0){
      LogCSV("CLOSE_NO_MAP;"+id);
      return;
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

      if(pnl_live < 0.0) g_cumulative_losses++;
      else g_cumulative_losses = 0;

      if(g_cumulative_losses >= 15){
         g_disabled_perm = true;
         FlattenAll("CONSECUTIVE_LOSSES");
         Notify("PHANTOM CASH DISABLED",
                "15 consecutive losses reached. Flattened & HARD-PAUSED until manual resume.");
         SaveState();
         LogCSV("DISABLE_CONSECUTIVE_LOSSES;count="+IntegerToString(g_cumulative_losses));
      }
   }
   else {
      LogCSV("CLOSE_FAIL;"+id+";ret="+IntegerToString(trade.ResultRetcode()));
   }
   UnmapId(id);
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
   else if(action=="heartbeat") { /* liveness only */ }
}

//==== FILE READ ====
void PumpFileLive()
{
   int h=FileOpen(InpSignalFile, FILE_READ|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h==INVALID_HANDLE) return;

   FileSeek(h,(long)g_filepos,SEEK_SET);
   while(!FileIsEnding(h)){
      string line=FileReadString(h);
      if(StringLen(line)>0) ProcessLine(line);
   }
   g_filepos=(ulong)FileTell(h);
   FileClose(h);
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
   if(in_tester){
      g_state_file = "";
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
   SaveState();

   g_replay_loaded = false;
   g_replay_next = 0;
   ArrayResize(g_replay_raw, 0);
   ArrayResize(g_replay_ts, 0);
   ArrayResize(g_open_once_ids, 0);
   ArrayResize(g_sig_entry, 0);
   ArrayResize(g_sig_qty, 0);
   ArrayResize(g_sig_dir, 0);
   ArrayResize(g_pending_ids, 0);
   ArrayResize(g_pending_tickets, 0);
   ArrayResize(g_pending_tp, 0);
   ArrayResize(g_pending_sl, 0);
   ArrayResize(g_pending_dir, 0);
   ArrayResize(g_pending_expiry, 0);
   g_synth_net = 0.0;
   g_synth_trades = 0;
   g_synth_wins = 0;

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
   StampModelMode();
   return INIT_SUCCEEDED;
}

void OnTick()
{
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
      PumpFileLive();
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
   if(InpReplayMode && InpReplayUseSignalPricing){
      LogCSV("SYNTH_SUMMARY;trades="+IntegerToString(g_synth_trades)+
             ";wins="+IntegerToString(g_synth_wins)+
             ";net="+DoubleToString(g_synth_net,2));
   }
   LogCSV("DEINIT;reason="+IntegerToString(reason));
}
