#!/usr/bin/env python3
"""Does an H1 trend reading predict direction, beyond the market's own drift?

Run #9 established that the only real directional effect in this data was
XAUUSD's uptrend. This tests whether a plain trend reading — price above or
below its moving average — captures that, or merely restates it.

THE TRAP THIS IS BUILT AROUND. The zone population was ~50/50 demand/supply, so
the market's drift cancelled in the aggregate almost automatically. A trend
signal is NOT balanced: in a year when gold rose, "above the MA" is true most of
the time, so a signal that is simply long-most-of-the-year would post a fine
direction-adjusted hit rate while carrying no timing information whatsoever.

Three defences, in increasing order of how hard they are to fool:

  1. Baseline correction. Score against +mu when long and -mu when short, where
     mu is the unconditional forward drift of the random baseline rows.
  2. Both sides reported separately. A real signal helps in both directions. One
     that only works long is the trend leaking through.
  3. A LONG-ONLY BENCHMARK. The honest competitor is not a coin flip, it is
     "hold long always". A trend signal has to beat THAT to have earned its
     complexity, and this is the comparison that usually kills it.

Also reports the cost bar from horizon_viability.py, because a hit rate that
beats the benchmark still has to clear execution cost to be worth trading.

usage: drift_trend_analysis.py <AjipSnD_Drift_*.csv>
"""
import csv, sys, random, statistics as st
from collections import defaultdict

random.seed(20260816)
if len(sys.argv) < 2:
    sys.exit("usage: drift_trend_analysis.py <AjipSnD_Drift_*.csv>")
CSV = sys.argv[1]
HZ = [('d05m', '5m'), ('d15m', '15m'), ('d1h', '1h'), ('d4h', '4h'), ('d1d', '1d')]

# Required accuracy at a 200 pt round-trip cost, from horizon_viability.py.
COST_BAR = {'5m': 64.9, '15m': 58.5, '1h': 54.2, '4h': 52.1, '1d': 50.8}


def detect_point(path):
    dec = 0
    with open(path, newline='') as fh:
        for i, r in enumerate(csv.DictReader(fh)):
            p = (r.get('arm_price') or '').strip()
            if '.' in p:
                dec = max(dec, len(p.split('.')[1]))
            if i > 500:
                break
    return 10.0 ** (-dec) if dec else 0.001


POINT = detect_point(CSV)

rows = []
with open(CSV, newline='') as f:
    rd = csv.DictReader(f)
    if 'kind' not in (rd.fieldnames or []):
        sys.exit("this CSV has no 'kind' column — it predates the trend probe")
    for r in rd:
        atr = float(r['atr_ltf']) if r.get('atr_ltf') else 0.0
        if atr <= 0 or not r.get('arm_time'):
            continue
        rec = {'kind': r['kind'], 'up': r.get('is_demand') == '1',
               'day': r['arm_time'][:10], 'hour': int(r['arm_time'][11:13]),
               'atr': atr,
               'ma': float(r['ma_dist_atr']) if r.get('ma_dist_atr') else None}
        for k, _ in HZ:
            v = r.get(k, '')
            rec[k] = (float(v) * POINT) / atr if v not in ('', None) else None
        rows.append(rec)

trend = [r for r in rows if r['kind'] == 'TREND']
base = [r for r in rows if r['kind'] == 'BASELINE']
zone = [r for r in rows if r['kind'] == 'ZONE']
if not trend:
    sys.exit("no TREND rows — was InpDriftTrendProbe on?")

nl = sum(1 for r in trend if r['up'])
print("=" * 80)
print("H1 TREND PROBE — does 'price vs its MA' carry direction?")
print("=" * 80)
print(f"  trend rows {len(trend)}  ({nl} long / {len(trend)-nl} short "
      f"= {100*nl/len(trend):.1f}% long)")
print(f"  baseline   {len(base)}      zone (control) {len(zone)}")
if nl / len(trend) > 0.6 or nl / len(trend) < 0.4:
    print("  NOTE: the signal is far from balanced, so the long-only benchmark")
    print("        below — not the 50% coin flip — is the comparison that counts.")
print()

mus = {}
for k, lab in HZ:
    v = [r[k] for r in base if r[k] is not None]
    mus[k] = st.mean(v) if v else 0.0


