#!/usr/bin/env python3
"""Run #8: how far each entry variant gets, and what it pays in slippage.

armed -> primed -> triggered, per variant. The funnel is the first thing to read
because it says how much of the difference between variants is selection (a
variant that never fires cannot lose) rather than edge.

usage: excursion_funnel.py <AjipSnD_Excursion_*.csv>
"""
import sys
import statistics as st
from excursion_common import load, VARIANTS

if len(sys.argv) < 2:
    sys.exit("usage: excursion_funnel.py <AjipSnD_Excursion_*.csv>\n"
             "  CSV lives in the MT5 terminal's Common\\Files directory.")

rows, arm = load(sys.argv[1])
print(f"total rows: {len(rows)}")
print(f"date range: {min(r['arm_time'] for r in rows)} -> {max(r['arm_time'] for r in rows)}")
print()

print("=== funnel: armed -> primed -> triggered, and slippage ===")
print(f"  {'variant':>12s} {'armed':>7s} {'primed':>7s} {'trig':>7s} "
      f"{'trig%':>6s} {'med slip pt':>11s} {'mean slip':>10s}")
for v in VARIANTS:
    r_ = arm[v]
    n = len(r_)
    if n == 0:
        continue
    primed = sum(1 for r in r_ if r['primed'] == '1')
    trig = sum(1 for r in r_ if r['t'])
    slips = [r['slip'] for r in r_ if r['t']]
    med = st.median(slips) if slips else 0.0
    mean = st.mean(slips) if slips else 0.0
    print(f"  {v[0] + ' +' + v[1]:>12s} {n:7d} {primed:7d} {trig:7d} "
          f"{100 * trig / n:5.1f}% {med:11.1f} {mean:10.1f}")

print()
print("Slippage sign convention: positive = paid worse than the order level.")
print("A STOP fills at its level or WORSE (price has already jumped through it),")
print("while a LIMIT fills at its level or better — so a non-zero median here is")
print("the stop ladder's structural cost, not noise.")
