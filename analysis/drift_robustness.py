#!/usr/bin/env python3
"""Run #9 robustness checks.

The headline result is a null, and a null is only as good as the checks that
could have broken it. Three things could make it wrong:

 1. UNFAIR BASELINE. Zones may fire in higher-volatility moments than the
    uniformly-drawn baseline, so mu would be measured on a different regime.
    Checked by comparing the ATR composition of the two populations.

 2. THE AGGREGATE HIDING TWO REAL, OPPOSITE EFFECTS. Checked by hit rate per
    side -- which needs no baseline and no normalisation at all.

 3. A REAL SIGNAL LIVING ONLY IN A SUBSET. Both quality inputs were disabled in
    this run (InpMaxZoneWidthAtr=0, InpMinDispBodyAtr=0), so every zone was
    armed. Slicing by displacement/width tests OUR OWN existing claim -- the
    architecture notes say those two together lifted median MFE out of sample.
    That is a pre-existing hypothesis, not a fishing expedition; it is reported
    with that limit stated, and the number of slices is kept small on purpose.
"""
import csv, sys, math, statistics as st

if len(sys.argv) < 3:
    sys.exit("usage: drift_robustness.py <AjipSnD_Drift_*.csv> <AjipSnD_Zones_*.csv>\n"
             "  Both CSVs live in the MT5 terminal's Common\\Files directory.")
DRIFT, ZONECSV = sys.argv[1], sys.argv[2]
HZ = [('d05m', '5m'), ('d15m', '15m'), ('d1h', '1h'), ('d4h', '4h'), ('d1d', '1d')]


def detect_point(path):
    """See drift_analysis.py -- point size is read off the data, never assumed."""
    dec = 0
    with open(path, newline='') as fh:
        for i, r in enumerate(csv.DictReader(fh)):
            p = (r.get('arm_price') or '').strip()
            if '.' in p:
                dec = max(dec, len(p.split('.')[1]))
            if i > 500:
                break
    if dec == 0:
        sys.exit("could not determine price precision from arm_price")
    return 10.0 ** (-dec)


POINT = detect_point(DRIFT)

rows = []
with open(DRIFT, newline='') as f:
    for r in csv.DictReader(f):
        if not r.get('arm_time'):
            continue
        atr = float(r['atr_ltf']) if r.get('atr_ltf') else 0.0
        if atr <= 0:
            continue
        rec = {'zone': r['is_zone'] == '1', 'demand': r.get('is_demand') == '1',
               'atr': atr, 'zt': (r.get('ltf_zone_time') or '').strip()}
        for k, _ in HZ:
            v = r.get(k, '')
            rec[k] = (float(v) * POINT) / atr if v not in ('', None) else None
        rows.append(rec)

zones = [r for r in rows if r['zone']]
base = [r for r in rows if not r['zone']]


def q(v, p):
    v = sorted(v)
    return v[min(len(v) - 1, int(p * len(v)))]


print("=" * 74)
print("CHECK 1 -- is the baseline drawn from the same volatility regime?")
print("=" * 74)
za = [r['atr'] for r in zones]
ba = [r['atr'] for r in base]
print(f"  zone ATR     p25={q(za,.25):.3f}  median={q(za,.5):.3f}  p75={q(za,.75):.3f}")
print(f"  baseline ATR p25={q(ba,.25):.3f}  median={q(ba,.5):.3f}  p75={q(ba,.75):.3f}")
ratio = q(za, .5) / q(ba, .5)
print(f"  median ratio = {ratio:.2f}x", end="  ")
print("-> regimes comparable" if 0.8 <= ratio <= 1.25 else
      "-> DIFFERENT regimes; baseline mu is measured on the wrong population")
print()

