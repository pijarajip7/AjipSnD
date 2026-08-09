# AjipSnD — EA Architecture

Files: `AjipSnD.mq5` (main) + 4 `.mqh` includes.

## Input Parameters

Dikelompokkan dengan `input group`.

**Strategy**
```
InpTimeframe       = PERIOD_M1    — LTF, entry timeframe
InpHtfTimeframe    = PERIOD_M15   — HTF, retest zones timeframe
InpCandlesInit     = 50           — Lookback bars for initial trend
InpMaxZones        = 2            — Max active zones per type (demand/supply)
```

**Entry & Trade Sizing**
```
InpFixedLot     = 0.02   — Fixed lot per entry
InpMaxTotalLots = 0.0    — Max volume per direction (0=disabled)
InpAllowHedging = true   — Allow BUY & SELL simultaneously
InpDeviation    = 10     — Slippage (points)
InpMagicNumber  = 99002  — Magic number
```

**Risk Management — Final** (permanen, lintas hari)
```
InpFinalProfitTarget = 0.0  — Close all + stop entry PERMANENTLY (0=disabled)
InpFinalMaxLoss      = 0.0  — Close all + stop entry PERMANENTLY (0=disabled)
InpStartingBalance   = 0.0  — Baseline (0=auto-capture, persisted via GlobalVariable)
```

**Risk Management — Daily**
```
InpDailyMaxProfit = 60.0   — Close all + block entries rest of day (0=disabled)
InpDailyMaxLoss   = 280.0  — Close all + block entries rest of day (0=disabled)
```

**Risk Management — Batch**
```
InpBatchMaxProfit       = 20.0  — Close batch only, new entries still allowed (0=disabled)
InpBatchMaxLoss         = 0.0   — Close batch only, new entries still allowed (0=disabled)
InpBatchCooldownMinutes = 11    — Cooldown after batch flat (0=disabled)
```

**Partial Close**
```
InpPartialCloseProfit  = 10.0  — Floating profit ($) to trigger one-time partial close (0=disabled)
InpPartialClosePercent = 50.0  — % of volume to close at threshold
```

**Session Filter**
```
InpSessionStart = "02:00"  — Session start HH:MM server time (==end = disabled)
InpSessionEnd   = "20:00"  — Session end — outside: no entries; PnL>0 → close all
```

**Chart Display**
```
InpDrawLines   = true / InpShowPanel = true
InpPanelCorner = CORNER_LEFT_UPPER / InpPanelX = 20 / InpPanelY = 50
```

**Diagnostics**
```
InpEnableLog = true  — Toggle Print/PrintFormat output
```

---

## Init

```
1. Cache symbol info (digits, point, volume min/max/step)
2. Parse session start/end → g_sessionFilterEnabled
3. CaptureStartingBalance — auto-capture or use InpStartingBalance
4. InitLTFStructure:
   - Fetch InpCandlesInit bars
   - DetermineInitialTrend (highest/lowest chronological)
   - Replay bars forward → build initial zones
   - Set g_ltfLastBarTime
5. InitHTFStructure — same as above for HTF
```

---

## OnTick

```
Per-tick (order matters):
1. UpdateMfeMae
2. CheckPartialClose (one-time per position)
3. CheckFinalCloseAll → return if max loss/target hit
4. CheckBatchCloseAll
5. CheckDailyCloseAll
6. CheckSessionCloseAll
7. RecalculateAggregateSL

HTF update (separate new-bar gate):
  CopyRates 3 bars InpHtfTimeframe
  if new closed bar → UpdateHTF()

LTF update:
  CopyRates 3 bars InpTimeframe
  if SAME bar as g_ltfLastBarTime → return (new-bar gate)
  UpdateLTF() — process closed bar for zone detection + entry check

Post-bar:
  CheckEntryCleanup — fold closed positions into batch accumulator
  DrawPanel (if enabled)
```

---

## UpdateLTF (bar-close processing)

```
1. bar = rates[1] (latest closed bar)
2. Save trendBefore
3. ProcessZoneBar(bar) → check if zone confirmed
4. If zone CONFIRMED:
   a. AddDemandZone / AddSupplyZone → manage active zones
   b. Check entry condition:
      - Demand confirmed: bar.close in HTF demand zone? → BUY
      - Supply confirmed: bar.close in HTF supply zone? → SELL
   c. EntryGateBlocked check → OpenTrade if allowed
   d. Reset candidate for new trend
```

---

## UpdateHTF (bar-close processing)

```
Same as UpdateLTF but for HTF zones.
On zone confirmed → redraw all zones on chart.
No entry from HTF directly.
```

---

## Zone Drawing

```
Demand zones:  blue (clrDodgerBlue), width=2 for HTF, width=1 for LTF
Supply zones:  red (clrOrangeRed), width=2 for HTF, width=1 for LTF
Zones drawn as OBJ_RECTANGLE from zone.time to TimeCurrent().
Redraw on every HTF zone confirmation.
```

---

## Position Management

- No SL/TP at entry — order always SL=0, TP=0
- Lot size: fixed (InpFixedLot)
- Multi-position: no position count limit
- Volume cap: InpMaxTotalLots per direction (BUY and SELL capped independently)
- Hedging: InpAllowHedging=false blocks entry while opposite side open

### Partial Close + Breakeven

`CheckPartialClose` runs every tick:
```
if POSITION_PROFIT >= InpPartialCloseProfit AND not yet partial-closed:
  1. Calculate closeVol = posVolume * InpPartialClosePercent / 100
  2. PositionClosePartial(ticket, closeVol)
  3. PositionModify(ticket, SL=entryPrice, TP=0) → BE
  4. Mark partialClosed = true
```

### Batch Close-All vs Daily Close-All

| | Batch | Daily |
|---|---|---|
| Total | g_batchRealizedPnl + floating | GetDailyPnL() + floating |
| Effect | Close batch only | Close all + block entries rest of day |
| After hit | New batch can start immediately | No entries until next day |

### Final Close-All

Measured from g_startingBalance (persisted via GlobalVariable). Once hit,
entry blocked permanently until input reset.

### Aggregate SL

Safety net: distributes smallest active max loss budget across positions
without their own SL. Per-direction budget (not halved — worst case one
direction at a time).

---

## Batch CSV Report

One row per batch flush. Columns: `CloseTime, CloseReason, PositionCount,
Wins, Losses, BreakEven, TotalRealizedPnL, SumMFE, SumMAE, FirstEntryTime,
LastEntryTime`. File: `AjipSnD_Batches_<symbol>_<magic>.csv` in
`Common\Files`.

Close reasons: `DAILY_TARGET`, `DAILY_MAX_LOSS`, `BATCH_TARGET`,
`BATCH_MAX_LOSS`, `SESSION_END`, `FINAL_TARGET`, `FINAL_MAX_LOSS`.
