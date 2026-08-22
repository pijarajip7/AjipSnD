# AjipSnD — Supply & Demand Zone Trading EA

> Single-timeframe Supply & Demand strategy for MT5. Every zone that confirms
> clean (no candidate-phase sweep) and validates is saved and watched, both
> directions, no bias gate; entry fires on the FIRST wick back into a saved
> zone — no rejection pattern required, checked every tick — as a market
> order with structural SL/TP (stop anchored to the zone's own structural
> edge; RR-derived target). Risk-based lot sizing. Exit via broker SL/TP or
> weekly/final close-all.

---

## Dokumentasi

| Dokumen | Isi |
|---------|-----|
| [docs/concept.md](docs/concept.md) | Konsep inti, SnD zone detection, entry mechanism, zone invalidation, exit plan |
| [docs/architecture.md](docs/architecture.md) | Input parameters, Init/OnTick flow, structural SL/TP, CSV, panel |

---

## Fitur Utama

| Fitur | Deskripsi |
|-------|-----------|
| SnD Detection | Raw candle bear/bull + body-break confirm, lowest-low / highest-high candidate |
| Immediate watch | Every zone that confirms clean and validates is saved and watched immediately, both directions — no bias gate, no wait for a second timeframe |
| Pre-touch filter | A zone already wicked into during its own confirm-to-validate window is saved already `used=true` — no watch, and not drawn on chart at all (it was never a watch candidate). Backtested: 56-58% hit rate at 5m/15m vs 75%+ for a clean (never-touched) validation |
| No-sweep filter | A zone whose CANDIDATE phase had a failed break attempt before it ever confirmed (`sweepHigh`/`sweepLow` > 0 — a wick past `candidate.high`/`.low` that didn't close through) gets the identical treatment: saved already `used=true`, never watched, never drawn. Same mechanism as the pre-touch filter, just a second disqualifying condition on the same gate. Requested directly, not measured first |
| favW filter | Entry gate (`InpMinFavW` / `InpMaxFavW`, default 3 / 10, 0=disabled per side): skip a zone whose first touch lands with its favorable pre-touch excursion — `favW`, in zone widths, the chart's runway label / CSV `fav_before_touch_width_ratio` — below min or above max. One-shot, marked `used` with no order. Runs off the zone-quality tracker, which stays active whenever the filter is on, independent of `InpZoneQualityLog` (CSV still requires it) |
| Zone-width filter | Entry gate (`InpMinZoneWidthPoints` / `InpMaxZoneWidthPoints`, 0=disabled per side): skip a zone whose own width (high−low) in POINTS is below min or at/above max. Applied at TOUCH time like favW — the zone stays drawn on chart (label included), marked `used` with no order on a failing touch — unlike the ATR-based width/displacement inputs, which only feed the diagnostic `qualityPass` |
| MA filter | Entry gate (`InpMaFilterEnabled`, default true, symmetric): BUY only when fast SMA > slow SMA (uptrend), SELL only when fast SMA < slow SMA (downtrend). `MaFilterBlocks(dir)` reads the last CLOSED bar's SMA (`InpMaFastPeriod` 20 / `InpMaSlowPeriod` 50), fails open on a missing handle. Hooks into `EntryGateBlocked` so both entry paths (tick + bar-close) are covered; the zone is still consumed on its first touch, the gate only decides whether an order follows |
| Aggressive entry | The EA's only entry mechanism: the FIRST wick into a saved zone triggers a market order immediately, no body/close-back-out requirement, checked on every TICK (not just LTF bar close) so entry doesn't wait for the current bar to finish. SL anchors to the zone's own structural edge (`breakLevel`, sweep-aware). Formerly an opt-in mode alongside a wait-for-rejection alternative; made the only mode directly, not on measured results |
| Zone invalidation | Saved zones leave the watch list on a body CLOSE past the far edge (sweep-aware) — the rectangle itself stays on chart, frozen (see Persistent zone drawing below) |
| Persistent zone drawing | A zone's rectangle is never deleted once drawn. While still watched, its right edge keeps extending to "now"; once resolved (traded, structurally broken, or superseded by a fresher same-direction zone) it freezes at the bar that resolved it, is redrawn once in that final form, then skipped on every later call — redraw cost tracks the live watch list, not the ever-growing total of every zone ever confirmed |
| On-chart runway label | A small white-text label inside each watched zone (never the zone's own blue/orange — the rectangle is a solid fill, so same-color text would be invisible), right-aligned against its (moving or frozen) right edge and vertically centered, tracks how many zone-widths price has run before coming back to touch it. Before touch: `favW~<ratio> · <width>pts`, a live preview recomputed every redraw from the tracker's running max-favorable-excursion. At/after touch: `favW <ratio> · <width>pts` (no `~`), frozen to the same value that lands in the CSV's `fav_before_touch_width_ratio` — identical number at the exact touch bar, so the display never jumps, only stops moving. Requires `InpZoneQualityLog` on. Zones seeded by OnInit replay get this too — the tracker entry is created and fed from replayed historical bars, so a zone already touched before the EA even started shows its real historical ratio immediately, not a cold `favW~0.00`; only the CSV write itself stays live-only, to avoid re-dumping the same historical zone's rows on every restart |
| Structural SL/TP | SL anchored to the zone's own structural edge (`breakLevel`, sweep-aware) + a buffer of `InpZoneSlBufferWidthMult` zone-widths (default 2.0, so total SL distance from a near-edge touch is roughly 3x the zone's own width); TP a multiple of the actual SL distance |
| Invalidation TP→BE (`InpInvalidationTpBeEnabled`) | On by default. Two additive triggers, either firing first locks the one-shot `tpMovedToBe`: (1) tick-level — price pushes past the position's own originating zone `breakLevel` by `InpInvalidationBufferZoneWidths` zone-widths (must stay below `InpZoneSlBufferWidthMult` so it fires before the SL); (2) bar-close — a closed LTF bar's close passes the originating zone's own sweep-aware `breakLevel` (looked up via `zoneTime`; the zone's real edge, not the derived approximation). TP moves to breakeven; SL is handled by `InpInvalidationRemoveSl` (default true): when true the SL is REMOVED (sl=0) and the account-level max-loss close-all takes over downside handling; when false the SL is left untouched so risk/reward turns asymmetric from that point (SL still far, TP now close). The tick path derives `breakLevel` on the fly from the position's own SL + entry price + `InpZoneSlBufferWidthMult` (not stored), so it works identically for a restart-recovered position — no special case, no gap (the bar-close path falls back to the same algebra when `zoneTime` is 0) |
| Risk-based sizing | Lot derived from `InpRiskPerTrade` and the real stop distance, capped by `InpMaxRiskOvershoot` |
| Recovery mode | Multi-position averaging-down. `InpMaxPositionsPerDir` removed; `TryEntry` decides: empty direction → normal entry; occupied + not-invalidated → skip; occupied + `tpMovedToBe` + price beyond all entries (below every BUY / above every SELL) → recovery add with the SAME lot, no SL/TP, then all positions converge to one TP = weighted-average entry ∓ `InpBreakEvenOffsetPoints`. Unlimited adds; downside left to max-loss close-all. `tpMovedToBe` reconstructed on restart (no SL or TP at BE) |
| Init replay | OnInit replays LTF bars chronologically, so the EA starts with its real zone structure and watch list instead of an empty one |
| Session + News | Weekly session filter (default Mon 06:00–Fri 12:00) blocks entries outside the window; session-end weekend-flat closes positions in 3 phases (P1 floating profit, P2 week+floating profit, P3 force at 23:00); news blackout blocks entries + profit-taking closes (max-loss never gated) |
| Panel | 19-line dashboard, saved-LTF-zone rectangles on chart |

---

## Panel Info

19-line on-chart dashboard (Consolas 9, OBJ_RECTANGLE_LABEL background):

| Section | Lines |
|---------|-------|
| Structure | Title, trend + timeframe, Demands/Supplies/Entries count |
| PnL | Today/Week/Month PnL (realized + floating), colored green/red |
| Limits | Final/Weekly limit status (TARGET/MAX LOSS/active/disabled) |
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
