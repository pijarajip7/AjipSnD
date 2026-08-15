#!/usr/bin/env python3
"""Is the edge ATR-scaled or distance-scaled, and is it just a spread artifact?

Two questions that look alike and are not:

  1. SCALING. Split the population into ATR terciles and read the deficit across
     stop levels. If the edge lives at a fixed ATR MULTIPLE, the minimum sits in
     the same column for all three terciles. If it lives at a fixed POINT
     distance, the minimum shifts left as ATR rises. The period's own ATR varies
     roughly 3x across the year, so the data can separate these.

  2. SPREAD FLOOR. A fixed cost (spread) eats a fixed number of points, so it
     consumes a much larger share of a stop when 0.50 ATR is only a few hundred
     points. That predicts an ATR FLOOR below which the edge dies — not a
     different geometry. Sweeping a floor tests it directly.

usage: excursion_atr_scaling.py <AjipSnD_Excursion_*.csv>
"""
import sys
import statistics as st
from excursion_common import LV, triggered_stops, outcome, mean_r, day_bootstrap

if len(sys.argv) < 2:
    sys.exit("usage: excursion_atr_scaling.py <AjipSnD_Excursion_*.csv>")

S, POINT = triggered_stops(sys.argv[1])
if not S:
    sys.exit("no triggered STOP+0.00 rows — was InpStopEntryProbe on for this run?")

PER_PRICE = 1.0 / POINT
SLIP = 12.0
SPREAD = 30.0                 # points, assumed
MIN_STOP_PTS = 336

S.sort(key=lambda r: r['atr'])
n = len(S)
TERCILES = [S[:n // 3], S[n // 3:2 * n // 3], S[2 * n // 3:]]
NAMES = ["LOW ATR", "MID ATR", "HIGH ATR"]
STOPS = [0, 1, 2, 3, 4, 5, 6]


def deficit(rows, tp, sl):
    """Percentage points below a driftless walk's win rate."""
    w = res = 0
    for r in rows:
        f, a = r['F'][tp], r['A'][sl]
        if f < 0 and a < 0:
            continue
        res += 1
        if a < 0 or (f >= 0 and f < a):
            w += 1
    return 100 * (LV[sl] / (LV[sl] + LV[tp]) - w / res) if res else None


def tp_for_3x(sl):
    """Grid index closest to 3x the stop, so R:R is held at 3:1 across the row."""
    want = LV[sl] * 3
    return min(range(13), key=lambda i: abs(LV[i] - want))


print("1. DOES THE EDGE SCALE WITH ATR OR WITH DISTANCE?\n")
for rows, nm in zip(TERCILES, NAMES):
    a = st.median(r['atr'] for r in rows)
    print(f"  {nm}: n={len(rows)}, median ATR {a:.3f}  ->  0.50 ATR = {a * 0.5 * PER_PRICE:.0f} pts")

print("\n  Deficit d by stop level, TP held at 3x the stop (R:R 3:1 throughout).")
print("  ATR-scaled  -> minimum stays in the SAME column across terciles.")
print("  Distance-scaled -> minimum shifts LEFT as ATR rises.\n")
print(f"  {'tercile':>9s} " + "".join(f"{format(LV[s], '.2f') + 'A':>9s}" for s in STOPS))
for rows, nm in zip(TERCILES, NAMES):
    line = f"  {nm:>9s} "
    for sl in STOPS:
        d = deficit(rows, tp_for_3x(sl), sl)
        line += f"{d:9.2f}" if d is not None else f"{'-':>9s}"
    print(line)

print("\n  The same stop levels in ABSOLUTE POINTS (what the broker sees):\n")
print(f"  {'tercile':>9s} " + "".join(f"{format(LV[s], '.2f') + 'A':>9s}" for s in STOPS))
for rows, nm in zip(TERCILES, NAMES):
    a = st.median(r['atr'] for r in rows)
    print(f"  {nm:>9s} " + "".join(f"{LV[sl] * a * PER_PRICE:9.0f}" for sl in STOPS))

print("\n  Expectancy (R) at 3:1, same layout:\n")
print(f"  {'tercile':>9s} " + "".join(f"{format(LV[s], '.2f') + 'A':>9s}" for s in STOPS))
for rows, nm in zip(TERCILES, NAMES):
    print(f"  {nm:>9s} " + "".join(f"{mean_r(rows, tp_for_3x(sl), sl):+9.4f}" for sl in STOPS))

print("\n\n2. IS IT A SPREAD FLOOR?\n")
print(f"  Spread as a share of a 0.50 ATR stop, by tercile (assuming {SPREAD:.0f} pts):")
for rows, nm in zip(TERCILES, NAMES):
    a = st.median(r['atr'] for r in rows)
    stop_pts = a * 0.5 * PER_PRICE
    print(f"    {nm:>9s}  ATR {a:.3f}  stop {stop_pts:4.0f} pts  "
          f"spread = {100 * SPREAD / stop_pts:5.1f}% of R")


def floor_sweep(tp, sl, floors, label, check_placeable=False):
    print(f"\n  {label}")
    hdr = (f"  {'floor':>10s} {'kept':>6s} {'%':>6s} {'stop pts':>9s} {'net R':>8s} "
           f"{'95% CI':>21s}")
    print(hdr + (f" {'placeable?':>11s}" if check_placeable else f" {'$/trade':>8s}"))
    for floor in floors:
        rows = [r for r in S if r['atr'] >= floor]
        if len(rows) < 200:
            continue
        o = [outcome(r, tp, sl) for r in rows]
        e = st.mean(o)
        lossfrac = sum(1 for x in o if x < 0) / len(o)
        med = st.median(r['atr'] for r in rows)
        pts = LV[sl] * med * PER_PRICE
        net = e - lossfrac * (SLIP / pts)
        lo, hi = day_bootstrap(rows, tp, sl, seed=101)
        tail = (f" {'yes' if pts >= MIN_STOP_PTS else 'NO':>11s}" if check_placeable
                else f" {net * 15:+8.2f}")
        print(f"  ATR>={floor:4.2f} {len(rows):6d} {100 * len(rows) / len(S):5.0f}% "
              f"{pts:9.0f} {net:+8.4f} [{lo:+.4f},{hi:+.4f}]" + tail)


floor_sweep(5, 1, [0.0, 0.6, 0.8, 1.0, 1.2, 1.5],
            "Main cell (SL 0.50 ATR / TP 1.50 ATR, 3:1) under an ATR floor:")
floor_sweep(2, 0, [0.0, 0.8, 1.0, 1.2, 1.5, 1.8],
            "Tightest cell (SL 0.25 ATR / TP 0.75 ATR, 3:1) — mind 'placeable':",
            check_placeable=True)
