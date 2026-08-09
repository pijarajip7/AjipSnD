# AjipSnD — Supply & Demand Zone Trading EA

> Multi-timeframe Supply & Demand strategy for MT5 EA. HTF identifies
> retest zones (Supply/Demand), LTF confirms entry when a zone forms
> inside an active HTF zone. Fixed lot, no SL/TP at entry — exit via
> one-time partial close (then SL to breakeven) + batch target/max loss
> (close batch only) + daily target/max loss (close all, block entries
> for rest of day) + final target/max loss (stop permanently) +
> profit-lock outside session + aggregate SL safety net.

---

## Dokumentasi

| Dokumen | Isi |
|---------|-----|
| [docs/concept.md](docs/concept.md) | Konsep inti, SnD zone detection, entry rules, zone management |
| [docs/architecture.md](docs/architecture.md) | Input parameters, Init/OnTick flow, position management |

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

## Known Limitations & TODO

### Belum diimplementasi
- [ ] Compile & backtest in MetaEditor
- [ ] Forward test live

### Potential improvements
- [ ] Minimum zone size filter (minimum pip distance between high/low)
- [ ] Alert/notification saat zone confirmed
- [ ] Allow user to choose between bar-close and per-tick entry

---

## Files

| File | Deskripsi |
|------|-----------|
| `AjipSnD.mq5` | EA MQL5 main file — inputs, OnInit, OnTick, OnDeinit |
| `AjipSnD_Globals.mqh` | Global state, structs, enums, helper functions |
| `AjipSnD_Zone.mqh` | SnD zone detection algorithm + zone management (activate/deactivate) |
| `AjipSnD_Entry.mqh` | Entry gate + entry logic (LTF zone + HTF zone filter) |
| `AjipSnD_Trade.mqh` | OpenTrade (fixed lot), partial close, close-all (batch/daily/final/session), aggregate SL, batch CSV, PnL helpers |
| `AjipSnD_News.mqh` | News blackout filter (high-impact calendar events) |
| `AjipSnD_Core.mqh` | InitStructure (LTF + HTF), UpdateLTF, UpdateHTF, DrawPanel |
| `docs/concept.md` | Konsep & strategi |
| `docs/architecture.md` | EA architecture |
