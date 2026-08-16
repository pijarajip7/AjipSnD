# AjipSnD — EA Architecture

Files: `AjipSnD.mq5` (main) + 8 `.mqh` includes (`Globals`, `Excursion`,
`Drift`, `Zone`, `News`, `Trade`, `Entry`, `Core`).

## Input Parameters

**Strategy**
```
InpTimeframe       = PERIOD_M5    — LTF, entry timeframe
InpHtfTimeframe    = PERIOD_H1    — HTF, bias timeframe
InpCandlesInit     = 50           — Lookback bars for initial trend + OnInit replay window
InpMaxZones        = 2            — Max active zones per type
InpRequireZoneValidation = true   — Require HTF zone follow-through before active (LTF always on)
InpMaxZoneWidthAtr = 0            — Max zone width / ATR to allow entry (0=disabled)
InpMinDispBodyAtr  = 0            — Min confirming-bar body / ATR to allow entry (0=disabled)
InpHtfMaFilter     = false        — HTF MA direction filter
```

### Zone Quality Gate — diagnostic only, does not gate rejection-entry

`ComputeZoneMetrics()` runs at every zone confirmation (live + OnInit
replay), independent of `InpZoneQualityLog`, and sets `zone.qualityPass`.
Historically this gated which zones were offered for entry (via
`FindContainingZoneIdx`), but the rejection-entry mechanism does not consult
it anywhere: `SaveLtfZonesForHtfBias` and `CheckRejectionRetests` both work
directly off `g_ltfValidatedHistory[]` / `g_savedLtfZones[]`, neither of
which carries a `qualityPass` field. Today `qualityPass` only feeds the
panel's `tradeable/total` count, `FindContainingZoneIdx`'s
`htfContextValidated` diagnostic column, and the zone CSV's
`quality_pass` column — it no longer decides what gets traded.

If ATR is unavailable the gate fails open and prints a warning, so a broken
indicator handle cannot silently stop all trading.

**Entry & Trade Sizing**
```
InpAllowHedging = true   — Allow BUY & SELL simultaneously
InpDeviation    = 10     — Slippage (points)
InpMagicNumber  = 99002  — Magic number
```

There is no fixed-lot input — lot size is always risk-derived (see
*Structural SL/TP & Risk Sizing* below), and there is no volume cap either;
both existed in an earlier build and were removed because the volume cap's
own check estimated the next trade's size from the fixed-lot input, which
no longer describes what a risk-sized trade actually opens.

**Stop Loss & Take Profit**
```
InpZoneSlBufferAtr  = 1.0   — SL buffer beyond the rejection bar's own extreme, in LTF ATR
InpRejectionBodyAtr = 0.5   — Min rejection-bar body/ATR in the favourable direction
InpRiskPerTrade     = 50.0  — Risk per trade ($); lot derived from it (0=disable sizing, no trades)
InpTakeProfitRR     = 4.0   — TP = this many multiples of the actual SL distance (0=no TP)
InpMaxPositionsPerDir = 1   — Max positions per direction (0=disabled)
InpMaxRiskOvershoot = 0     — Cap on actual/budgeted risk when min lot floors it (0=no cap)
```

**Risk Management — Final** (permanen, lintas hari)
```
InpFinalProfitTarget = 0.0  — Close all + stop entry PERMANENTLY
InpFinalMaxLoss      = 0.0  — Close all + stop entry PERMANENTLY
InpStartingBalance   = 0.0  — Baseline (0=auto-capture)
```

**Risk Management — Daily**
```
InpDailyMaxProfit = 0.0   — Close all + block entries rest of day
InpDailyMaxLoss   = 0.0   — Close all + block entries rest of day
```

**Session Filter**
```
InpTimezoneOffset = 7.0      — UTC offset for daily/weekly/session boundaries
InpSessionStart   = "06:00"  — Session start HH:MM local time
InpSessionEnd     = "00:00"  — Session end
```

