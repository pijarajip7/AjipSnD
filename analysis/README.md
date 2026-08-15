# Offline analysis of backtest CSVs

Scripts that read the CSVs the EA writes during a backtest and answer questions
the Strategy Tester report cannot. Pure Python 3 stdlib — no dependencies.

All CSVs are written to the terminal's **`Common\Files`** directory:

```
<wine prefix>/drive_c/users/crossover/AppData/Roaming/MetaQuotes/Terminal/Common/Files/
```

Named `AjipSnD_<kind>_<SYMBOL>_<LOGIN>.csv`. Delete the old one before a rerun —
the EA appends.

## Scripts

### Run #8 — entry mechanism (excursion / first-touch grid)

Need a run with `InpExcursionLog=true`, and `InpStopEntryProbe` /
`InpRejectEntryProbe` for the ladders. Every variant is observed on the *same*
zones over the *same* windows, so comparisons between them carry no population
difference — that is the whole point of the design.

```bash
python3 analysis/excursion_funnel.py       <AjipSnD_Excursion_*.csv>
python3 analysis/excursion_surface.py      <AjipSnD_Excursion_*.csv>
python3 analysis/excursion_significance.py <AjipSnD_Excursion_*.csv>
```

- **`excursion_funnel.py`** — armed → primed → triggered per variant, plus
  slippage. Read this first: it says how much of any variant's apparent edge is
  just declining to trade the hard zones.
- **`excursion_surface.py`** — expectancy per (TP, SL) cell, scored **per armed
  zone** rather than per trade taken, so a variant that declines zones cannot
  flatter itself. Includes a control cell that must replicate run #6's 4.58pp;
  if it drifts, suspect the data before believing anything else in the output.
- **`excursion_significance.py`** — day-level bootstrap CIs plus a placebo bar
  for best-of-169-cells selection. As of run #8 the observed best does **not**
  clear the placebo, i.e. REJECT's apparent advantage is cell selection.
- **`excursion_common.py`** — shared loading and the `outcome()` scorer. Its
  level grid must stay in step with `ExcLevelAtr[]` in `AjipSnD_Excursion.mqh`.

### Runs #6–#7 — stop-entry geometry, and its failed replication

Same excursion CSV format, scored on `STOP+0.00` triggered entries. Take the CSV
for whichever period you want; nothing is baked in.

```bash
python3 analysis/excursion_cell_ranking.py <period A excursion CSV>
python3 analysis/excursion_atr_scaling.py  <period A excursion CSV>
python3 analysis/excursion_replication.py  <period B excursion CSV>
```

- **`excursion_cell_ranking.py`** — every (TP, SL) cell with R:R ≥ 1 ranked net
  of exit-slippage drag; then only cells the broker would accept; then an honest
  holdout that picks on one half and scores on the other. **Read the holdout
  first** — the ranked tables are exploratory and will always show a winner.
- **`excursion_atr_scaling.py`** — does the edge live at a fixed ATR multiple or
  a fixed point distance, and is it just a spread floor in disguise? ATR
  terciles plus a floor sweep.
- **`excursion_replication.py`** — the pre-registered test of period A's
  stop-entry finding on a second 12-month period: mechanism checks, then the
  named cell against a stated pass bar, then a diagnosis if it fails. It does
  fail (+0.0115 R against a +0.10 bar, halves at +0.196 / −0.187), and that sign
  flip inside one sample is why the stop-entry line was dropped.

Scoring unit differs by question and it matters: these score **per trade** (one
fixed mechanism, comparing geometries), while `excursion_surface.py` scores
**per armed zone** (comparing mechanisms, where declining a zone must count).

### `test_reject_trigger.py` — STOP vs REJECT trigger semantics

```bash
python3 analysis/test_reject_trigger.py
```

