# AjipSnD — Supply & Demand Zone Trading EA

> Multi-timeframe Supply & Demand strategy for MT5 EA. HTF identifies
> retest zones (Supply/Demand), LTF triggers pending orders (BUY/SELL LIMIT)
> at zone boundaries. Fixed lot, no SL/TP at entry — exit via partial close
> (then SL to BE + trailing stop) + zone invalidation handler + batch/daily/
> final close-all + aggregate SL safety net.

---

## Dokumentasi

| Dokumen | Isi |
|---------|-----|
| [docs/concept.md](docs/concept.md) | Konsep inti, SnD zone detection, entry rules, zone invalidation, exit plan |
| [docs/architecture.md](docs/architecture.md) | Input parameters, Init/OnTick flow, position management, CSV, panel |

---

## Fitur Utama

| Fitur | Deskripsi |
|-------|-----------|
| SnD Detection | Raw candle bear/bull + body-break confirm, lowest-low / highest-high candidate |
| Zone Invalidation | HTF zones dihapus saat price break boundary (sweep-aware) |
| Pending Orders | BUY LIMIT at demand.high, SELL LIMIT at supply.low |
| Invalid Position Handler | TP→BE jika entry zone invalidated atau floating loss > InpPosMaxLoss |
| Trailing Stop | Fixed-step untuk posisi partial-closed, SL hanya maju |
| Aggregate SL | Weighted average entry, satu level SL untuk semua posisi se-arah |
| Partial Close | Once per position → SL ke BE, trailing stop aktif |
| Batch/Daily/Final | Close-all dengan target/max loss, daily + final block entry |
| Session + News | Session filter, news blackout (profit exits gated, max loss never) |
| Panel | 22-line dashboard, HTF zone rectangles |

---

## Panel Info

22-line on-chart dashboard (Consolas 9, OBJ_RECTANGLE_LABEL background):

| Section | Lines |
|---------|-------|
| Structure | Title, LTF/HTF trend + timeframe, Demands/Supplies/Entries count |
| PnL | Today/Week/Month PnL (realized + floating), colored green/red |
| Limits | Final/Daily/Batch limit status (TARGET/MAX LOSS/active/disabled) |
| Gates | Batch cooldown, Session status, News blackout status |
| MFE/MAE | Open MFE/MAE summed across all tracked positions |

---

## Files

| File | Deskripsi |
|------|-----------|
| `AjipSnD.mq5` | EA MQL5 main file — inputs, OnInit, OnTick, OnDeinit |
| `AjipSnD_Globals.mqh` | Structs (SnDZone, EntryTracker, PendingOrder), globals, helpers |
| `AjipSnD_Zone.mqh` | SnD detection + zone management + invalidation + drawing |
| `AjipSnD_Entry.mqh` | Entry gate (EntryGateBlocked, ZoneGapBlocked), RebuildTrackedPositions |
| `AjipSnD_Trade.mqh` | Pending orders, trailing stop, invalid pos handler, partial close, close-all, aggregate SL, batch CSV, heartbeat, handoff |
| `AjipSnD_News.mqh` | News blackout filter |
| `AjipSnD_Core.mqh` | InitStructure, UpdateLTF/HTF, DrawPanel |
| `docs/concept.md` | Konsep & strategi |
| `docs/architecture.md` | EA architecture & parameters |