Session filter only gates NEW entries (`EntryGateBlocked` → `InSession()`).
There is no session-end profit close-all — an earlier build force-closed
open profitable positions when the session ended; that was removed, so
positions now run purely to their own broker SL/TP or a daily/final
close-all regardless of session.

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
InpEnableLog      = true — Toggle Print/PrintFormat output
InpZoneQualityLog = true — Log zone quality metrics to CSV for backtest analysis
InpTradeLog       = true — Log per-trade CSV for backtest analysis
```

**Diagnostics — excursion grid (currently dormant, see the section below)**
```
InpExcursionLog     = false — First-touch grid per entry opportunity (offline SL/TP surface)
InpExcursionBars    = 240   — Horizon tracked after the limit is touched (M1 bars)
InpExcursionArmBars = 60    — How long an untouched limit stays armed (M1 bars)
InpStopEntryProbe   = false — Also observe stop-entry variants (5 records/zone, no orders)
InpRejectEntryProbe = false — Also observe rejection-entry variants (5 more records/zone, no orders)
```

**Diagnostics — forward drift**
```
InpDriftLog          = false — Log forward-drift probe (zone confirm vs random baseline)
InpDriftBaselineProb = 0.03  — Per-bar draw probability for the random baseline
InpDriftTrendProbe   = false — Also observe an MA-trend probe
InpDriftTrendTf      = PERIOD_H1
InpDriftTrendMaPeriod = 50
```

**Multi-Account Orchestrator**
```
InpHandoffEnabled = false
InpHandoffFile    = "AjipSnD_Handoff.csv"
InpHeartbeatFile  = "AjipSnD_Heartbeat.csv"
```

---

## Init — `ReplayInitialStructure()`

Replaces the EA's earlier "seed the zone arrays from the last N bars"
init with a real chronological replay, so the EA leaves OnInit with the
same `g_htfBiasDir` / `g_savedLtfZones[]` continuous live operation would
have accumulated, instead of an empty bias waiting for the first live HTF
validation.

```
1. CopyRates InpHtfTimeframe, start_pos=1 (skip the still-forming current
   bar), InpCandlesInit bars → HTF trend via DetermineInitialTrend
2. windowStart = oldest fetched HTF bar's time
3. CopyRates InpTimeframe from windowStart to TimeCurrent() — a calendar
   span, not a fixed bar count: a fixed InpCandlesInit LTF-bar count would
   badly under-cover the HTF window whenever InpTimeframe is much finer
   than InpHtfTimeframe (e.g. InpCandlesInit=50 gives ~50 HTF bars but only
   50 LTF bars — a fraction of the same calendar span). Drop the newest LTF
   bar if it hasn't closed yet.
4. LTF trend via DetermineInitialTrend over the last InpCandlesInit bars
   of that fetched LTF window (same short-recent-window convention as
   before, just sourced from the larger fetch)
5. Merge-walk both bar streams by CLOSE time (bar.time + PeriodSeconds(tf)),
   calling UpdateHTF(bar, true) / UpdateLTF(bar, true) in true
   chronological order
