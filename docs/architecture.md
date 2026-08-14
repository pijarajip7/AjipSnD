# AjipSnD — EA Architecture

Files: `AjipSnD.mq5` (main) + 6 `.mqh` includes.

## Input Parameters

**Strategy**
```
InpTimeframe       = PERIOD_M1    — LTF, entry timeframe
InpHtfTimeframe    = PERIOD_M15   — HTF, retest zones timeframe
InpCandlesInit     = 50           — Lookback bars for initial trend
InpMaxZones        = 2            — Max active zones per type
InpMinZoneGapPoints = 0           — Min gap to NEWEST opposite HTF zone for entry (0=disabled)
InpRequireZoneValidation = true   — Require HTF zone follow-through before active (LTF always on)
InpMaxZoneWidthAtr = 1.25         — Max zone width / ATR to allow entry (0=disabled)
InpMinDispBodyAtr  = 1.00         — Min confirming-bar body / ATR to allow entry (0=disabled)
InpHtfMaFilter     = false        — HTF MA direction filter
```

### Zone Quality Gate

`ComputeZoneMetrics()` runs at every zone confirmation (live + init replay),
independent of `InpZoneQualityLog`, and sets `zone.qualityPass`. Zones that
fail stay in the active arrays — replacement, expiry, invalidation and CSV
logging are untouched — but `IsPriceInDemandZone()` / `IsPriceInSupplyZone()`
skip them, so they are never offered as entry areas. Panel shows
`tradeable/total`.

Both thresholds must pass together. Backtested on two separate 12-month
XAUUSD periods (threshold fitted on the first, validated once on the second):
neither does anything alone — width alone and displacement alone both leave
the MFE/MAE ratio at baseline. Combined they lift median MFE from 1.45 to
1.98 ATR with MAE unchanged, keeping ~13% of HTF zones.

If ATR is unavailable the gate fails open and prints a warning, so a broken
indicator handle cannot silently stop all trading.

**Entry & Trade Sizing**
```
InpFixedLot     = 0.02   — Fixed lot per entry / pending
InpMaxTotalLots = 0.0    — Max volume per direction (0=disabled)
InpAllowHedging = true   — Allow BUY & SELL simultaneously
InpPosMaxLoss   = 0.0    — Max floating loss before TP→BE (0=disabled)
InpDeviation    = 10     — Slippage (points)
InpMagicNumber  = 99002  — Magic number
```

**Structural Stop Loss** (experimental — see the section below)
```
InpStructuralSlMode   = false — Master switch (false=batch architecture, unchanged)
InpZoneSlBufferAtr    = 0.5   — SL buffer beyond the HTF zone's far edge, in LTF ATR
InpRiskPerTrade       = 15.0  — Risk per trade ($); lot derived from it (0=use InpFixedLot)
InpTakeProfitAtr      = 1.0   — TP distance from entry, in LTF ATR (0=no TP)
InpMaxPositionsPerDir = 0     — Max positions+pendings per direction (0=disabled)
InpMaxRiskOvershoot   = 1.25  — Cap on actual/budgeted risk when min lot floors it (0=no cap)
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
InpBatchMaxProfitAtr    = 1.0   — Target as x HTF ATR (frozen at batch start) x current open volume (0=use fixed $)
InpBatchMaxProfit       = 20.0  — Fixed $ batch target, used when InpBatchMaxProfitAtr=0
InpBatchMaxLoss         = 0.0   — Close batch only (always $ — not ATR-scaled)
InpBatchCooldownMinutes = 11    — Cooldown after batch flat
```

**Partial Close**
```
InpPartialCloseAtr     = 1.5   — Target as x HTF ATR frozen at entry (0=use fixed $)
InpPartialCloseProfit  = 10.0  — Fixed $ threshold, used when InpPartialCloseAtr=0
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
InpZoneQualityLog = true — Log zone quality metrics to CSV for backtest analysis
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
2. Follow-through validation (ALWAYS-ON):
   - awaiting: demand → bar.close > pending.confirmLevel? supply → bar.close < pending.confirmLevel?
   - passed → PlaceEntryForZone (inside HTF + ZoneGapBlocked + EntryGateBlocked → PlacePendingOrder)
3. ProcessZoneBar(bar) → check if zone confirmed
4. If zone CONFIRMED:
   a. Opposite formed first → pending zone fails (discarded, no entry)
   b. confirmLevel = bar.high (demand) / bar.low (supply)
   c. AddDemandZone / AddSupplyZone (data-only)
   d. Hold for follow-through validation (g_ltfPendingZone + g_ltfAwaitingValidation)
```