def hit_rate(pop, k, flip=None):
    """Share moving the predicted way. flip=True/False forces a fixed side."""
    out = []
    for r in pop:
        if r[k] is None:
            continue
        want_up = r['up'] if flip is None else flip
        out.append((r[k] > 0) == want_up)
    return (100.0 * sum(out) / len(out), len(out)) if out else (None, 0)


def excess(pop, k):
    """Baseline-corrected signed drift, in ATR."""
    v = []
    for r in pop:
        if r[k] is None:
            continue
        s = 1.0 if r['up'] else -1.0
        v.append(s * r[k] - s * mus[k])
    return st.mean(v) if v else None


def boot(pop, k, n=1500):
    byday = defaultdict(list)
    for r in pop:
        if r[k] is not None:
            byday[r['day']].append(r)
    days = list(byday)
    if len(days) < 5:
        return None, None
    est = []
    for _ in range(n):
        s = []
        for _ in range(len(days)):
            s += byday[random.choice(days)]
        e = excess(s, k)
        if e is not None:
            est.append(e)
    est.sort()
    return est[int(0.025 * len(est))], est[int(0.975 * len(est))]


print("=" * 80)
print("1. HIT RATE vs THE BENCHMARKS")
print("=" * 80)
print("  'long-only' = the same rows scored as if always long — the competitor")
print("  the trend signal must beat. 'cost bar' = accuracy needed at 200 pt.\n")
print(f"  {'hz':>4s} {'trend':>8s} {'long-only':>10s} {'edge':>7s} "
      f"{'cost bar':>9s} {'zones':>8s}  verdict")
for k, lab in HZ:
    t, n = hit_rate(trend, k)
    lo_, _ = hit_rate(trend, k, flip=True)
    z, _ = hit_rate(zone, k)
    if t is None:
        continue
    edge = t - lo_
    bar = COST_BAR[lab]
    if t < bar:
        vd = "below cost bar"
    elif edge <= 0:
        vd = "no edge over long-only"
    else:
        vd = "CLEARS BOTH"
    print(f"  {lab:>4s} {t:7.2f}% {lo_:9.2f}% {edge:+6.2f} {bar:8.1f}% "
          f"{(f'{z:7.2f}%' if z is not None else '     n/a')}  {vd}")

print("\n" + "=" * 80)
print("2. BASELINE-CORRECTED DRIFT, AND BOTH SIDES SEPARATELY")
print("=" * 80)
print("  A real signal is positive on BOTH sides. Long-only-positive is the trend.\n")
print(f"  {'hz':>4s} {'all (ATR)':>11s} {'95% CI':>22s} {'long':>9s} {'short':>9s}")
for k, lab in HZ:
    e = excess(trend, k)
    if e is None:
        continue
    lo, hi = boot(trend, k)
    el = excess([r for r in trend if r['up']], k)
    es = excess([r for r in trend if not r['up']], k)
    ci = f"[{lo:+.4f},{hi:+.4f}]" if lo is not None else "n/a"
    both = "" if (el is None or es is None) else ("  both+" if el > 0 and es > 0 else "  one-sided")
    print(f"  {lab:>4s} {e:+11.4f} {ci:>22s} {el:+9.4f} {es:+9.4f}{both}")

print("\n" + "=" * 80)
print("3. DOES DISTANCE FROM THE MA MATTER?")
print("=" * 80)
print("  If trend strength carries information, deeper |distance| should score")
print("  better. A flat profile means the MA is only picking a side, not a state.\n")
d = sorted(abs(r['ma']) for r in trend if r['ma'] is not None)
if d:
    qs = [d[int(p * len(d))] for p in (0.25, 0.5, 0.75)]
    buckets = [("|dist| Q1 (nearest)", lambda x: x < qs[0]),
               ("|dist| Q2", lambda x: qs[0] <= x < qs[1]),
               ("|dist| Q3", lambda x: qs[1] <= x < qs[2]),
               ("|dist| Q4 (deepest)", lambda x: x >= qs[2])]
    print(f"  {'bucket':<22s} {'n':>6s} " + "".join(f"{lab:>8s}" for _, lab in HZ))
    for name, fn in buckets:
        pop = [r for r in trend if r['ma'] is not None and fn(abs(r['ma']))]
        cells = ""
        for k, _ in HZ:
            hr, _n = hit_rate(pop, k)
            cells += f"{hr:7.2f}%" if hr is not None else "     n/a"
        print(f"  {name:<22s} {len(pop):6d} " + cells)
