#!/usr/bin/env python3
"""Do the zone-null and trend-null conclusions hold on a second, non-overlapping
12-month period?

Every prior drift/trend measurement came from one calendar year (2024.08-
2025.07). Run #7 is the standing warning about trusting a single period: a
stop-entry finding that passed period A reversed sign on period B. This script
puts the SAME two questions (does the zone predict anything, does the H1 trend
signal predict anything) through the same period-B split, using the drift CSV
schema rather than the excursion CSV.

usage: drift_period_compare.py <period A drift CSV> <period B drift CSV>
"""
import csv, sys, statistics as st

if len(sys.argv) < 3:
    sys.exit("usage: drift_period_compare.py <period A drift CSV> <period B drift CSV>")

HZ = [('d05m', '5m'), ('d15m', '15m'), ('d1h', '1h'), ('d4h', '4h'), ('d1d', '1d')]
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


def load(path):
    point = detect_point(path)
    zones, trend, base = [], [], []
    with open(path, newline='') as f:
        rd = csv.DictReader(f)
        has_kind = 'kind' in (rd.fieldnames or [])
        for r in rd:
            atr = float(r['atr_ltf']) if r.get('atr_ltf') else 0.0
            if atr <= 0 or not r.get('arm_time'):
                continue
            kind = r['kind'] if has_kind else ('ZONE' if r['is_zone'] == '1' else 'BASELINE')
            rec = {'up': r.get('is_demand') == '1', 'day': r['arm_time'][:10]}
            for k, _ in HZ:
                v = r.get(k, '')
                # ATR-normalised for hit-rate/drift use (sign is unaffected,
                # since point and atr are both always positive). d1h_pts keeps
                # the raw point value alongside it for the move-size diagnostic
                # below, which must not be reported in ATR units as points.
                rec[k] = (float(v) * point) / atr if v not in ('', None) else None
            rec['d1h_pts'] = float(r['d1h']) if r.get('d1h') not in ('', None) else None
            (zones if kind == 'ZONE' else trend if kind == 'TREND' else base).append(rec)
    return zones, trend, base, min(r['day'] for r in zones + trend + base if 'day' in r), \
        max(r['day'] for r in zones + trend + base if 'day' in r)


def mu(base, k):
    v = [r[k] for r in base if r[k] is not None]
    return st.mean(v) if v else 0.0


def hit_rate(pop, k, flip=None):
    out = []
    for r in pop:
        if r[k] is None:
            continue
        want_up = r['up'] if flip is None else flip
        out.append((r[k] > 0) == want_up)
    return (100.0 * sum(out) / len(out), len(out)) if out else (None, 0)


def report(label, zones, trend, base):
    print(f"\n{'=' * 78}\n{label}\n{'=' * 78}")
    print(f"  zones {len(zones)}   trend {len(trend)}   baseline {len(base)}\n")

    print("  ZONE hit rate (direction-adjusted, 50% = coin flip):")
    print(f"    {'hz':>4s} " + "".join(f"{lab:>8s}" for _, lab in HZ))
    line = "    zone "
    for k, lab in HZ:
        hr, _ = hit_rate(zones, k)
        line += f"{hr:7.2f}%" if hr is not None else "     n/a"
    print(line)

    if trend:
        print("\n  TREND vs LONG-ONLY benchmark, vs the execution cost bar:")
        print(f"    {'hz':>4s} {'trend':>8s} {'long-only':>10s} {'edge':>7s} {'cost bar':>9s}")
        for k, lab in HZ:
            t, _ = hit_rate(trend, k)
            lo, _ = hit_rate(trend, k, flip=True)
            if t is None:
                continue
            print(f"    {lab:>4s} {t:7.2f}% {lo:9.2f}% {t - lo:+6.2f} {COST_BAR[lab]:8.1f}%")

    print("\n  Move available (median |1h forward move|, baseline rows only, no signal):")
    v = [abs(r['d1h_pts']) for r in base if r['d1h_pts'] is not None]
    if v:
        print(f"    {st.median(v):.0f} points")
    return {k: hit_rate(zones, k)[0] for k, _ in HZ}, \
        ({k: (hit_rate(trend, k)[0], hit_rate(trend, k, flip=True)[0]) for k, _ in HZ} if trend else None)


zA, tA, bA, dayA0, dayA1 = load(sys.argv[1])
zB, tB, bB, dayB0, dayB1 = load(sys.argv[2])

zoneA, trendA = report(f"PERIOD A  ({dayA0} -> {dayA1})", zA, tA, bA)
zoneB, trendB = report(f"PERIOD B  ({dayB0} -> {dayB1})", zB, tB, bB)

print(f"\n{'=' * 78}\nSIDE BY SIDE\n{'=' * 78}")
print("  Zone hit rate, A vs B (both should sit near 50% if the null replicates):")
print(f"    {'hz':>4s} {'period A':>10s} {'period B':>10s} {'gap':>7s}")
for k, lab in HZ:
    a, b = zoneA.get(k), zoneB.get(k)
    if a is None or b is None:
        continue
    print(f"    {lab:>4s} {a:9.2f}% {b:9.2f}% {a - b:+6.2f}")

if trendA and trendB:
    print("\n  Trend edge over long-only, A vs B (should agree in SIGN if the")
    print("  'worse than holding' finding is not period-specific):")
    print(f"    {'hz':>4s} {'A: trend':>9s} {'A: long':>8s} {'A edge':>8s} "
          f"{'B: trend':>9s} {'B: long':>8s} {'B edge':>8s}")
    for k, lab in HZ:
        (ta, la), (tb, lb) = trendA[k], trendB[k]
        if None in (ta, la, tb, lb):
            continue
        ea, eb = ta - la, tb - lb
        agree = "" if (ea > 0) == (eb > 0) else "  <- SIGN FLIP"
        print(f"    {lab:>4s} {ta:8.2f}% {la:7.2f}% {ea:+7.2f} "
              f"{tb:8.2f}% {lb:7.2f}% {eb:+7.2f}{agree}")
