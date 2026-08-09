# AjipSnD — Konsep & Strategi

AjipSnD adalah strategi Supply & Demand (SnD) zone-based untuk MT5,
berbeda dari AjipSMC dan AjipIDM.

| Aspek | AjipIDM | AjipSnD |
|-------|---------|---------|
| Structure | SL/SH swings | Tidak ada — murni candle-based |
| Detection | 2-stage pullback + simple structure | Raw candle (bear/bull) + body-break confirm |
| Zones | idm zone (single level) | Supply/Demand zone (high-low range) |
| HTF role | Equilibrium filter (discount/premium) | Retest zones |
| Entry trigger | idm touch + no body break | LTF zone confirmed + price inside HTF zone |
| Lot | Fixed lot | Fixed lot |
| SL/TP | Tidak ada di entry | Tidak ada di entry |

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

  if candidate exists AND bar.close > candidate.high:
      → DEMAND ZONE CONFIRMED
      zone = [candidate.high, candidate.low]
      trend flips → UPTREND
```

### Supply Zone (uptrend → mencari reversal bearish) — Mirror

```
  Cari bull candle dengan HIGH TERTINGGI:
    if bar is BULL (close > open) AND (no candidate OR bar.high > candidate.high):
        candidate = {high: bar.high, low: bar.low}

  if candidate exists AND bar.high > candidate.high:
      candidate.high = bar.high    // low tetap

  if candidate exists AND bar.close < candidate.low:
      → SUPPLY ZONE CONFIRMED
      zone = [candidate.high, candidate.low]
      trend flips → DOWNTREND
```

---

## Zone Management

```
InpMaxZones (default 2) — max zona aktif per tipe

Demand zone baru:  if zone.low < any_existing_demand.low → old deactivated
Supply zone baru:  if zone.high > any_existing_supply.high → old deactivated

Max exceeded → oldest (index 0) deactivated
```

---

## Entry Rules

```
Entry = LTF zone confirmed + price inside active HTF zone at bar close

BUY:
  - LTF demand zone confirmed
  - bar.close inside ANY active HTF demand zone
  → BUY @ bar.close, lot = InpFixedLot, SL=0, TP=0

SELL:
  - LTF supply zone confirmed
  - bar.close inside ANY active HTF supply zone
  → SELL @ bar.close, lot = InpFixedLot, SL=0, TP=0
```

**One-shot per zone:** Setiap zona LTF hanya bisa memicu SATU entry.
Setelah entry, zona tersebut tidak bisa memicu entry lagi.

---

## Multi-Timeframe Architecture

```
HTF (InpHtfTimeframe, e.g., M15):
  └─ Detect Supply & Demand zones from bar data
  └─ Active zones = retest areas for LTF entries
  └─ After zone confirmed → trend flips → detect next zone
  └─ Zone management: max InpMaxZones, lower demand / higher supply invalidates older

LTF (InpTimeframe, e.g., M1):
  └─ Detect Supply & Demand zones independently
  └─ When LTF zone confirmed + close inside HTF active zone → ENTRY
  └─ Multi-position allowed: one entry per LTF zone confirmation
```

---

## Exit Plan

Sama dengan AjipIDM — tidak ada TP/SL di entry. Exit via:

| Mekanisme | Trigger | Efek |
|-----------|---------|------|
| Partial close | POSITION_PROFIT >= InpPartialCloseProfit | Tutup InpPartialClosePercent%, SL sisa → BE |
| Batch target/loss | g_batchRealizedPnl + floating | Tutup batch INI saja, entry baru tetap boleh |
| Daily target/loss | GetDailyPnL() + floating | Tutup semua, blokir entry baru SISA HARI |
| Final target/loss | Balance - baseline + floating | Tutup semua, stop PERMANEN |
| Session close | Di luar jam + PnL > 0 | Tutup semua, profit-lock |
| Aggregate SL | Budget dari max loss terkecil | SL broker-side per posisi tanpa SL |

Daily/weekly/month boundary mengikuti `InpTimezoneOffset` (default UTC).
Session times (`InpSessionStart`/`InpSessionEnd`) juga mengikuti timezone offset.

---

## Fixed Lot, No SL/TP

- `OpenTrade` selalu buka posisi dengan lot = `InpFixedLot`, SL=0, TP=0
- Tidak ada TP order sama sekali
- SL nol di entry, tapi bisa muncul dari: breakeven after partial close, atau aggregate SL

---

## Init

```
1. Fetch InpCandlesInit bars (CopyRates)
2. Find highest high dan lowest low
3. Initial trend: highIdx < lowIdx → DOWNTREND, else → UPTREND
4. Replay bars forward → build initial zones
5. No entry on historical bars
```

---

## Full Cycle Example

```
HTF (M15) — downtrend, mencari demand zone:
  Bar 1: bear → candidate {H=2000, L=1990}
  Bar 2: bear → replace candidate {H=1998, L=1985}
  Bar 3: low=1980 < 1985 → candidate.low=1980, high tetap 1998
  Bar 4: close=2005 > 1998 → HTF DEMAND ZONE CONFIRMED [2005, 1980]
  → Trend HTF flips ke UPTREND → sekarang cari supply zone

LTF (M1) — uptrend, mencari supply zone (untuk entry SELL):
  Beberapa bar kemudian...
  Bar N: bull → candidate {H=1995, L=1988}
  Bar N+1: close=1986 < 1988 → LTF SUPPLY ZONE CONFIRMED [1995, 1986]
  → close=1986 inside HTF demand zone [2005, 1980]? YES!
  → SELL @ 1986, lot=InpFixedLot

Exit: posisi jalan sampai partial close ($10 profit → SL ke BE),
      atau batch/daily/final target loss tercapai.
```
