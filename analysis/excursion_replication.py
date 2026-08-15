#!/usr/bin/env python3
"""Pre-registered replication of the period A stop-entry finding, on new data.

Period A (run #6) suggested a stop entry at the zone edge erased the deficit a
limit entry suffered, and that SL 0.50 ATR / TP 1.50 ATR was the cell to trade.
This script is the test of that claim on a second, untouched 12-month period —
written BEFORE the second period was scored, with its pass bar stated up front,
which is the only arrangement in which a replication means anything.

  1. Mechanism checks. Does the period A machinery even show up here? If the
     LIMIT deficit is absent, the data differ for some reason unrelated to the
     claim and nothing downstream is interpretable.
  2. The main cell, against its stated bar.
  3. If it fails: is it one bad cell, or the whole surface? Plus month by month,
     because a sign flip inside the period is worse news than a weak average.

Period A reference values are quoted inline as the thing being replicated.

usage: excursion_replication.py <AjipSnD_Excursion_*.csv>   (period B CSV)
"""
import sys
import statistics as st
from collections import defaultdict
from excursion_common import (LV, VARIANTS, load, triggered_stops, outcome,
                              mean_r, day_bootstrap)

if len(sys.argv) < 2:
    sys.exit("usage: excursion_replication.py <AjipSnD_Excursion_*.csv>")

CSV = sys.argv[1]
_, arm = load(CSV)
S, POINT = triggered_stops(CSV)
if not S:
    sys.exit("no triggered STOP+0.00 rows — was InpStopEntryProbe on for this run?")
PER_PRICE = 1.0 / POINT
MIN_STOP_PTS = 336


def deficit(variant, tp, sl):
    w = res = 0
    for r in arm[variant]:
        if not r['t']:
            continue
        f, a = r['F'][tp], r['A'][sl]
        if f < 0 and a < 0:
            continue
        res += 1
        if a < 0 or (f >= 0 and f < a):
            w += 1
    return 100 * (LV[sl] / (LV[sl] + LV[tp]) - w / res) if res else None


print("=== 1. PRE-REGISTERED MECHANISM CHECKS ===")
print("    (must pass before the main cell means anything)\n")

d1 = deficit(("LIMIT", "0.00"), 3, 9)
print("Check 1: LIMIT deficit at TP1.0/SL4.0 — period A measured +4.58 pp")
print(f"  this period: {d1:+.2f} pp   -> "
      f"{'PASS (same mechanism present)' if d1 is not None and d1 > 2.0 else 'FAIL'}")

d2 = deficit(("STOP", "0.00"), 3, 9)
print("\nCheck 2: STOP+0.00 deficit at TP1.0/SL4.0 — period A measured +0.18 pp (~zero)")
print(f"  this period: {d2:+.2f} pp   -> "
      f"{'PASS (inversion still erases it at wide stops)' if d2 is not None and abs(d2) < 2.0 else 'FAIL'}")

ladder = [("STOP", "0.00"), ("STOP", "0.25"), ("STOP", "0.50"), ("STOP", "1.00")]
ds = [deficit(v, 3, 9) for v in ladder]
print("\nCheck 3: offset ladder worsens monotonically (0.00 < 0.25 < 0.50 < 1.00)")
if all(d is not None for d in ds):
    print(f"  d values: 0.00={ds[0]:+.2f}  0.25={ds[1]:+.2f}  0.50={ds[2]:+.2f}  1.00={ds[3]:+.2f}")
    mono = ds[0] < ds[1] < ds[2] < ds[3]
    print(f"  monotonic increasing: {'PASS' if mono else 'FAIL'}")

print("\n--- full deficit table for context ---")
CELLS = [(3, 9), (6, 9), (3, 12), (6, 12), (6, 6), (8, 8)]
print(f"  {'variant':>12s} " + "".join(
    f"{'TP' + format(LV[t], '.1f') + '/' + format(LV[s], '.0f'):>12s}" for t, s in CELLS))
for v in VARIANTS:
    if not arm[v]:
        continue
    line = f"  {v[0] + ' +' + v[1]:>12s} "
    for tp, sl in CELLS:
        x = deficit(v, tp, sl)
        line += f"{x:12.2f}" if x is not None else f"{'-':>12s}"
    print(line)

