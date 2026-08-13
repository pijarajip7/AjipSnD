# AjipSnD — Konsep & Strategi

AjipSnD adalah strategi Supply & Demand (SnD) zone-based untuk MT5,
berbeda dari AjipSMC dan AjipIDM.

| Aspek | AjipIDM | AjipSnD |
|-------|---------|---------|
| Structure | SL/SH swings | Tidak ada — murni candle-based |
| Detection | 2-stage pullback + simple structure | Raw candle (bear/bull) + body-break confirm |
| Zones | idm zone (single level) | Supply/Demand zone (high-low range) |
| HTF role | Equilibrium filter (discount/premium) | Retest zones |
| Entry trigger | idm touch + no body break | BUY LIMIT at LTF demand.high / SELL LIMIT at LTF supply.low |
| Lot | Fixed lot | Fixed lot |
| SL/TP | Tidak ada di entry | Tidak ada di entry |
| Zone invalidation | Tidak ada | HTF zones dihapus saat price break |
| Pending orders | Tidak ada | BUY/SELL LIMIT |
| Invalid positions | Tidak ada | TP→BE jika zone entry invalidated atau loss > InpPosMaxLoss |
| Trailing stop | Tidak ada | Untuk posisi partial-closed |

---

## SnD Zone Detection

### Demand Zone (downtrend → mencari reversal bullish)

```
Scan bar-by-bar:

  Cari bear candle dengan LOW TERENDAH:
    if bar is BEAR (close < open) AND (no candidate OR bar.low < candidate.low):
        candidate = {high: bar.high, low: bar.low}

  if candidate exists AND bar.low < candidate.low:
      candidate.low = bar.low    // high tetap

  // Track both sweep directions
  Sweep above: if bar.high > candidate.high AND bar.close <= candidate.high:
      candidate.sweepHigh = max(sweepHigh, bar.high)
  Sweep below: if bar.low < candidate.low AND bar.close >= candidate.low:
      candidate.sweepLow = min(sweepLow, bar.low)

  if candidate exists AND bar.close > (sweepHigh if swept else candidate.high):
      → DEMAND ZONE CONFIRMED
      zone = [candidate.high, candidate.low]
      trend flips → UPTREND
      Seeding: if confirming bar is BULL → seed as first supply candidate
```

### Supply Zone (uptrend → mencari reversal bearish) — Mirror

```
  Cari bull candle dengan HIGH TERTINGGI:
    if bar is BULL (close > open) AND (no candidate OR bar.high > candidate.high):
        candidate = {high: bar.high, low: bar.low}

  if candidate exists AND bar.high > candidate.high:
      candidate.high = bar.high

  // Track both sweep directions
  Sweep below: if bar.low < candidate.low AND bar.close >= candidate.low:
      candidate.sweepLow = min(sweepLow, bar.low)
  Sweep above: if bar.high > candidate.high AND bar.close <= candidate.high:
      candidate.sweepHigh = max(sweepHigh, bar.high)

  if candidate exists AND bar.close < (sweepLow if swept else candidate.low):
      → SUPPLY ZONE CONFIRMED
      zone = [candidate.high, candidate.low]
      trend flips → DOWNTREND
      Seeding: if confirming bar is BEAR → seed as first demand candidate
```

---

## Zone Management

```
InpMaxZones (default 2) — max zona aktif per tipe

Demand zone baru:  if zone.low < any_existing_demand.low → old deactivated + cancel pending
Supply zone baru:  if zone.high > any_existing_supply.high → old deactivated + cancel pending

Max exceeded → oldest (index 0) deactivated
```

---

## HTF Zone Invalidation

HTF zones yang di-break price action dihapus dari array + chart.
Per HTF bar close, BEFORE ProcessZoneBar (existing zones checked first).

Sweep hanya memperlebar batas zone, **tidak** mengubah trigger invalidasi:
- Demand: bar.close < zone.low → INVALID. Jika swept → bar.close < zone.sweepLow → INVALID
- Supply: bar.close > zone.high → INVALID. Jika swept → bar.close > zone.sweepHigh → INVALID

Sweep tracking: ProcessZoneBar track **kedua arah** sweep untuk **kedua jenis** zone.
Demand invalidation pakai sweepLow (support side), supply pakai sweepHigh (resistance side).

InvalidateHtfZones juga dipanggil di InitHTFStructure replay loop — zone yang
break di tengah replay langsung dihapus.

---

## Zone Validation (Follow-through)

Setelah zona dikonfirmasi oleh bar X, zona harus tervalidasi oleh follow-through
sebelum boleh dipakai. Konfirmasi + follow-through:

- Demand: bar X close > candidate.high/sweepHigh → butuh bar berikutnya close > barX.high
- Supply: bar X close < candidate.low/sweepLow → butuh bar berikutnya close < barX.low

