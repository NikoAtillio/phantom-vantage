//+------------------------------------------------------------------+
//|  PhantomVisual.mq5                                               |
//|  PHANTOM p2 — Chart Visual Overlay Indicator                     |
//|  Reads signals_vantage_live.jsonl and renders:                   |
//|    • EMA 20 / 50 / 200 on current chart timeframe               |
//|    • Entry arrows per trade                                       |
//|    • Entry / SL / Trailing-SL / Breakeven / TP lines            |
//|    • Regime + confidence label per trade                          |
//|    • Corner HUD (bias, status, equity, open count)               |
//|    • Session boundary verticals (13:00 & 21:00 server time)      |
//+------------------------------------------------------------------+
#property copyright   "Phantom Trading Systems 2025-2026"
#property version     "1.20"
#property indicator_chart_window
#property indicator_buffers 3
#property indicator_plots   3

//--- EMA 20
#property indicator_label1 "EMA 20"
#property indicator_type1  DRAW_LINE
#property indicator_color1 clrDeepSkyBlue
#property indicator_style1 STYLE_SOLID
#property indicator_width1 1

//--- EMA 50
#property indicator_label2 "EMA 50"
#property indicator_type2  DRAW_LINE
#property indicator_color2 clrDodgerBlue
#property indicator_style2 STYLE_SOLID
#property indicator_width2 2

//--- EMA 200
#property indicator_label3 "EMA 200"
#property indicator_type3  DRAW_LINE
#property indicator_color3 clrMidnightBlue
#property indicator_style3 STYLE_SOLID
#property indicator_width3 2

//=== INPUTS ===========================================================
input string  InpSignalFile   = "signals_vantage_live.jsonl"; // Signal file (Common\Files)
input bool    InpShowEMAs     = true;          // Show EMA 20 / 50 / 200
input bool    InpShowSessions = true;          // Show NY session verticals
input bool    InpShowHUD      = true;          // Show corner HUD panel
input bool    InpShowControlPanel = true;      // Show pause status + manual resume button
input int     InpPollSecs     = 5;             // Poll interval (seconds)
input int     InpHistoryTrades= 20;            // How many closed trades to keep drawn
input bool    InpHideMarkersBeforeWeekStart = true; // Hide historical markers from prior weeks (server Sunday rollover)
input string  InpDailyResumeFlagFile = "phantom_live/cash_daily_resume.flag"; // Common\\Files flag for Python daily soft-resume
input string  InpMasterControlFile = "phantom_live/master_control.flag"; // Common\\Files master pause/resume control file
input color   InpColLong      = clrDodgerBlue;  // Long trade colour
input color   InpColShort     = clrOrangeRed;   // Short trade colour
input color   InpColSL        = clrCrimson;     // Stop-loss line colour
input color   InpColBE        = clrGold;        // Breakeven SL colour
input color   InpColTP        = clrLimeGreen;   // Take-profit line colour

//=== BUFFERS ==========================================================
double g_ema20[];
double g_ema50[];
double g_ema200[];

int g_h20  = INVALID_HANDLE;
int g_h50  = INVALID_HANDLE;
int g_h200 = INVALID_HANDLE;

//=== TRADE STATE ======================================================
struct PhTrade {
   string   id;
   string   dir;
   double   entry;
   double   sl_init;
   double   sl_now;
   double   tp;
   double   qty;
   double   conf;
   string   regime;
   double   atr;
   int      stack_max;
   double   live_equity;
   datetime entry_ts;
   datetime close_ts;
   string   close_reason;
   double   close_price;
   bool     is_open;
   bool     be_hit;
};

PhTrade  g_trades[];
int      g_ntrades   = 0;

string   g_last_regime = "";
string   g_pause_reason = "";
datetime g_resume_after = 0;
bool     g_paused      = false;
double   g_acct_size   = 0.0;
double   g_atr_trail_mult = 0.0;
double   g_live_equity = 0.0;
ulong    g_filepos     = 0;
int      g_timer_ticks = 0;

string PREFIX = "PV_";   // all object names start with this

datetime _WeekStart(const datetime t);
string _ShortTradeId(const string &id);
bool _HasLivePosition(const string &id);
bool _GetLivePositionSnapshot(const string &id, double &liveEntry, double &liveSL, double &liveTP, double &liveLots);
void _UpdateControlPanel();
void _HandlePauseButtonClick();
void _HandleResumeButtonClick();
bool _AppendControlEvent(const string &action, const string &reason);
bool _WriteDailyResumeFlag();
bool _WriteMasterControlFlag(const string &mode);
string _NowISO();
void _HSeg(const string &nm, const datetime t0, const datetime t1, const double price,
           const color c, const ENUM_LINE_STYLE style, const int width, const string tooltip);

