#!/usr/bin/env python3
"""Run #9 forward-drift analysis.

Question: at LTF zone confirmation, does price drift in the direction the zone
predicts over fixed horizons -- more than from a random moment on the same chart?

Method notes (why it is built this way):

* DIRECTION. A demand zone predicts up, a supply zone predicts down. Signed
  drift = +delta for demand, -delta for supply. The baseline rows have no
  direction at all, so they cannot be signed the same way; instead the baseline
  gives the market's unconditional drift mu, and the zone population is compared
  against +mu (demand) / -mu (supply). This matters: XAUUSD trended hard over
  2024-25, so an unbalanced demand/supply mix alone would manufacture a signal.

* DEMAND AND SUPPLY REPORTED SEPARATELY. If the zone concept carries direction
  information, BOTH sides should beat their own baseline. A result driven by one
  side only is the market trend leaking through, not zone information.

* CLUSTERED BOOTSTRAP. Zones fire in bursts and the 1h/4h/1d horizons of nearby
  zones overlap almost completely, so rows are nowhere near independent. CIs come
  from a day-level block bootstrap (resample whole days), matching the run #8
  analysis. The 1d horizon still overlaps ACROSS adjacent days, so its CI is the
  most optimistic of the five -- flagged in the output rather than silently used.
"""
import csv, sys, random, statistics as st
from collections import defaultdict

random.seed(20260815)

if len(sys.argv) < 2:
    sys.exit("usage: drift_analysis.py <AjipSnD_Drift_SYMBOL_LOGIN.csv>\n"
             "  CSV lives in the MT5 terminal's Common\\Files directory.")
CSV = sys.argv[1]
HZ = [('d05m', '5m'), ('d15m', '15m'), ('d1h', '1h'), ('d4h', '4h'), ('d1d', '1d')]


def detect_point(path):
    """Derive the symbol's point size from arm_price's decimal places.

    The drift CSV logs horizon deltas in POINTS but ATR in PRICE, so converting
    between them needs the point size. Hardcoding it is a silent 10x error when
    the symbol's digits differ from what the author assumed (XAUUSD is digits=3
    on this broker, digits=2 on others), and every number downstream is scaled
    by it. Reading it off the data cannot drift out of sync with the data.
    """
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
    return 10.0 ** (-dec), dec


POINT, DIGITS = detect_point(CSV)

rows = []
with open(CSV, newline='') as f:
    for r in csv.DictReader(f):
        if not r.get('arm_time'):
            continue
        rec = {
            'zone': r['is_zone'] == '1',
            'demand': r.get('is_demand') == '1',
            'day': r['arm_time'][:10],
            'atr': float(r['atr_ltf']) if r.get('atr_ltf') else 0.0,
        }
        if rec['atr'] <= 0:
            continue
        ok = False
        for k, _ in HZ:
            v = r.get(k, '')
            if v not in ('', None):
                # points -> price -> ATR units
                rec[k] = (float(v) * POINT) / rec['atr']
                ok = True
            else:
                rec[k] = None
        if ok:
            rows.append(rec)

zones = [r for r in rows if r['zone']]
base = [r for r in rows if not r['zone']]
dem = [r for r in zones if r['demand']]
sup = [r for r in zones if not r['demand']]

print("=" * 78)
print("FORWARD DRIFT FROM ZONE CONFIRMATION (no entry, no SL/TP)")
print("=" * 78)
print(f"price precision: {DIGITS} decimals -> point={POINT} (auto-detected)")
print(f"zone rows     : {len(zones):6d}   (demand {len(dem)}, supply {len(sup)})")
print(f"baseline rows : {len(base):6d}")
if zones:
    print(f"median LTF ATR: {st.median([r['atr'] for r in zones]):.3f} price "
          f"({st.median([r['atr'] for r in zones])/POINT:.0f} pts) -- sanity check")
print()


def mean_of(pop, k):
    v = [r[k] for r in pop if r[k] is not None]
    return (st.mean(v), len(v)) if v else (None, 0)


