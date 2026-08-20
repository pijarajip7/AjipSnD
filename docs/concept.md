# AjipSnD — Konsep & Strategi

AjipSnD adalah strategi Supply & Demand (SnD) zone-based untuk MT5,
berbeda dari AjipSMC dan AjipIDM.

| Aspek | AjipIDM | AjipSnD |
|-------|---------|---------|
| Structure | SL/SH swings | Tidak ada — murni candle-based |
| Detection | 2-stage pullback + simple structure | Raw candle (bear/bull) + body-break confirm |
| Zones | idm zone (single level) | Supply/Demand zone (high-low range) |
| Timeframe | Single | Single — satu timeframe deteksi zona, tanpa bias timeframe lain |
| Entry trigger | idm touch + no body break | Zona di-retest, wick masuk lalu REJECTED |
| Order type | — | Market order (bukan pending limit) |
| Lot | Fixed lot | Risk-based — diturunkan dari `InpRiskPerTrade` / jarak SL |
| SL/TP | Tidak ada di entry | Structural — SL di swing zone, TP = RR x jarak SL |
| Zone invalidation | Tidak ada | Saved zone dicoret dari watch-list saat body close break boundary |
| Init | Bar terakhir saja | Replay kronologis — EA start dengan watch-list nyata |

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

`g_ltfDemandZones[]`/`g_ltfSupplyZones[]` — array structural zone mentah (buat
panel count + zone-quality CSV), TERPISAH dari `g_savedLtfZones[]` (watch-list
rejection-entry, lihat [Rejection-Entry Mechanism](#rejection-entry-mechanism)).
Array ini tidak punya body-close-break invalidation sendiri — cuma dua aturan:

```
InpMaxZones (default 10) — max zona aktif per tipe

Demand zone baru:  if zone.low < any_existing_demand.low → old deactivated
Supply zone baru:  if zone.high > any_existing_supply.high → old deactivated

Max exceeded → oldest (index 0) deactivated
```

`AddDemandZone`/`AddSupplyZone` juga punya cabang "zona sudah touched
dideaktivasi begitu zona baru searah confirm" — sisa dari era ketika ini
timeframe-generic (dipanggil untuk HTF dan LTF). Sekarang cabang itu digerbang
oleh `isHtf`, yang selalu `false` di single-timeframe ini, jadi tidak pernah
jalan lagi — dibiarkan sebagai dead weight yang tidak berbahaya, bukan
dihapus, karena parameter `htf`/`isHtf` masih dipakai fungsi-fungsi
zone-tracking lain (lihat `AjipSnD_Zone.mqh`).

---

## Zone Validation (Follow-through)

Setelah zona dikonfirmasi oleh bar X, zona harus tervalidasi oleh follow-through
sebelum boleh dipakai. Konfirmasi + follow-through:

- Demand: bar X close > candidate.high/sweepHigh → butuh bar berikutnya close > barX.high
- Supply: bar X close < candidate.low/sweepLow → butuh bar berikutnya close < barX.low

Aturan:
- Validasi SELALU aktif — entry ditunda sampai follow-through muncul.
- Validasi harus selesai SEBELUM zona opposite terbentuk; kalau opposite duluan → zona gagal (discard, no entry).

Saat zona VALIDATED, EA juga cek apakah wick sudah masuk ke range zona itu
sejak dia jadi pending (`g_ltfPendingTouched`) — dipakai nanti sebagai
`touchedAtValidation` di CSV tracker, independen dari `InpZoneQualityLog`
supaya tetap akurat walau logging mati atau saat replay OnInit.

---

## Rejection-Entry Mechanism

Ini satu-satunya cara EA membuka posisi. Tidak ada bias timeframe lain, tidak
ada filter arah dari luar — zona itu sendiri, begitu VALIDATED, langsung jadi
kandidat watch, dua arah, tanpa gerbang apapun.

### 1. Validasi → langsung masuk watch-list, bukan trigger entry

Begitu zona VALIDATED (lihat [Zone Validation](#zone-validation-follow-through)),
`SaveLtfZoneForWatch` langsung append satu entry baru ke `g_savedLtfZones[]` —
status `touched=false, used=false`. Tidak ada delay, tidak ada bias arah yang
harus dicocokkan dulu: zona demand dan supply sama-sama langsung di-watch
begitu masing-masing tervalidasi. Validasi zona itu sendiri **belum** berarti
entry — cuma berarti "sekarang mulai diawasi untuk retest."

### 2. Tunggu retest → REJECTED, baru entry

Zona tersimpan **tidak langsung ditradingkan**. Tiap bar LTF closed dicek
(`CheckRejectionRetests`):

1. **Structural break** — body CLOSE tembus far edge (atau sweep level kalau
   ada) → zona invalid, `used=true`, tidak ada entry.
2. **Rejection** — SEMUA tiga syarat: wick masuk ke range zona, body bar/ATR
   >= `InpRejectionBodyAtr` searah favorable, DAN close berakhir di luar
   zona lagi → `used=true`, **market order** (`OpenMarketWithStructuralStops`).
3. Sentuhan yang bukan break maupun rejection bersih → zona tetap aktif,
   cuma dicatat `touched=true`, terus ditunggu. **Bukan one-shot** — zona
   bisa disentuh berkali-kali sebelum akhirnya break atau reject.

Order pakai market (bukan limit) karena begitu bar rejection sudah closed,
harga sudah bergerak menjauh dari edge zona — tidak ada lagi "edge" untuk
ditunggu dengan limit order.

### 3. Zona yang sudah touched, disupersede otomatis

Kalau zona searah yang lebih baru VALIDATED sementara zona lama di watch-list
sudah pernah tersentuh (`touched`), zona lama langsung ditandai `used=true`
(`MarkLtfValidationContext`) — pasar sudah bergerak, setup lama basi. Ini
dicek di titik paling awal yang mungkin: tiap kali ada zona baru validasi,
bukan ditunda ke pengecekan lain. Zona yang belum pernah tersentuh TIDAK
disupersede — cuma yang sudah `touched` dan belum resolve.

### Rectangle chart: dibekukan, bukan dihapus

`g_ltfZoneDrawEnd[]` (index-aligned dengan `g_savedLtfZones[]`) mencatat kapan
tiap zona berhenti diawasi — `0` selama masih live. Begitu `used=true`
(break, rejection-traded, atau superseded di atas), entry ini di-stamp dengan
waktu bar yang menyelesaikannya. `DrawSavedLtfZones` pakai stamp ini: zona
yang masih live terus digambar ulang tiap bar dengan ujung kanan mengikuti
"sekarang," zona yang sudah resolve digambar SEKALI LAGI dengan ujung kanan
beku di titik itu, lalu ditandai `g_ltfZoneDrawFrozen[i]=true` dan tidak
pernah disentuh lagi — rectangle-nya **tetap ada di chart selamanya**, tidak
pernah dihapus, tapi juga tidak pernah diproses ulang setelah beku (jaga
biaya redraw supaya tidak ikut membengkak seiring total zona sepanjang umur
EA).

---

## Single-Timeframe Architecture

```
LTF (InpTimeframe, e.g., M5) — satu-satunya timeframe deteksi zona:
  └─ Detect Supply & Demand zones
  └─ Zone confirmed → follow-through validation (selalu aktif) → VALIDATED
  └─ VALIDATED → SaveLtfZoneForWatch: langsung masuk g_savedLtfZones[], dua arah, tanpa gerbang
  └─ Zone management (g_ltfDemandZones/g_ltfSupplyZones, terpisah dari watch-list):
       max InpMaxZones, lower demand / higher supply invalidates older
  └─ Tiap bar closed: CheckRejectionRetests terhadap semua saved zone (break/reject/masih-nunggu)
  └─ DrawSavedLtfZones — satu-satunya objek chart, tidak pernah dihapus, dibekukan saat resolve
```

Tidak ada timeframe kedua yang menentukan arah atau menunda watch-list —
setiap zona yang tervalidasi di timeframe ini langsung jadi kandidat retest,
apapun arahnya.

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

- SL = titik ekstrem bar rejection itu sendiri (`bar.low` untuk demand,
  `bar.high` untuk supply — bukan batas statis zona) ± `InpZoneSlBufferAtr`
  x LTF ATR. Wick yang barusan di-reject itu bukti nyata di mana level
  bertahan, dan bisa lebih dangkal atau lebih dalam dari `zLow`/`zHigh`
  zona (`wickedIn` cuma butuh wick masuk ke range, tidak harus berhenti
  tepat di edge)
- TP = `InpTakeProfitRR` x jarak SL aktual dari harga fill (0 = tanpa TP)
- Lot dihitung `LotForRisk()`: `InpRiskPerTrade` / (jarak SL x nilai per
  poin), dibulatkan KE BAWAH ke volume step broker
- `InpMaxRiskOvershoot` membatasi seberapa jauh risiko boleh melebihi
  budget kalau lot minimum broker sudah lebih besar dari yang seharusnya
  (0 = terima overshoot berapapun)

---

## Zone Quality Logging (CSV)

Setiap zona yang dikonfirmasi live dicatat ke CSV untuk analisis
kualitas — `InpZoneQualityLog` (default true).

- **CONFIRM row**: atribut kualitas saat zona terbentuk — displacement
  (`disp_body_atr`, `disp_range_atr`), lebar zona (`width_atr`), `base_bars`,
  sweep flag, trend saat konfirmasi.
- **OUTCOME row**: nasib zona — `FAILED_OPPOSITE`, `TOUCHED_SUPERSEDED`,
  `REPLACED`, `EXPIRED`, `UNRESOLVED` (masih `trackingActive` saat EA
  shutdown) — plus statistik perilaku sejak konfirmasi (excursion, first
  touch, `fav_after_touch_pts`). Validasi sendiri bukan outcome — itu kolom
  boolean terpisah (`validated`) di baris yang sama.

Tujuan: kumpulkan data dulu, lalu analisis korelasi atribut → outcome, dan
jadikan atribut yang terbukti sebagai filter entry.

File: `AjipSnD_Zones_<symbol>_<login>.csv` di `Common\Files`.

---

## Init

`ReplayInitialStructure()` — replay bar LTF kronologis, bukan cuma isi array
zona:

```
1. Fetch InpCandlesInit bar LTF (skip bar yang belum closed)
2. Trend awal: DetermineInitialTrend atas bar-bar itu
3. Replay bar-per-bar lewat UpdateLTF yang SAMA dipakai live (isReplay=true)
4. Setiap validasi zona selama replay tetap men-trigger SaveLtfZoneForWatch
   — EA keluar dari OnInit dengan watch-list nyata, bukan kosong
5. CheckRejectionRetests tetap resolve nasib tiap saved zone (break/reject)
   terhadap bar historis, TAPI tidak pernah kirim order — harga sudah
   bergerak jauh dari momen historis itu, tidak ada fill yang valid
6. CSV/diagnostic write (zone quality tracker, excursion, drift) di-skip
   selama replay — supaya CSV tidak dibanjiri data replay tiap kali restart
7. DrawSavedLtfZones dipanggil SEKALI di akhir (bukan tiap bar historis) —
   zona yang sudah resolve selama replay langsung mendapat ujung kanan beku
   yang benar sejak gambar pertamanya, bukan "sekarang" yang salah
```