//+------------------------------------------------------------------+
//| Init                                                              |
//+------------------------------------------------------------------+
int OnInit() {
   if(!InpShowEMAs) {
      // hide buffers
      PlotIndexSetInteger(0, PLOT_DRAW_TYPE, DRAW_NONE);
      PlotIndexSetInteger(1, PLOT_DRAW_TYPE, DRAW_NONE);
      PlotIndexSetInteger(2, PLOT_DRAW_TYPE, DRAW_NONE);
   }

   SetIndexBuffer(0, g_ema20,  INDICATOR_DATA);
   SetIndexBuffer(1, g_ema50,  INDICATOR_DATA);
   SetIndexBuffer(2, g_ema200, INDICATOR_DATA);

   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, 0.0);
   PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, 0.0);
   PlotIndexSetDouble(2, PLOT_EMPTY_VALUE, 0.0);

   // EMA handles on current chart symbol + TF
   g_h20  = iMA(_Symbol, PERIOD_CURRENT, 20,  0, MODE_EMA, PRICE_CLOSE);
   g_h50  = iMA(_Symbol, PERIOD_CURRENT, 50,  0, MODE_EMA, PRICE_CLOSE);
   g_h200 = iMA(_Symbol, PERIOD_CURRENT, 200, 0, MODE_EMA, PRICE_CLOSE);

   if(g_h20==INVALID_HANDLE || g_h50==INVALID_HANDLE || g_h200==INVALID_HANDLE) {
      Alert("PhantomVisual: EMA handle creation failed.");
      return INIT_FAILED;
   }

   // Load full signal history
   _LoadAllSignals();
   _RedrawAll();

   if(InpShowSessions) _DrawSessionLines();
   if(InpShowHUD)      _UpdateHUD();
   if(InpShowControlPanel) _UpdateControlPanel();

   EventSetTimer(InpPollSecs);
   Print("PhantomVisual: init | file=", InpSignalFile, " trades=", g_ntrades, " filepos=", g_filepos);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Calculate – fill EMA buffers                                      |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[]) {
   if(!InpShowEMAs || rates_total < 1) return rates_total;

   int start = (prev_calculated > 1) ? prev_calculated - 1 : 0;

   for(int i = start; i < rates_total; i++) {
      int shift = rates_total - 1 - i;   // 0 = current bar, 1 = 1 bar ago …
      double tmp[1];
      if(CopyBuffer(g_h20,  0, shift, 1, tmp) == 1) g_ema20[i]  = tmp[0]; else g_ema20[i]  = 0;
      if(CopyBuffer(g_h50,  0, shift, 1, tmp) == 1) g_ema50[i]  = tmp[0]; else g_ema50[i]  = 0;
      if(CopyBuffer(g_h200, 0, shift, 1, tmp) == 1) g_ema200[i] = tmp[0]; else g_ema200[i] = 0;
   }
   return rates_total;
}

//+------------------------------------------------------------------+
//| Timer – poll for new signals, refresh overlays                    |
//+------------------------------------------------------------------+
void OnTimer() {
   bool changed = _PollNewSignals();
   if(changed) _RedrawAll();
   g_timer_ticks++;
   int session_every = (InpPollSecs > 0) ? (60 / InpPollSecs) : 1;
   if(session_every < 1) session_every = 1;
   if(InpShowSessions && (g_timer_ticks % session_every == 0)) _DrawSessionLines();
   if(InpShowHUD)      _UpdateHUD();
   if(InpShowControlPanel) _UpdateControlPanel();
}

void OnChartEvent(const int id,
                  const long &lparam,
                  const double &dparam,
                  const string &sparam)
{
   if(id != CHARTEVENT_OBJECT_CLICK) return;
   if(sparam == PREFIX + "CTRL_PAUSE")
      _HandlePauseButtonClick();
   if(sparam == PREFIX + "CTRL_RESUME")
      _HandleResumeButtonClick();
}

//+------------------------------------------------------------------+
//| Deinit                                                            |
//+------------------------------------------------------------------+
void OnDeinit(const int reason) {
   EventKillTimer();
   _DeleteAllObjects();
   if(g_h20  != INVALID_HANDLE) IndicatorRelease(g_h20);
   if(g_h50  != INVALID_HANDLE) IndicatorRelease(g_h50);
   if(g_h200 != INVALID_HANDLE) IndicatorRelease(g_h200);
}

//+------------------------------------------------------------------+
//| FILE I/O                                                          |
//+------------------------------------------------------------------+

void _LoadAllSignals() {
   g_filepos = 0;
   ArrayResize(g_trades, 0);
   g_ntrades = 0;

   int fh = FileOpen(InpSignalFile, FILE_READ | FILE_SHARE_READ | FILE_ANSI | FILE_COMMON);
   if(fh == INVALID_HANDLE) {
      Print("PhantomVisual: signal file not found — ", InpSignalFile);
      return;
   }
   FileSeek(fh, 0, SEEK_SET);
   while(!FileIsEnding(fh)) {
      string ln = _Trim(FileReadString(fh));
      if(StringLen(ln) > 5) _ProcessLine(ln);
   }
   g_filepos = FileTell(fh);
   FileClose(fh);
}

bool _PollNewSignals() {
   int fh = FileOpen(InpSignalFile, FILE_READ | FILE_SHARE_READ | FILE_ANSI | FILE_COMMON);
   if(fh == INVALID_HANDLE) return false;

   FileSeek(fh, (long)g_filepos, SEEK_SET);
   bool had_new = false;
   while(!FileIsEnding(fh)) {
      string ln = _Trim(FileReadString(fh));
      if(StringLen(ln) > 5) { _ProcessLine(ln); had_new = true; }
   }
   g_filepos = FileTell(fh);
   FileClose(fh);
   return had_new;
}

//+------------------------------------------------------------------+
//| SIGNAL DISPATCHER                                                 |
//+------------------------------------------------------------------+

void _ProcessLine(const string &ln) {
   string action = _JStr(ln, "action");
   if(action == "")              return;
   if(action == "meta")          { _DoMeta(ln); return; }
   if(action == "open")          { _DoOpen(ln);  return; }
   if(action == "modify")        { _DoModify(ln); return; }
   if(action == "close")         { _DoClose(ln);  return; }
   if(action == "heartbeat")     { return; }
   if(action == "pause_entries") {
      g_paused = true;
      g_pause_reason = _JStr(ln, "reason");
      string resume_after = _JStr(ln, "resume_after");
      g_resume_after = _ParseISO(resume_after);
      return;
   }
   if(action == "resume_entries"){
      g_paused = false;
      g_pause_reason = "";
      g_resume_after = 0;
      return;
   }
   if(action == "hard_stop")     {
      g_paused = true;
      g_pause_reason = "HARD_STOP";
      g_resume_after = 0;
      return;
   }
}