print("=" * 74)
print("CHECK 2 -- hit rate per side (no baseline, no normalisation needed)")
print("=" * 74)
print("  In a strong uptrend demand SHOULD beat 50% and supply SHOULD trail it,")
print("  from market drift alone. Zone information would show as BOTH above 50%.")
print(f"  {'hz':>4s}  {'demand':>16s}  {'supply':>16s}  {'combined':>16s}")
for k, lab in HZ:
    d = [r[k] for r in zones if r['demand'] and r[k] is not None]
    s = [r[k] for r in zones if not r['demand'] and r[k] is not None]
    if not d or not s:
        continue
    dh = 100.0 * sum(1 for x in d if x > 0) / len(d)          # demand wants up
    sh = 100.0 * sum(1 for x in s if x < 0) / len(s)          # supply wants down
    ch = 100.0 * (sum(1 for x in d if x > 0) + sum(1 for x in s if x < 0)) / (len(d) + len(s))
    se = 100.0 * 0.5 / math.sqrt(len(d) + len(s))
    z = (ch - 50.0) / se
    print(f"  {lab:>4s}  {dh:15.2f}%  {sh:15.2f}%  {ch:15.2f}%   z={z:+.1f}")
print("  (z is vs a 50% coin flip on the combined, near-balanced population)")
print()

print("=" * 74)
print("CHECK 3 -- does any zone-quality slice carry direction?")
print("=" * 74)
meta = {}
try:
    with open(ZONECSV, newline='') as f:
        for r in csv.DictReader(f):
            if r.get('action') != 'CONFIRM' or r.get('tf') != 'LTF':
                continue
            try:
                meta[r['zone_time'].strip()] = {
                    'disp': float(r['disp_body_atr']), 'width': float(r['width_atr']),
                    'htf': r.get('htf_trend', '').strip(),
                    'demand': r.get('type') == 'DEMAND'}
            except (ValueError, KeyError):
                pass
except OSError as e:
    print(f"  zone CSV unavailable ({e}) -- slice check skipped")
    meta = {}

if meta:
    joined = [r for r in zones if r['zt'] in meta]
    print(f"  joined {len(joined)} / {len(zones)} zone rows to zone-quality metrics")

    def hit(pop, k):
        v = [(r, r[k]) for r in pop if r[k] is not None]
        if len(v) < 200:
            return None, 0
        h = sum(1 for r, x in v if (x > 0) == r['demand'])
        return 100.0 * h / len(v), len(v)

    def show(label, pop):
        out = []
        for k, lab in [('d15m', '15m'), ('d1h', '1h'), ('d4h', '4h')]:
            hr, n = hit(pop, k)
            out.append(f"{lab}={hr:5.2f}%" if hr is not None else f"{lab}=  n/a")
        print(f"  {label:<34s} n={len(pop):6d}  " + "  ".join(out))

    print("\n  -- by displacement (our stated quality driver; gate was OFF this run) --")
    dv = sorted(meta[r['zt']]['disp'] for r in joined)
    for lo, hi, name in [(0, .25, 'displacement Q1 (weakest)'),
                         (.25, .5, 'displacement Q2'),
                         (.5, .75, 'displacement Q3'),
                         (.75, 1.0, 'displacement Q4 (strongest)')]:
        a, b = q(dv, lo), q(dv, hi) if hi < 1.0 else float('inf')
        show(name, [r for r in joined if a <= meta[r['zt']]['disp'] < b])

    print("\n  -- by zone width (the other gate input) --")
    wv = sorted(meta[r['zt']]['width'] for r in joined)
    for lo, hi, name in [(0, .5, 'width, tighter half'), (.5, 1.0, 'width, wider half')]:
        a, b = q(wv, lo), q(wv, hi) if hi < 1.0 else float('inf')
        show(name, [r for r in joined if a <= meta[r['zt']]['width'] < b])

    print("\n  -- by HTF trend alignment (cross-timeframe confluence) --")
    show('aligned with HTF trend',
         [r for r in joined
          if (meta[r['zt']]['htf'] == 'UP') == meta[r['zt']]['demand']])
    show('against HTF trend',
         [r for r in joined
          if (meta[r['zt']]['htf'] == 'UP') != meta[r['zt']]['demand']])

    print("\n  Reading: ~50% everywhere = no slice carries direction. Values a point")
    print("  or two off 50 across 10 slices x 3 horizons are what noise looks like;")
    print("  a real edge would show as one slice consistently clear of 50 at EVERY")
    print("  horizon, not one cell in isolation.")
