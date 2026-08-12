# AjipSnD — EA Architecture

Files: `AjipSnD.mq5` (main) + 6 `.mqh` includes.

## Input Parameters

**Strategy**
```
InpTimeframe       = PERIOD_M1    — LTF, entry timeframe
InpHtfTimeframe    = PERIOD_M15   — HTF, retest zones timeframe
InpCandlesInit     = 50           — Lookback bars for initial trend
InpMaxZones        = 2            — Max active zones per type
InpMinZoneGapPoints = 0           — Min gap to opposite zone for entry (0=disabled)
InpHtfMaFilter     = false        — HTF MA direction filter
```

**Entry & Trade Sizing**
```
InpFixedLot     = 0.02   — Fixed lot per entry / pending
InpMaxTotalLots = 0.0    — Max volume per direction (0=disabled)
InpAllowHedging = true   — Allow BUY & SELL simultaneously
InpPosMaxLoss   = 0.0    — Max floating loss before TP→BE (0=disabled)
InpDeviation    = 10     — Slippage (points)
InpMagicNumber  = 99002  — Magic number
```

**Risk Management — Final** (permanen, lintas hari)
```
InpFinalProfitTarget = 0.0  — Close all + stop entry PERMANENTLY
InpFinalMaxLoss      = 0.0  — Close all + stop entry PERMANENTLY
InpStartingBalance   = 0.0  — Baseline (0=auto-capture)
```

**Risk Management — Daily**
```
InpDailyMaxProfit = 60.0   — Close all + block entries rest of day
InpDailyMaxLoss   = 280.0  — Close all + block entries rest of day
```

**Risk Management — Batch**
```
InpBatchMaxProfit       = 20.0  — Close batch only
InpBatchMaxLoss         = 0.0   — Close batch only
InpBatchCooldownMinutes = 11    — Cooldown after batch flat
```

**Partial Close**
```
InpPartialCloseProfit  = 10.0  — Floating profit threshold
InpPartialClosePercent = 50.0  — % of volume to close
```

**Trailing Stop**
```
InpTrailStartPoints    = 0     — Min profit (points) from entry before trail
InpTrailDistancePoints = 0     — SL distance (points) behind current price
```

**Session Filter**
```
InpTimezoneOffset = 0.0   — UTC offset for daily/weekly/session boundaries
InpSessionStart   = "02:00"  — Session start HH:MM local time
InpSessionEnd     = "20:00"  — Session end
```

**News Filter**
```
InpNewsFilterEnabled = true   — Block entries + profit exits around news
InpNewsMinImportance = CALENDAR_IMPORTANCE_HIGH
InpNewsMinutesBefore = 30
InpNewsMinutesAfter  = 30
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

**Multi-Account Orchestrator**
```
InpHandoffEnabled = false
InpHandoffFile    = "AjipSnD_Handoff.csv"
InpHeartbeatFile  = "AjipSnD_Heartbeat.csv"
```

---

## Init

```
1. Cache symbol info (digits, point, volume min/max/step)
2. Configure CTrade (SetDeviationInPoints, SetTypeFillingBySymbol, SetExpertMagicNumber)
3. Parse session start/end → g_sessionFilterEnabled
4. Set g_timezoneOffsetSeconds = InpTimezoneOffset * 3600
5. CaptureStartingBalance
6. RebuildTrackedPositions — detect partialClosed via volume < InpFixedLot
7. InitLTFStructure — replay bars, build initial LTF zones
8. InitHTFStructure — replay bars, build initial HTF zones, InvalidateHtfZones per bar
9. Initial DrawAllHtfZones
```

---

## OnTick

```
Per-tick (order matters):
0. WriteHeartbeat (~30s throttle)
1. UpdateMfeMae
1b. CheckPendingOrders — delete if outside HTF zone, detect fills → AddEntry
1c. CheckTrailingStop — per-tick, partialClosed positions only
2. CheckPartialClose (gated by news)
3. CheckFinalTargetCloseAll (gated) → return if hit
3b. CheckFinalMaxLossCloseAll (never gated) → return if hit
4. CheckBatchTargetCloseAll (gated) / CheckBatchMaxLossCloseAll (never)
5. CheckDailyTargetCloseAll (gated) / CheckDailyMaxLossCloseAll (never)
6. CheckSessionCloseAll (gated)
7. RecalculateAggregateSL

HTF update (separate new-bar gate):
  CopyRates 3 bars InpHtfTimeframe
  if new closed bar:
    InvalidateHtfZones(bar) — remove broken zones first
    ProcessZoneBar(bar) — detect new zone
    DrawAllHtfZones() — always, on every HTF bar close

LTF update (new closed bar gate):
  CopyRates 3 bars InpTimeframe
  if SAME bar as g_ltfLastBarTime → return
  UpdateLTF() — process closed bar + place pending if zone confirmed
  CheckInvalidPositions() — per LTF bar close, not per-tick
  CheckEntryCleanup() — fold closed positions into batch accumulator
  DrawPanel (if enabled)
```

---

## UpdateLTF (bar-close processing)

```
1. bar = rates[1] (latest closed bar)
2. ProcessZoneBar(bar) → check if zone confirmed
3. If zone CONFIRMED:
   a. AddDemandZone / AddSupplyZone → manage active zones
   b. Compute limit price: BUY LIMIT at demand.high, SELL LIMIT at supply.low
   c. Check if limit price is inside HTF zone
   d. One-shot check (confirmed.time != g_ltfZonePendingTime)
   e. ZoneGapBlocked + EntryGateBlocked → PlacePendingOrder
