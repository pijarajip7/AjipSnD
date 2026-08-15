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