---

## UpdateHTF (bar-close processing)

```
1. bar = rates[1]
2. InvalidateHtfZones(bar) — remove validated zones broken by this bar
3. Follow-through validation (gated by InpRequireZoneValidation):
   - awaiting + bar.close beyond confirmLevel → promote pending to active (AddDemandZone/AddSupplyZone)
4. ProcessZoneBar(bar) → if zone confirmed:
   - InpRequireZoneValidation=true: opposite formed first → pending fails; hold new zone for validation
   - InpRequireZoneValidation=false: AddDemandZone/AddSupplyZone immediately
5. DrawAllHtfZones() — always; pending zone drawn in distinct colour
```

---

## Pending Orders

| Action | Trigger |
|--------|---------|
| Place | LTF zone VALIDATED (follow-through) + limit price inside HTF zone + gates pass |
| Cancel | Zone replaced (new better zone of same type → CancelPendingForZone) |
| Cancel | Pending price drifts outside HTF zone (CheckPendingOrders per-tick) |
| Cancel | Close-all (daily/final/session → CancelAllPendingOrders; batch TIDAK cancel) |
| Fill | OrderSelect fails → scan for new position → AddEntry to g_entries[] |

Struct: `PendingOrder { ticket, dir, price, zoneTime }` in `g_pendingOrders[]` array.
One-shot: `g_ltfZonePendingTime` prevents duplicate pendings per LTF zone.

---

## Zone Drawing

```
HTF zones: OBJ_RECTANGLE, dotted, filled, background
  Validated demand → clrDodgerBlue, Supply → clrOrangeRed (width 2)
  Pending (unvalidated) → clrSteelBlue (demand) / clrIndianRed (supply)
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

Target scale: `PartialCloseThreshold()` returns
`InpPartialCloseAtr x atrAtEntry x (tickValue/tickSize) x volume`, falling back
to the fixed `InpPartialCloseProfit` when the ATR mode is off or no ATR reading
is available. `atrAtEntry` is the HTF ATR frozen in `EntryTracker` at entry, so
a volatility spike cannot move the target away from a running position.

A fixed dollar target does not survive a regime change: on XAUUSD $10 was
reached by 33% of filtered entries in a low-volatility year and 67% in a
high-volatility one, while 1.5x ATR gave 57% and 61%. Since partial close is
what arms SL→BE and the trailing stop, a target that rarely fires leaves most
positions unmanaged.

`CheckPartialClose` per-tick, gated by news:
```
if POSITION_PROFIT >= PartialCloseThreshold(...) AND not yet partial-closed:
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
| Target | BatchProfitThreshold() — ATR x volume, or fixed $ | InpDailyMaxProfit (always $) |
| Effect | Close batch only | Close all + block entries rest of day |
| After hit | New batch can start immediately | No entries until next day |

`BatchProfitThreshold()` returns `InpBatchMaxProfitAtr x g_batchAtrAtStart x
(tickValue/tickSize) x totalOpenVolume`, falling back to the fixed
`InpBatchMaxProfit` when the ATR mode is off or no ATR/volume reading is
available. `g_batchAtrAtStart` is the HTF ATR frozen at the batch's first
entry (`AddEntry()`); `totalOpenVolume` is summed live from `g_entries[]` each
check, so a batch running more size needs a proportionally bigger move to
close. Scaling by volume matters because floating PnL scales with volume —
without it, a 10-position batch and a 1-position batch would cap at the same
dollar figure despite very different size.

A backtest comparing the zone quality gate ON vs OFF across two 12-month
XAUUSD periods found `BATCH_TARGET` realizing ~$20 on average in every run —
regardless of volatility regime or entries filtered — because a fixed dollar
cap always lands near itself the moment it's crossed. That flatness is what
motivated the ATR scaling: it made it structurally impossible for a
better-quality batch to bank a bigger win than a mediocre one.

`InpBatchMaxLoss` is unaffected — still a plain dollar figure, not ATR-scaled.

### Final Close-All

