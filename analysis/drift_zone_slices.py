#!/usr/bin/env python3
"""Do the zone attributes we never tested individually carry direction?

Run #9 sliced displacement, width and HTF alignment — all null. Three attributes
that shape EA behaviour were never tested on their own, and all three are
already on disk, so this needs no backtest:

  swept      — a liquidity sweep preceded confirmation. The core SMC claim, and
               already baked into ProcessZoneBar (a swept candidate must close
               beyond the sweep level to confirm), yet never checked in isolation.
  base_bars  — fastest possible origin (2 bars) vs a base that sat longer. The
               struct comment used to say "1=impulsive", a state that cannot
               occur; this analysis is what found that.
  validated  — passed follow-through. This gate decides whether an entry is
               placed at all, so if it carries no direction the gate is
               filtering on nothing.

METHOD. Direction-adjusted hit rate per group (no baseline needed: the demand
and supply counts are near-balanced, so 50% is the honest null). Significance by
STRATIFIED PERMUTATION — the attribute labels are shuffled WITHIN each day, so
day-level common shocks (overlapping windows, regime) are held fixed and the
test asks only whether the attribute separates zones beyond them. Shuffling
labels freely would ignore that clustering and overstate significance.

MULTIPLE COMPARISONS. Enough tests to manufacture one winner. Alongside per-test
p-values there is a family-wise test on the MAX |gap| across every test, against
the permutation distribution of that same maximum — the same discipline as the
run #8 placebo bar.

RESULT (run #9 data): family-wise p = 0.201. Largest gap anywhere was 1.39 pp
against a permutation 95th percentile of 1.70 pp. The one cell under p<0.05
uncorrected was swept at 1h, and its sign is NEGATIVE — swept zones did slightly
worse, the opposite of the claim the sweep rule encodes. No lead.
"""
import csv, sys, random
from collections import defaultdict

random.seed(20260816)
if len(sys.argv) < 3:
    sys.exit("usage: drift_zone_slices.py <AjipSnD_Drift_*.csv> <AjipSnD_Zones_*.csv>\n"
             "  Both CSVs live in the MT5 terminal's Common\\Files directory.\n"
             "  Note the zones CSV is APPENDED across runs; zone attributes are\n"
             "  deterministic so duplicates are harmless, but check the join count.")
DRIFT, ZONES = sys.argv[1], sys.argv[2]
HZ = [('d05m', '5m'), ('d15m', '15m'), ('d1h', '1h'), ('d4h', '4h'), ('d1d', '1d')]
NPERM = 2000

# ---- zone metadata -------------------------------------------------------
# base_bars / swept are fixed at confirmation, so they are correct on the
# CONFIRM row. validated is NOT: TrackZone writes the CONFIRM row with
# validated=false and MarkZoneValidated updates the tracker afterwards, so the
# only truthful copy is the OUTCOME row. Reading it off CONFIRM would score
# every zone as unvalidated.
conf, outc = {}, {}
for r in csv.DictReader(open(ZONES, newline='')):
    if r.get('tf') != 'LTF':
        continue
    key = (r['zone_time'].strip(), r.get('type') == 'DEMAND')
    if r.get('action') == 'CONFIRM':
        try:
            conf[key] = {'base': int(r['base_bars']),
                         'swept': (r['swept_low'] == '1' or r['swept_high'] == '1')}
        except (ValueError, KeyError):
            pass
    elif r.get('action') == 'OUTCOME':
        outc[key] = {'validated': r.get('validated') == '1'}

rows = []
for r in csv.DictReader(open(DRIFT, newline='')):
    if r['is_zone'] != '1':
        continue
    dem = r['is_demand'] == '1'
    key = ((r.get('ltf_zone_time') or '').strip(), dem)
    if key not in conf:
        continue
    rec = {'day': r['arm_time'][:10], 'demand': dem,
           'base': conf[key]['base'], 'swept': conf[key]['swept'],
           'validated': outc.get(key, {}).get('validated')}
    for k, _ in HZ:
        v = r.get(k, '')
        rec[k] = float(v) if v not in ('', None) else None
    rows.append(rec)

print(f"joined {len(rows)} zone rows  (CONFIRM meta {len(conf)}, OUTCOME meta {len(outc)})")
nb = sum(1 for r in rows if r['base'] == 1)
print(f"  swept:     {sum(1 for r in rows if r['swept'])} yes / {sum(1 for r in rows if not r['swept'])} no")
print(f"  base_bars: {nb} impulsive (==1) / {len(rows)-nb} multi-bar")
nv = sum(1 for r in rows if r['validated'] is True)
print(f"  validated: {nv} yes / {sum(1 for r in rows if r['validated'] is False)} no"
      f" / {sum(1 for r in rows if r['validated'] is None)} unknown")
print()

