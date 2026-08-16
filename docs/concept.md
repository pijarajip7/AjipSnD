# AjipSnD — Konsep & Strategi

AjipSnD adalah strategi Supply & Demand (SnD) zone-based untuk MT5,
berbeda dari AjipSMC dan AjipIDM.

| Aspek | AjipIDM | AjipSnD |
|-------|---------|---------|
| Structure | SL/SH swings | Tidak ada — murni candle-based |
| Detection | 2-stage pullback + simple structure | Raw candle (bear/bull) + body-break confirm |
| Zones | idm zone (single level) | Supply/Demand zone (high-low range) |
| HTF role | Equilibrium filter (discount/premium) | Directional bias saja — bukan price range untuk entry |
| Entry trigger | idm touch + no body break | LTF zone (searah bias HTF) di-retest, wick masuk lalu REJECTED |
| Order type | — | Market order (bukan pending limit) |
| Lot | Fixed lot | Risk-based — diturunkan dari `InpRiskPerTrade` / jarak SL |
| SL/TP | Tidak ada di entry | Structural — SL di swing LTF zone, TP = RR x jarak SL |
| Zone invalidation | Tidak ada | HTF & saved LTF zone dihapus saat body close break boundary |
| Init | Bar terakhir saja | Replay HTF+LTF kronologis — EA start dengan bias & watch-list nyata |

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

Demand zone baru:  if zone.low < any_existing_demand.low → old deactivated
Supply zone baru:  if zone.high > any_existing_supply.high → old deactivated
HTF only: zone yang sudah touched juga deactivated begitu zona baru searah confirm
  (TOUCHED_SUPERSEDED — pasar sudah bikin struktur baru, zona lama basi)

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