Self-contained, no CSV. Checks that REJECT fires only on a bar *close* past the
threshold while STOP fires intrabar — the distinction the whole REJECT ladder
rests on. Note the model collapses each bar to OHLC and cannot represent
intrabar ordering, so fixtures must not depend on it; see the comment at the top
before adding a case.

### Run #9 — does the zone predict anything at all?

### `drift_analysis.py` — does zone confirmation predict anything?

```bash
python3 analysis/drift_analysis.py /path/to/AjipSnD_Drift_XAUUSD_463734686.csv
```

Needs a run with `InpDriftLog=true`. Measures forward price drift at fixed
horizons (5m/15m/1h/4h/1d) from each LTF zone confirmation, against random-time
baseline draws recorded through the identical mechanism — no entry, no SL/TP, so
none of the fill-timing effects the excursion work isolated can contaminate it.

Reports the direction-adjusted, baseline-corrected drift per horizon with
day-level block bootstrap CIs, split by side, plus hit rates.

**Read the per-side split, not just the aggregate.** In a trending market one
side flatters and the other decays by complementary amounts; only both sides
beating their own baseline is zone information. See the RESULT block in
`AjipSnD_Drift.mqh` for what run #9 found (short version: a coin flip).

### `horizon_viability.py` — how accurate would ANY signal have to be?

```bash
python3 analysis/horizon_viability.py <drift CSV>
```

Not a signal search — the question underneath every signal search. Execution
cost is fixed while the available move grows with horizon, so the accuracy a
signal needs to break even falls sharply as the holding period lengthens. Run
this before designing a strategy, not after.

On run #9 data, at a 200 pt round-trip cost: **64.9%** accuracy needed at a 5m
horizon, **52.1%** at 4h. The same 55% signal loses 133 pt/trade at 5m and makes
288 pt/trade at 4h. It also buckets by hour — the London/NY overlap (13:00–15:00
server) moves 4–5x as far as 20:00–22:00, which changes the required accuracy
from ~52% to ~59% for the identical signal.

This is what explains runs #1–#9: the EA targeted ~756 pt, needing 58–65%, and
the zones delivered 49.6%. That gap was set by the horizon, not by the entry
mechanism the five preceding runs spent their time on.

### Does a coarser LTF/HTF pairing help? (M5/H1)

Every result above used LTF=M1, HTF=M15. A natural objection: maybe zone
*significance* scales with the timeframe it's drawn on, and M1 zones are just
too small to mean anything — a claim distinct from "the zone concept has no
information" and untested by anything above. It needs no code change; the
probe reads whatever `InpTimeframe`/`InpHtfTimeframe` the EA is configured
with. Tested on period A with `InpTimeframe=M5`, `InpHtfTimeframe=H1`
(everything else unchanged, quality gates still off, baseline draw probability
raised to 0.10 to compensate for M5 having 1/5 as many bars).

Same null: hit rate 49.07–49.85% across all five horizons, 9,130 zones,
baseline-ATR-regime ratio 0.98x (valid). The per-side split disagrees in sign
at 15m/4h/1d — the same market-trend-leaking-through signature as the M1
result — and the significant-looking +0.0111 ATR excess drift at 5m has a CI
crossing zero and a hit rate *below* 50% (49.46%), i.e. it's mean-skew from a
few large moves, not a real edge; don't read it as one.

One correction to a plausible-sounding but wrong intuition: M5/H1 does **not**
need less accuracy at a given wall-clock horizon than M1/M15 does — `1h`
needs 53.6% here vs 54.2% at M1/M15, `4h` needs 51.7% vs 52.1%, essentially
the same, because both measure the same underlying market over the same
wall-clock window regardless of which timeframe detected the entry. What
*does* change is that the EA's target is sized in the entry timeframe's own
ATR, and M5's ATR (1,967 pt) is ~2.6x M1's (756 pt), so covering a 1.0 ATR
target takes on the order of 30 minutes at M5 vs 7-8 minutes at M1 — a
longer, friendlier hold, but a side effect of position sizing, not of the
signal being any less blind at that horizon. It doesn't rescue anything here:
the friendliest horizon (1d, bar 50.6%) still only gets 49.85%.