void _DoMeta(const string &ln) {
   g_acct_size = _JDbl(ln, "signal_account_size");
   if(g_acct_size > 0) g_live_equity = g_acct_size;
   double tm = _JDbl(ln, "atr_trail_mult");
   if(tm > 0) g_atr_trail_mult = tm;
}

void _DoOpen(const string &ln) {
   string id = _JStr(ln, "id");
   if(id == "") id = _JStr(ln, "entry_ts");
   if(id == "") id = _JStr(ln, "signal_ts");
   if(id == "") return;
   int i = _GetOrAddTrade(id);

   g_trades[i].id       = id;
   g_trades[i].dir      = _JStr(ln, "dir");
   g_trades[i].entry    = _JDbl(ln, "entry");
   g_trades[i].sl_init  = _JDbl(ln, "stop");
   g_trades[i].sl_now   = _JDbl(ln, "stop");
   g_trades[i].tp       = _JDbl(ln, "tp");
   g_trades[i].qty      = _JDbl(ln, "qty");
   g_trades[i].conf     = _JDbl(ln, "conf");
   g_trades[i].atr      = _JDbl(ln, "atr_entry");
   g_trades[i].regime   = _JStr(ln, "regime");

   int sm = (int)_JDbl(ln, "stack_max");
   if(sm <= 0) sm = (int)_JDbl(ln, "stack_count");
   if(sm > 0) g_trades[i].stack_max = sm;

   double leq = _JDbl(ln, "signal_account_size");
   if(leq <= 0.0) leq = _JDbl(ln, "live_equity");
   if(leq > 0.0){
      g_trades[i].live_equity = leq;
      g_live_equity = leq;
   }

   double tm = _JDbl(ln, "atr_trail_mult");
   if(tm > 0.0) g_atr_trail_mult = tm;

   string entry_ts = _JStr(ln, "entry_ts");
   g_trades[i].entry_ts = _ParseISO(entry_ts);
   if(g_trades[i].entry_ts == 0)
   {
      string signal_ts = _JStr(ln, "signal_ts");
      g_trades[i].entry_ts = _ParseISO(signal_ts);
   }
   g_trades[i].close_ts = 0;
   g_trades[i].close_reason = "";
   g_trades[i].close_price = 0.0;
   g_trades[i].is_open  = true;
   g_trades[i].be_hit   = false;

   if(g_trades[i].regime != "") g_last_regime = g_trades[i].regime;
}

void _DoModify(const string &ln) {
   string id = _JStr(ln, "id");
   int i = _FindTrade(id);
   if(i < 0) return;
   double new_sl = _JDbl(ln, "new_stop");
   if(new_sl > 0) g_trades[i].sl_now = new_sl;
   string reason = _JStr(ln, "reason");
   StringToLower(reason);
   if(StringFind(reason, "breakeven") >= 0) g_trades[i].be_hit = true;

   int sm = (int)_JDbl(ln, "stack_max");
   if(sm <= 0) sm = (int)_JDbl(ln, "stack_count");
   if(sm > g_trades[i].stack_max) g_trades[i].stack_max = sm;

   double leq = _JDbl(ln, "signal_account_size");
   if(leq <= 0.0) leq = _JDbl(ln, "live_equity");
   if(leq > 0.0){
      g_trades[i].live_equity = leq;
      g_live_equity = leq;
   }
}

void _DoClose(const string &ln) {
   string id = _JStr(ln, "id");
   int i = _FindTrade(id);
   if(i < 0) return;
   g_trades[i].is_open = false;
   g_trades[i].close_reason = _JStr(ln, "reason");
   g_trades[i].close_price = _JDbl(ln, "exit");
   string signal_ts = _JStr(ln, "signal_ts");
   g_trades[i].close_ts = _ParseISO(signal_ts);

   double leq = _JDbl(ln, "signal_account_size");
   if(leq <= 0.0) leq = _JDbl(ln, "live_equity");
   if(leq > 0.0) g_live_equity = leq;
}

//+------------------------------------------------------------------+
//| TRADE INDEX HELPERS                                               |
//+------------------------------------------------------------------+

int _FindTrade(const string &id) {
   for(int i = 0; i < g_ntrades; i++)
      if(g_trades[i].id == id) return i;
   return -1;
}

int _GetOrAddTrade(const string &id) {
   int i = _FindTrade(id);
   if(i >= 0) return i;
   ArrayResize(g_trades, g_ntrades + 1);
   g_trades[g_ntrades].id      = id;
   g_trades[g_ntrades].is_open = false;
   g_trades[g_ntrades].be_hit  = false;
   g_trades[g_ntrades].stack_max = 0;
   g_trades[g_ntrades].live_equity = 0.0;
   g_trades[g_ntrades].close_ts = 0;
   g_trades[g_ntrades].close_reason = "";
   g_trades[g_ntrades].close_price = 0.0;
   return g_ntrades++;
}

//+------------------------------------------------------------------+
//| DRAWING                                                           |
//+------------------------------------------------------------------+

void _RedrawAll() {
   _DeleteTradeObjects();
   datetime week_start = _WeekStart(TimeCurrent());

   for(int i = 0; i < g_ntrades; i++) {
      // Draw open trades always; draw recent closed trades up to InpHistoryTrades
      if(g_trades[i].is_open)
         _DrawTrade(i, true);
      else if(i >= g_ntrades - InpHistoryTrades) {
         if(InpHideMarkersBeforeWeekStart) {
            datetime anchor = (g_trades[i].close_ts > 0) ? g_trades[i].close_ts : g_trades[i].entry_ts;
            if(anchor < week_start) continue;
         }
         _DrawTrade(i, false);
      }
   }
   ChartRedraw(0);
}

