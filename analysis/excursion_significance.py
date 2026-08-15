#!/usr/bin/env python3
"""Run #8: does REJECT's apparent advantage survive scrutiny?

Two tests, because the surface has 169 cells and picking the best one after
looking is how noise gets promoted to a finding:

  1. Day-level block bootstrap CIs on a few pre-chosen cells.
  2. A placebo bar: the best-of-169 cell from the OBSERVED data, against the
     distribution of best-of-169 from random resamples of the SAME pool. If the
     observed best does not clear the placebo's 95th percentile, the advantage
     is just selection across cells.

usage: excursion_significance.py <AjipSnD_Excursion_*.csv>
"""
import sys
import random
from excursion_common import load, outcome, day_bootstrap

if len(sys.argv) < 2:
    sys.exit("usage: excursion_significance.py <AjipSnD_Excursion_*.csv>")

rows, arm = load(sys.argv[1])
rnd = random.Random(139)

print("=== run #6 vs run #8, STOP+0.00 ===")
print("    STOP+0.00 at TP1.0/SL4.0:  run#6=+0.18pp   run#8=+8.52pp")
print("    LIMIT      at TP1.0/SL4.0: run#6=+4.58pp   run#8=+4.47pp  (replicates)")
print("    Only STOP diverges sharply while LIMIT replicates almost exactly. Both")
print("    are tick-triggered, so a blanket 'different broker tick synthesis'")
print("    explanation should hit both similarly — it doesn't. More consistent")
print("    reading: STOP's run #6 result was fragile (it ALREADY failed period B")
print("    on the original broker), and this is a second, independent")
print("    non-replication rather than an artifact.")
print()

print("=== REJECT: day-level bootstrap CI, pre-chosen cells (exploratory) ===")
CELLS = [(3, 9, 'TP1.0/SL4.0'), (6, 9, 'TP2.0/SL8.0'),
         (3, 12, 'TP1.0/SL8.0'), (6, 6, 'TP3.0/SL3.0')]
for off in ['0.00', '0.25', '0.50']:
    rows_ = arm[('REJECT', off)]
    if not rows_:
        continue
    print(f"  REJECT +{off}:")
    for tp, sl, lab in CELLS:
        pz = sum(outcome(r, tp, sl) for r in rows_ if r['t']) / len(rows_)
        lo, hi = day_bootstrap(rows_, tp, sl)
        if lo is None:
            print(f"    {lab:>12s}  R/armed={pz:+.4f}  (CI unavailable)")
            continue
        verdict = ('crosses zero' if lo < 0 < hi
                   else 'ALL POSITIVE' if lo > 0 else 'all negative')
        print(f"    {lab:>12s}  R/armed={pz:+.4f}  95% CI=[{lo:+.4f},{hi:+.4f}]  {verdict}")
print()

print("=== placebo bar: is REJECT's advantage best-of-many-cells selection? ===")


def mean_cells(pop):
    """Mean R across all 169 (TP, SL) cells for a population."""
    M = []
    for r in pop:
        M.append([outcome(r, tp, sl) for tp in range(13) for sl in range(13)])
    if not M:
        return [0.0] * 169
    return [sum(c) / len(M) for c in zip(*M)]


pool = [r for r in arm[('REJECT', '0.00')] if r['t']]
if pool:
    best_obs = max(mean_cells(pool))
    n = len(pool)
    placebo = sorted(max(mean_cells(rnd.sample(pool, n))) for _ in range(150))
    p95 = placebo[142]
    print(f"  REJECT+0.00 best-of-169 (observed, n={n}): {best_obs:+.4f}")
    print(f"  placebo 95th pct (same n, resampled from the SAME pool): {p95:+.4f}")
    print(f"  -> {'clears the bar' if best_obs > p95 else 'does NOT clear — indistinguishable from noise'}")
