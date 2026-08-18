# AjipSnD — Supply & Demand Zone Trading EA

> Multi-timeframe Supply & Demand strategy for MT5. HTF zone validation sets
> a directional bias — not a price range entries are gated on currently
> sitting inside — but only LTF zones fully contained inside that specific
> HTF zone's own range qualify to trade off it. Each gets an immediate
> resting limit order, fixed lot, at its own midpoint — no rejection wait,
> no pattern match, no SL/TP at placement. A resting order is cancelled
> once its own zone leaves the watch list, not after a fixed time. Exit is
> managed entirely by this EA in points from entry: a loss-side breakeven
> safety net, a profit-side partial-close + breakeven, then an HTF-ATR
> trailing stop — or daily/final close-all.

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
| HTF = bias, not a price-must-sit-inside zone | HTF validation sets a directional bias (demand/supply); entries are never gated on price currently being inside an HTF zone |
| HTF containment filter | Of the LTF zones matching the bias direction since the HTF zone's own origin bar, only those fully contained inside that specific HTF zone's `[low, high]` get saved and get a pending order |
| Pending-order entry | Each qualifying LTF zone gets an immediate resting limit order at its own midpoint — no wait, no pattern match |
| Fixed-lot sizing | Every entry uses `InpFixedLot` — no SL exists at placement to size risk-based sizing against |
| Zone touch tracking | A saved zone's rectangle freezes the moment price wicks into it (order already resting since save time); HTF structure itself still drops on a body CLOSE past the far edge (sweep-aware) |
| Zone-watch cancellation | A resting order is cancelled once its own zone leaves the watch list (touched, or superseded) — no fixed-bar expiry |
| No SL/TP at placement | Orders are placed bare; there is no per-position protective stop until the points-based exit logic below sets one |
| Points-based exit | Loss-side: past `InpLossPointsSetTpBe` points against, a TP is set at breakeven (does not cap the loss). Profit-side: past `InpPartialClosePoints` points in favor, partial-close + SL to breakeven, then an HTF-ATR trailing stop on the remainder |
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
| `AjipSnD_Trade.mqh` | Points-based exit (`CheckLossRecoveryTp`, `CheckPartialClose`, `UpdateTrailingStop`), close-all, per-trade CSV, heartbeat/handoff |
| `AjipSnD_PendingEntry.mqh` | Pending-limit entry (`PlacePendingOrderForZone`), fill detection + zone-watch cancellation (`ManagePendingOrders`, `ZoneStillWatched`) |
| `AjipSnD_News.mqh` | News blackout filter |
| `AjipSnD_Excursion.mqh` | First-touch grid diagnostic (currently dormant — see docs/architecture.md) |
| `AjipSnD_Drift.mqh` | Forward-drift probe diagnostic — does zone confirmation predict anything? |
| `AjipSnD_Core.mqh` | `ReplayInitialStructure`, `UpdateLTF`/`UpdateHTF`, `SaveLtfZonesForHtfBias`, `CheckPendingZoneTouches`, `DrawPanel` |
| `docs/concept.md` | Konsep & strategi |
| `docs/architecture.md` | EA architecture & parameters |
