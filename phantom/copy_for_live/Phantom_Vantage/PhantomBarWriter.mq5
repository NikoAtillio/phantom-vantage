//+------------------------------------------------------------------+
//| PhantomBarWriter.mq5                                             |
//| Exports live bar data for ALL required timeframes to CSV files   |
//| in MT5 Common\Files\phantom_live\ so the Python live daemon can  |
//| detect new bars and re-run the Phantom signal engine.            |
//|                                                                  |
//| HOW IT WORKS                                                     |
//|   - OnInit: exports full history for all 7 timeframes.           |
//|   - OnTick: on each new M5 bar, checks which higher timeframes   |
//|     also have a new completed bar and re-exports only those.     |
//|   - Each file is a full overwrite (Python re-reads everything).  |
//|   - Format: MetaTrader tab-separated OHLCV (same as MT5 export). |
//|                                                                  |
//| FILES WRITTEN (Common\Files\phantom_live\)                       |
//|   US100_M1.csv   US100_M5.csv   US100_M15.csv                   |
//|   US100_H1.csv   US100_H4.csv   US100_Daily.csv  US100_Weekly.csv|
//|                                                                  |
//| SETUP                                                            |
//|   1. Compile and attach to any chart of the instrument.          |
//|   2. Set InpSymbol to match your broker's symbol name.           |
//|   3. Set InpPrefix to match your instrument label (e.g. US100).  |
//|   4. The phantom_live_daemon.py --m5 arg should point to         |
//|      Common\Files\phantom_live\US100_M5.csv (and so on).         |
//+------------------------------------------------------------------+
#property strict
#property description "PhantomBarWriter - exports live bars for the Python daemon"

input string InpSymbol        = "US100.cash"; // Broker symbol to export
input string InpPrefix        = "US100";       // File prefix (e.g. US100, XAU, BTC)
input int    InpM1Bars        = 10000;         // Max M1 bars to export
input int    InpM5Bars        = 10000;         // Max M5 bars to export
input int    InpM15Bars       = 5000;          // Max M15 bars to export
input int    InpH1Bars        = 3000;          // Max H1 bars to export
input int    InpH4Bars        = 2000;          // Max H4 bars to export
input int    InpDailyBars     = 1500;          // Max Daily bars to export
input int    InpWeeklyBars    = 500;           // Max Weekly bars to export
input bool   InpExportOnInit  = true;          // Full export on attach/restart
input bool   InpVerbose       = false;         // Print debug messages

string g_folder = "phantom_live\\";
string g_symbol = "";

datetime g_last_m1   = 0;
datetime g_last_m5   = 0;
datetime g_last_m15  = 0;
datetime g_last_h1   = 0;
datetime g_last_h4   = 0;
datetime g_last_d1   = 0;
datetime g_last_w1   = 0;

//+------------------------------------------------------------------+
string FileName(const string tf)
{
   return g_folder + InpPrefix + "_" + tf + ".csv";
}

//+------------------------------------------------------------------+
bool ExportTF(const ENUM_TIMEFRAMES tf, const string tf_name, const int max_bars, datetime &last_bar)
{
   // Always export a minimum of 1 closed bar beyond the current (open) bar.
   // iTime(,, 0) is the current forming bar - we skip it and only export
   // completed bars (index 1..max_bars).
   int total = iBars(g_symbol, tf);
   if(total <= 1)
   {
      if(InpVerbose)
         PrintFormat("PhantomBarWriter: skip %s %s | insufficient bars=%d", g_symbol, tf_name, total);
      return false;
   }

   int count = MathMin(max_bars, total - 1); // exclude the open bar at index 0
   if(count <= 0) return false;

   datetime newest_bar = iTime(g_symbol, tf, 1); // last COMPLETED bar
   if(newest_bar == last_bar) return false;        // nothing new

   string fname = FileName(tf_name);
   ResetLastError();
   int h = FileOpen(fname, FILE_WRITE|FILE_TXT|FILE_ANSI|FILE_COMMON);
   if(h == INVALID_HANDLE)
   {
      PrintFormat("PhantomBarWriter: cannot open %s | err=%d", fname, GetLastError());
      return false;
   }

   // Header - matches MetaTrader standard export format (tab-separated)
   FileWrite(h, "<DATE>\t<TIME>\t<OPEN>\t<HIGH>\t<LOW>\t<CLOSE>\t<TICKVOL>\t<VOL>\t<SPREAD>");

   // Write bars from oldest to newest (index count..1)
   for(int i = count; i >= 1; i--)
   {
      datetime bar_time = iTime(g_symbol, tf, i);
      if(bar_time == 0) continue;

      MqlDateTime dt;
      TimeToStruct(bar_time, dt);

      string date_str = StringFormat("%04d.%02d.%02d", dt.year, dt.mon, dt.day);
      string time_str = StringFormat("%02d:%02d:%02d", dt.hour, dt.min, dt.sec);

      double o = iOpen(g_symbol,  tf, i);
      double hi = iHigh(g_symbol, tf, i);
      double lo = iLow(g_symbol,  tf, i);
      double c = iClose(g_symbol, tf, i);
      long   tv = iTickVolume(g_symbol, tf, i);
      long   rv = iVolume(g_symbol, tf, i);
      int    sp = iSpread(g_symbol, tf, i);

      FileWrite(h,
         date_str + "\t" + time_str + "\t" +
         DoubleToString(o, _Digits)  + "\t" +
         DoubleToString(hi, _Digits) + "\t" +
         DoubleToString(lo, _Digits) + "\t" +
         DoubleToString(c, _Digits)  + "\t" +
         IntegerToString(tv) + "\t" +
         IntegerToString(rv) + "\t" +
         IntegerToString(sp)
      );
   }

   FileClose(h);
   last_bar = newest_bar;

   if(InpVerbose)
      PrintFormat("PhantomBarWriter: exported %s %s (%d bars) -> %s", g_symbol, tf_name, count, fname);

   return true;
}

