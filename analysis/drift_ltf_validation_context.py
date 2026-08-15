#!/usr/bin/env python3
"""Real-time-honest version of the no-touch idea, plus the HTF-anchor context.

Fixes the look-ahead in the earlier quick check: touchedAtValidation is
snapshotted at the EXACT instant validation passes (MarkLtfValidationContext,
called right after MarkZoneValidated), not derived from the final OUTCOME
row's 'touched' -- that field reflects the zone's WHOLE tracking lifetime,
unknowable in real time. htfContextValidated reuses the identical containment
check PlaceEntryForZone already gates real orders on: is this LTF edge inside
an ACTIVE, VALIDATED HTF zone (a zone only enters the active HTF array once it
has itself validated) at the same instant.

Four cells, since the user's original idea was the compound of both:
  validated + touched-not-yet + HTF-context   <- the actual proposal
  validated + touched-not-yet + no HTF-context
  validated + already-touched + HTF-context
  validated + already-touched + no HTF-context

Reading: if the compound cell is real, it should be visibly ahead of the
other three, not just ahead of a flat 50% baseline -- multiple related-but-
different filters make it easy to find ONE positive-looking cell by chance.
"""
import csv, sys, statistics as st

if len(sys.argv) < 3:
    sys.exit("usage: drift_ltf_validation_context.py <AjipSnD_Drift_*.csv> <AjipSnD_Zones_*.csv>\n"
             "  Needs a run with build >= 1.12 (touched_at_validation / htf_context_validated\n"
             "  columns). The zones CSV header is written once, on first creation, so an\n"
             "  older shared file needs its header line patched with the two new column\n"
             "  names before DictReader will align them by name -- see the commit that\n"
             "  added this script for the one-off fix.")
DRIFT, ZONES = sys.argv[1], sys.argv[2]
HZ = [('d05m', '5m'), ('d15m', '15m'), ('d1h', '1h'), ('d4h', '4h'), ('d1d', '1d')]

meta = {}
with open(ZONES, newline='') as f:
    for r in csv.DictReader(f):
        if r.get('action') != 'OUTCOME' or r.get('tf') != 'LTF':
            continue
        if 'touched_at_validation' not in r:
            sys.exit("this zones CSV predates the new columns -- wrong file?")
        key = (r['zone_time'].strip(), r.get('type') == 'DEMAND')
        meta[key] = {
            'validated': r.get('validated') == '1',
            'touched_at_val': r.get('touched_at_validation') == '1',
            'htf_ctx': r.get('htf_context_validated') == '1',
        }

rows = []
with open(DRIFT, newline='') as f:
    for r in csv.DictReader(f):
        if r['is_zone'] != '1':
            continue
        dem = r['is_demand'] == '1'
        key = ((r.get('ltf_zone_time') or '').strip(), dem)
        if key not in meta or not meta[key]['validated']:
            continue
        rec = {'demand': dem, **meta[key]}
        for k, _ in HZ:
            v = r.get(k, '')
            rec[k] = float(v) if v not in ('', None) else None
        rows.append(rec)

print(f"joined {len(rows)} VALIDATED zone rows to the new fields")
n_notouch = sum(1 for r in rows if not r['touched_at_val'])
n_htf = sum(1 for r in rows if r['htf_ctx'])
print(f"  not-yet-touched at validation: {n_notouch} / {len(rows)} ({100*n_notouch/len(rows):.1f}%)")
print(f"  inside validated HTF context : {n_htf} / {len(rows)} ({100*n_htf/len(rows):.1f}%)\n")


def hit(pop, k):
    v = [(r[k] > 0) == r['demand'] for r in pop if r[k] is not None]
    return (100.0 * sum(v) / len(v), len(v)) if v else (None, 0)


cells = [
    ("no-touch + HTF-context  (the proposal)", lambda r: not r['touched_at_val'] and r['htf_ctx']),
    ("no-touch + no HTF-context", lambda r: not r['touched_at_val'] and not r['htf_ctx']),
    ("already-touched + HTF-context", lambda r: r['touched_at_val'] and r['htf_ctx']),
    ("already-touched + no HTF-context", lambda r: r['touched_at_val'] and not r['htf_ctx']),
]

print(f"  {'cell':<40s} {'n':>6s} " + "  ".join(f"{lab:>7s}" for _, lab in HZ))
for name, fn in cells:
    pop = [r for r in rows if fn(r)]
    line = f"  {name:<40s} {len(pop):6d} "
    for k, _ in HZ:
        hr, _ = hit(pop, k)
        line += f"{hr:6.2f}% " if hr is not None else "   n/a  "
    print(line)

print("\n  Reading: the proposal cell needs to be visibly ahead of the OTHER")
print("  three, not just ahead of 50% -- four related cells make it easy to")
print("  find one that looks good by chance alone.")