### `drift_zone_slices.py` — do the untested zone attributes carry direction?

```bash
python3 analysis/drift_zone_slices.py <drift CSV> <zones CSV>
```

Slices the drift result by three attributes that shape EA behaviour but were
never tested on their own: `swept` (liquidity sweep — the rule `ProcessZoneBar`
encodes), `base_bars` (origin speed), and `validated` (follow-through). Uses
stratified permutation — labels shuffled *within* each day, so day-level shocks
are held fixed — plus a family-wise test on the maximum gap across all tests.

Two things it established, both worth knowing before writing another slice:

- **`validated` is circular and is excluded from testing.** A demand zone is
  marked validated exactly when a later bar closes above the confirm bar's high
  — when price went up — and the drift asks whether price went up. The apparent
  66.9% vs 11.0% gap at 5m is one event scored twice; watch it decay to 51.1%
  at 1d as the horizon outruns the validation. Testing whether that gate has
  real predictive value needs drift measured from the *validation* moment
  forward, which this instrument does not do.
- **`base_bars` can never be 1**, which is what corrected the struct comment.

Result on run #9 data: family-wise p = 0.201. No lead.

### `drift_robustness.py` — could that null be wrong?

```bash
python3 analysis/drift_robustness.py <drift CSV> <zones CSV>
```

Needs `InpDriftLog=true` **and** `InpZoneQualityLog=true` (joins on
`ltf_zone_time`). Checks the three ways the null could be an artifact: baseline
drawn from a different volatility regime, an aggregate hiding two real opposite
effects, and a signal living only in a zone-quality subset.

### Point size

Both scripts derive the symbol's point size from `arm_price`'s decimal places
rather than hardcoding it. Horizon deltas are logged in points while ATR is in
price, so a wrong point size silently rescales every number by 10x. XAUUSD is
digits=3 on this broker and digits=2 elsewhere — do not reintroduce a constant.

## Producing the CSVs

`mt5-quant`'s `compile_ea` and `launch_backtest` both fail on this EA. Three
traps, each of which cost a full run to find:

1. **`compile_ea` cannot build a multi-file EA.** Each call wipes its staging
   directory and copies only the entry `.mq5`, so the eight `.mqh` includes are
   never present. Compile through MetaEditor under Wine instead — and use a
   **relative** path, because an absolute `C:\Program Files\...` path fails
   silently on the spaces:

   ```bash
   cd "<prefix>/drive_c/Program Files/MetaTrader 5"
   WINEPREFIX=<prefix> "/Applications/MetaTrader 5.app/Contents/SharedSupport/wine/bin/wine64" \
     MetaEditor64.exe /compile:"MQL5\Experts\AjipSnD.mq5" /log:"C:\mecompile.log"
   ```

   The log is UTF-16LE (`iconv -f UTF-16LE`). Source files must be copied into
   `MQL5/Experts/` first; the project directory is not what gets built.

2. **`patch_set_file` writes NEW keys with `:` instead of `=`.** MT5 parses only
   `key=value` and ignores the rest without a word, so a newly added input
   silently keeps its default. Existing keys patch fine. After adding an input,
   always verify:

   ```bash
   grep '^Inp' <file>.set
   ```

3. **`launch_backtest` hangs.** Drive the terminal directly with a `[Tester]`
   config ini and `ShutdownTerminal=1`, then wait for the process to exit.

The EA prints a build banner on `OnInit` naming the build and the state of every
probe input. Check it in `Tester/logs/<date>.log` (UTF-16LE) before trusting any
run — it is what catches both a stale `.ex5` and trap 2:

```
AjipSnD build 1.09-driftprobe | ... driftProbe=ON (p=0.030) | XAUUSD PERIOD_M1
```
