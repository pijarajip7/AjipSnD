# AjipSnD — Supply & Demand Zone Trading EA

> Single-timeframe Supply & Demand strategy for MT5. Every zone that confirms
> and validates is saved and watched, both directions, no bias gate; entry
> fires once that zone's own retest is REJECTED (wick back in, closed back
> out, real-bodied bar) — or, in aggressive mode, on the first wick in, no
> rejection required — as a market order with structural SL/TP
> (trigger-bar-anchored stop, RR-derived target). Risk-based lot sizing.
> Exit via broker SL/TP or daily/final close-all.

---

## Dokumentasi

| Dokumen | Isi |
|---------|-----|
| [docs/concept.md](docs/concept.md) | Konsep inti, SnD zone detection, rejection-entry mechanism, zone invalidation, exit plan |
| [docs/architecture.md](docs/architecture.md) | Input parameters, Init/OnTick flow, structural SL/TP, CSV, panel |

---

## Fitur Utama

| Fitur | Deskripsi |
|-------|-----------|
| SnD Detection | Raw candle bear/bull + body-break confirm, lowest-low / highest-high candidate |
| Rejection watch | Every zone that confirms and validates is saved and watched immediately, both directions — no bias gate, no wait for a second timeframe |
| Pre-touch filter | A zone already wicked into during its own confirm-to-validate window is saved already `used=true` — no rejection watch, and not drawn on chart at all (it was never a watch candidate). Backtested: 56-58% hit rate at 5m/15m vs 75%+ for a clean (never-touched) validation |
| Rejection entry | Wick back into a saved zone, closed back out, body/ATR above threshold → market order |
| Aggressive entry (`InpAggressiveEntry`) | Off by default. When on, skips the whole rejection pattern — the FIRST wick into a saved zone triggers the market order immediately, no body/close-back-out requirement. Unvalidated, not measured against the default |
| Zone invalidation | Saved zones leave the watch list on a body CLOSE past the far edge (sweep-aware) — the rectangle itself stays on chart, frozen (see Persistent zone drawing below) |
| Persistent zone drawing | A zone's rectangle is never deleted once drawn. While still watched, its right edge keeps extending to "now"; once resolved (rejected+traded, structurally broken, or superseded by a fresher same-direction zone) it freezes at the bar that resolved it, is redrawn once in that final form, then skipped on every later call — redraw cost tracks the live watch list, not the ever-growing total of every zone ever confirmed |
| Structural SL/TP | SL anchored to the entry-trigger bar's own extreme + ATR buffer (rejection bar, or first-touch bar if aggressive); TP a multiple of the actual SL distance |
| Risk-based sizing | Lot derived from `InpRiskPerTrade` and the real stop distance, capped by `InpMaxRiskOvershoot` |
| Init replay | OnInit replays LTF bars chronologically, so the EA starts with its real zone structure and watch list instead of an empty one |
| Session + News | Session filter blocks entries outside hours; news blackout blocks entries + profit-taking closes (max-loss never gated) |
| Panel | 19-line dashboard, saved-LTF-zone rectangles on chart |

---

## Panel Info

19-line on-chart dashboard (Consolas 9, OBJ_RECTANGLE_LABEL background):

| Section | Lines |
|---------|-------|
| Structure | Title, trend + timeframe, Demands/Supplies/Entries count |
| PnL | Today/Week/Month PnL (realized + floating), colored green/red |
| Limits | Final/Daily limit status (TARGET/MAX LOSS/active/disabled) |
| Session/News | Session status, news blackout status |
| MFE/MAE | Open MFE/MAE summed across all tracked positions |

---

## Files

| File | Deskripsi |
|------|-----------|
| `AjipSnD.mq5` | EA MQL5 main file — inputs, OnInit, OnTick, OnDeinit |
| `AjipSnD_Globals.mqh` | Structs (SnDZone, EntryTracker, EntryFillInfo, SavedLtfZone), globals, helpers |
| `AjipSnD_Zone.mqh` | SnD detection, zone lifecycle + invalidation, drawing, zone-quality CSV |
| `AjipSnD_Entry.mqh` | Entry gate (`EntryGateBlocked`), restart recovery (`RebuildTrackedPositions`) |
| `AjipSnD_Trade.mqh` | Market-order entry (`OpenMarketWithStructuralStops`), risk sizing, close-all, per-trade CSV, heartbeat/handoff |
| `AjipSnD_News.mqh` | News blackout filter |
| `AjipSnD_Excursion.mqh` | First-touch grid diagnostic (currently dormant — see docs/architecture.md) |
| `AjipSnD_Drift.mqh` | Forward-drift probe diagnostic — does zone confirmation predict anything? |
| `AjipSnD_Core.mqh` | `ReplayInitialStructure`, `UpdateLTF`, `SaveLtfZoneForWatch`, `CheckRejectionRetests`, `DrawPanel` |
| `docs/concept.md` | Konsep & strategi |
| `docs/architecture.md` | EA architecture & parameters |
