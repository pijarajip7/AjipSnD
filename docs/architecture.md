# AjipSnD — EA Architecture

Files: `AjipSnD.mq5` (main) + 8 `.mqh` includes (`Globals`, `Excursion`,
`Drift`, `Zone`, `News`, `Trade`, `Entry`, `Core`).

## Input Parameters

**Strategy**
```
InpTimeframe       = PERIOD_M5    — the only timeframe this EA detects zones on
InpCandlesInit     = 50           — Lookback bars for initial trend + OnInit replay window
InpMaxZones        = 10           — Max active zones per type
InpMaxZoneWidthAtr = 0            — Max zone width / ATR to allow entry (0=disabled)
InpMinDispBodyAtr  = 0            — Min confirming-bar body / ATR to allow entry (0=disabled)
InpMinZoneWidthPoints = 0         — Min zone width (points) to allow entry (0=disabled; real gate)
InpMaxZoneWidthPoints = 0         — Max zone width (points) to allow entry (0=disabled; real gate)
InpMinFavW = 3, InpMaxFavW = 10   — favW entry filter (min/max favorable pre-touch excursion, in zone widths; 0=disabled per side)
```

### Zone Quality Gate — diagnostic only, does not gate entry

`ComputeZoneMetrics()` runs at every zone confirmation (live + OnInit
replay), independent of `InpZoneQualityLog`, and sets `zone.qualityPass`.
Historically this gated which zones were offered for entry, but the
entry mechanism does not consult it anywhere:
`SaveLtfZoneForWatch` and `CheckRejectionRetests` both work directly off
`g_savedLtfZones[]`, which carries no `qualityPass` field. Today
`qualityPass` only feeds the panel's `tradeable/total` count and the zone
CSV's `quality_pass` column — it no longer decides what gets traded.
(`FindContainingZoneIdx`, which used to read it for an HTF-context
diagnostic column, was removed along with the rest of the HTF mechanism —
see *UpdateLTF* below for what replaced it.)

If ATR is unavailable the gate fails open and prints a warning, so a broken
indicator handle cannot silently stop all trading.

### favW entry filter — an actual entry gate (unlike the quality gate above)

`InpMinFavW` / `InpMaxFavW` (default 3 / 10) gate entry on
`favW`: the favorable pre-touch excursion expressed in zone widths — how far
price ran in the profitable direction after a zone confirmed, before coming
back to touch it. Same ratio as the chart's `favW~x` / `favW x` runway label
and the CSV's `fav_before_touch_width_ratio` column.

A saved zone whose FIRST touch lands with `favW` below `InpMinFavW` or above
`InpMaxFavW` is skipped — marked `used` with no order, one-shot consistent
with aggressive entry (the metric is monotonic, so a later touch can only be
further out of range). Evaluated on both the tick-level path
(`CheckAggressiveTickEntries`) and the bar-close path (`CheckRejectionRetests`);
on the tick path the value is `maxFavPts` as of the last closed bar — one bar
stale by construction, the same granularity the CSV's snapshot uses.

The metric lives in the zone-quality tracker (`maxFavPts`), so the tracker now
runs whenever this filter is enabled even if `InpZoneQualityLog` is off — CSV
writes still require `InpZoneQualityLog` (see `NeedsZoneTracking`).

### Zone-width filter (points) — an actual entry gate

`InpMinZoneWidthPoints` / `InpMaxZoneWidthPoints` gate entry on the zone's own
width in **points** (`zHigh − zLow`). Unlike the ATR-based
`InpMaxZoneWidthAtr`/`InpMinDispBodyAtr` (which feed the diagnostic
`qualityPass` only), this is applied for real — but at TOUCH time, exactly like
the favW filter: the zone stays on the watch list and drawn on chart (label
included), and a zone whose width falls below the min or at/above the max is
skipped when its first touch arrives (marked `used`, no order). No ATR
dependency, so it cannot fail open.