//+------------------------------------------------------------------+
void ExportAll()
{
   ExportTF(PERIOD_M1,  "M1",     InpM1Bars,    g_last_m1);
   ExportTF(PERIOD_M5,  "M5",     InpM5Bars,    g_last_m5);
   ExportTF(PERIOD_M15, "M15",    InpM15Bars,   g_last_m15);
   ExportTF(PERIOD_H1,  "H1",     InpH1Bars,    g_last_h1);
   ExportTF(PERIOD_H4,  "H4",     InpH4Bars,    g_last_h4);
   ExportTF(PERIOD_D1,  "Daily",  InpDailyBars, g_last_d1);
   ExportTF(PERIOD_W1,  "Weekly", InpWeeklyBars,g_last_w1);
}

//+------------------------------------------------------------------+
void ExportAllWithSummary(const string source)
{
   ExportAll();

   if(InpVerbose)
      PrintFormat("PhantomBarWriter: export sweep from %s complete | symbol=%s prefix=%s | last_m1=%s last_m5=%s last_m15=%s last_h1=%s last_h4=%s last_d1=%s last_w1=%s",
                  source,
                  g_symbol,
                  InpPrefix,
                  TimeToString(g_last_m1, TIME_DATE|TIME_SECONDS),
                  TimeToString(g_last_m5, TIME_DATE|TIME_SECONDS),
                  TimeToString(g_last_m15, TIME_DATE|TIME_SECONDS),
                  TimeToString(g_last_h1, TIME_DATE|TIME_SECONDS),
                  TimeToString(g_last_h4, TIME_DATE|TIME_SECONDS),
                  TimeToString(g_last_d1, TIME_DATE|TIME_SECONDS),
                  TimeToString(g_last_w1, TIME_DATE|TIME_SECONDS));
}

//+------------------------------------------------------------------+
int OnInit()
{
   ResetLastError();
   if(!FolderCreate(g_folder, FILE_COMMON))
   {
      int folder_err = GetLastError();
      if(folder_err != 0 && folder_err != 5018)
      {
         PrintFormat("PhantomBarWriter: failed to create Common\\Files\\%s | err=%d", g_folder, folder_err);
         return INIT_FAILED;
      }
   }

   g_symbol = InpSymbol;
   if(g_symbol == "" || !SymbolSelect(g_symbol, true))
   {
      g_symbol = _Symbol;
      if(!SymbolSelect(g_symbol, true))
      {
         string alts[] = {"US100", "US100.cash", "NAS100", "USTEC", "USTECH", "ND100m", "ND100M"};
         bool found = false;
         for(int i = 0; i < ArraySize(alts); i++)
         {
            if(SymbolSelect(alts[i], true))
            {
               g_symbol = alts[i];
               found = true;
               break;
            }
         }
         if(!found)
         {
            Print("PhantomBarWriter: symbol not found - ", InpSymbol, " / ", _Symbol);
            return INIT_FAILED;
         }
      }
   }

   // Create the output folder (harmless if already exists)
   // MT5 Common\Files is the root; subdirectory created via FileOpen path
   PrintFormat("PhantomBarWriter: init | symbol=%s prefix=%s folder=Common\\Files\\%s",
               g_symbol, InpPrefix, g_folder);

   EventSetTimer(1);

   if(InpExportOnInit)
   {
      Print("PhantomBarWriter: running full initial export...");
      ExportAllWithSummary("OnInit");
      Print("PhantomBarWriter: initial export complete");
   }

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnTick()
{
   // Only act on new M5 bars (cheap check)
   datetime cur_m5 = iTime(g_symbol, PERIOD_M5, 0);
   if(cur_m5 == g_last_m5) return; // same bar, skip

   // A new M5 bar has formed - export all TFs that have a new completed bar.
   // ExportTF() internally checks last_bar and skips if unchanged.
   ExportAllWithSummary("OnTick");
}

//+------------------------------------------------------------------+
void OnTimer()
{
   ExportAllWithSummary("OnTimer");
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   Print("PhantomBarWriter: deinitialized | reason=", reason);
}
//+------------------------------------------------------------------+
