# TimeZone Fix Implementation - UTC Offset Correction

## Problem Identified

The MT5 EA was using incorrect UTC offset parameters (2 for winter, 3 for summer) which are typical for European brokers (CET/CEST). However, US100 trades in **NYSE timezone (EST/EDT)**, which requires offset of **-5 (winter) or -4 (summer)**.

This caused a 7-hour time zone mismatch:
- **Bar time in CSV**: 14:40 EST (actual: 19:40 UTC)
- **EA interpretation**: 14:40 - 2 hours = 12:40 UTC (wrong!)
- **Session check**: 12:40 < 13:00 → sessionMult=0.00 ❌
- **Result**: Trades blocked despite being in valid session

## Fix Applied

### File: [phantom/mql5/mql5_v1_ftmo.mq5](phantom/mql5/mql5_v1_ftmo.mq5)

Changed UTC offset parameters on lines 76-79:

**BEFORE:**
```c
input int  InpBrokerUTCOffset = 2;         // Broker time = UTC + offset
input bool InpAutoUTCOffset = true;
input int  InpWinterUTCOffset = 2;         // Winter (Nov-Mar)
input int  InpSummerUTCOffset = 3;         // Summer (Mar-Nov)
```

**AFTER:**
```c
input int  InpBrokerUTCOffset = -5;        // Broker time = UTC + offset (US100 = EST = UTC-5)
input bool InpAutoUTCOffset = true;
input int  InpWinterUTCOffset = -5;        // Winter (EST, Nov-Mar)
input int  InpSummerUTCOffset = -4;        // Summer (EDT, Mar-Nov)
```

### Why This Works

**Time Conversion Logic** (lines 2017-2019):
```c
datetime ToUTC(datetime serverTime) {
   int offset = GetEffectiveUTCOffset();
   return serverTime - (offset * 3600);    // Convert server time to UTC
}
```

**With corrected offset:**
- Bar time: 14:40 (EST, displayed on chart)
- Offset: -5 (EST is UTC-5)
- UTC calculation: 14:40 - (-5) = 14:40 + 5 = 19:40 UTC ✓
- Session check: 13 ≤ 19 < 21 → sessionMult=1.00 ✓

## Verification Steps

After recompiling (DONE ✓), run the Strategy Tester with these settings:

### Test Configuration
- **Symbol**: US100.cash
- **Period**: 2026-01-28 to 2026-01-30 (includes divergence date 2026-01-29)
- **Model**: Every tick
- **Enable**: Debug Output (InpEnableDebugPrint=true)

### Expected Outputs on 2026-01-29

**SessionDebug lines** (should now show correct UTC times):
```
2026.01.29 14:40:00   SessionDebug: serverTime=2026.01.29 14:40 utcHour=19 start=13 end=21 → sessionMult=1.00
2026.01.29 15:10:00   SessionDebug: serverTime=2026.01.29 15:10 utcHour=20 start=13 end=21 → sessionMult=1.00
2026.01.29 15:35:00   SessionDebug: serverTime=2026.01.29 15:35 utcHour=20 start=13 end=21 → sessionMult=1.00
2026.01.29 16:40:00   SessionDebug: serverTime=2026.01.29 16:40 utcHour=21 start=13 end=21 → sessionMult=0.00 (just outside)
```

**EntryScanSummary** should now show:
- Session gating NOT blocking at 14:40+
- Only tolerance rejections remaining as blocker

### Success Criteria

✅ **Trade Execution**: Python and MT5 should execute trades at similar times (within tolerance threshold)
✅ **Session Alignment**: UTC hour values should be 19-21 for afternoon trades on 2026-01-29
✅ **Secondary Issue**: Tolerance rejections will still block trades (separate issue - may need adjustment)

## Remaining Issues

### 1. Zone Tolerance (0.2% = 0.002)
- Even with session fixed, all zones exceed tolerance threshold
- Evidence: `reason=tolerance zoneDist=0.615 tol=0.002000` (3x outside limit)
- **Status**: Known root cause, debug output now visible
- **Next**: May need tolerance adjustment or different signal price source

### 2. Peak Session Hours (14-17 UTC)
- Current: 14-17 UTC = 9-12 EST (market OPEN, not peak)
- NYSE peak: 14-16 EST = 19-21 UTC (better alignment)
- **Recommendation**: Review and adjust if needed

## Python Implementation Alignment

The Python code (phantom_US100_high_ftmo.py) may also need timezone verification:

```python
# Current: directly uses ts.hour from CSV (EST)
hour = ts.hour  # Gets 14, 15, 16, 17 in EST

# Session check: 13 <= hour < 21
# This passes for 14-20, but treats EST as UTC!
```

**Recommended**: Convert to UTC before session check
```python
# Better approach
ts_utc = pd.to_datetime(ts, utc=True).dt.tz_convert('UTC')
hour_utc = ts_utc.hour
```

## Files Modified

1. [phantom/mql5/mql5_v1_ftmo.mq5](phantom/mql5/mql5_v1_ftmo.mq5) - UTC offset parameters
   - Lines 76-79: Input parameters updated
   - Compiled to: mql5_v1_ftmo.ex5
   
2. [TIME_ZONE_ROOT_CAUSE.md](TIME_ZONE_ROOT_CAUSE.md) - Root cause analysis

## Build Status

✅ **Compilation**: Success (0 errors, 1 warning - type conversion)
✅ **Output**: /Users/niko/Library/Application Support/net.metaquotes.wine.metatrader5/drive_c/Program Files/MetaTrader 5/MQL5/Experts/mql5_v1_ftmo.ex5 (118 KB)
✅ **Timestamp**: May 15, 17:39 UTC

## Next Actions

1. **Run tester** with corrected EA on 2026-01-28 to 2026-01-30 period
2. **Analyze SessionDebug** output for correct UTC hour values
3. **Compare trade execution** between Python and MT5
4. **Address tolerance threshold** if session gating now allows trades to reach that filter
5. **Verify peak hours** configuration for US100 if peak session boost should be applied

## Testing Command

To manually run with latest compiled EA:
```bash
# Tester GUI will automatically use the latest .ex5 file
# Set parameters in: Tester → Settings
# - Symbol: US100.cash
# - Model: Every tick
# - Period: 2026-01-28 to 2026-01-30
# - Enable: Debug output in EA properties
```