datetime _WeekStart(const datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   dt.hour = 0;
   dt.min = 0;
   dt.sec = 0;
   datetime day_start = StructToTime(dt);
   return day_start - (datetime)(dt.day_of_week * 86400);
}

void _DrawTrade(const int idx, const bool isOpen) {
   PhTrade t = g_trades[idx];
   if(t.entry <= 0) return;
   double live_entry = 0.0;
   double live_sl = 0.0;
   double live_tp = 0.0;
   double live_lots = 0.0;
   bool live_now = isOpen && _GetLivePositionSnapshot(t.id, live_entry, live_sl, live_tp, live_lots);

   double effective_entry = (live_now && live_entry > 0.0) ? live_entry : t.entry;
   double effective_sl = (live_now && live_sl > 0.0)
      ? live_sl
      : ((t.sl_now > 0.0) ? t.sl_now : t.sl_init);
   double effective_tp = (live_now && live_tp > 0.0) ? live_tp : t.tp;
   double effective_qty = (live_now && live_lots > 0.0) ? live_lots : t.qty;

   bool long_dir = (t.dir == "long");
   color cDir  = long_dir ? InpColLong : InpColShort;
   string base = PREFIX + "T" + t.id + "_";
   string shortId = _ShortTradeId(t.id);
   datetime seg_end = isOpen
      ? (TimeCurrent() + (datetime)(PeriodSeconds() * 10))
      : ((t.close_ts > 0) ? t.close_ts : (t.entry_ts + (datetime)(PeriodSeconds() * 8)));
   if(seg_end <= t.entry_ts) seg_end = t.entry_ts + (datetime)(PeriodSeconds() * 8);

   // ── Entry arrow ───────────────────────────────────────────────
   string nm = base + "ARR";
   ObjectCreate(0, nm, OBJ_ARROW, 0, t.entry_ts, effective_entry);
   ObjectSetInteger(0, nm, OBJPROP_ARROWCODE, long_dir ? 233 : 234);
   ObjectSetInteger(0, nm, OBJPROP_COLOR, cDir);
   ObjectSetInteger(0, nm, OBJPROP_WIDTH, live_now ? 3 : 2);
   ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, nm, OBJPROP_HIDDEN, true);

   // ── Entry label ───────────────────────────────────────────────
   string regimeLbl = (t.regime != "") ? t.regime : "—";
   string confLbl   = (t.conf > 1.0) ? " ★" + DoubleToString(t.conf, 1) + "x" : "";
   string stackLbl  = (t.stack_max > 1) ? " [S" + IntegerToString(t.stack_max) + "]" : "";
   string qtySrcLbl = live_now ? " (live)" : " (signal)";
   string hudTxt = "[" + shortId + "] " + (long_dir ? "▲ LONG " : "▼ SHORT ") +
                   DoubleToString(effective_qty, 2) + "L" + qtySrcLbl +
                   confLbl + stackLbl + " | " + regimeLbl;
   nm = base + "LBL";
   datetime lbl_t = t.entry_ts + (datetime)(PeriodSeconds() * 3);
   ObjectCreate(0, nm, OBJ_TEXT, 0, lbl_t, effective_entry);
   ObjectSetString(0, nm, OBJPROP_TEXT, hudTxt);
   ObjectSetInteger(0, nm, OBJPROP_COLOR, cDir);
   ObjectSetInteger(0, nm, OBJPROP_FONTSIZE, 8);
   ObjectSetString(0, nm, OBJPROP_FONT, "Consolas");
   ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, nm, OBJPROP_HIDDEN, true);

   if(isOpen) {
      nm = base + "EL";
      _HSeg(nm, t.entry_ts, seg_end, effective_entry, cDir, STYLE_DOT, 1, "[" + shortId + "] Entry");

      if(t.sl_init > 0) {
         nm = base + "SL0";
         _HSeg(nm, t.entry_ts, seg_end, t.sl_init, C'120,0,0', STYLE_DASH, 1, "[" + shortId + "] Initial SL");
      }

      nm = base + "SL";
      color cSL = t.be_hit ? InpColBE : InpColSL;
      double trail_sl = effective_sl;
      _HSeg(nm, t.entry_ts, seg_end, trail_sl, cSL, STYLE_SOLID, 2, t.be_hit ? ("[" + shortId + "] SL @ Breakeven") : ("[" + shortId + "] Trailing SL"));

      nm = base + "SLL";
      ObjectCreate(0, nm, OBJ_TEXT, 0, seg_end, trail_sl);
      ObjectSetString(0, nm, OBJPROP_TEXT, "[" + shortId + "] " + (t.be_hit ? "BE" : "Trail SL"));
      ObjectSetInteger(0, nm, OBJPROP_COLOR, cSL);
      ObjectSetInteger(0, nm, OBJPROP_FONTSIZE, 7);
      ObjectSetString(0, nm, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, nm, OBJPROP_HIDDEN, true);

      if(effective_tp > 0.0) {
         nm = base + "TP";
         string tpTip = live_now ? ("[" + shortId + "] Take Profit (broker)") : ("[" + shortId + "] Take Profit");
         _HSeg(nm, t.entry_ts, seg_end, effective_tp, InpColTP, STYLE_DASH, 2, tpTip);
      }

      if(effective_sl > 0.0 && effective_tp > 0.0 && effective_entry > 0.0) {
         double risk = MathAbs(effective_entry - effective_sl);
         double rwd  = MathAbs(effective_tp - effective_entry);
         double rr   = (risk > 0) ? rwd / risk : 0.0;
         nm = base + "TPL";
         ObjectCreate(0, nm, OBJ_TEXT, 0, seg_end, effective_tp);
         ObjectSetString(0, nm, OBJPROP_TEXT, "[" + shortId + "] TP " + DoubleToString(rr, 2) + "R");
         ObjectSetInteger(0, nm, OBJPROP_COLOR, InpColTP);
         ObjectSetInteger(0, nm, OBJPROP_FONTSIZE, 7);
         ObjectSetString(0, nm, OBJPROP_FONT, "Consolas");
         ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, nm, OBJPROP_HIDDEN, true);
      }
   }

   if(!isOpen && t.close_price > 0) {
      datetime exit_t = (t.close_ts > 0) ? t.close_ts : lbl_t + (datetime)(PeriodSeconds() * 30);
      nm = base + "EXT";
      ObjectCreate(0, nm, OBJ_TEXT, 0, exit_t, t.close_price);

      string reason_up = t.close_reason;
      StringToUpper(reason_up);
      color  exit_col = clrSilver;
      string exit_pfx = "EXIT";
      if(StringFind(reason_up, "TP") >= 0 || StringFind(reason_up, "TAKE") >= 0){
         exit_col = clrLimeGreen;
         exit_pfx = "TP";
      }
      else if(StringFind(reason_up, "SL") >= 0 || StringFind(reason_up, "STOP") >= 0){
         exit_col = clrCrimson;
         exit_pfx = "SL";
      }
      else if(StringFind(reason_up, "GUARD") >= 0){
         exit_col = clrOrange;
         exit_pfx = "GUARD";
      }
      else if(StringFind(reason_up, "TRAIL") >= 0){
         exit_col = clrGold;
         exit_pfx = "TRAIL";
      }
      else if(StringFind(reason_up, "BE") >= 0 || StringFind(reason_up, "BREAKEVEN") >= 0){
         exit_col = clrYellow;
         exit_pfx = "BE";
      }

      string exit_txt = "[" + shortId + "] " + ((t.close_reason != "") ? (exit_pfx + " " + t.close_reason) : exit_pfx);
      ObjectSetString(0, nm, OBJPROP_TEXT, exit_txt);
      ObjectSetInteger(0, nm, OBJPROP_COLOR, exit_col);
      ObjectSetInteger(0, nm, OBJPROP_FONTSIZE, 7);
      ObjectSetString(0, nm, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, nm, OBJPROP_HIDDEN, true);

      nm = base + "EARR";
      ObjectCreate(0, nm, OBJ_ARROW, 0, exit_t, t.close_price);
      ObjectSetInteger(0, nm, OBJPROP_ARROWCODE, 251);
      ObjectSetInteger(0, nm, OBJPROP_COLOR, exit_col);
      ObjectSetInteger(0, nm, OBJPROP_WIDTH, 2);
      ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, nm, OBJPROP_HIDDEN, true);
   }
}