def signed(pop, k, mu):
    """Signed drift in ATR, baseline-corrected. mu = unconditional market drift."""
    out = []
    for r in pop:
        if r[k] is None:
            continue
        s = 1.0 if r['demand'] else -1.0
        out.append(s * r[k] - s * mu)
    return out


def boot_ci(pop, k, mu, n=2000):
    """Day-level block bootstrap on the baseline-corrected signed drift."""
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
        v = signed(s, k, mu)
        if v:
            est.append(st.mean(v))
    if not est:
        return None, None
    est.sort()
    return est[int(0.025 * len(est))], est[int(0.975 * len(est))]


print("--- unconditional market drift (baseline rows, NOT direction-adjusted) ---")
print("    this is what the zone population must beat, not zero")
mus = {}
for k, lab in HZ:
    m, n = mean_of(base, k)
    mus[k] = m if m is not None else 0.0
    if m is not None:
        print(f"  {lab:>4s}  mu = {m:+.4f} ATR  ({m*st.median([r['atr'] for r in base])/POINT:+7.1f} pts at median ATR)   n={n}")
    else:
        print(f"  {lab:>4s}  no data")
print()

print("--- zone forward drift, direction-adjusted and baseline-corrected ---")
print("    positive = price moved the way the zone predicted, beyond market drift")
print(f"  {'hz':>4s}  {'ALL zones':>22s}  {'95% CI (day-block)':>26s}  verdict")
results = {}
for k, lab in HZ:
    v = signed(zones, k, mus[k])
    if not v:
        print(f"  {lab:>4s}  (no data)")
        continue
    m = st.mean(v)
    lo, hi = boot_ci(zones, k, mus[k])
    med_atr = st.median([r['atr'] for r in zones])
    pts = m * med_atr / POINT
    ci = f"[{lo:+.4f},{hi:+.4f}]" if lo is not None else "n/a"
    if lo is None:
        vd = "?"
    elif lo > 0:
        vd = "POSITIVE"
    elif hi < 0:
        vd = "NEGATIVE"
    else:
        vd = "crosses zero"
    flag = "  <-- overlapping windows, CI optimistic" if lab == '1d' else ""
    print(f"  {lab:>4s}  {m:+.4f} ATR ({pts:+7.1f} pts)  {ci:>26s}  {vd}{flag}")
    results[lab] = (m, lo, hi, len(v))
print()

print("--- split by side (both must work, or it is just the market trend) ---")
print(f"  {'hz':>4s}  {'DEMAND (predict up)':>28s}  {'SUPPLY (predict down)':>28s}")
for k, lab in HZ:
    dv = signed(dem, k, mus[k])
    sv = signed(sup, k, mus[k])
    if not dv or not sv:
        continue
    dm, sm = st.mean(dv), st.mean(sv)
    dlo, dhi = boot_ci(dem, k, mus[k], n=1200)
    slo, shi = boot_ci(sup, k, mus[k], n=1200)
    ds = f"{dm:+.4f} [{dlo:+.3f},{dhi:+.3f}]" if dlo is not None else f"{dm:+.4f}"
    ss = f"{sm:+.4f} [{slo:+.3f},{shi:+.3f}]" if slo is not None else f"{sm:+.4f}"
    agree = "both same sign" if (dm > 0) == (sm > 0) else "DISAGREE -> trend artifact"
    print(f"  {lab:>4s}  {ds:>28s}  {ss:>28s}   {agree}")
print()

print("--- hit rate: share of zones that moved the predicted way at all ---")
print("    (50% = coin flip; direction-adjusted, no baseline correction)")
for k, lab in HZ:
    v = [(1.0 if r['demand'] else -1.0) * r[k] for r in zones if r[k] is not None]
    if not v:
        continue
    hits = sum(1 for x in v if x > 0)
    print(f"  {lab:>4s}  {100.0*hits/len(v):5.2f}%   n={len(v)}")
print()

print("--- decision bar ---")
print("  Execution cost measured in runs #4-#8 was ~150-200 pts round trip.")
print("  A drift smaller than that cannot support a direct entry trigger, but a")
print("  drift that is reliably NONZERO still supports zone-as-filter for some")
print("  other primary signal. A drift indistinguishable from zero at every")
print("  horizon closes both doors for the zone definition as it stands.")
