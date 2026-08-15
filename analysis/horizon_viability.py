#!/usr/bin/env python3
"""Is M1 XAUUSD tradeable at all, given our execution cost?

Not a signal search. This asks the question that sits UNDER every signal search:
how big is the move available at each horizon, and therefore how accurate would
any signal have to be to clear a fixed round-trip cost?

Model: enter on a signal, exit at the horizon. Being right earns roughly the
typical move M, being wrong loses roughly M, and the cost c is paid either way.

    expectancy = (2h - 1) * M - c        break-even h = 0.5 + c / (2M)

M is taken as the MEDIAN absolute forward move of the random baseline rows —
what price does from an arbitrary moment, with no signal at all. That is the
right scale: a signal cannot manufacture volatility, it can only pick a side of
what is already there.

Cost is swept over a range rather than fixed, because our own measurements
disagree: LIMIT fills showed ~0 slippage but pay spread twice, while STOP fills
showed a 216 pt median slip. The conclusion should not depend on picking one.
"""
import csv, sys, statistics as st
from collections import defaultdict

if len(sys.argv) < 2:
    sys.exit("usage: horizon_viability.py <AjipSnD_Drift_*.csv>")
CSV = sys.argv[1]


def detect_point(path):
    """See drift_analysis.py — never assume the symbol's digits."""
    dec = 0
    with open(path, newline='') as fh:
        for i, r in enumerate(csv.DictReader(fh)):
            p_ = (r.get('arm_price') or '').strip()
            if '.' in p_:
                dec = max(dec, len(p_.split('.')[1]))
            if i > 500:
                break
    if dec == 0:
        sys.exit("could not determine price precision from arm_price")
    return 10.0 ** (-dec)


POINT = detect_point(CSV)
HZ = [('d05m', '5m'), ('d15m', '15m'), ('d1h', '1h'), ('d4h', '4h'), ('d1d', '1d')]
COSTS = [50, 100, 200, 400]

base, zones = [], []
for r in csv.DictReader(open(CSV, newline='')):
    if not r.get('arm_time'):
        continue
    atr = float(r['atr_ltf']) if r.get('atr_ltf') else 0.0
    if atr <= 0:
        continue
    rec = {'hour': int(r['arm_time'][11:13]), 'atr': atr}
    for k, _ in HZ:
        v = r.get(k, '')
        rec[k] = float(v) if v not in ('', None) else None
    (zones if r['is_zone'] == '1' else base).append(rec)

print("=" * 78)
print("HOW BIG IS THE MOVE, AND WHAT ACCURACY WOULD IT TAKE?")
print("=" * 78)
print(f"baseline rows: {len(base)}   (random moments, no signal)\n")
print(f"  {'hz':>4s} {'median |move|':>14s} {'in ATR':>8s} "
      + "".join(f"{'h@' + str(c) + 'pt':>9s}" for c in COSTS))
for k, lab in HZ:
    v = [abs(r[k]) for r in base if r[k] is not None]
    if not v:
        continue
    M = st.median(v)
    atr = st.median(r['atr'] for r in base) / POINT
    cells = ""
    for c in COSTS:
        h = 0.5 + c / (2 * M)
        cells += f"{100 * h:8.1f}%" if h < 1.0 else f"{'impossible':>9s}"
    print(f"  {lab:>4s} {M:11.0f} pt {M / atr:8.2f} " + cells)

print("\n  h@Npt = hit rate a signal would need, at that horizon, to break even")
print("  against an N point round-trip cost. Our measured range is 50-200 pt;")
print("  the STOP ladder's own median slip alone was 216 pt.")

print("\n" + "=" * 78)
print("FOR SCALE — what our zones actually delivered")
print("=" * 78)
print("  Zone hit rates measured in run #9: 48.7% / 49.6% / 49.7% / 49.8% / 49.8%")
print("  Gold's trend, the one real effect in the data, moved demand-side 1d")
print("  accuracy to 58.5% — and that is a whole-year directional bias, not")
print("  something a per-trade signal can be assumed to reach.")

print("\n" + "=" * 78)
print("WHEN does the market actually move? (baseline, by hour)")
print("=" * 78)
print("  If a tradeable window exists at all it should show as a fatter median")
print("  move, which lowers the required accuracy for the SAME fixed cost.\n")
byh = defaultdict(list)
for r in base:
    if r['d1h'] is not None:
        byh[r['hour']].append(abs(r['d1h']))
rows = [(h, st.median(v), len(v)) for h, v in byh.items() if len(v) >= 60]
rows.sort(key=lambda x: -x[1])
print(f"  {'hour':>5s} {'median |1h move|':>17s} {'n':>6s} {'h@200pt':>9s}")
for h, m, n in rows[:6]:
    print(f"  {h:02d}:00 {m:14.0f} pt {n:6d} {100 * (0.5 + 200 / (2 * m)):8.1f}%")
print("  ...")
for h, m, n in rows[-3:]:
    print(f"  {h:02d}:00 {m:14.0f} pt {n:6d} {100 * (0.5 + 200 / (2 * m)):8.1f}%")