**Entry & Trade Sizing**
```
InpAllowHedging = false  — Allow BUY & SELL simultaneously (false=block opposite)
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
InpZoneSlBufferWidthMult = 2.0 — SL buffer beyond breakLevel, in zone widths (was ATR-based)
InpRiskPerTrade     = 50.0  — Risk per trade ($); lot derived from it (0=disable sizing, no trades)
InpTakeProfitRR     = 4.0   — TP = this many multiples of the actual SL distance (0=no TP)
InpMaxPositionsPerDir = 1   — Max positions per direction (0=disabled)
InpMaxRiskOvershoot = 0     — Cap on actual/budgeted risk when min lot floors it (0=no cap)
```

Entry is always aggressive (first touch, no rejection pattern) — formerly
gated behind `InpAggressiveEntry`, now the only mode, so that input and its
paired `InpRejectionBodyAtr` (the rejection-bar body/ATR threshold) are both
gone.

**Trailing Stop & Invalidation TP**
```
InpBreakEvenOffsetPoints   = 0     — Points beyond entry for the BE price (invalidation TP→BE)
InpInvalidationTpBeEnabled = true  — Move TP to breakeven when price pushes past the entry zone's breakLevel + buffer
InpInvalidationBufferZoneWidths = 1.0 — Zone widths beyond breakLevel before the position is considered invalid
InpTrailingStopEnabled     = true  — Enable trailing stop on all open positions (new SL applied only once in profit)
InpTrailingStopTrigger     = 2.0   — Arm trailing once floating profit reaches this many zone widths past entry
InpTrailingStopStart       = 1.0   — Trailing distance behind price, in zone widths
InpTrailingStopStep        = 1.0   — Min SL improvement (zone widths) before re-modifying the broker
```

### Invalidation TP→BE (`CheckInvalidationTpToBe`, `ManageOpenPositions`)

`breakLevel` is **derived on the fly**, not stored — no `EntryTracker`
field, no parameter threaded through `OpenMarketWithStructuralStops`. SL
was placed at `breakLevel` minus (demand) / plus (supply) a buffer of
`InpZoneSlBufferWidthMult` zone-widths, and the zone-width itself
approximates the entry-to-breakLevel distance (entry happens at the zone's
near edge, `breakLevel` is the far edge). Both directions reduce to the
same algebra — `SL = B ∓ M(entry∓B)` → `B(1+M) = SL + M·entry` → :

```
breakLevel = (slPrice + InpZoneSlBufferWidthMult * entryPrice) / (1 + InpZoneSlBufferWidthMult)
```

