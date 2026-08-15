# Mirrors the real MQL5 logic:
#  - priming: tick-level, price must touch (enter) the zone -> zoneEdge
#  - STOP trigger: tick-level, price crosses limitPrice (=zoneEdge+offset) at any point
#  - REJECT trigger: bar-CLOSE only, and only once primed; bar.close must clear limitPrice
#
# MODEL LIMIT — read before adding a case. A bar here is only (o,h,l,c), so the
# ORDER of the high and the low inside a bar is not represented. The real EA does
# not have this limitation: UpdateExcursions() primes on a tick and then
# `continue`s, so a record's trigger is never evaluated before the tick after it
# primed. This model instead treats "primed somewhere in the bar" and "crossed
# somewhere in the bar" as simultaneous, which makes any fixture whose expected
# STOP result depends on the high landing before the low untestable — it will
# report a STOP the EA would not have taken.
#
# So: keep the priming bar's extreme on the trigger side BELOW limitPrice (above,
# for supply). Cases B and E originally violated this — their priming bar ran to
# 101.2 against a 100.5 threshold, intending that spike to precede the dip into
# the zone — and failed for that reason alone, not because of any EA defect.
#
# dir=1 (demand/BUY): zoneEdge is the proximal (upper) edge, price enters by
# dropping to/below it; limitPrice = zoneEdge + offset sits ABOVE zoneEdge.
class Rec:
    def __init__(s, dir_, zoneEdge, offset):
        s.dir=dir_; s.zoneEdge=zoneEdge; s.offset=offset
        s.limitPrice = zoneEdge + offset*dir_   # STOP/REJECT: proof beyond the edge, in the trade direction
        s.primed=False; s.stop_triggered=False; s.reject_triggered=False
        s.stop_bar=None; s.reject_bar=None; s.reject_fill=None

def run(rec, bars):
    """bars: list of (open, high, low, close) tuples, bar index = chronological order."""
    for bi, (o,h,l,c) in enumerate(bars):
        # --- tick-level pass within the bar: for dir=1, price path touches down to `l` and up to `h` ---
        # priming: did price reach zoneEdge (or beyond) at any point in this bar?
        if not rec.primed:
            entered = (l <= rec.zoneEdge) if rec.dir==1 else (h >= rec.zoneEdge)
            if entered:
                rec.primed = True
        # STOP: once primed (possibly just now, same bar), did price EVER reach limitPrice intrabar?
        if rec.primed and not rec.stop_triggered:
            hit = (h >= rec.limitPrice) if rec.dir==1 else (l <= rec.limitPrice)
            if hit:
                rec.stop_triggered = True
                rec.stop_bar = bi
        # --- bar-close pass: REJECT only checked here, only if primed BEFORE or during this bar ---
        if rec.primed and not rec.reject_triggered:
            confirmed = (c >= rec.limitPrice) if rec.dir==1 else (c <= rec.limitPrice)
            if confirmed:
                rec.reject_triggered = True
                rec.reject_bar = bi
                rec.reject_fill = c
    return rec

def report(name, dir_, zoneEdge, offset, bars, expect_stop, expect_reject):
    r = Rec(dir_, zoneEdge, offset)
    run(r, bars)
    ok_s = (r.stop_triggered == (expect_stop is not None)) and (expect_stop is None or r.stop_bar==expect_stop)
    ok_r = (r.reject_triggered == (expect_reject is not None)) and (expect_reject is None or r.reject_bar==expect_reject)
    print(f"{name}")
    print(f"  STOP   triggered={r.stop_triggered} bar={r.stop_bar}   expect bar={expect_stop}   {'OK' if ok_s else 'FAIL'}")
    print(f"  REJECT triggered={r.reject_triggered} bar={r.reject_bar} fill={r.reject_fill}  expect bar={expect_reject}   {'OK' if ok_r else 'FAIL'}")
    return ok_s and ok_r

allok = True
# Demand zone: proximal edge (top of zone) = 100.0. offset = 0.5. limitPrice = 100.5.
# A. Clean rejection: bar 0 wicks down into zone (low<=100) AND closes back above 100.5, same bar.
allok &= report("A. clean rejection, primes+confirms same bar",
    1, 100.0, 0.5,
    [(101.0,101.2,99.5,100.8)],   # o,h,l,c : low touches zone, close clears 100.5
    expect_stop=0, expect_reject=0)

# B. Fakeout: bar 0 wicks into zone but closes back INSIDE the zone (below 100.5, e.g. at 99.9).
#    Then bar 1 is flat/irrelevant. REJECT must never fire since no later close clears it.
# Priming bar's high stays under 100.5 so the STOP result is path-independent.
allok &= report("B. wick in, closes back inside zone -> no reject ever",
    1, 100.0, 0.5,
    [(100.4,100.4,99.5,99.9), (99.9,100.1,99.8,100.0)],
    expect_stop=None, expect_reject=None)

# C. THE decisive case: bar 0 primes (low touches zone) AND its HIGH momentarily reaches
#    100.5+ (would fire STOP mid-bar) but the bar CLOSES back at 100.2 (below threshold).
#    STOP must fire on bar 0; REJECT must NOT fire on bar 0.
allok &= report("C. intrabar spike past threshold, closes back below -> STOP yes, REJECT no (that bar)",
    1, 100.0, 0.5,
    [(101.0,100.7,99.5,100.2)],
    expect_stop=0, expect_reject=None)

# D. Never revisits the zone at all.
allok &= report("D. never enters zone -> neither primes nor triggers",
    1, 100.0, 0.5,
    [(103,104,102,103.5),(103.5,104,103,103.8)],
    expect_stop=None, expect_reject=None)

# E. Primes on bar 0 (close doesn't clear); bar 1's close clears it -> REJECT fires on bar 1, not bar 0.
# Same fix as B: bar 0 primes without its high reaching the 100.5 threshold, so
# both triggers must land on bar 1 regardless of intrabar path.
allok &= report("E. primes bar0 (no confirm), confirms bar1 -> reject on bar1",
    1, 100.0, 0.5,
    [(100.4,100.4,99.5,99.8), (99.8,100.9,99.7,100.6)],
    expect_stop=1, expect_reject=1)

# F. SUPPLY mirror of case C: zoneEdge=100 (bottom of supply zone), offset=0.5, limitPrice=99.5.
#    Price enters by rising to >=100; intrabar dips to 99.4 (would fire STOP) but closes at 99.8.
allok &= report("F. SUPPLY mirror: intrabar spike past threshold, closes back above -> STOP yes, REJECT no",
    -1, 100.0, 0.5,
    [(99.0,100.5,99.4,99.8)],
    expect_stop=0, expect_reject=None)

# G. SUPPLY clean rejection: enters (high>=100), closes at 99.3 (<=99.5) same bar.
allok &= report("G. SUPPLY clean rejection, same bar",
    -1, 100.0, 0.5,
    [(101.0,100.3,99.0,99.3)],
    expect_stop=0, expect_reject=0)

print()
print("ALL CASES:", "PASS" if allok else "FAIL")