Measured from g_startingBalance. Once hit, entry blocked permanently.

---

## Batch CSV Report

One row per batch flush. Columns: CloseTime, CloseReason, PositionCount,
Wins, Losses, BreakEven, TotalRealizedPnL, SumMFE, SumMAE, FirstEntryTime,
LastEntryTime. File: `AjipSnD_Batches_<symbol>_<login>.csv` in `Common\\Files`.

Close reasons: `DAILY_TARGET`, `DAILY_MAX_LOSS`, `BATCH_TARGET`,
`BATCH_MAX_LOSS`, `BATCH_FLAT`, `SESSION_END`, `FINAL_TARGET`, `FINAL_MAX_LOSS`.

### A row means positions actually closed

`CloseAllAndFlushBatch()` banks a position only after the close has removed
it, and flushes only once the batch is flat. This matters because
`PositionClose` can be rejected — market closed over a holiday, trade context
busy — and every caller re-checks its trigger on the next tick.

The function used to bank all open positions *before* calling
`CloseAllPositions()` and flush regardless of the outcome. When a close was
rejected the positions survived, but the row was written and the accumulator
reset anyway; the next tick found the same trigger still true and repeated the
whole sequence. One stalled close therefore produced hundreds of duplicate
rows, recognisable by a `FirstEntryTime` of `1970.01.01 00:00:00` (the zeroed
`g_batchFirstEntryTime`), a `PositionCount` that never decreases, and a
`TotalRealizedPnL` that drifts slightly per row because it is re-read from
still-open positions. Two 12-month XAUUSD runs contained 759 such rows across
three holiday sessions, inflating counted positions to 2.5x the number of
entries the zone log recorded — enough to reverse the sign of an A/B comparison
if read at face value.

Deferring the flush until the batch is flat keeps one row per batch when a
close needs several attempts, rather than fragmenting it into one row per
attempt (which would corrupt batch-level statistics just as badly). A deferred
flush logs `close incomplete — N position(s) still open`. If the remaining
positions disappear by another route first, `CheckEntryCleanup()` flushes the
batch as `BATCH_FLAT`.

---

## Zone Quality CSV (backtest analysis)

`InpZoneQualityLog=true` (default). Live-confirmed zones (LTF + HTF) are tracked
from confirmation to outcome. Two row types join via `tf,type,zone_time`:

```
CONFIRM   — written at zone confirmation; quality attributes measured at that moment
OUTCOME   — written when fate is known; behavior stats accumulated since confirm
```

Outcomes: `VALIDATED`, `FAILED_OPPOSITE`, `INVALIDATED`, `REPLACED`, `EXPIRED`,
`UNRESOLVED` (flushed on OnDeinit).

Quality attributes (CONFIRM):
```
atr, width_atr, disp_body_atr, disp_range_atr  — displacement / width vs ATR
base_bars        — bars candidate stayed alive before confirmation (1=impulsive)
swept_low/high   — liquidity grab recorded on candidate
trend_at_confirm — trend of this TF when zone confirmed. Carries NO information:
                   a demand zone can only confirm out of a DOWN trend on its own
                   timeframe and a supply zone only out of an UP trend, so this
                   field is a restatement of `type`. Kept for log continuity.
htf_trend        — HTF trend at confirmation. On an LTF zone this is the real
                   cross-timeframe alignment attribute; on an HTF zone it is
                   collinear with type, like trend_at_confirm.
```

Behavior stats (OUTCOME):
```
bars_since, bars_to_touch, touched, touch_depth_pts
max_fav_pts, max_adv_pts, fav_after_touch_pts
validated, entry_placed, quality_pass
```

File is written as `FILE_CSV|FILE_ANSI` with `,` and CP_UTF8 — `FILE_TXT`
writes every field with no separator at all, which makes the log
unparseable. Header is one argument per column so the field counts cannot
drift apart.

Tracker: `g_zoneTracker[]` (SnDZone copies with `isHtf` key). Stats updated per
bar via `UpdateZoneTracking()` — HTF before invalidation so the breaking bar is
captured. ATR via `iATR(14)` handles (LTF + HTF) created in OnInit.

File: `AjipSnD_Zones_<symbol>_<login>.csv` in `Common\Files`.

Purpose: collect data now; later analyze which attributes predict good outcomes,
then turn winners into entry filters.