Aturan:
- LTF: validasi SELALU aktif — entry ditunda sampai follow-through muncul.
- HTF: gated oleh `InpRequireZoneValidation` (default true).
- Validasi harus selesai SEBELUM zona opposite terbentuk; kalau opposite duluan → zona gagal (discard, no entry).
- HTF zona belum tervalidasi digambar beda warna (pending), belum jadi retest area aktif.

---

## Entry Rules

Entry pakai **pending order** (BUY LIMIT / SELL LIMIT), bukan market order.

```
BUY LIMIT:
  - LTF demand zone confirmed + VALIDATED (follow-through close > barX.high)
  - BUY LIMIT at confirmed.high inside ANY active HTF demand zone
  - EntryGateBlocked + ZoneGapBlocked pass → PlacePendingOrder(BUY, demand.high)
  - One-shot per LTF zone (g_ltfZonePendingTime)

SELL LIMIT:
  - LTF supply zone confirmed + VALIDATED (follow-through close < barX.low)
  - SELL LIMIT at confirmed.low inside ANY active HTF supply zone
  - EntryGateBlocked + ZoneGapBlocked pass → PlacePendingOrder(SELL, supply.low)
```

**Pending order lifecycle:**
- Placed → per-tick CheckPendingOrders: hapus jika price keluar HTF zone
- Filled → detect via OrderSelect fail + new position → AddEntry to g_entries[]
- Cancelled → zone replaced (AddDemandZone/AddSupplyZone call CancelPendingForZone)
- Cancelled → close-all daily/final/session: CancelAllPendingOrders; batch close-all TIDAK cancel pending

---

## Multi-Timeframe Architecture

```
HTF (InpHtfTimeframe, e.g., M15):
  └─ Detect Supply & Demand zones from bar data
  └─ Active zones = retest areas for pending placement + validation
  └─ Zone confirmed → (optional) follow-through validation → active (gated by InpRequireZoneValidation)
  └─ After zone confirmed → trend flips → detect next zone
  └─ Zone management: max InpMaxZones, lower demand / higher supply invalidates older
  └─ Zone invalidation: close breaks zone boundary → remove from array + chart
  └─ DrawAllHtfZones on every HTF bar close

LTF (InpTimeframe, e.g., M1):
  └─ Detect Supply & Demand zones independently
  └─ When LTF zone confirmed + VALIDATED + limit price inside HTF zone → PLACE PENDING
  └─ Per LTF bar close: CheckInvalidPositions, CheckEntryCleanup
```

---

## Exit Plan

| Mekanisme | Trigger | Gate |
|-----------|---------|------|
| Trailing stop | profit ≥ InpTrailStartPoints (points from entry) | Hanya partialClosed positions, per-tick |
| Pending cancel | Price outside HTF zone | Per-tick |
| Invalid pos → TP BE | Entry zone invalidated OR loss > InpPosMaxLoss | Per LTF bar, one-shot, grace 1 bar |
| Partial close | POSITION_PROFIT ≥ InpPartialCloseProfit | Gated by news |
| Batch target/loss | g_batchRealizedPnl + floating | Close batch, target gated |
| Daily target/loss | GetDailyPnL() + floating | Close all + block rest of day |
| Final target/loss | Balance - baseline + floating | Close all + stop permanent |
| Session close | Di luar jam + PnL > 0 | Gated by news |
| Aggregate SL | Budget / totalVol / valuePerPoint → same SL price | Every tick |

---

## Trailing Stop

Fixed-step, hanya untuk posisi yang sudah partial-closed ke BE:
- `InpTrailStartPoints` — minimum profit dari entry sebelum trail aktif
- `InpTrailDistancePoints` — jarak SL di belakang current price
- SL hanya maju (BUY naik, SELL turun), tidak pernah mundur
- Per-tick via `CheckTrailingStop()`

---

## Invalid Position Handler

Posisi yang entry premise-nya sudah tidak valid:
1. Entry zone invalidated → `entryPrice` tidak ada di zona aktif manapun
2. Floating loss > `InpPosMaxLoss`

Action: TP diset ke entry price (BE). Tidak close — kasih kesempatan exit BE.
One-shot: skip jika TP sudah di entry. Grace period: skip posisi di bar yang sama.
Per LTF bar close (bukan per-tick), setelah UpdateLTF.

---

## Fixed Lot, No SL/TP

- Entry via pending LIMIT dengan lot = `InpFixedLot`, SL=0, TP=0
- Tidak ada TP order sama sekali
- SL bisa muncul dari: breakeven after partial close, trailing stop, atau aggregate SL

---

## Init

```
1. Fetch InpCandlesInit bars (CopyRates)
2. Find highest high dan lowest low
3. Initial trend: highIdx < lowIdx → DOWNTREND, else → UPTREND
4. Replay bars forward → build initial zones
5. InvalidateHtfZones called on every bar during replay
6. No entry/pending on historical bars
7. RebuildTrackedPositions: detect partialClosed via volume < InpFixedLot
```
