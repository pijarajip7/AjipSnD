#!/usr/bin/env python3
"""Which (TP, SL) geometry is worth trading, and does the choice survive holdout?

Scored on STOP+0.00 triggered entries. Three sections, in the order they have to
be read:

  1. Every cell with reward:risk >= 1.0, ranked by expectancy net of an assumed
     exit slippage drag. This is the exploratory view and it WILL be optimistic —
     it ranks 100+ cells and shows the winner.

  2. The same, restricted to cells the broker would actually accept (stop at
     least the observed minimum distance) — several of the best cells in (1) sit
     at stops too tight to place, so ranking without this filter is fiction.
     Adds the share of profit coming from the best 1% of trades: a cell whose
     result rests on a handful of outliers will not repeat.

  3. An honest holdout. Pick the best cell on the first half ONLY, then score it
     on the second half it has never seen, and vice versa. This is the number
     that matters; sections 1-2 exist to be checked against it.

usage: excursion_cell_ranking.py <AjipSnD_Excursion_*.csv>
"""
import sys
import statistics as st
from excursion_common import LV, triggered_stops, outcome, mean_r, day_bootstrap

if len(sys.argv) < 2:
    sys.exit("usage: excursion_cell_ranking.py <AjipSnD_Excursion_*.csv>")

S, POINT = triggered_stops(sys.argv[1])
if not S:
    sys.exit("no triggered STOP+0.00 rows — was InpStopEntryProbe on for this run?")

PER_PRICE = 1.0 / POINT          # price units -> points
ATR = st.median(r['atr'] for r in S)
RISK = 15.0                      # $ per trade, matches InpRiskPerTrade
SLIP = 12.0                      # measured entry slippage, assumed symmetric on exit
MIN_STOP_PTS = 336               # tightest stop the broker was ever seen to accept
CUT = "2025.02.01"

H1 = [r for r in S if r['day'] < CUT]
H2 = [r for r in S if r['day'] >= CUT]


def outs(rows, tp, sl):
    return [outcome(r, tp, sl) for r in rows]


def net_of_drag(rows, tp, sl):
    """Expectancy minus a slippage drag charged on the losers.

    A stop-out pays the spread again on exit, and that cost is a FIXED number of
    points, so it hurts a tight stop far more than a wide one. Ranking raw
    expectancy without it systematically favours stops too tight to survive
    contact with a real broker.
    """
    o = outs(rows, tp, sl)
    e = st.mean(o)
    lossfrac = sum(1 for x in o if x < 0) / len(o)
    dist_pts = LV[sl] * ATR * PER_PRICE
    return e - lossfrac * (SLIP / dist_pts), e, dist_pts, 100 * sum(1 for x in o if x > 0) / len(o)


print(f"{len(S)} triggered opportunities, median LTF ATR {ATR:.3f} "
      f"({ATR * PER_PRICE:.0f} pts). Risk ${RISK:.0f}/trade.\n")

print("=" * 96)
print("1. ALL cells with reward:risk >= 1.0 — EXPLORATORY, ranked after the fact")
print("=" * 96)
rows = []
for tp in range(13):
    for sl in range(13):
        if LV[tp] / LV[sl] < 1.0:
            continue
        net, e, pts, wr = net_of_drag(S, tp, sl)
        rows.append((net, tp, sl, LV[tp] / LV[sl], wr, pts))
rows.sort(reverse=True)
print(f"  {'SL':>6s} {'= pts':>6s} {'TP':>6s} {'R:R':>5s} {'reward$':>8s} {'win%':>6s} "
      f"{'net R':>8s} {'95% CI':>20s} {'$/trade':>8s} {'H1':>7s} {'H2':>7s}")
for net, tp, sl, rr, wr, pts in rows[:14]:
    lo, hi = day_bootstrap(S, tp, sl, seed=83)
    h1, h2 = mean_r(H1, tp, sl), mean_r(H2, tp, sl)
    flag = "" if pts >= MIN_STOP_PTS else f"  (<{MIN_STOP_PTS}pt: never placeable)"
    print(f"  {LV[sl]:5.2f}A {pts:6.0f} {LV[tp]:5.2f}A {rr:5.1f} {rr * RISK:8.2f} {wr:5.1f}% "
          f"{net:+8.4f} [{lo:+.4f},{hi:+.4f}] {net * RISK:+8.2f} {h1:+7.3f} {h2:+7.3f}{flag}")