```

---

## UpdateHTF (bar-close processing)

```
1. bar = rates[1]
2. InvalidateHtfZones(bar) — remove zones broken by this bar
3. ProcessZoneBar(bar) → if zone confirmed → AddDemandZone/AddSupplyZone
4. DrawAllHtfZones() — always, zone rectangles extend to TimeCurrent()
```

---

## Pending Orders

| Action | Trigger |
|--------|---------|
| Place | LTF zone confirmed + limit price inside HTF zone + gates pass |
| Cancel | Zone replaced (new better zone of same type → CancelPendingForZone) |
| Cancel | Pending price drifts outside HTF zone (CheckPendingOrders per-tick) |
| Fill | OrderSelect fails → scan for new position → AddEntry to g_entries[] |

Struct: `PendingOrder { ticket, dir, price, zoneTime }` in `g_pendingOrders[]` array.
One-shot: `g_ltfZonePendingTime` prevents duplicate pendings per LTF zone.

---

## Zone Drawing

```
HTF zones: OBJ_RECTANGLE, dotted, filled, background
  Demand → clrDodgerBlue (width 2), Supply → clrOrangeRed (width 2)
  Redrawn via DrawAllHtfZones() on EVERY HTF bar close
  Zones extend from zone.time to TimeCurrent()

LTF zones: data-only — no chart objects (arrows removed)
```

---

## Position Management

- No SL/TP at entry — pending orders SL=0, TP=0
- Lot size: fixed (InpFixedLot)
- Multi-position: no position count limit
- Volume cap: InpMaxTotalLots per direction
- Hedging: InpAllowHedging=false blocks entry while opposite side open

### Partial Close + Breakeven

`CheckPartialClose` per-tick, gated by news:
```
if POSITION_PROFIT >= InpPartialCloseProfit AND not yet partial-closed:
  1. Calculate closeVol = posVolume * InpPartialClosePercent / 100
  2. PositionClosePartial(ticket, closeVol)
  3. PositionModify(ticket, SL=entryPrice, TP=0) → BE
  4. Mark partialClosed = true
```

### Trailing Stop

`CheckTrailingStop` per-tick, only for `partialClosed = true` positions:
```
BUY: if bid - entry >= trailStart → newSl = bid - trailDist, only move up
SELL: if entry - ask >= trailStart → newSl = ask + trailDist, only move down
```
Uses CopyTicks for real-time bid/ask (fallback to SymbolInfoTick).

### Invalid Position Handler

`CheckInvalidPositions` per LTF bar close (after UpdateLTF):
```
for each position:
  skip if PnL >= 0 (never touch profitable)
  skip if TP already at entry (one-shot)
  skip if entryTime >= g_ltfLastBarTime (grace 1 bar)

  Condition 1: entryPrice not in any active zone → entry premise broken
  Condition 2: |PnL| > InpPosMaxLoss → loss too high

  If invalid: PositionModify(ticket, curSl, entryPrice)
```

### Aggregate SL

Pooled budget per direction, same SL price for all positions:
```
1. Single loop: totalVolume + weightedSum (entryPrice × volume)
2. avgEntry = weightedSum / totalVolume
3. slPoints = budget / (totalVolume × valuePerPointPerLot)
4. commonSl = avgEntry ± slPoints × g_point
5. Apply same commonSl to all positions in direction
6. Skip if already within 0.5 point
```

### Batch Close-All vs Daily Close-All

| | Batch | Daily |
|---|---|---|
| Total | g_batchRealizedPnl + floating | GetDailyPnL() + floating |
| Effect | Close batch only | Close all + block entries rest of day |
| After hit | New batch can start immediately | No entries until next day |

### Final Close-All

Measured from g_startingBalance. Once hit, entry blocked permanently.

---

## Batch CSV Report

One row per batch flush. Columns: CloseTime, CloseReason, PositionCount,
Wins, Losses, BreakEven, TotalRealizedPnL, SumMFE, SumMAE, FirstEntryTime,
LastEntryTime. File: `AjipSnD_Batches_<symbol>_<login>.csv` in `Common\\Files`.

Close reasons: `DAILY_TARGET`, `DAILY_MAX_LOSS`, `BATCH_TARGET`,
`BATCH_MAX_LOSS`, `BATCH_FLAT`, `SESSION_END`, `FINAL_TARGET`, `FINAL_MAX_LOSS`.

---

## Timezone Offset

`InpTimezoneOffset` (default 0 = UTC) shifts all time-based calculations:
- GetLocalDayStart(), GetDailyPnL, GetWeekPnL, GetMonthPnL, InSession
- Example: offset `-4` (EST) → daily reset at 04:00 UTC

---

## Info Panel

22-line dashboard via OBJ_LABEL on OBJ_RECTANGLE_LABEL background:
```
AjipSnD v1.0
LTF Trend: UP (M1)       HTF Trend: DOWN (M15)
Demands: 2   Supplies: 1   Entries: 3
Today P/L: 123.45   Week P/L: 456.78   Month P/L: -12.34
Final: active   Daily: TARGET   Batch: active
Cooldown: clear   Session: OPEN   News: clear
Open MFE: 12.34   Open MAE: -5.67
```