void _HSeg(const string &nm, const datetime t0, const datetime t1, const double price,
           const color c, const ENUM_LINE_STYLE style, const int width, const string tooltip)
{
   ObjectCreate(0, nm, OBJ_TREND, 0, t0, price, t1, price);
   ObjectSetInteger(0, nm, OBJPROP_RAY_RIGHT, false);
   ObjectSetInteger(0, nm, OBJPROP_RAY_LEFT, false);
   ObjectSetInteger(0, nm, OBJPROP_COLOR, c);
   ObjectSetInteger(0, nm, OBJPROP_STYLE, style);
   ObjectSetInteger(0, nm, OBJPROP_WIDTH, width);
   ObjectSetString(0, nm, OBJPROP_TOOLTIP, tooltip);
   ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, nm, OBJPROP_HIDDEN, true);
}

string _ShortTradeId(const string &id)
{
   int hashPos = StringFind(id, "#");
   if(hashPos >= 0 && hashPos + 1 < StringLen(id))
      return StringSubstr(id, hashPos + 1);

   string cleaned = id;
   StringReplace(cleaned, "-", "");
   StringReplace(cleaned, ":", "");
   StringReplace(cleaned, "T", "");
   int len = StringLen(cleaned);
   if(len <= 6) return cleaned;
   return StringSubstr(cleaned, len - 6);
}

bool _HasLivePosition(const string &id)
{
   double live_entry = 0.0;
   double live_sl = 0.0;
   double live_tp = 0.0;
   double live_lots = 0.0;
   return _GetLivePositionSnapshot(id, live_entry, live_sl, live_tp, live_lots);
}