6. Draw the saved-zone rectangles once, after the replay completes
```

Interleaving by close time (not replaying LTF fully, then HTF, in two
passes) is required for correctness: `SaveLtfZonesForHtfBias`'s backward
search and `MarkLtfValidationContext`'s superseded-marking both depend on
`g_ltfValidatedHistory` reflecting only what had already validated as of
that same real-time moment. A two-pass replay would let an HTF bias see LTF
zones that, chronologically, validated after it did — over-saving relative
to what live processing would ever have produced.

`isReplay=true` (see `UpdateLTF`/`UpdateHTF` below) never places a real
order — `CheckRejectionRetests` still resolves every saved zone's fate
(broken, rejected, or still open) against the historical bars that follow
it, but skips `OpenMarketWithStructuralStops`: by the time OnInit runs,
price has already moved on from wherever a historical rejection bar closed,
so there is no legitimate fill left to send. It also skips every CSV/
diagnostic write (`UpdateZoneTracking`, `TrackZone`+`ZoneCsvWrite`, the
excursion/drift probes), so replaying the same historical window on every
restart does not keep re-appending rows to the same CSVs.

---

## OnTick

```
Per-tick (order matters):
0. WriteHeartbeat (~30s throttle)
1. UpdateMfeMae
1a. UpdateExcursions — diagnostic only, currently arms nothing (see Excursion CSV section)
1a2. DriftArmTrend — trend probe, self-gated on its own timeframe's bar close
2. CheckFinalTargetCloseAll (gated by news) → return if hit
2b. CheckFinalMaxLossCloseAll (never gated) → return if hit
3. CheckDailyTargetCloseAll (gated) / CheckDailyMaxLossCloseAll (never)

HTF update (separate new-bar gate):
  CopyRates 3 bars InpHtfTimeframe
  if >= 2 bars: UpdateHTF(htfRates[1])

LTF update (new closed bar gate):
  CopyRates 3 bars InpTimeframe
  if SAME bar as g_ltfLastBarTime → return
  UpdateLTF(ltfRates[1])
  CheckEntryCleanup() — positions closed outside close-all (broker SL/TP)
  DrawPanel (if enabled)
```

---

## UpdateLTF(bar, isReplay=false)

```
1. Quality tracker per-bar stats (if InpZoneQualityLog && !isReplay)
2. UpdateLtfValidatedHistoryTouch(bar) — keeps touchedEver current, always runs
3. Diagnostic probes (excursion reject check, drift baseline/records) — skipped if isReplay
4. If a zone is awaiting validation: track wick re-entry into its own range
   (g_ltfPendingTouched) — independent of the CSV tracker, so it stays
   accurate whether or not InpZoneQualityLog is on