print("\n\n=== 2. THE PRE-REGISTERED MAIN CELL ===")
print("STOP +0.00, SL 0.50 ATR, TP 1.50 ATR (3:1)")
print("Prediction: exceed period A's +0.163 R (this period sits in the high-ATR regime)")
print("Pass bar:   95% CI excludes zero AND point estimate > +0.10 R\n")

e = mean_r(S, 5, 1)
lo, hi = day_bootstrap(S, 5, 1, n=2000, seed=107)
o = [outcome(r, 5, 1) for r in S]
wr = 100 * sum(1 for x in o if x > 0) / len(o)
atr = st.median(r['atr'] for r in S)
print(f"  n = {len(S)}   win rate = {wr:.1f}%   stop = {0.50 * atr * PER_PRICE:.0f} pts")
print(f"  period A: +0.1626 R   [+0.129, +0.243]")
print(f"  this period: {e:+.4f} R   [{lo:+.4f}, {hi:+.4f}]")
verdict = "PASS" if (lo > 0 and e > 0.10) else ("MARGINAL" if lo > 0 else "FAIL")
print(f"  verdict: {verdict}")
print("  vs prediction: " + (
    "exceeded A as predicted" if e > 0.1626 else
    "positive but BELOW A — the volatility story was wrong even if an edge survives"
    if e > 0 else "reversed"))

days = sorted(set(r['day'] for r in S))
mid = days[len(days) // 2]
H1 = [r for r in S if r['day'] < mid]
H2 = [r for r in S if r['day'] >= mid]
print(f"\n  half-period split: H1 ({len(H1)}) {mean_r(H1, 5, 1):+.4f}   "
      f"H2 ({len(H2)}) {mean_r(H2, 5, 1):+.4f}")
print("  period A's own halves were +0.147 / +0.220 — both positive.")

print("\n--- neighbouring cells, for context ---")
print(f"  {'SL':>6s} {'TP':>6s} {'R:R':>5s} {'net R':>8s} {'95% CI':>21s} {'win%':>6s}")
for sl, tp in [(0, 2), (1, 3), (1, 4), (1, 5), (1, 6), (1, 7), (2, 7), (3, 9)]:
    if LV[tp] / LV[sl] < 1.0:
        continue
    o2 = [outcome(r, tp, sl) for r in S]
    lo2, hi2 = day_bootstrap(S, tp, sl, n=2000, seed=107)
    print(f"  {LV[sl]:5.2f}A {LV[tp]:5.2f}A {LV[tp] / LV[sl]:5.1f} {st.mean(o2):+8.4f} "
          f"[{lo2:+.4f},{hi2:+.4f}] {100 * sum(1 for x in o2 if x > 0) / len(o2):5.1f}%")

print("\n\n=== 3. ONE BAD CELL, OR THE WHOLE SURFACE? ===")
print("Best cell anywhere in the R:R>=1 grid — no cherry-pick rescue:\n")
best = []
for tp in range(13):
    for sl in range(13):
        if LV[tp] / LV[sl] < 1.0:
            continue
        o3 = [outcome(r, tp, sl) for r in S]
        best.append((st.mean(o3), tp, sl, 100 * sum(1 for x in o3 if x > 0) / len(o3)))
best.sort(reverse=True)
print(f"  {'TP':>6s} {'SL':>6s} {'R:R':>5s} {'net R':>8s} {'win%':>6s}")
for e3, tp, sl, wr3 in best[:6]:
    print(f"  {LV[tp]:6.2f} {LV[sl]:6.2f} {LV[tp] / LV[sl]:5.1f} {e3:+8.4f} {wr3:5.1f}%")
placeable = [e3 for e3, tp, sl, _ in best if LV[sl] * atr * PER_PRICE >= MIN_STOP_PTS]
print(f"\n  period A best-of-grid was +0.3357 R (SL0.25/TP6.00, later disqualified as")
print(f"  unplaceable and fragile). Best PLACEABLE here: {max(placeable):+.4f} R")

print("\n--- month by month, the main cell ---")
m = defaultdict(list)
for r in S:
    m[r['day'][:7]].append(r)
print(f"  {'month':>9s} {'n':>5s} {'net R':>8s}")
for k in sorted(m):
    print(f"  {k:>9s} {len(m[k]):5d} {mean_r(m[k], 5, 1):+8.4f}")
print("\n  A sign flip between halves inside a single 12-month sample is worse than a")
print("  weak average: it says the cell was never stable, only luckily sampled.")