print("\n  'reward$' is what one winner pays against the $15 risk budget.")
print("  H1/H2 are the two halves of the period, raw (no drag) — a cell whose two")
print("  halves disagree in sign is noise no matter how good the full-period number.")

print("\n" + "=" * 96)
print(f"2. IMPLEMENTABLE cells only (stop >= {MIN_STOP_PTS} pts)")
print("=" * 96)


def open_rate(rows_, tp, sl):
    n = sum(1 for r in rows_ if r['F'][tp] < 0 and r['A'][sl] < 0)
    return 100 * n / len(rows_)


def top_share(rows_, tp, sl):
    """Share of total profit from the best 1% of trades."""
    o = sorted(outs(rows_, tp, sl), reverse=True)
    k = max(1, len(o) // 100)
    tot = sum(o)
    return (sum(o[:k]) / tot * 100) if tot > 0 else float('nan')


cands = []
for sl in range(13):
    if LV[sl] * ATR * PER_PRICE < MIN_STOP_PTS:
        continue
    for tp in range(13):
        if LV[tp] / LV[sl] < 1.0:
            continue
        net, e, pts, wr = net_of_drag(S, tp, sl)
        cands.append((net, tp, sl, LV[tp] / LV[sl], wr))
cands.sort(reverse=True)
print(f"  {'SL':>6s} {'pts':>5s} {'TP':>6s} {'R:R':>5s} {'rew$':>7s} {'win%':>6s} {'open%':>6s} "
      f"{'net R':>8s} {'95% CI':>20s} {'H1':>7s} {'H2':>7s} {'top1%':>7s}")
for net, tp, sl, rr, wr in cands[:12]:
    lo, hi = day_bootstrap(S, tp, sl, seed=89)
    print(f"  {LV[sl]:5.2f}A {LV[sl] * ATR * PER_PRICE:5.0f} {LV[tp]:5.2f}A {rr:5.1f} "
          f"{rr * RISK:7.0f} {wr:5.1f}% {open_rate(S, tp, sl):5.1f}% {net:+8.4f} "
          f"[{lo:+.4f},{hi:+.4f}] {mean_r(H1, tp, sl):+7.3f} {mean_r(H2, tp, sl):+7.3f} "
          f"{top_share(S, tp, sl):6.1f}%")
print("\n  open% = neither level reached inside the tracking horizon.")
print("  top1% = share of all profit from the best 1% of trades; high values mean")
print("  the cell rests on a few outliers and will not repeat reliably.")

print("\n" + "=" * 96)
print("3. HONEST HOLDOUT — pick on one half, score on the other")
print("=" * 96)


def best_cell(pool):
    best = None
    for sl in range(13):
        if LV[sl] * ATR * PER_PRICE < MIN_STOP_PTS:
            continue
        for tp in range(13):
            if LV[tp] / LV[sl] < 1.0:
                continue
            e = mean_r(pool, tp, sl)
            if best is None or e > best[0]:
                best = (e, tp, sl)
    return best


for train, test, tn, sn in ((H1, H2, "H1", "H2"), (H2, H1, "H2", "H1")):
    e, tp, sl = best_cell(train)
    lo, hi = day_bootstrap(test, tp, sl, seed=89)
    scored = mean_r(test, tp, sl)
    print(f"  {tn} picks TP {LV[tp]:.2f} / SL {LV[sl]:.2f} "
          f"(R:R {LV[tp] / LV[sl]:.0f}:1)  train {e:+.4f}")
    print(f"    scored on {sn} (never seen): {scored:+.4f}  95% CI [{lo:+.4f},{hi:+.4f}]"
          f"   {'holds' if lo > 0 else 'DOES NOT HOLD'}")
