#!/usr/bin/env python3
"""Shared loading and scoring for the run #8 excursion (first-touch grid) CSVs.

Extracted from what were three scratch scripts that shared state by exec'ing a
prefix of each other, split on the literal text of a print statement. That broke
if the working directory changed or if anyone edited that print line, so the
common part lives here as an ordinary importable module instead.

The grid itself is defined by the EA (see EXC_LEVELS / ExcLevelAtr and the
STOP/REJECT ladders in AjipSnD_Excursion.mqh); the constants below must stay in
step with it.
"""
import csv
from collections import defaultdict

# Level grid in LTF ATR — mirrors ExcLevelAtr[] in AjipSnD_Excursion.mqh
LV = [0.25, 0.50, 0.75, 1.00, 1.25, 1.50, 2.00, 2.50, 3.00, 4.00, 5.00, 6.00, 8.00]
KF = ["f025", "f050", "f075", "f100", "f125", "f150", "f200",
      "f250", "f300", "f400", "f500", "f600", "f800"]
KA = ["a025", "a050", "a075", "a100", "a125", "a150", "a200",
      "a250", "a300", "a400", "a500", "a600", "a800"]

# The entry variants observed side by side on every zone.
VARIANTS = [("LIMIT", "0.00"),
            ("STOP", "0.00"), ("STOP", "0.25"), ("STOP", "0.50"), ("STOP", "1.00"),
            ("REJECT", "0.00"), ("REJECT", "0.25"), ("REJECT", "0.50"), ("REJECT", "1.00")]


def detect_point(path):
    """Derive the symbol's point size from a price column's decimal places.

    Several of these analyses convert an ATR (price) into points to check a
    level against the broker's minimum stop distance. Hardcoding the factor is a
    silent 10x error when the symbol's digits differ — XAUUSD is digits=3 here
    and digits=2 on other brokers — so it is read off the data instead.
    """
    dec = 0
    with open(path, newline='') as fh:
        for i, r in enumerate(csv.DictReader(fh)):
            p = (r.get('limit_price') or r.get('fill_price') or '').strip()
            if '.' in p:
                dec = max(dec, len(p.split('.')[1]))
            if i > 500:
                break
    if dec == 0:
        raise ValueError("could not determine price precision")
    return 10.0 ** (-dec)


def load(path):
    """Return (all_rows, arm) where arm maps (kind, offset) -> list of rows.

    Triggered rows gain 'F'/'A' (first-touch seconds per grid level, -1 = never
    reached) and 'slip'. Untriggered rows are kept: a variant that declines a
    zone must still contribute that zone to its denominator, otherwise every
    variant is scored on a different, self-selected population.
    """
    rows = list(csv.DictReader(open(path, newline='')))
    arm = defaultdict(list)
    for r in rows:
        k = (r['entry_kind'], r['offset_atr'])
        if k not in VARIANTS:
            continue
        r['t'] = (r['triggered'] == '1')
        r['day'] = r['arm_time'][:10]
        r['atr'] = float(r['atr_ltf']) if r.get('atr_ltf') else 0.0
        if r['t']:
            r['F'] = [int(r[x]) for x in KF]
            r['A'] = [int(r[x]) for x in KA]
            r['slip'] = float(r['slip_pts'])
        arm[k].append(r)
    return rows, arm


def triggered_stops(path):
    """The STOP+0.00 rows that actually fired — the population several of the
    period A/B analyses are scored on. Returns (rows, point_size).

    Note the scoring unit: because this list is already filtered to triggered
    rows, a mean over it is per-TRADE, not per-armed-zone. That is the right
    unit when comparing (TP, SL) geometries for ONE fixed entry mechanism, and
    the wrong one when comparing mechanisms against each other — see
    excursion_surface.py, which scores per armed zone for exactly that reason.
    """
    _, arm = load(path)
    return [r for r in arm[('STOP', '0.00')] if r['t']], detect_point(path)


def outcome(r, tp, sl):
    """R-multiple of one triggered row under a (TP, SL) pair, in units of risk.

    This is the whole reason the first-touch grid exists: max-excursion data can
    prove both levels were reached but not which came first, and that is exactly
    what decides the trade. Comparing the two timestamps resolves it exactly.

    -1 = stopped, +LV[tp]/LV[sl] = target paid, 0 = neither level reached inside
    the tracking horizon (an open position at horizon end, scored flat).
    """
    pay = LV[tp] / LV[sl]
    f, a = r['F'][tp], r['A'][sl]
    if f < 0 and a < 0:
        return 0.0          # neither touched
    if a < 0:
        return pay          # target only
    if f < 0:
        return -1.0         # stop only
    if f < a:
        return pay          # target first
    if a < f:
        return -1.0         # stop first
    return 0.0              # same second — unresolvable, scored flat


def mean_r(rows, tp, sl):
    """Mean R over the rows given, counting only triggered ones in the numerator.

    Pass an already-triggered list for per-trade scoring; pass every armed row
    for per-armed-zone scoring. The denominator is always len(rows), so the
    caller's choice of population IS the choice of unit.
    """
    if not rows:
        return 0.0
    return sum(outcome(r, tp, sl) for r in rows if r['t']) / len(rows)


def day_bootstrap(rows, tp, sl, n=1200, seed=137):
    """95% CI on R-per-armed-zone, resampling whole DAYS.

    Zones fire in bursts and their tracking windows overlap, so rows are far
    from independent; resampling rows individually would give a CI several times
    too narrow. Days are the block unit.
    """
    import random
    rnd = random.Random(seed)
    byday = defaultdict(list)
    for r in rows:
        byday[r['day']].append(r)
    keys = list(byday)
    if not keys:
        return None, None
    est = []
    for _ in range(n):
        s = []
        for _ in range(len(keys)):
            s += byday[rnd.choice(keys)]
        if s:
            est.append(sum(outcome(r, tp, sl) for r in s if r['t']) / len(s))
    if not est:
        return None, None
    est.sort()
    return est[int(0.025 * len(est))], est[int(0.975 * len(est))]