---

## Structural SL Mode (experimental)

A second risk architecture living beside the batch one in the same binary, so
the Strategy Tester can A/B them without recompiling. `InpStructuralSlMode=false`
skips every path it adds; the batch architecture is untouched.

**Why it exists.** Measured over two 12-month XAUUSD periods, the batch
architecture runs about 1 percentage point above the win rate it needs to break
even (88–90% actual against an 88–94% requirement), and that win rate is
manufactured by having no stop at all. Positions are opened naked —
`BuyLimit(..., 0.0, 0.0, ...)` — and the only protection is a pooled dollar
budget applied afterwards, which lets a loser run until it either recovers or
consumes the whole daily allowance. Wins average $13–26; a bad day costs $227–280,
so one bad day erases 9–20 wins while only 10–13 are available to pay for it.

**The trade shape it replaces.** One position per zone, with a hard stop beyond
the structure that justified the trade and a target measured from the entry.
Win rate is expected to fall sharply — 83–84% of entries eventually reach 1.0
LTF ATR if you wait indefinitely, and a stop stops the waiting. It has to be
judged on expectancy, never on win rate.

### The stop is anchored to the HTF zone, not the LTF zone

The LTF zone is the trigger; the HTF zone is the thesis. Entry sits at the LTF
zone's near edge, but the entry is only allowed when that price falls inside a
live HTF zone, so either could anchor the stop. Measured on the entries that
actually happened:

| | median distance from entry | stop touched |
|---|---|---|
| LTF far edge | 1995 pts (1.21 LTF ATR) | 59% |
| HTF far edge | 5765 pts (3.34 LTF ATR) | 17% |
| median adverse excursion | 3293 pts | — |

The third row settles it: the typical move against the trade is deeper than the
LTF zone is wide, so an LTF-anchored stop sits inside ordinary noise. Price
leaving the LTF zone means the timing was wrong; price leaving the HTF zone
means the reason was.

The cost is reward:risk. A stop 3x wider needs a 3x smaller multiple for the
same target, which is why `InpTakeProfitAtr` is capped in practice around 1.0:
at 2.0 LTF ATR only 61% of entries ever travel far enough, already short of the
66% such a reward:risk needs to break even.

`FindContainingZoneIdx()` is the single containment rule; `IsPriceInDemandZone`
and `IsPriceInSupplyZone` are wrappers over it. Where several zones contain the
price the furthest far edge wins — never a tighter stop than another equally
valid zone would have justified.

### Lot follows the stop

`LotForRisk()` sizes so that hitting the stop costs about `InpRiskPerTrade`,
rounding **down** to the volume step so the budget is a ceiling. Sizing happens
after the stops-level clamp, since the clamp can widen the stop.

The broker's minimum lot puts a floor under achievable risk, and on XAUUSD that
floor is high: 0.01 lots cost roughly a dollar per price unit of stop distance,
and stop distances run 3.9–12.6 price units across the quartiles. A $5 budget is
therefore unreachable on 64% of entries, with realised risk averaging $10.37 —
risk sizing collapsing into fixed lots with extra steps. `InpRiskPerTrade`
defaults to 15.0, where only 19% are floored and the realised average matches
the target.

Where the floor bites, the position can only be opened by risking **more** than
the budget, and `InpMaxRiskOvershoot` decides how much more is tolerable. Run #4
accepted the floor unconditionally, and the result was a risk cap that leaked:
5.2% of trades exceeded the budget and the worst risked $38.26 against $15 —
2.5x, on a 18.4-ATR stop. The worst single loss of the run, -$31.49, was not
slippage; it was sized that way on purpose.

The cap is a multiple rather than a hard 1.00 because volume-step rounding puts
many entries barely over the line. Measured against run #4:

| `InpMaxRiskOvershoot` | entries dropped | worst risk left |
|---|---|---|
| 1.00 | 5.8% | $15.00 |
| **1.25** (default) | **3.4%** | **$18.73** |
| 1.50 | 1.3% | $22.38 |
| 0 (no cap) | 0% | $38.26 |

Expectancy is unchanged at -0.065 R at every threshold, so the cap bounds the
tail without touching the edge — and 0 restores the run #4 behaviour for an
unbiased measurement pass, where discarding the widest-stop setups would skew
the sample.