bool _GetLivePositionSnapshot(const string &id, double &liveEntry, double &liveSL, double &liveTP, double &liveLots)
{
   liveEntry = 0.0;
   liveSL = 0.0;
   liveTP = 0.0;
   liveLots = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0) continue;
      if(!PositionSelectByTicket(tk)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      string comment = PositionGetString(POSITION_COMMENT);
      if(comment == id)
      {
         liveEntry = PositionGetDouble(POSITION_PRICE_OPEN);
         liveSL = PositionGetDouble(POSITION_SL);
         liveTP = PositionGetDouble(POSITION_TP);
         liveLots = PositionGetDouble(POSITION_VOLUME);
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| SESSION VERTICALS                                                 |
//+------------------------------------------------------------------+

void _DrawSessionLines() {
   // Remove old session objects
   for(int i = ObjectsTotal(0) - 1; i >= 0; i--) {
      string nm = ObjectName(0, i);
      if(StringFind(nm, PREFIX + "SS_") == 0) ObjectDelete(0, nm);
   }

   datetime now = TimeCurrent();
   // Draw for the last 7 days + next 2 (covers weekend gaps)
   for(int d = -7; d <= 2; d++) {
      datetime base_day = now + (datetime)(d * 86400);
      MqlDateTime mdt;
      TimeToStruct(base_day, mdt);
      if(mdt.day_of_week == 0 || mdt.day_of_week == 6) continue; // skip weekends

      // NY pre-market open 13:00 UTC
      mdt.hour = 13; mdt.min = 0; mdt.sec = 0;
      datetime t_open = StructToTime(mdt);
      // NY session close 21:00 UTC
      mdt.hour = 21; mdt.min = 0; mdt.sec = 0;
      datetime t_close = StructToTime(mdt);

      string nm_open = PREFIX + "SS_O" + IntegerToString(d);
      string nm_close = PREFIX + "SS_C" + IntegerToString(d);
      _VLine(nm_open, t_open,  clrForestGreen, "NY Open (server 13:00)");
      _VLine(nm_close, t_close, C'80,80,80',    "NY Close (server 21:00)");
   }
}

void _VLine(const string &nm, const datetime t, const color c, const string tip) {
   if(ObjectFind(0, nm) >= 0) return;
   ObjectCreate(0, nm, OBJ_VLINE, 0, t, 0);
   ObjectSetInteger(0, nm, OBJPROP_COLOR, c);
   ObjectSetInteger(0, nm, OBJPROP_STYLE, STYLE_DASH);
   ObjectSetInteger(0, nm, OBJPROP_WIDTH, 1);
   ObjectSetString(0, nm, OBJPROP_TOOLTIP, tip);
   ObjectSetInteger(0, nm, OBJPROP_BACK, true);
   ObjectSetInteger(0, nm, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, nm, OBJPROP_HIDDEN, true);
}

//+------------------------------------------------------------------+
//| HUD PANEL                                                         |
//+------------------------------------------------------------------+

void _UpdateHUD() {
   int open_cnt = 0;
   for(int i = 0; i < g_ntrades; i++)
      if(g_trades[i].is_open) open_cnt++;

   string bias = _RegimeBias(g_last_regime);
   string status;
   color  hudCol;
   if(g_paused) {
      status = "⏸ PAUSED | " + g_pause_reason;
      if(g_resume_after > 0)
         status += " | resumes " + TimeToString(g_resume_after, TIME_DATE|TIME_MINUTES);
      hudCol = clrOrange;
   } else if(open_cnt > 0) {
      status = "● IN TRADE (" + IntegerToString(open_cnt) + ")";
      hudCol = clrLimeGreen;
   } else {
      status = "◌ WATCHING";
      hudCol = clrSilver;
   }

   string eqLine = (g_live_equity > 0)
      ? ("║ Equity : £" + DoubleToString(g_live_equity, 0) + "\n")
      : "";

   string trailLine = (g_atr_trail_mult > 0)
      ? ("║ Trail  : " + DoubleToString(g_atr_trail_mult, 2) + "x ATR\n")
      : "";

   string panel_txt =
      "╔══ PHANTOM p2 │ VANTAGE ══╗\n" +
      "║ Regime : " + (g_last_regime != "" ? g_last_regime : "—") + "\n" +
      "║ Bias   : " + bias + "\n" +
      "║ Status : " + status + "\n" +
      "║ Capital: £" + DoubleToString(g_acct_size, 0) + "\n" +
      eqLine +
      trailLine +
      "╚══════════════════════════╝";

   string nm = PREFIX + "HUD";
   if(ObjectFind(0, nm) < 0) {
      ObjectCreate(0, nm, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, nm, OBJPROP_CORNER,    CORNER_LEFT_UPPER);
      ObjectSetInteger(0, nm, OBJPROP_XDISTANCE, 12);
      ObjectSetInteger(0, nm, OBJPROP_YDISTANCE, 28);
      ObjectSetString(0, nm,  OBJPROP_FONT,      "Consolas");
      ObjectSetInteger(0, nm, OBJPROP_FONTSIZE,  9);
      ObjectSetInteger(0, nm, OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0, nm, OBJPROP_HIDDEN,    true);
   }
   ObjectSetInteger(0, nm, OBJPROP_COLOR, hudCol);
   ObjectSetString(0,  nm, OBJPROP_TEXT,  panel_txt);
   ChartRedraw(0);
}

string _RegimeBias(const string &regime) {
   string r = regime;
   StringToLower(r);
   if(StringFind(r, "bull") >= 0)   return "▲ BULLISH";
   if(StringFind(r, "bear") >= 0)   return "▼ BEARISH";
   if(StringFind(r, "trend") >= 0)  return "→ TRENDING";
   if(StringFind(r, "neutral") >= 0)return "— NEUTRAL";
   if(r == "") return "—";
   return regime;
}

void _UpdateControlPanel()
{
   string panelNm  = PREFIX + "CTRL_PANEL";
   string statusNm = PREFIX + "CTRL_STATUS";
   string pauseNm  = PREFIX + "CTRL_PAUSE";
   string buttonNm = PREFIX + "CTRL_RESUME";

   if(ObjectFind(0, panelNm) >= 0)
      ObjectDelete(0, panelNm);

   if(ObjectFind(0, statusNm) < 0)
   {
      ObjectCreate(0, statusNm, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, statusNm, OBJPROP_CORNER, CORNER_LEFT_LOWER);
      ObjectSetInteger(0, statusNm, OBJPROP_XDISTANCE, 22);
      ObjectSetInteger(0, statusNm, OBJPROP_YDISTANCE, 198);
      ObjectSetString(0, statusNm, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, statusNm, OBJPROP_FONTSIZE, 12);
      ObjectSetInteger(0, statusNm, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, statusNm, OBJPROP_HIDDEN, false);
   }

   if(ObjectFind(0, buttonNm) < 0)
   {
      ObjectCreate(0, buttonNm, OBJ_BUTTON, 0, 0, 0);
      ObjectSetInteger(0, buttonNm, OBJPROP_CORNER, CORNER_LEFT_LOWER);
      ObjectSetInteger(0, buttonNm, OBJPROP_XDISTANCE, 22);
      ObjectSetInteger(0, buttonNm, OBJPROP_YDISTANCE, 128);
      ObjectSetInteger(0, buttonNm, OBJPROP_XSIZE, 264);
      ObjectSetInteger(0, buttonNm, OBJPROP_YSIZE, 30);
      ObjectSetInteger(0, buttonNm, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, buttonNm, OBJPROP_HIDDEN, true);
      ObjectSetString(0, buttonNm, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, buttonNm, OBJPROP_FONTSIZE, 11);
      ObjectSetInteger(0, buttonNm, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, buttonNm, OBJPROP_HIDDEN, false);
   }

   if(ObjectFind(0, pauseNm) < 0)
   {
      ObjectCreate(0, pauseNm, OBJ_BUTTON, 0, 0, 0);
      ObjectSetInteger(0, pauseNm, OBJPROP_CORNER, CORNER_LEFT_LOWER);
      ObjectSetInteger(0, pauseNm, OBJPROP_XDISTANCE, 22);
      ObjectSetInteger(0, pauseNm, OBJPROP_YDISTANCE, 164);
      ObjectSetInteger(0, pauseNm, OBJPROP_XSIZE, 264);
      ObjectSetInteger(0, pauseNm, OBJPROP_YSIZE, 30);
      ObjectSetInteger(0, pauseNm, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, pauseNm, OBJPROP_HIDDEN, true);
      ObjectSetString(0, pauseNm, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, pauseNm, OBJPROP_FONTSIZE, 11);
      ObjectSetInteger(0, pauseNm, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, pauseNm, OBJPROP_HIDDEN, false);
   }

   string statusText;
   color statusCol;
   if(g_paused)
   {
      statusText = "PHANTOM: PAUSED";
      if(g_resume_after > 0)
         statusText += "  until " + TimeToString(g_resume_after, TIME_DATE | TIME_MINUTES);
      statusCol = clrOrangeRed;
   }
   else
   {
      statusText = "PHANTOM: LIVE";
      statusCol = clrLimeGreen;
   }

   ObjectSetString(0, statusNm, OBJPROP_TEXT, statusText);
   ObjectSetInteger(0, statusNm, OBJPROP_COLOR, statusCol);

   if(g_paused)
   {
      ObjectSetString(0, buttonNm, OBJPROP_TEXT, "Master Resume");
      ObjectSetInteger(0, buttonNm, OBJPROP_COLOR, clrWhite);
      ObjectSetInteger(0, buttonNm, OBJPROP_BGCOLOR, clrSeaGreen);

      ObjectSetString(0, pauseNm, OBJPROP_TEXT, "Master Pause (active)");
      ObjectSetInteger(0, pauseNm, OBJPROP_COLOR, clrBlack);
      ObjectSetInteger(0, pauseNm, OBJPROP_BGCOLOR, clrSilver);
   }
   else
   {
      ObjectSetString(0, buttonNm, OBJPROP_TEXT, "Master Resume");
      ObjectSetInteger(0, buttonNm, OBJPROP_COLOR, clrBlack);
      ObjectSetInteger(0, buttonNm, OBJPROP_BGCOLOR, clrSilver);

      ObjectSetString(0, pauseNm, OBJPROP_TEXT, "Master Pause");
      ObjectSetInteger(0, pauseNm, OBJPROP_COLOR, clrWhite);
      ObjectSetInteger(0, pauseNm, OBJPROP_BGCOLOR, clrIndianRed);
   }
}

void _HandlePauseButtonClick()
{
   bool wrotePauseEvent = _AppendControlEvent("pause_entries", "manual_master_pause");
   bool wroteMasterFlag = _WriteMasterControlFlag("PAUSE");

   if(wrotePauseEvent || wroteMasterFlag)
   {
      g_paused = true;
      g_pause_reason = "manual_master_pause";
      g_resume_after = 0;
      _UpdateHUD();
   }

   _UpdateControlPanel();
   ChartRedraw(0);

   string msg = "PhantomVisual: master pause requested";
   if(wrotePauseEvent) msg += " | signal event sent";
   if(wroteMasterFlag) msg += " | master control file updated";
   if(!wrotePauseEvent && !wroteMasterFlag)
      msg += " | failed to write event/control file";
   Alert(msg);
   Print(msg);
}

void _HandleResumeButtonClick()
{
   bool wroteResumeEvent = _AppendControlEvent("resume_entries", "manual_chart_resume");
   bool wroteResumeFlag  = _WriteDailyResumeFlag();
   bool wroteMasterFlag  = _WriteMasterControlFlag("RESUME");

   if(wroteResumeEvent || wroteMasterFlag)
   {
      g_paused = false;
      g_pause_reason = "";
      g_resume_after = 0;
      _UpdateHUD();
   }

   _UpdateControlPanel();
   ChartRedraw(0);

   string msg = "PhantomVisual: resume requested";
   if(wroteResumeEvent) msg += " | signal event sent";
   if(wroteResumeFlag)  msg += " | daily-resume flag written";
    if(wroteMasterFlag) msg += " | master control file updated";
   if(!wroteResumeEvent && !wroteResumeFlag && !wroteMasterFlag)
      msg += " | failed to write event/flags";
   Alert(msg);
   Print(msg);
}

bool _AppendControlEvent(const string &action, const string &reason)
{
   int fh = FileOpen(InpSignalFile, FILE_READ | FILE_WRITE | FILE_ANSI | FILE_COMMON | FILE_SHARE_READ | FILE_SHARE_WRITE);
   if(fh == INVALID_HANDLE)
   {
      Print("PhantomVisual: cannot open signal file for control event: ", InpSignalFile);
      return false;
   }

   string ln = "{\"v\":1,\"action\":\"" + action + "\",\"reason\":\"" + reason + "\",\"signal_ts\":\"" + _NowISO() + "\"}";
   FileSeek(fh, 0, SEEK_END);
   uint n = FileWriteString(fh, ln + "\r\n");
   g_filepos = (ulong)FileTell(fh);
   FileClose(fh);
   return (n > 0);
}

bool _WriteDailyResumeFlag()
{
   if(StringLen(InpDailyResumeFlagFile) == 0)
      return false;

   int fh = FileOpen(InpDailyResumeFlagFile, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON | FILE_SHARE_READ | FILE_SHARE_WRITE);
   if(fh == INVALID_HANDLE)
   {
      Print("PhantomVisual: cannot create daily resume flag: ", InpDailyResumeFlagFile);
      return false;
   }

   uint n = FileWriteString(fh, _NowISO() + "\r\n");
   FileClose(fh);
   return (n > 0);
}

bool _WriteMasterControlFlag(const string &mode)
{
   if(StringLen(InpMasterControlFile) == 0)
      return false;

   string normalized = mode;
   StringToUpper(normalized);
   if(normalized != "PAUSE" && normalized != "RESUME")
      return false;

   int fh = FileOpen(InpMasterControlFile, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON | FILE_SHARE_READ | FILE_SHARE_WRITE);
   if(fh == INVALID_HANDLE)
   {
      Print("PhantomVisual: cannot write master control file: ", InpMasterControlFile);
      return false;
   }

   uint n = FileWriteString(fh, normalized + " " + _NowISO() + "\r\n");
   FileClose(fh);
   return (n > 0);
}

string _NowISO()
{
   string iso = TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS);
   StringReplace(iso, ".", "-");
   StringReplace(iso, " ", "T");
   return iso;
}

//+------------------------------------------------------------------+
//| OBJECT CLEANUP                                                    |
//+------------------------------------------------------------------+

void _DeleteTradeObjects() {
   for(int i = ObjectsTotal(0) - 1; i >= 0; i--) {
      string nm = ObjectName(0, i);
      if(StringFind(nm, PREFIX + "T") == 0) ObjectDelete(0, nm);
   }
}

void _DeleteAllObjects() {
   for(int i = ObjectsTotal(0) - 1; i >= 0; i--) {
      string nm = ObjectName(0, i);
      if(StringFind(nm, PREFIX) == 0) ObjectDelete(0, nm);
   }
}

//+------------------------------------------------------------------+
//| MINIMAL JSON HELPERS                                              |
//+------------------------------------------------------------------+

string _JStr(const string &json, const string &key) {
   string search = "\"" + key + "\"";
   int pos = StringFind(json, search);
   if(pos < 0) return "";
   pos += StringLen(search);
   // skip whitespace and colon
   while(pos < StringLen(json)) {
      ushort c = StringGetCharacter(json, pos);
      if(c != ' ' && c != ':') break;
      pos++;
   }
   if(pos >= StringLen(json)) return "";
   ushort first = StringGetCharacter(json, pos);
   if(first == '"') {
      pos++;
      string result = "";
      while(pos < StringLen(json)) {
         ushort c = StringGetCharacter(json, pos);
         if(c == '"') break;
         result += ShortToString(c);
         pos++;
      }
      return result;
   }
   // number / bool / null
   string result = "";
   while(pos < StringLen(json)) {
      ushort c = StringGetCharacter(json, pos);
      if(c==',' || c=='}' || c==']' || c==' ' || c=='\n' || c=='\r') break;
      result += ShortToString(c);
      pos++;
   }
   return result;
}

double _JDbl(const string &json, const string &key) {
   string s = _JStr(json, key);
   if(s == "" || s == "null") return 0.0;
   return StringToDouble(s);
}

string _Trim(const string &s) {
   string r = s;
   StringTrimLeft(r);
   StringTrimRight(r);
   return r;
}

datetime _ParseISO(const string &s) {
   if(StringLen(s) < 10) return 0;
   string cleaned = s;

   // Normalize common ISO-8601 variants: 2026-07-20T01:40:18(.sss)?(Z|+00:00)
   StringReplace(cleaned, "T", " ");
   StringReplace(cleaned, "Z", "");

   int plusPos  = StringFind(cleaned, "+", 10);
   int minusPos = StringFind(cleaned, "-", 10); // timezone offset only; date part is before index 10
   int tzPos = -1;
   if(plusPos >= 0) tzPos = plusPos;
   if(minusPos >= 0 && (tzPos < 0 || minusPos < tzPos)) tzPos = minusPos;
   if(tzPos > 0) cleaned = StringSubstr(cleaned, 0, tzPos);

   int dotPos = StringFind(cleaned, ".", 10); // strip fractional seconds
   if(dotPos > 0) cleaned = StringSubstr(cleaned, 0, dotPos);

   cleaned = _Trim(cleaned);

   // MQL StringToTime accepts yyyy.mm.dd hh:mi:ss
   StringReplace(cleaned, "-", ".");
   return StringToTime(cleaned);
}