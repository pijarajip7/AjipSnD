# AjipSnD — Supply & Demand Zone Trading EA

> Multi-timeframe Supply & Demand strategy for MT5. HTF zone validation sets
> a directional bias only — not a price range to sit inside. Every matching
> LTF zone gets an immediate resting limit order at its own midpoint — no
> rejection wait, no pattern match — with structural SL/TP (SL beyond the
> HTF bias zone's own extreme + ATR buffer, RR-derived target). Risk is
> split evenly across currently-active pending orders. Exit via broker
> SL/TP or daily/final close-all.

---

## Dokumentasi

| Dokumen | Isi |
|---------|-----|
| [docs/concept.md](docs/concept.md) | Konsep inti, SnD zone detection, bias + rejection-entry mechanism, zone invalidation, exit plan |
| [docs/architecture.md](docs/architecture.md) | Input parameters, Init/OnTick flow, structural SL/TP, CSV, panel |

---

## Fitur Utama

| Fitur | Deskripsi |
|-------|-----------|
| SnD Detection | Raw candle bear/bull + body-break confirm, lowest-low / highest-high candidate |
| HTF = bias, not a zone | HTF validation sets a directional bias (demand/supply); never geometrically checked as a containment box |
| Pending-order entry | Matching LTF zones since the HTF bias's own origin bar get an immediate resting limit order at their own midpoint — no wait, no pattern match |
| Zone touch tracking | A saved zone's rectangle freezes the moment price wicks into it (order already resting since save time); HTF structure itself still drops on a body CLOSE past the far edge (sweep-aware) |
| Structural SL/TP | SL beyond the HTF bias zone's own extreme + HTF-ATR buffer, shared by every pending order under that bias; TP a multiple of the actual SL distance |
| Risk-based sizing | Lot derived from `InpPendingOrderTotalRisk` split evenly across active pending orders, capped by `InpMaxRiskOvershoot` |
| Pending-order expiry | A resting order not triggered within `InpPendingOrderExpiryHtfBars` HTF bars is cancelled |
| Init replay | OnInit replays HTF+LTF bars together, chronologically, so the EA starts with a real bias and watch list instead of an empty one |
| Session + News | Session filter blocks entries outside hours; news blackout blocks entries + profit-taking closes (max-loss never gated) |
| Panel | 20-line dashboard, saved-LTF-zone rectangles on chart |

---

## Panel Info

20-line on-chart dashboard (Consolas 9, OBJ_RECTANGLE_LABEL background):

| Section | Lines |
|---------|-------|
| Structure | Title, LTF/HTF trend + timeframe, Demands/Supplies/Entries count |
| PnL | Today/Week/Month PnL (realized + floating), colored green/red |
| Limits | Final/Daily limit status (TARGET/MAX LOSS/active/disabled) |
| Session/News | Session status, news blackout status |
| MFE/MAE | Open MFE/MAE summed across all tracked positions |

---

## Files

| File | Deskripsi |
|------|-----------|
| `AjipSnD.mq5` | EA MQL5 main file — inputs, OnInit, OnTick, OnDeinit |
| `AjipSnD_Globals.mqh` | Structs (SnDZone, EntryTracker, EntryFillInfo, PendingOrderTracker, LtfValidatedZone, SavedLtfZone), globals, helpers |
| `AjipSnD_Zone.mqh` | SnD detection, zone lifecycle + invalidation, LTF validation history, drawing, zone-quality CSV |
| `AjipSnD_Entry.mqh` | Entry gate (`EntryGateBlocked`), restart recovery (`RebuildTrackedPositions`) |
| `AjipSnD_Trade.mqh` | Risk sizing (`LotForRisk`), close-all, per-trade CSV, heartbeat/handoff |
| `AjipSnD_PendingEntry.mqh` | Pending-limit entry (`PlacePendingOrderForZone`), fill detection, expiry (`ManagePendingOrders`) |
| `AjipSnD_News.mqh` | News blackout filter |
| `AjipSnD_Excursion.mqh` | First-touch grid diagnostic (currently dormant — see docs/architecture.md) |
| `AjipSnD_Drift.mqh` | Forward-drift probe diagnostic — does zone confirmation predict anything? |
| `AjipSnD_Core.mqh` | `ReplayInitialStructure`, `UpdateLTF`/`UpdateHTF`, `SaveLtfZonesForHtfBias`, `CheckPendingZoneTouches`, `DrawPanel` |
| `docs/concept.md` | Konsep & strategi |
| `docs/architecture.md` | EA architecture & parameters |