Both `slPrice` and `entryPrice` live on the broker position itself
(`EntryTracker` already carries them for other reasons), so this needs
nothing a restart can lose — works identically for a freshly-opened or a
restart-recovered position, no special case. Traded deliberately for
precision: entry isn't always exactly at the near edge (the bar-close
fallback trigger path can land a bar's worth inside the zone), so this is
an approximation, not the zone's literal historical `breakLevel` — accepted
directly in exchange for eliminating the restart gap an earlier version of
this feature had (a stored `breakLevel` field that restart-recovered
positions couldn't repopulate).

Checked every tick, alongside trailing:

- The invalidation threshold is `breakLevel` pushed further out by
  `InpInvalidationBufferZoneWidths` zone-widths (demand: below, supply:
  above) — extra room beyond the exact edge before the position is declared
  invalid. If price reaches it before the position resolves any other way,
  TP moves to breakeven (`InpBreakEvenOffsetPoints` past entry) — one-shot,
  gated by `EntryTracker.tpMovedToBe`.
- **SL is deliberately left untouched.** The buffer must stay below
  `InpZoneSlBufferWidthMult` so this fires before the SL; the SL then still
  sits further out, making risk/reward asymmetric from that point on — SL
  still far, TP now close. Confirmed directly as the wanted tradeoff over
  also tightening SL or closing the position outright.
- No-op only if the position has no structural SL at all
  (`!hasStructuralSl || slPrice<=0`) — otherwise applies unconditionally,
  restart-recovered or not.

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
same `g_savedLtfZones[]` continuous live operation would have accumulated,
instead of an empty watch list waiting for the first live validation.

```
1. CopyRates InpTimeframe, start_pos=1 (skip the still-forming current
   bar), InpCandlesInit bars → trend via DetermineInitialTrend
2. Forward walk, calling UpdateLTF(bar, true) for each bar in true
   chronological order (the array comes back oldest-first)
3. Draw the saved-zone rectangles once, after the replay completes
```

Single-stream now — before HTF was removed, this interleaved HTF and LTF
bars by close time, because `SaveLtfZonesForHtfBias`'s backward search and
`MarkLtfValidationContext`'s superseded-marking both depended on
`g_ltfValidatedHistory` reflecting only what had already validated as of
that same real-time moment. With `SaveLtfZoneForWatch` saving a zone
directly at its own validation instant (see *UpdateLTF* below), there is
nothing left to interleave against — one stream is enough.

`isReplay=true` (see `UpdateLTF` below) never places a real order —
`CheckRejectionRetests` still resolves every saved zone's fate (broken,
triggered, or still open) against the historical bars that follow it, but
skips `OpenMarketWithStructuralStops`: by the time OnInit runs, price has
already moved on from wherever a historical trigger bar closed, so there
is no legitimate fill left to send. `UpdateZoneTracking` and `TrackZone`
still run (so `g_zoneTracker[]` — and the chart's runway label — reflect
real replayed history, not a cold restart), but the CSV write itself
(`ZoneCsvWrite`, both the CONFIRM row and any OUTCOME row via
`LogZoneOutcome`'s own `isReplay` flag) and the excursion/drift probes stay
skipped, so replaying the same historical window on every restart does not
keep re-appending rows to the same CSVs. Per-bar chart redraws are also
skipped — the one draw call at the end means a zone that already resolved
during replay gets its correct frozen right edge on its first-ever draw,
instead of a live-extending one that would then need a second call to
freeze.

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
3a. CheckAggressiveTickEntries — checks tick.bid against every unresolved
    saved zone and enters immediately on first touch, without waiting for
    the LTF bar to close (see Zone Drawing / Structural SL/TP sections
    below for what it shares with the bar-close path). Placed after the
    close-all checks above so a target/loss hit
    this same tick isn't immediately followed by a fresh entry.

LTF update (new closed bar gate):
  CopyRates 3 bars InpTimeframe
  if SAME bar as g_ltfLastBarTime → return
  UpdateLTF(ltfRates[1])
  CheckEntryCleanup() — positions closed outside close-all (broker SL/TP)
  DrawPanel (if enabled)
```

---

## UpdateLTF(bar, isReplay=false)

The only per-bar update function left — there is no `UpdateHTF` anymore
(removed with the rest of the HTF mechanism; see the removal note under
*Zone Quality Gate* above).

```
1. Quality tracker per-bar stats (if InpZoneQualityLog — runs during
   OnInit replay too, see the replay note above)
2. Diagnostic probes (excursion reject check, drift baseline/records) — skipped if isReplay
3. If a zone is awaiting validation: track wick re-entry into its own range
   (g_ltfPendingTouched) — independent of the CSV tracker, so it stays
   accurate whether or not InpZoneQualityLog is on
4. Follow-through validation (ALWAYS-ON):
   - passed → MarkZoneValidated, MarkLtfValidationContext(zone, g_ltfPendingTouched)
     (CSV-diagnostic touchedAtValidation bit, plus superseded-retirement of
     any stale same-direction watch-list entry — see concept.md's
     Entry Mechanism section), then
     SaveLtfZoneForWatch(zone, g_ltfPendingTouched, bar.time) — appends
     directly to g_savedLtfZones[], both directions, no gate, EXCEPT: if
     g_ltfPendingTouched is true (zone already wicked into during its own
     confirm-to-validate window) OR the zone's own candidate phase swept
     (zone.sweepHigh > 0 || zone.sweepLow > 0), it's saved already used=true
     AND g_ltfZoneDrawFrozen=true — a record stays in g_savedLtfZones[] (CSV
     join key etc.) but it never enters the active watch and is never drawn
     on chart at all, since it was never really a watch candidate (see Zone
     Drawing below). Zone confirmation and clean validation still never earn
     an order on their own; only the zone's own first touch does.
5. ProcessZoneBar(bar) → check if zone confirmed
6. If zone CONFIRMED:
   a. Opposite formed first → pending zone fails (discarded, no entry)
   b. confirmLevel = bar.high (demand) / bar.low (supply)
   c. AddDemandZone / AddSupplyZone (data-only)
   d. Hold for follow-through validation, reset g_ltfPendingTouched
7. CheckRejectionRetests(bar, isReplay) — resolve every saved zone's fate
   against this bar; on break/trigger also stamps g_ltfZoneDrawEnd[i] with
   this bar's time (see Zone Drawing below)
8. DrawSavedLtfZones() — skipped if isReplay (ReplayInitialStructure draws
   once at the end instead)
```

---

## Zone Drawing

```
Every DRAWN zone: OBJ_RECTANGLE via DrawZoneRect, dotted, filled, background
  Demand → clrDodgerBlue, Supply → clrOrangeRed

Never deleted once drawn. Three states, tracked per zone (index-aligned
with g_savedLtfZones[]) via g_ltfZoneDrawFrozen[]/g_ltfZoneDrawEnd[]:
  - Still live (g_ltfZoneDrawFrozen[i] == false, g_ltfZoneDrawEnd[i] == 0):
    redrawn every DrawSavedLtfZones call, right edge extended to
    TimeCurrent()
  - Resolved after being watched (g_ltfZoneDrawFrozen[i] == false,
    g_ltfZoneDrawEnd[i] != 0 — break, traded, or superseded):
    redrawn ONE more time with the right edge frozen at that stamp, then
    g_ltfZoneDrawFrozen[i] set true and skipped on every later call — its
    rectangle never changes again, so there is nothing left to update.
  - Never watched at all (g_ltfZoneDrawFrozen[i] == true from the moment
    SaveLtfZoneForWatch created the entry — pre-touched, or swept during
    its own candidate phase: `zone.sweepHigh > 0 || zone.sweepLow > 0`,
    the two conditions OR'd on one gate): never drawn even once. It was
    never a real watch candidate, so there is nothing on chart to
    represent.

Redraw cost tracks the live watch list, not the total number of zones ever
confirmed over the EA's whole runtime.
```

### Runway label (`favW~<ratio>` / `favW <ratio>`)

Alongside the rectangle, an `OBJ_TEXT` object (`<rect name>_ratio`) tracks how
many zone-widths price has run before coming back to touch the zone — read
live from that zone's `g_zoneTracker[]` entry.

- **Position**: anchored at `(endTime, (high+low)/2)` with `ANCHOR_RIGHT` —
  same time coordinate the rectangle's own right edge uses (`TimeCurrent()`
  while live, the frozen resolve stamp once resolved), so the label sits
  right-aligned *inside* the rectangle, vertically centered, and tracks the
  moving edge every redraw exactly like the rectangle does. Font size 8,
  `OBJPROP_ZORDER` above the rectangle's default.
- **Color is always `clrWhite`, never the zone's own `clrDodgerBlue`/
  `clrOrangeRed`** — the rectangle is a *solid* fill (`OBJPROP_FILL=true`),
  so same-color text drawn on top of it has zero contrast and is invisible
  regardless of position or z-order. Confirmed from a live screenshot where
  the very first version (same-color text) never showed at all.
- `g_ltfZoneTrackerIdx[]` (index-aligned with `g_savedLtfZones[]`) is resolved
  **once**, in `SaveLtfZoneForWatch`, via a backward search of `g_zoneTracker[]`
  for the matching `time`+`isDemand` — avoids re-searching an array that only
  ever grows on every redraw. `-1` only if `InpZoneQualityLog` was off at
  confirm time, in which case no label is ever drawn for that zone.
- **OnInit replay is fully tracked too**: `TrackZone` and `UpdateZoneTracking`
  both run regardless of `isReplay` (only the CSV write itself — the CONFIRM
  row, and any OUTCOME row via `LogZoneOutcome`'s own `isReplay` param — stays
  gated to live-only, so replaying the same historical window on every EA
  restart never re-dumps duplicate rows to disk). A zone seeded by replay
  therefore has an accurate, real `g_zoneTracker[]` entry from the moment
  `ReplayInitialStructure` finishes — already-touched history shows its true
  frozen ratio immediately, not a cold restart at 0.
- **Before first touch** (`g_zoneTracker[tIdx].touched == false`): the label
  shows `favW~<ratio>`, computed fresh on every redraw as
  `maxFavPts / widthPts` — `maxFavPts` is the tracker's running
  max-favorable-excursion, updated every bar regardless of touch state, so
  this is a genuine live preview, not a placeholder.
- **At/after first touch**: the label switches to `favW <ratio>` (no `~`),
  showing the frozen `favBeforeTouchWidthRatio` field itself — the same value
  that lands in the CSV. Identical to the live preview at the exact touch bar
  (both are `maxFavPts / widthPts` at that instant), so the display never
  jumps — it just stops moving.
- Drawn/updated inside the same per-zone loop iteration as the rectangle, so it
  freezes in lockstep: once the zone resolves and `g_ltfZoneDrawFrozen[i]` is
  set, the label's last redraw is also its final one.

---

## Structural SL/TP & Risk Sizing

Every entry is a market order (`OpenMarketWithStructuralStops`) with SL and
TP attached at the same moment — this is simply how the EA sizes and stops
every trade, with no separate sizing mode or toggle of its own.

**SL** anchors to `breakLevel` — the same sweep-aware level
`CheckRejectionRetests` already uses to decide BROKEN — ±
`InpZoneSlBufferWidthMult` zone-widths (`zHigh - zLow` of the zone that
triggered, default multiplier 1.0). This is a deliberate choice, not a
fallback: the touch that triggers entry is normally a live tick now
(`CheckAggressiveTickEntries`), not even a finished bar, so there is no bar
wick to anchor to in the common case — and even in the bar-close fallback
path the touching bar can close anywhere, including deep inside the zone.
`breakLevel` is the point at which the zone's own thesis is actually
invalidated, not just wherever price happened to be at the trigger moment —
independent of what triggered entry, and stable regardless. The buffer
itself was ATR-based (`InpZoneSlBufferAtr`); changed to scale with the
zone's own width instead, so a wider zone gets proportionally more room —
at the default 1.0 multiplier, total SL distance from a touch near the
zone's near edge works out to roughly 2x the zone's own width (1x crossing
the zone, 1x the buffer beyond `breakLevel`).

Formerly a mode-dependent choice (the rejection bar's own extreme when
waiting for a confirmed rejection, `breakLevel` only when aggressive); made
aggressive-only directly, so `breakLevel` is now the only anchor.

An earlier build had an HTF-zone-edge anchor as a toggle; this build has no
HTF reference left to anchor to at all.

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
directly around a market order fired on a saved zone's own first touch (not
a resting limit), there is no remaining call site that arms
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
mfe_usd, mae_usd, mfe_r, mae_r, atr_ltf, structural, ltf_zone_time
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

19-line dashboard via OBJ_LABEL on OBJ_RECTANGLE_LABEL background:
```
AjipSnD v1.0
LTF Trend: UP (M5)
Demands: 2/2   Supplies: 1/1   Entries: 3
Today P/L: 123.45   Week P/L: 456.78   Month P/L: -12.34
Final: active   Daily: TARGET
Session: OPEN   News: clear
Open MFE: 12.34   Open MAE: -5.67
```
`Demands`/`Supplies` count `g_ltfDemandZones`/`g_ltfSupplyZones` as
`tradeable/total`. See the Zone Quality Gate note above on what `tradeable`
still means now that it no longer gates
entries.