Because risk is per-trade and `InpMaxPositionsPerDir` caps concurrency, total
simultaneous risk is bounded by construction — 2 directions x
`InpRiskPerTrade` x `InpMaxRiskOvershoot` — which is what makes the daily
allowance redundant here rather than merely unused.

### entry_placed means an order exists

`PlaceEntryForZone()` returns whether an order was actually accepted, not
whether a zone was worth trading. It used to return `true` before knowing:
entries rejected by the broker's volume range or by a failed send were latched
and still recorded as `entry_placed=1` in the zone CSV. Adding a risk cap would
have widened that gap by roughly 60 phantom rows per run.

The zone is still latched on a rejected entry — the same setup would be
re-evaluated identically on the next tick, so retrying only floods the log — but
the CSV column now tracks orders, not intentions. This corrects the column in
batch mode too; trading behaviour there is unchanged, but `entry_placed` counts
from run #4 and earlier are not directly comparable.

### One position per direction

`InpMaxPositionsPerDir` counts open positions **and resting limit orders**.
Counting only what is open would let several limits sit in the book and fill
together, so the rule would hold on average and fail exactly when several zones
confirm in a row. It is separate from `InpMaxTotalLots`, which caps volume —
and volume stops mapping to a position count once lot size varies.

### What stands down

Structural mode gives each trade exactly two outcomes so the result can be
stated in R. Everything else that writes SL or TP is disabled:

| | why it would interfere |
|---|---|
| `CheckPartialClose` | splits P&L across two fills while `riskUsd` covers the whole position — and its breakeven step calls `PositionModify(ticket, entry, 0.0)`, zeroing the TP |
| `CheckTrailingStop` | walks the stop away from the zone justifying it |
| `CheckInvalidPositions` | overwrites the TP with a breakeven one; the structural stop already *is* the invalidation rule |
| `CheckBatchTargetCloseAll` | the old architecture's primary exit, firing at an HTF-ATR-scaled threshold (~4.1x the LTF ATR the target uses) |
| `RecalculateAggregateSL` | skips structural positions in **both** its loops — leaving their volume in the pooled total would compute the shared stop distance against size the budget does not govern |

The batch target is gated in code rather than left to the preset: a preset that
forgot it would still run, and would quietly measure something else.

Portfolio-level closes (daily, session, final) are deliberately left alone —
they are risk limits, not trade exits. When they do fire they truncate a trade,
which is why `exit_reason` in the trade CSV matters: truncated trades can be
segmented out of an R analysis instead of silently polluting it.

---

## Trade CSV (per-position)

`InpTradeLog=true` (default). One row per closed position:
`AjipSnD_Trades_<symbol>_<login>.csv` in `Common\\Files`, written from every
path that removes an entry.

```
entry_time, exit_time, dir, entry_price, exit_price, sl_price, tp_price,
sl_dist_pts, sl_dist_atr, lot, risk_usd, exit_reason, pnl_usd, pnl_r,
mfe_usd, mae_usd, mfe_r, mae_r, atr_ltf, atr_htf, structural, ltf_zone_time
```

The batch CSV cannot serve this purpose. Its `CloseReason` explains why a
*batch* was flushed, so a stop-out and a target hit both arrive as `BATCH_FLAT`
— the EA only notices the position is gone. And its dollar P&L stops being
comparable across trades once lot size varies with stop distance.

Two columns carry most of the value:

- **`pnl_r`** — P&L over the risk the trade was sized for. The only thing that
  makes trades with different lot sizes comparable. It is 0 in batch mode,
  where no per-trade risk was ever defined.
- **`ltf_zone_time`** — the join key back to the zone CSV, connecting a trade's
  outcome to the characteristics of the zone that produced it. The two could
  previously only be measured separately. This is why `zoneTime` is threaded
  from `PendingOrder` into `EntryTracker` at the fill.

`exit_reason` comes from `DEAL_REASON` on the closing deal, so `SL` and `TP`
reflect what the broker did rather than an inference. That lookup also sums
profit + swap + **commission** across the position's deals and prefers that
figure, since R should be net of costs. On the close-all path the deal may not
have settled — the same history-timing gap the batch accounting works around —
so the caller's value and close reason are used as fallbacks. In structural mode
the dominant exits are broker-side and settle before they are read.

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
