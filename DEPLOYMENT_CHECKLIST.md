# Phantom P2 US100 Scenario B - MT5 Deployment Checklist

**Version**: Phantom P2 US100 B (mql5_v1.ex5)  
**Status**: Ready for Live Deployment  
**Compile Date**: 2026-04-29  
**Compiled Errors**: 0 | **Warnings**: 0

---

## 📋 Pre-Deployment Checklist

### 1. **File Placement**
- [x] `.ex5` compiled artifact is in: `/Users/niko/Library/Application Support/net.metaquotes.wine.metatrader5/drive_c/Program Files/MetaTrader 5/MQL5/Experts/Custom/mql5_v1.ex5`
- [ ] Open MT5 Terminal → **Navigator** (Ctrl+N) → **Expert Advisors** → **Custom**
- [ ] You should see **mql5_v1** in the list (or refresh with F5)
- [ ] **Source file** (optional, for editing): Copy `phantom/mql5/mql5_v1.mq5` to your MT5 MQL5/Experts/Custom folder if you need to recompile

### 2. **Symbol & Timeframe Setup**
- [ ] Open US100 chart in **M5 timeframe** (M5 is the entry timeframe)
- [ ] Ensure the chart is in **UTC timezone** or your broker's UTC offset is correctly configured
- [ ] Symbol should be **US100** (verify broker's exact name: sometimes `NAS100`, `IND100`, etc.)

### 3. **Attach to Chart**
- [ ] Right-click on chart → **Attach Expert Advisor** (or drag `mql5_v1` onto chart)
- [ ] Or: Double-click `mql5_v1` in Navigator
- [ ] Select **Inputs** tab in the EA dialog

---

## ⚙️ Recommended Input Parameters for Scenario B (High Risk)

```
=== ENTRY ZONE PARAMETERS ===
Pivot Bars for Zone Detection       : 2
H4 Bars Lookback for Zones          : 50
Zone Proximity Tolerance (0-1%)     : 0.002
Max Distance from Zone (M15 ATR mult): 1.5

=== SESSION FILTER ===
Session Start (UTC hour)            : 13
Session End (UTC hour)              : 21
Enable Peak Session Boost (14-17)   : true

=== ZONE CONFIRMATION ===
Min H1 Bars Before Zone Active      : 1
Confirmation Timeframe              : H1

=== SCORING ===
Minimum Total Score                 : 3
Minimum H4 Score                    : 1
Minimum H1 Score                    : 1
Minimum LTF (M5) Score              : 1
Maximum LTF Score Cap               : 3
Additional Score Required for Longs : 1

=== RISK MANAGEMENT ===
Risk per Trade (% of capital)       : 1.4
Stop Loss (H4 ATR multiplier)       : 1.5
Take Profit (R multiple)            : 1.3
Trailing Stop (H4 ATR multiplier)   : 0.8
Move Stop to BE at this R value     : 0.8
Max Concurrent Positions per 4H     : 3
Cooldown between entries (minutes)  : 20
Lockout after loss (minutes)        : 60
Consecutive Losses to Pause         : 5
Pause Duration (hours)              : 24

=== POSITION SIZING ===
Confidence Multiplier (high score)  : 1.5
Session Soft Multiplier             : 0.5
Counter-Trend Multiplier            : 0.5

=== EXECUTION ===
Spread Adjustment (basis points)    : 1.0
Slippage Adjustment (basis points)  : 1.0
Magic Number (unique identifier)    : 202406
Order Comment                       : Phantom P2 US100 B

=== TIME HANDLING ===
Broker UTC Offset                   : 2 (or auto-detect: 2 winter, 3 summer)
Auto-Switch Winter/Summer Offsets   : true
Winter UTC Offset (Nov-Mar)         : 2
Summer UTC Offset (Mar-Nov)         : 3

=== DEVELOPMENT ===
Enable Debug Print Output           : false (set to true if troubleshooting)
Enable Visuals (zone drawing)       : true
```

---

## 🚀 Live Deployment Steps

### Step 1: Validate Settings
1. [ ] Verify **Magic Number** is **unique** (202406 is recommended, but must not clash with other EAs on same account)
2. [ ] Check **Risk %** matches your account risk tolerance (1.4% is aggressive; reduce to 0.7% for conservative)
3. [ ] Confirm **Broker UTC Offset** matches your broker's time offset (usually 2 for EET/FET, 3 for EEST/FEST)
4. [ ] Test **Symbol name** is correct for your broker

### Step 2: Paper Trading (Recommended)
1. [ ] Switch MT5 to a **Demo Account** first
2. [ ] Attach EA to US100 M5 chart
3. [ ] Run for at least **1 week** to observe entry signals and position management
4. [ ] Check **Expert tab** for any error messages
5. [ ] Verify zone detection and trade entries appear reasonable
6. [ ] Monitor the **Circuit Breaker** (should not activate unless 5 consecutive losses occur)

### Step 3: Go Live on Real Account
1. [ ] Switch to **Live Account**
2. [ ] Verify account balance and equity are correct
3. [ ] Start with **minimum risk** (0.5% instead of 1.4%) for first few days
4. [ ] Attach EA to chart with the same timeframe (M5)
5. [ ] Monitor trades closely during first trading session

---

## ⚠️ Critical Notes Before Going Live

### Known Limitations
- **Manual Stop/TP Management**: The EA does NOT use broker-side stops. Instead, it monitors positions on each M5 bar close and manually exits. This means:
  - Exits only trigger on M5 bar closes, not intrabar
  - Slippage may occur between signal time and execution
  - **Recommendation**: If your broker supports it, consider adding broker-side stops for additional safety
  
- **Zone Confirmation Delay**: Zones require 1 H1 bar (60 minutes) of price holding the zone before they become tradeable. This matches the Python backtest model but can feel slow in live markets.

- **Cooldown/Lockout Periods**: 
  - 20 minutes between entries (cluster prevention)
  - 60 minutes after a loss (lockout)
  - These are strict to prevent revenge trading

### Safety Recommendations
1. [ ] **Start with a paper account** to verify signals and zone detection before real money
2. [ ] **Reduce risk % by 50%** for the first week live (use 0.7% instead of 1.4%)
3. [ ] **Monitor the Expert tab daily** for any errors or warnings
4. [ ] **Set maximum daily loss limit** at account level (e.g., max 5 consecutive losses triggers circuit breaker)
5. [ ] **Review trades weekly** to ensure entry/exit logic matches expectations

### Emergency Procedures
- **To Disable EA Immediately**: Right-click chart → **Remove Expert Advisor**
- **To Close All Positions**: Open each position → Right-click → **Close Position**
- **To Review Trade History**: Terminal → **Account History** tab → filter by Magic Number 202406

---

## 📊 Performance Expectations (From Backtests)

**US100 Scenario B (High Risk Profile)**
- Average Win: ~+0.5R to +1.5R (depends on market volatility)
- Average Loss: ~-1.0R (stop loss)
- Win Rate: ~45-55% (not a majority, but profitable due to larger wins)
- Risk/Reward Ratio: ~1.3:1 (intentional asymmetry)
- Max Drawdown: 15-25% (high risk profile)

**Expected Timeframe**: 50-200 trades per month (depends on market structure)

---

## 🔧 Troubleshooting

| Issue | Cause | Solution |
|-------|-------|----------|
| EA won't attach to chart | Symbol/timeframe mismatch | Ensure US100 chart is M5 and symbol name matches broker |
| No entry signals | Sessions blocked or zones not forming | Enable `InpEnableDebugPrint = true` to see zone count in Expert tab |
| Positions don't close | Manual exit management not triggered | Verify M5 bars are loading; check timezone offset |
| Compilation errors | Source file has syntax issues | Recompile in MetaEditor; check for typos in input parameters |

---

## 📞 Support & Logging

**Debug Mode**: Set `InpEnableDebugPrint = true` to see:
- Zone count refreshed
- Entry/exit signals
- Score calculations
- Circuit breaker activations

**Output Location**: Expert Advisor tab in MT5 Terminal → Messages tab

---

## ✅ Final Checklist Before First Trade

- [ ] Symbol is US100 (correct name for your broker)
- [ ] Timeframe is M5
- [ ] Magic Number is unique (202406)
- [ ] Risk % matches your tolerance
- [ ] UTC offset is correct for your broker
- [ ] EA is attached and shows "Status: Running" (or "Expert Advisor" in title bar)
- [ ] Visuals enabled to see zones on chart
- [ ] Debug print enabled (at least for first few days)
- [ ] Account is verified and funded
- [ ] Emergency procedures understood

---

**Last Updated**: 2026-04-29  
**Status**: ✅ Ready for Deployment
