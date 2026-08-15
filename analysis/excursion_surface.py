#!/usr/bin/env python3
"""Run #8: expectancy surface per entry variant, scored per ARMED zone.

Two numbers per (TP, SL) cell:

  deficit d  -- percentage points below a driftless random walk. A walk with a
                stop at SL and target at TP wins SL/(SL+TP) of the time by
                geometry alone; d is how far the observed win rate falls short.
                Positive d means the entry is worse than no information at all,
                which is what runs #4-#6 kept finding at the fill.

  R/armed    -- expectancy per zone OFFERED, not per trade taken. Scoring per
                trade would flatter any variant that declines the hard zones,
                and declining is exactly what the STOP/REJECT ladders do at
                larger offsets, so per-armed is the only comparable unit.

usage: excursion_surface.py <AjipSnD_Excursion_*.csv>
"""
import sys
from excursion_common import load, outcome, LV, VARIANTS

if len(sys.argv) < 2:
    sys.exit("usage: excursion_surface.py <AjipSnD_Excursion_*.csv>")

rows, arm = load(sys.argv[1])


def stats(rows_, tp, sl):
    """(R per armed zone, deficit in pp vs driftless walk, trigger rate %)"""
    tot = 0.0
    wins = resolved = triggered = 0
    n = len(rows_)
    if n == 0:
        return 0.0, None, 0.0
    for r in rows_:
        if not r['t']:
            continue
        triggered += 1
        tot += outcome(r, tp, sl)
        f, a = r['F'][tp], r['A'][sl]
        if f < 0 and a < 0:
            continue                      # unresolved inside the horizon
        resolved += 1
        if a < 0 or (f >= 0 and f < a):
            wins += 1
    walk = LV[sl] / (LV[sl] + LV[tp])     # driftless-walk win rate
    deficit = 100 * (walk - wins / resolved) if resolved else None
    return tot / n, deficit, 100 * triggered / n


CELLS = [(3, 9), (6, 9), (3, 12), (6, 12), (6, 6), (8, 8)]
hdr = "".join(f"{'TP' + format(LV[t], '.1f') + '/' + format(LV[s], '.0f'):>12s}"
              for t, s in CELLS)

print("Deficit d (pp below driftless walk) — positive means worse than no edge.\n")
print(f"  {'variant':>13s} " + hdr)
for v in VARIANTS:
    line = f"  {v[0] + ' +' + v[1]:>13s} "
    for tp, sl in CELLS:
        _, d, _ = stats(arm[v], tp, sl)
        line += f"{d:12.2f}" if d is not None else f"{'-':>12s}"
    print(line)

print("\nR per ARMED zone at the same cells:\n")
print(f"  {'variant':>13s} " + hdr)
for v in VARIANTS:
    line = f"  {v[0] + ' +' + v[1]:>13s} "
    for tp, sl in CELLS:
        pz, _, _ = stats(arm[v], tp, sl)
        line += f"{pz:+12.4f}"
    print(line)

print("\n=== control: LIMIT should replicate run #6 (period A: d=4.58pp at TP1.0/SL4.0) ===")
_, d, _ = stats(arm[("LIMIT", "0.00")], 3, 9)
if d is not None:
    print(f"  LIMIT TP1.0/SL4.0: d={d:.2f}pp (run #6 measured 4.58pp)")
    print("  A control that replicates is what licenses reading the other rows;")
    print("  if this drifts far from 4.58, suspect the data before the finding.")