5. Follow-through validation (ALWAYS-ON):
   - passed → MarkZoneValidated, MarkLtfValidationContext(zone, g_ltfPendingTouched)
     (appends to g_ltfValidatedHistory[], runs superseded-marking — see
     concept.md's Rejection-Entry Mechanism). Nothing trades here — an LTF
     zone validating never earns an order on its own.
6. ProcessZoneBar(bar) → check if zone confirmed
7. If zone CONFIRMED:
   a. Opposite formed first → pending zone fails (discarded, no entry)
   b. confirmLevel = bar.high (demand) / bar.low (supply)
   c. AddDemandZone / AddSupplyZone (data-only)
   d. Hold for follow-through validation, reset g_ltfPendingTouched
8. CheckRejectionRetests(bar, isReplay) — resolve every saved zone's fate
   against this bar
9. DrawSavedLtfZones() — skipped if isReplay (ReplayInitialStructure draws
   once at the end instead)
```

---

## UpdateHTF(bar, isReplay=false)

```
1. Quality tracker per-bar stats BEFORE invalidation (if InpZoneQualityLog && !isReplay)
2. InvalidateHtfZones(bar) — remove validated zones broken by this bar
3. Follow-through validation (gated by InpRequireZoneValidation):
   - passed → AddDemandZone/AddSupplyZone, then UNCONDITIONALLY:
     g_htfBiasDir = zone.isDemand ? 1 : -1
     SaveLtfZonesForHtfBias(zone) — backward replay, see concept.md
4. ProcessZoneBar(bar) → if zone confirmed:
   - InpRequireZoneValidation=true: opposite formed first → pending fails; hold new zone for validation
   - InpRequireZoneValidation=false: AddDemandZone/AddSupplyZone immediately
     (note: this path never sets g_htfAwaitingValidation, so step 3's bias/
     save trigger never fires — a pre-existing quirk of running with
     validation off, unrelated to isReplay)
5. Nothing drawn — HTF is a directional bias, not a chart object
```

---

## Zone Drawing

```
LTF (saved, watched) zones: OBJ_RECTANGLE via DrawHtfZoneRect, dotted, filled, background
  Demand → clrDodgerBlue, Supply → clrOrangeRed
  Zones already used (broken/rejected) are dropped, not kept drawn
  Redrawn on every LTF bar close (live) or once after replay (OnInit)

HTF zones: never drawn. HTF is a directional bias, not a chart object —
  see the Rejection-Entry Mechanism in concept.md.
```

---

## Structural SL/TP & Risk Sizing

Every entry is a market order (`OpenMarketWithStructuralStops`) with SL and
TP attached at the same moment — there is no separate mode or toggle;
this is simply how the EA sizes and stops every trade.

**SL** = the rejection bar's own extreme (`bar.low` for demand, `bar.high`
for supply — not the zone's static boundary, and not any HTF reference) ±
`InpZoneSlBufferAtr` x LTF ATR. The wick that just got rejected is the
actual proof the level held, and can sit shallower or deeper than the
zone's own `zLow`/`zHigh` (`wickedIn` only requires the wick to enter the
zone's range, not stop exactly at its edge). By the time an order is
placed the HTF side of the mechanism is a bias flag, not a zone reference,
so there is no HTF-anchor alternative to choose between either — an
earlier build had that choice as a toggle; this build does not.

**TP** = `InpTakeProfitRR` x the ACTUAL SL distance from the real fill
price, not an independent target — so the realised reward:risk is enforced
against what the order actually transacted at (0 = no TP).

### Lot follows the stop

`LotForRisk()` sizes so that hitting the stop costs about `InpRiskPerTrade`,
rounding **down** to the volume step so the budget is a ceiling. Returns
`0.0` — a skip, not a lot — whenever risk cannot actually be sized
(`InpRiskPerTrade<=0`, no stop distance, or broker tick data unavailable).
Sizing happens after the stops-level clamp, since the clamp can widen the
stop.

The broker's minimum lot puts a floor under achievable risk, and on XAUUSD
that floor is high: 0.01 lots cost roughly a dollar per price unit of stop
distance, and stop distances run 3.9–12.6 price units across the quartiles.
A $5 budget is therefore unreachable on 64% of entries, with realised risk
averaging $10.37 — risk sizing collapsing into fixed lots with extra steps.

Where the floor bites, the position can only be opened by risking **more**
than the budget, and `InpMaxRiskOvershoot` decides how much more is
tolerable:

| `InpMaxRiskOvershoot` | entries dropped | worst risk left (against a $15 budget) |
|---|---|---|
| 1.00 | 5.8% | $15.00 |
| 1.25 | 3.4% | $18.73 |
| 1.50 | 1.3% | $22.38 |
| 0 (no cap) | 0% | $38.26 |

Because risk is per-trade and `InpMaxPositionsPerDir` caps concurrency,
total simultaneous risk is bounded by construction — 2 directions x
`InpRiskPerTrade` x `InpMaxRiskOvershoot`.

### One position per direction

`InpMaxPositionsPerDir` counts open positions only (`DirectionalExposureCount`
sums `g_entries[]`) — there is no resting-order count to add, since every
entry fills immediately as a market order. An earlier build also counted
resting limit orders and capped total volume separately
(`InpMaxTotalLots`); both were removed once the entry mechanism stopped
using limit orders.

### `entry_placed` in the zone CSV

The function that set this column (`MarkZoneEntryPlaced`, called from the
old LIMIT-order entry path) was removed along with that path — nothing
sets it anymore, so it reads `0` for every row now. The field stays in the
CSV schema for column-count stability rather than being dropped.

---

## Excursion CSV (first-touch grid) — currently dormant

`InpExcursionLog=false` by default. One row per entry **opportunity**:
`AjipSnD_Excursion_<symbol>_<login>.csv` in `Common\\Files`.

**This diagnostic currently arms nothing.** It was built to observe the
EA's old LIMIT-at-zone-edge entry (`ExcursionArm`, called from the
now-removed `PlaceEntryForZone`/`CheckPendingOrders`) against STOP/REJECT
inversions of the same fill. With the entry mechanism itself now built
directly around a rejection concept (market order after a confirmed
rejection, not a resting limit), there is no remaining call site that arms
a record — `InpExcursionLog`, `InpStopEntryProbe` and `InpRejectEntryProbe`
still exist as inputs and the tracker (`UpdateExcursions`,
`ExcursionCsvWrite`, etc.) still compiles and runs every tick, but with
nothing ever calling `ExcursionArm`, it iterates an always-empty array. Left
in place rather than removed, since it is separately-built research tooling
(see `analysis/README.md`) rather than part of the entry mechanism, and
deleting it would need a deliberate decision about whether to rewire it
into the new mechanism first.

### Why stamps, not maxima

MFE/MAE prove a level was reached but not *when*, so they cannot say which
of two levels came first — exactly what a stop-and-target pair asks.
Recording the first-touch **time** of each level removes the ambiguity: for
any (SL, TP) pair on the grid the outcome is whichever stamp is smaller, so
a single run yields the entire expectancy surface — including targets the
EA never traded.

Grid, in LTF ATR at arm time:
```
0.25  0.50  0.75  1.00  1.25  1.50  2.00  2.50  3.00  4.00  5.00  6.00  8.00
```

`f025`..`f800` are seconds from trigger to first favorable touch, `a025`..`a800`
the adverse side, `-1` = never reached inside the horizon.

See `analysis/README.md` for the scripts that read this CSV and the
historical run findings (runs #4–#8) that motivated its design — those
findings describe the LIMIT-order entry this instrument was built to
observe, which is no longer how the EA trades.

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

- **`pnl_r`** — P&L over the risk the trade was sized for. The only thing
  that makes trades with different lot sizes comparable.
- **`structural`** — whether the position carried a stop at fill (`slPrice
  > 0.0`). Kept from an earlier build that had a non-structural path too;
  every current entry sets it, so the column is always `1` now.
- **`ltf_zone_time`** — the join key back to the zone CSV, connecting a
  trade's outcome to the characteristics of the zone that produced it.
  Threaded from `EntryFillInfo` (the fill-info struct `OpenMarketWithStructuralStops`
  passes to `AddEntry`) into `EntryTracker` at the fill.

`exit_reason` comes from `DEAL_REASON` on the closing deal, so `SL` and
`TP` reflect what the broker did rather than an inference. That lookup also
sums profit + swap + **commission** across the position's deals and prefers
that figure, since `pnl_r` should be net of costs. On the close-all path
the deal may not have settled yet, so the caller's snapshot value and close
reason are used as fallbacks.

---

## Timezone Offset

`InpTimezoneOffset` (default 7.0) shifts all time-based calculations:
- GetLocalDayStart(), GetDailyPnL, GetWeekPnL, GetMonthPnL, InSession
- Example: offset `-4` (EST) → daily reset at 04:00 UTC

---

## Info Panel

20-line dashboard via OBJ_LABEL on OBJ_RECTANGLE_LABEL background:
```
AjipSnD v1.0
LTF Trend: UP (M5)       HTF Trend: DOWN (H1)
Demands: 2/2   Supplies: 1/1   Entries: 3
Today P/L: 123.45   Week P/L: 456.78   Month P/L: -12.34
Final: active   Daily: TARGET
Session: OPEN   News: clear
Open MFE: 12.34   Open MAE: -5.67
```
`Demands`/`Supplies` count `g_ltfDemandZones`/`g_ltfSupplyZones` (LTF, not
HTF — HTF is a directional bias only, never geometrically meaningful) as
`tradeable/total`. See the Zone Quality Gate note above on what `tradeable`
still means now that it no longer gates
entries.