# base_bars==1 is unreachable: the bar that creates a candidate increments
# baseBars to 1 and cannot confirm itself (confirmation needs close > its own
# high), so the fastest possible confirmation is 2. The "1=impulsive" comment in
# AjipSnD_Globals.mqh describes a state that never occurs; 2 is the real floor.
#
# validated is CIRCULAR and is excluded from the significance tests below. A
# demand zone is marked validated exactly when a later bar closes above the
# confirm bar's high — that is, when price went up — and the drift asks whether
# price went up. It is the same event scored twice, not a prediction.
SPLITS = [
    ('swept',     'sweep before confirm',     lambda r: r['swept'],      True),
    ('base_bars', 'fastest origin (==2 bars)', lambda r: r['base'] == 2, True),
    ('validated', 'passed follow-through',    lambda r: r['validated'],  False),
]
TESTABLE = [s for s in SPLITS if s[3]]


def hit(r, k):
    """Direction-adjusted: did price move the way this zone predicted?"""
    v = r[k]
    return None if v is None else ((v > 0) == r['demand'])


def rate(pop, k):
    h = [hit(r, k) for r in pop]
    h = [x for x in h if x is not None]
    return (100.0 * sum(h) / len(h), len(h)) if h else (None, 0)


print("=" * 82)
print("OBSERVED — direction-adjusted hit rate by group (50% = coin flip)")
print("=" * 82)
observed = {}
for name, label, fn, testable in SPLITS:
    pop = [r for r in rows if fn(r) is not None]
    tag = "" if testable else "   [CIRCULAR — reported, not tested]"
    print(f"\n  {name}  ({label}){tag}")
    print(f"    {'hz':>4s}  {'TRUE':>18s}  {'FALSE':>18s}  {'gap (pp)':>9s}")
    for k, lab in HZ:
        a = [r for r in pop if fn(r)]
        b = [r for r in pop if not fn(r)]
        ra, na = rate(a, k)
        rb, nb_ = rate(b, k)
        if ra is None or rb is None:
            continue
        gap = ra - rb
        if testable:
            observed[(name, k)] = gap
        print(f"    {lab:>4s}  {ra:8.2f}% (n={na:5d})  {rb:8.2f}% (n={nb_:5d})  {gap:+9.2f}")


# ---- stratified permutation ---------------------------------------------
def permute_within_days(pop, fn):
    """Reassign the attribute label within each day, preserving day composition."""
    byday = defaultdict(list)
    for r in pop:
        byday[r['day']].append(r)
    assign = {}
    for day, rs in byday.items():
        labels = [fn(r) for r in rs]
        random.shuffle(labels)
        for r, lb in zip(rs, labels):
            assign[id(r)] = lb
    return assign


print("\n" + "=" * 82)
print(f"PERMUTATION — labels shuffled within each day, {NPERM} draws")
print(f"  (circular attributes excluded; {len(TESTABLE)} attributes x {len(HZ)} horizons tested)")
print("=" * 82)
print("  p = share of shuffles whose |gap| reaches the observed |gap|\n")

null_by_test = defaultdict(list)
null_max = []
for _ in range(NPERM):
    biggest = 0.0
    for name, label, fn, _tb in TESTABLE:
        pop = [r for r in rows if fn(r) is not None]
        assign = permute_within_days(pop, fn)
        for k, lab in HZ:
            if (name, k) not in observed:
                continue
            a = [r for r in pop if assign[id(r)]]
            b = [r for r in pop if not assign[id(r)]]
            ra, _ = rate(a, k)
            rb, _ = rate(b, k)
            if ra is None or rb is None:
                continue
            g = abs(ra - rb)
            null_by_test[(name, k)].append(g)
            biggest = max(biggest, g)
    null_max.append(biggest)

print(f"  {'attribute':>11s} {'hz':>4s} {'gap':>8s} {'p':>7s}")
for name, label, fn, _tb in TESTABLE:
    for k, lab in HZ:
        key = (name, k)
        if key not in observed:
            continue
        g = abs(observed[key])
        nulls = null_by_test[key]
        p = sum(1 for x in nulls if x >= g) / len(nulls)
        mark = "  <-- p<0.05 (uncorrected)" if p < 0.05 else ""
        print(f"  {name:>11s} {lab:>4s} {observed[key]:+8.2f} {p:7.3f}{mark}")

null_max.sort()
obs_max = max(abs(v) for v in observed.values())
p95 = null_max[int(0.95 * len(null_max))]
pfam = sum(1 for x in null_max if x >= obs_max) / len(null_max)
print("\n" + "-" * 82)
print("FAMILY-WISE (the only line that survives 15 tests):")
print(f"  largest |gap| observed anywhere: {obs_max:.2f} pp")
print(f"  95th pct of the same maximum under permutation: {p95:.2f} pp")
print(f"  family-wise p = {pfam:.3f}  -> "
      + ("A REAL LEAD" if pfam < 0.05 else "indistinguishable from noise"))