Aturan yang sama persis (body-close-break, sweep-aware) dipakai untuk saved LTF
zone di watch-list rejection — lihat [Rejection-Entry Mechanism](#rejection-entry-mechanism).

`InvalidateHtfZones` juga jalan selama `ReplayInitialStructure` di OnInit — zona
yang break di tengah replay langsung dihapus, sama seperti live.

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

Saat LTF zona VALIDATED, EA juga cek apakah wick sudah masuk ke range zona itu
sejak dia jadi pending (`g_ltfPendingTouched`) — dipakai nanti sebagai
`touchedAtValidation` di riwayat LTF, independen dari CSV tracker supaya tetap
akurat walau `InpZoneQualityLog=false` atau saat replay OnInit.

---

## Rejection-Entry Mechanism

Ini satu-satunya cara EA membuka posisi. HTF di sini **murni sinyal arah**,
bukan area harga untuk ditunggu — LTF zone sendiri yang jadi pemicu entry.

### 1. HTF validasi → set bias, bukan zona

Begitu zona HTF VALIDATED, `g_htfBiasDir` di-set (1=demand/bullish,
-1=supply/bearish). HTF tidak pernah dicek secara geometris (harga di dalam
zona HTF atau tidak) — dia cuma bilang arah mana yang layak diperhatikan.

### 2. Replay mundur cari kandidat LTF

Begitu bias berubah, `SaveLtfZonesForHtfBias` replay MUNDUR lewat
`g_ltfValidatedHistory[]` — arsip permanen semua zona LTF yang pernah
VALIDATED — mencari yang:
- Searah dengan bias baru
- Waktunya `>= HTF zone.time` (origin bar HTF, bukan waktu HTF validasi —
  supaya zona LTF yang validasi SEBELUM bias HTF terbentuk tetap ketemu,
  bukan cuma yang validasi setelahnya)
- Belum `superseded` (lihat poin 4)

Yang cocok dan belum pernah disimpan → masuk `g_savedLtfZones[]`, status
`touched=false, used=false`.

### 3. Tunggu retest → REJECTED, baru entry

Zona tersimpan **tidak langsung ditradingkan**. Tiap bar LTF closed dicek
(`CheckRejectionRetests`):

1. **Structural break** — body CLOSE tembus far edge (atau sweep level kalau
   ada) → zona invalid, `used=true`, tidak ada entry. Aturan sama persis
   dengan invalidasi HTF.
2. **Rejection** — SEMUA tiga syarat: wick masuk ke range zona, body bar/ATR
   >= `InpRejectionBodyAtr` searah favorable, DAN close berakhir di luar
   zona lagi → `used=true`, **market order** (`OpenMarketWithStructuralStops`).
3. Sentuhan yang bukan break maupun rejection bersih → zona tetap aktif,
   cuma dicatat `touched=true`, terus ditunggu. **Bukan one-shot** — zona
   bisa disentuh berkali-kali sebelum akhirnya break atau reject.

Order pakai market (bukan limit) karena begitu bar rejection sudah closed,
harga sudah bergerak menjauh dari edge zona — tidak ada lagi "edge" untuk
ditunggu dengan limit order.

### 4. Zona yang sudah touched, disupersede otomatis

Kalau zona LTF searah yang lebih baru VALIDATED sementara zona lama sudah
pernah tersentuh (`touchedEver`), zona lama ditandai `superseded` — pasar
sudah bergerak, setup lama basi. Ini dicek di titik paling awal yang
mungkin (tiap kali LTF zona validasi, bukan cuma pas HTF validasi
berikutnya), dan berlaku dua arah:
- `g_ltfValidatedHistory[]` — ditandai `superseded` (arsip permanen, tidak
  dihapus), supaya replay mundur berikutnya tidak menawarkan zona ini lagi
- `g_savedLtfZones[]` — kalau sudah `touched` (bukan cuma di history, tapi
  di watch-list yang sedang aktif) → langsung `used=true`, dicoret dari
  chart

---

## Multi-Timeframe Architecture

```
HTF (InpHtfTimeframe, e.g., H1):
  └─ Detect Supply & Demand zones dari bar data
  └─ Zone confirmed → (optional) follow-through validation → VALIDATED (gated InpRequireZoneValidation)
  └─ VALIDATED → set g_htfBiasDir + SaveLtfZonesForHtfBias (replay mundur cari kandidat LTF)
  └─ Zone management: max InpMaxZones, lower demand / higher supply invalidates older
  └─ Zone invalidation: close breaks zone boundary → remove dari array (bookkeeping/CSV — tidak digambar)

LTF (InpTimeframe, e.g., M5):
  └─ Detect Supply & Demand zones independently
  └─ Zone confirmed + VALIDATED → masuk g_ltfValidatedHistory[] permanen (bukan trigger entry)
  └─ Tiap bar closed: CheckRejectionRetests terhadap semua saved zone (break/reject/masih-nunggu)
  └─ DrawSavedLtfZones — HANYA zona LTF yang digambar; HTF tidak pernah jadi objek chart
```

---

## Exit Plan

| Mekanisme | Trigger | Gate |
|-----------|---------|------|
| Broker SL | Zone-anchored stop, attached saat entry | Selalu |
| Broker TP | RR x jarak SL, attached saat entry (0=tanpa TP) | Selalu |
| Daily target/loss | GetDailyPnL() + floating | Close all + block rest of day |
| Final target/loss | Balance - baseline + floating | Close all + stop permanent |

Tidak ada partial close, trailing stop, invalid-position handler, atau
aggregate SL — posisi murni jalan sampai kena SL/TP broker atau kena salah
satu close-all di atas.

---

## Structural SL/TP, Risk-Based Lot

- SL = LTF zone's own far edge (`zLow`/`zHigh` dari zona tersimpan) ±
  `InpZoneSlBufferAtr` x LTF ATR
- TP = `InpTakeProfitRR` x jarak SL aktual dari harga fill (0 = tanpa TP)
- Lot dihitung `LotForRisk()`: `InpRiskPerTrade` / (jarak SL x nilai per
  poin), dibulatkan KE BAWAH ke volume step broker
- `InpMaxRiskOvershoot` membatasi seberapa jauh risiko boleh melebihi
  budget kalau lot minimum broker sudah lebih besar dari yang seharusnya
  (0 = terima overshoot berapapun)

---

## Zone Quality Logging (CSV)

Setiap zona yang dikonfirmasi live (LTF & HTF) dicatat ke CSV untuk analisis
kualitas — `InpZoneQualityLog` (default true).

- **CONFIRM row**: atribut kualitas saat zona terbentuk — displacement
  (`disp_body_atr`, `disp_range_atr`), lebar zona (`width_atr`), `base_bars`,
  sweep flag, trend saat konfirmasi.
- **OUTCOME row**: nasib zona — `VALIDATED`, `FAILED_OPPOSITE`, `INVALIDATED`,
  `REPLACED`, `EXPIRED`, `UNRESOLVED` — plus statistik perilaku sejak
  konfirmasi (excursion, first touch, `fav_after_touch_pts`).

Tujuan: kumpulkan data dulu, lalu analisis korelasi atribut → outcome, dan
jadikan atribut yang terbukti sebagai filter entry.

File: `AjipSnD_Zones_<symbol>_<login>.csv` di `Common\Files`.

---

## Init

`ReplayInitialStructure()` — replay HTF+LTF bersamaan, urut kronologis per
waktu-close, bukan cuma isi array zona:

```
1. Fetch InpCandlesInit bar HTF (skip bar yang belum closed)
2. Trend awal HTF: DetermineInitialTrend atas bar-bar itu
3. Fetch bar LTF SEPANJANG rentang kalender yang sama dengan window HTF
   (bukan InpCandlesInit bar LTF — timeframe LTF/HTF bisa jauh beda skala,
   fixed count akan under-cover window HTF)
4. Trend awal LTF: dari InpCandlesInit bar TERAKHIR pada window LTF itu
5. Merge kedua stream per waktu-close, replay bar-per-bar lewat UpdateHTF/
   UpdateLTF yang SAMA dipakai live (isReplay=true)
6. Setiap validasi HTF selama replay tetap men-trigger SaveLtfZonesForHtfBias
   — EA keluar dari OnInit dengan bias & watch-list nyata, bukan kosong
7. CheckRejectionRetests tetap resolve nasib tiap saved zone (break/reject)
   terhadap bar historis, TAPI tidak pernah kirim order — harga sudah
   bergerak jauh dari momen historis itu, tidak ada fill yang valid
8. CSV/diagnostic write (zone quality tracker, excursion, drift) di-skip
   selama replay — supaya CSV tidak dibanjiri data replay tiap kali restart
```
