# AjipSnD — Konsep & Strategi

AjipSnD adalah strategi Supply & Demand (SnD) zone-based untuk MT5,
berbeda dari AjipSMC dan AjipIDM.

| Aspek | AjipIDM | AjipSnD |
|-------|---------|---------|
| Structure | SL/SH swings | Tidak ada — murni candle-based |
| Detection | 2-stage pullback + simple structure | Raw candle (bear/bull) + body-break confirm |
| Zones | idm zone (single level) | Supply/Demand zone (high-low range) |
| Timeframe | Single | Single — satu timeframe deteksi zona, tanpa bias timeframe lain |
| Entry trigger | idm touch + no body break | Zona di-retest, WICK PERTAMA yang masuk langsung entry |
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
entry, lihat [Entry Mechanism](#entry-mechanism)).
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

## Entry Mechanism

Ini satu-satunya cara EA membuka posisi. Tidak ada bias timeframe lain, tidak
ada filter arah dari luar — zona itu sendiri, begitu VALIDATED, langsung jadi
kandidat watch, dua arah, tanpa gerbang apapun.

### 1. Validasi → langsung masuk watch-list, bukan trigger entry

Begitu zona VALIDATED (lihat [Zone Validation](#zone-validation-follow-through)),
`SaveLtfZoneForWatch` langsung append satu entry baru ke `g_savedLtfZones[]`.
Tidak ada delay, tidak ada bias arah yang harus dicocokkan dulu: zona demand
dan supply sama-sama langsung di-watch begitu masing-masing tervalidasi.
Validasi zona itu sendiri **belum** berarti entry — cuma berarti "sekarang
mulai diawasi untuk retest."

**Kecuali** kalau zona itu sudah pernah tersentuh SEBELUM validasinya
selesai (`g_ltfPendingTouched` — wick masuk ke range zona di antara bar
konfirmasi dan bar validasi). Zona begini tetap disimpan di
`g_savedLtfZones[]` (buat jejak/join-key CSV) TAPI langsung `used=true` —
tidak pernah masuk watch-list aktif, tidak pernah dapat kesempatan
entry, DAN tidak pernah digambar di chart sama sekali
(`g_ltfZoneDrawFrozen=true` sejak awal) — zona ini tidak pernah jadi
kandidat yang benar-benar diawasi, jadi tidak ada apapun yang perlu
ditampilkan, beda dengan zona yang SEMPAT diawasi lalu resolve (lihat
[Rectangle chart: dibekukan, bukan dihapus](#rectangle-chart-dibekukan-bukan-dihapus)
di bawah). Ini backtested: zona yang sudah tersentuh saat validasi hit
rate-nya 56-58% di horizon 5m/15m, vs 75%+ untuk zona yang validasi bersih
(belum pernah tersentuh) — lihat RESULT block di `MarkLtfValidationContext`
(`AjipSnD_Zone.mqh`) untuk detail pengukurannya.

**Gerbang yang sama juga berlaku untuk zona yang sweep saat konfirmasi** —
`zone.sweepHigh > 0 || zone.sweepLow > 0`, artinya candidate-nya sempat
kena percobaan break yang gagal (wick lewat `candidate.high`/`.low` tapi
close tidak menembusnya) sebelum akhirnya benar-benar terkonfirmasi.
Diperlakukan identik dengan pre-touch: `used=true` sejak lahir, tidak
pernah masuk watch-list, tidak pernah digambar. Dua kondisi ini (pre-touch
dan swept) di-OR di satu gerbang yang sama (`SaveLtfZoneForWatch`), jadi
kalau salah satu saja terjadi, zona langsung didiskualifikasi — belum
diukur dulu, langsung diterapkan atas permintaan.

### 2. Retest → WICK PERTAMA yang masuk, langsung entry

Zona tersimpan **tidak langsung ditradingkan**. Tiap bar LTF closed dicek
(`CheckRejectionRetests`), dan tiap tick juga dicek (`CheckAggressiveTickEntries`,
lihat di bawah):

1. **Structural break** — body CLOSE tembus far edge (atau sweep level kalau
   ada) → zona invalid, `used=true`, tidak ada entry. Ini SELALU nunggu bar
   closed — tidak ada konsep "close" di level tick.
2. **Trigger entry** — WICK PERTAMA yang masuk ke range zona, titik. Tidak
   ada syarat body bar, tidak ada syarat close-back-out sama sekali →
   `used=true`, **market order** (`OpenMarketWithStructuralStops`) langsung.
   Zona jadi praktis selalu one-shot: begitu wick pertama masuk (dan bukan
   break), langsung trigger — tidak pernah ada state "touched tapi masih
   nunggu". Formerly opsional (`InpAggressiveEntry`) berdampingan dengan
   mode nunggu rejection bar (body/ATR minimum + close-back-out searah);
   dijadikan satu-satunya mode langsung atas permintaan, bukan hasil
   pengukuran.

**Jalan di level TICK, bukan cuma bar close** — `CheckAggressiveTickEntries`
(dipanggil tiap `OnTick`, bukan cuma pas bar LTF baru closed) cek `tick.bid`
terhadap tiap zona yang belum `used`, dan begitu wick pertama tersentuh
(walau bar-nya sendiri belum selesai), langsung trigger — tidak nunggu bar
itu closed dulu. `CheckRejectionRetests` sendiri MASIH punya cabang
bar-close-nya sendiri untuk hal yang sama — dipakai untuk replay OnInit
(tidak ada tick live untuk direaksi di sana), dan sebagai fallback redundant
yang aman di operasi live: keduanya cek `used` duluan, jadi siapa yang
trigger lebih dulu itu yang menang, tidak ada risiko entry dobel.

Order pakai market (bukan limit) karena begitu bar/tick trigger sudah
terjadi, harga sudah bergerak menjauh dari edge zona — tidak ada lagi "edge" untuk
ditunggu dengan limit order.

### favW filter (opsional)

`InpMinFavW` / `InpMaxFavW` (default 3 / 10; 0 = mati) — gerbang entry berbasis
`favW`: ekskursi favorable sebelum touch, dalam satuan lebar zona (sama
persis dengan label `favW~x`/`favW x` di chart dan kolom CSV
`fav_before_touch_width_ratio`). Zona yang touch pertamanya mendarat dengan
`favW` di luar `[min, max]` langsung `used=true` tanpa entry — one-shot,
konsisten dengan mode agresif (metric monotonic, touch berikutnya cuma makin
jauh di luar range). Dinilai di jalur tick dan bar-close; di jalur tick
nilainya `maxFavPts` per bar closed terakhir (stale satu bar, sama
granularitas dengan snapshot CSV). Metric ini hidup di zone-quality tracker,
jadi tracker ikut jalan kalau filter ini on walau `InpZoneQualityLog` off —
penulisan CSV tetap digerbang `InpZoneQualityLog`.

### MA filter (opsional)

`InpMaFilterEnabled` (default true) — filter tren double-SMA **simetris**,
dipasang di dalam `EntryGateBlocked(dir)` sehingga kedua jalur entry (tick
`CheckAggressiveTickEntries` dan bar-close `CheckRejectionRetests`)
ter-cover satu hook:

- BUY (zona demand) hanya boleh ketika fast SMA > slow SMA (uptrend).
- SELL (zona supply) hanya boleh ketika fast SMA < slow SMA (downtrend).

`MaFilterBlocks(dir)` baca SMA bar terakhir yang sudah CLOSED (`CopyBuffer`
shift=1) — stabil, tidak repaint di tengah bar — dan fail-open (handle hilang
→ tidak di-block). Handle SMA dibuat kalau `InpMaFilterEnabled ||
InpShowMaLines`.

Catatan urutan: seperti gerbang `EntryGateBlocked` lainnya (session/news/
max-positions), cek MA jalan SETELAH zona yang kena touch sudah ditandai
`used=true` — jadi arah yang ke-block tetap menghabiskan zona di touch pertama
(one-shot, tanpa order), bukan menunggu state MA yang lebih baik.

Catatan arah: zona demand terbentuk di downtrend, supply di uptrend, jadi
filter ini membiaskan entry ke retest yang sudah searah tren MA (buy demand
hanya setelah MA naik, sell supply hanya setelah MA turun) — filter
trend-alignment, bukan filter reversal murni.

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
(break, traded, atau superseded di atas), entry ini di-stamp dengan
waktu bar yang menyelesaikannya. `DrawSavedLtfZones` pakai stamp ini: zona
yang masih live terus digambar ulang tiap bar dengan ujung kanan mengikuti
"sekarang," zona yang sudah resolve digambar SEKALI LAGI dengan ujung kanan
beku di titik itu, lalu ditandai `g_ltfZoneDrawFrozen[i]=true` dan tidak
pernah disentuh lagi — rectangle-nya **tetap ada di chart selamanya**, tidak
pernah dihapus, tapi juga tidak pernah diproses ulang setelah beku (jaga
biaya redraw supaya tidak ikut membengkak seiring total zona sepanjang umur
EA).

Pengecualian: zona yang kena [filter pre-touch](#1-validasi--langsung-masuk-watch-list-bukan-trigger-entry)
(sudah tersentuh sebelum validasi) langsung `g_ltfZoneDrawFrozen=true` dari
awal, TANPA pernah melalui fase live sama sekali — jadi tidak pernah digambar
walau sekali. Berbeda dari zona yang sempat diawasi dulu baru resolve: zona
pre-touch tidak pernah benar-benar jadi kandidat watch, jadi tidak ada
apapun yang perlu direpresentasikan di chart.

**Label runway (`favW~<rasio>` / `favW <rasio>`):** posisinya **di dalam**
rectangle, rata kanan dan center vertikal — anchor-nya `(endTime,
(high+low)/2)` dengan `ANCHOR_RIGHT`, persis koordinat waktu yang dipakai
sisi kanan rectangle-nya sendiri (`TimeCurrent()` selama live, stempel beku
begitu resolve), jadi label ikut mengikuti sisi kanan yang bergerak tiap
redraw sama seperti rectangle-nya. Warnanya selalu **putih**, bukan warna
zona sendiri (biru/oranye) — rectangle-nya solid fill, jadi teks warna sama
dengan fill-nya kontrasnya nol, tidak kelihatan sama sekali walau posisi
dan z-order sudah benar (ini akar masalah versi sebelumnya, dikonfirmasi
dari screenshot chart langsung). Dibaca lewat `g_ltfZoneTrackerIdx[]`
(index-aligned dengan `g_savedLtfZones[]`, di-resolve sekali di
`SaveLtfZoneForWatch` lewat pencarian mundur, bukan re-search tiap redraw).
`-1` (label tidak pernah muncul) cuma kalau `InpZoneQualityLog` mati saat
konfirmasi.

- **Zona hasil replay OnInit ikut ter-track penuh**: `TrackZone` dan
  `UpdateZoneTracking` sama-sama jalan tanpa peduli `isReplay` — cuma
  penulisan CSV-nya sendiri (baris CONFIRM, dan baris OUTCOME lewat
  parameter `isReplay` di `LogZoneOutcome`) yang tetap live-only, supaya
  replay window yang sama tidak nge-dump baris duplikat ke disk tiap EA
  restart. Begitu `ReplayInitialStructure` selesai, zona hasil replay sudah
  punya entry tracker yang akurat — yang sudah tersentuh di histori langsung
  tampil rasio beku yang benar, bukan mulai dari 0 gara-gara restart.
- **Sebelum tersentuh** (`touched=false` di tracker): label tampil
  `favW~<rasio>` — dihitung ulang tiap redraw dari `maxFavPts / widthPts`.
  `maxFavPts` sendiri sudah live sejak awal (update tiap bar, tidak
  digerbang `touched`), jadi ini pratinjau sungguhan, bukan placeholder.
- **Begitu tersentuh**: label pindah ke `favW <rasio>` (tanpa `~`) — nilai
  `favBeforeTouchWidthRatio` yang sudah beku, persis yang masuk CSV. Sama
  persis dengan pratinjau live di bar touch itu sendiri (dua-duanya
  `maxFavPts / widthPts` di momen yang sama), jadi tampilannya tidak pernah
  lompat, cuma berhenti bergerak.
- Ikut beku bareng rectangle-nya begitu zona resolve.

---

## Single-Timeframe Architecture

```
LTF (InpTimeframe, e.g., M5) — satu-satunya timeframe deteksi zona:
  └─ Detect Supply & Demand zones
  └─ Zone confirmed → follow-through validation (selalu aktif) → VALIDATED
  └─ VALIDATED → SaveLtfZoneForWatch: langsung masuk g_savedLtfZones[], dua arah, tanpa gerbang
  └─ Zone management (g_ltfDemandZones/g_ltfSupplyZones, terpisah dari watch-list):
       max InpMaxZones, lower demand / higher supply invalidates older
  └─ Tiap bar closed (+ tiap tick): CheckRejectionRetests / CheckAggressiveTickEntries terhadap semua saved zone (break/trigger/belum tersentuh)
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
| Trailing stop | Profit = InpTrailingStopTrigger·W → SL = price ∓ InpTrailingStopStart·W; tiap naik InpTrailingStopStep·W, SL ikut (W = lebar zona turunan dari jarak SL) | InpTrailingStopEnabled; SEMUA posisi |
| Invalidation TP→BE (tick) | Harga (bid/ask) lewat breakLevel ∓ InpInvalidationBufferZoneWidths·W → TP→BE | InpInvalidationTpBeEnabled |
| Invalidation TP→BE (bar close) | Bar LTF CLOSE melewati breakLevel zona asal entry (sweep-aware) → TP→BE | InpInvalidationTpBeEnabled |
| Weekly target/loss | GetWeekPnL() + floating | Close all + block rest of week |
| Final target/loss | Balance - baseline + floating | Close all + stop permanent |
| Session-end close | 3 fase: P1 floating>0 → P2 weekly+floating>0 → P3 force | Close all after session end (weekend flat) |

Trailing dan invalidation TP→BE (trigger tick) jalan di `ManageOpenPositions`
(tiap tick); trigger bar-close jalan di `UpdateLTF` (tiap bar LTF close),
masing-masing digerbang input-nya sendiri (independen). Tidak ada aggregate
SL: SL hanya digerakkan oleh trailing (in-profit, satu arah); TP hanya
digerakkan oleh invalidation TP→BE (kedua trigger, mana duluan yang menang).

---

## Structural SL/TP, Risk-Based Lot

- SL selalu anchor ke `breakLevel` — level sweep-aware yang sama yang
  menentukan zona BROKEN — ± `InpZoneSlBufferWidthMult` x lebar zona
  (`zHigh - zLow` zona yang trigger, default multiplier 2.0 → total jarak SL
  dari titik sentuh dekat sisi-dekat zona jadi kira-kira 3x lebar zona
  sendiri: 1x menyeberangi zona, 2x buffer di luar `breakLevel`). Ini
  pilihan sengaja, bukan fallback: bar/tick yang trigger entry (wick
  pertama) bisa closed DI MANA SAJA, termasuk di dalam zona — wick-nya
  sendiri bukan referensi stop yang bisa diandalkan (bisa terlalu dekat ke
  harga entry, bahkan lebih dekat dari lebar zona-nya sendiri; trigger-nya
  malah sering murni tick, bukan bar closed sama sekali). `breakLevel`
  adalah titik di mana thesis zona itu sendiri sudah pasti gagal, bukan
  sekadar titik yang kebetulan tercapai saat itu — stabil terlepas dari apa
  yang men-trigger entry-nya. Buffer-nya sendiri tadinya berbasis ATR
  (`InpZoneSlBufferAtr`); diganti supaya skalanya ikut lebar zona sendiri,
  bukan volatilitas pasar. Formerly beda anchor per mode entry (bar rejection sendiri kalau
  nunggu rejection, `breakLevel` cuma kalau agresif); dijadikan agresif
  satu-satunya mode langsung, jadi `breakLevel` sekarang satu-satunya anchor.
- TP = `InpTakeProfitRR` x jarak SL aktual dari harga fill (0 = tanpa TP)
- Lot dihitung `LotForRisk()`: `InpRiskPerTrade` / (jarak SL x nilai per
  poin), dibulatkan KE BAWAH ke volume step broker
- `InpMaxRiskOvershoot` membatasi seberapa jauh risiko boleh melebihi
  budget kalau lot minimum broker sudah lebih besar dari yang seharusnya
  (0 = terima overshoot berapapun)

---

## Invalidation TP→BE

`breakLevel` di sini **dihitung ulang tiap kali**, bukan disimpan — tidak
ada field `EntryTracker`, tidak ada parameter yang diteruskan lewat
`OpenMarketWithStructuralStops`. SL ditempatkan di `breakLevel` dikurang
(demand) / ditambah (supply) buffer sebesar `InpZoneSlBufferWidthMult` x
lebar zona, dan lebar zona itu sendiri kira-kira sama dengan jarak
entry-ke-breakLevel (entry terjadi di sisi-dekat zona, breakLevel di
sisi-jauh). Kedua arah reduce ke aljabar yang sama — `SL = B ∓ M(entry∓B)`
→ `B(1+M) = SL + M·entry` → :

```
breakLevel = (slPrice + InpZoneSlBufferWidthMult * entryPrice) / (1 + InpZoneSlBufferWidthMult)
```

`slPrice` dan `entryPrice` dua-duanya sudah ada di posisi broker sendiri
(`EntryTracker` sudah nyimpen keduanya buat keperluan lain) — jadi tidak
butuh apapun yang bisa hilang gara-gara restart. Berlaku identik buat
posisi yang baru dibuka maupun hasil restart, tanpa kasus khusus. Ini
pendekatan aproksimasi (bukan `breakLevel` historis zona yang literal —
entry tidak selalu persis di sisi-dekat, jalur fallback bar-close bisa
mendarat sejauh satu bar di dalam zona), diterima sengaja demi menghilangkan
celah restart yang ada di versi fitur sebelumnya (field `breakLevel`
tersimpan yang tidak bisa diisi ulang oleh posisi hasil restart).

Dicek tiap tick lewat `CheckInvalidationTpToBe` (dipanggil dari
`ManageOpenPositions`, sejajar dengan trailing):

- Threshold invalidasi = `breakLevel` digeser lebih jauh sebesar
  `InpInvalidationBufferZoneWidths` x lebar zona (demand: di bawah, supply:
  di atas) — ruang ekstra di luar edge persis sebelum posisi dianggap
  invalid. Kalau harga lewat level itu sebelum posisi resolve dengan cara
  lain, TP dipindah ke breakeven (`InpBreakEvenOffsetPoints` dari entry) —
  sekali tembak, dikunci `tpMovedToBe`.
- **SL: dua mode.** Default (`InpInvalidationRemoveSl=false`) SL TIDAK
  diubah — buffer invalidasi harus tetap di bawah `InpZoneSlBufferWidthMult`
  supaya fire SEBELUM SL; SL tetap lebih jauh, jadi risk/reward asimetris
  sejak titik itu (SL masih jauh, TP sudah dekat). Kalau
  `InpInvalidationRemoveSl=true`, SL justru DIHAPUS (sl=0) bersamaan TP→BE —
  downside diserahkan ke max-loss close-all (weekly/final/batch), bukan stop
  per-posisi. Eksperimen; kalau semua input max-loss 0, posisi tidak punya
  proteksi downside setelah invalidasi.
- Tidak berlaku cuma kalau posisi itu tidak punya SL struktural sama sekali
  (`!hasStructuralSl || slPrice<=0`) — selain itu berlaku tanpa syarat,
  baik posisi baru maupun hasil restart.

`InpInvalidationTpBeEnabled` (default true) mengontrol fitur ini secara
independen dari trailing.

### Trigger bar-close (tambahan, additif)

Selain trigger tick di atas, ada trigger struktural kedua
(`CheckBarCloseInvalidation`, dipanggil dari `UpdateLTF` tiap bar LTF close,
live only — tidak pernah saat replay OnInit): bar LTF yang **close**-nya
melewati `breakLevel` zona asal entry → TP ke breakeven. Ini persis event
"BROKEN" yang dipakai `CheckRejectionRetests` untuk mencoret zona dari
watch-list.

- **`breakLevel` dipakai zona ASLI, bukan aproksimasi turunan** — dicari
  lewat `EntryTracker.zoneTime` (join key ke `g_savedLtfZones[]`), lalu pakai
  edge sweep-aware (`sweepLow`/`zLow` demand, `sweepHigh`/`zHigh` supply).
  Untuk posisi hasil restart (`zoneTime == 0`, zona tidak bisa direkonstruksi),
  fallback ke aljabar turunan `(slPrice + M·entryPrice)/(1+M)` yang sama
  dengan trigger tick — paritas perilaku restart tetap terjaga.
- **Tidak ada buffer** — beda dari trigger tick yang menambah
  `InpInvalidationBufferZoneWidths·W` di luar edge. Trigger bar-close ini
  memakai `breakLevel` persis, karena kejadiannya sendiri (close bar) sudah
  konfirmasi struktural, bukan sentuhan harga intra-bar.
- **Additif, satu kali tembak** — kedua trigger berbagi flag `tpMovedToBe`
  yang sama, jadi mana yang duluan menyala akan mengunci flag dan yang lain
  jadi no-op. SL mengikuti mode `InpInvalidationRemoveSl` yang sama dengan
  trigger tick (dipertahankan atau dihapus).

---

## Recovery Mode (multi posisi, averaging down)

Setelah posisi arah D kena invalidasi (TP→BE, `tpMovedToBe=true`), arah itu
masuk "recovery mode". `InpMaxPositionsPerDir` dihapus — jumlah posisi kini
diatur oleh logika recovery di `TryEntry` (satu titik keputusan yang dipakai
kedua jalur entry, tick dan bar-close):

- **Arah kosong** → entry normal (lot risk-based, SL/TP struktural).
- **Arah terisi + bukan recovery** (belum ada `tpMovedToBe`) → skip — posisi
  masih normal, tidak boleh posisi kedua.
- **Arah terisi + recovery aktif + harga di luar semua posisi** → recovery
  add: buka posisi market dengan lot SAMA, **tanpa SL/TP**, lalu
  `ReaverageTpToBreakEven` menyatukan TP semua posisi searah ke satu level =
  rata-rata harga entry terbobot ∓ `InpBreakEvenOffsetPoints`. SELL mirror
  (tambah saat harga di atas semua entry).

`RecoveryModeActive(dir)` = ada posisi terbuka searah dengan `tpMovedToBe`.
`PriceBeyondAllEntries(dir, price)` mensyaratkan harga di bawah semua entry
BUY / di atas semua entry SELL, supaya tiap add memperbaiki rata-rata. Tanpa
batas jumlah add — downside diserahkan ke max-loss close-all. `tpMovedToBe`
direkonstruksi saat restart (`RebuildTrackedPositions`): posisi dianggap
sudah invalidasi kalau tanpa SL atau TP-nya sudah di breakeven.

---

## Zone Quality Logging (CSV)

Setiap zona yang dikonfirmasi live dicatat ke CSV untuk analisis
kualitas — `InpZoneQualityLog` (default true).

- **CONFIRM row**: atribut kualitas saat zona terbentuk — displacement
  (`disp_body_atr`, `disp_range_atr`), lebar zona (`width_atr`), `base_bars`
  (bar yang dibutuhkan CANDIDATE untuk jadi zona CONFIRMED — lihat komentar
  di `ProcessZoneBar`/`SnDZone.baseBars`, floor 2 bar), sweep flag
  (`swept_low`/`swept_high` — pernah kejadian atau tidak) + **hitungannya**
  (`sweep_low_count`/`sweep_high_count` — berapa BAR CANDIDATE yang wick-nya
  nembus `candidate.low`/`candidate.high` tanpa close-nya ikut nembus,
  sebelum akhirnya CONFIRMED; bisa >1 kalau level itu di-test berkali-kali),
  trend saat konfirmasi. `bars_to_validate`/`validate_sweep_count` masih `0`
  di baris ini — belum tervalidasi saat CONFIRM ditulis, lihat OUTCOME row.
- **OUTCOME row**: nasib zona — `FAILED_OPPOSITE`, `TOUCHED_SUPERSEDED`,
  `REPLACED`, `EXPIRED`, `UNRESOLVED` (masih `trackingActive` saat EA
  shutdown) — plus statistik perilaku sejak konfirmasi (excursion, first
  touch, `fav_after_touch_pts`). Excursion sebelum touch dipecah dua:
  `fav_before_touch_pts` (snapshot `max_fav_pts` persis di bar yang
  akhirnya touch — seberapa jauh harga sempat menjauh sebelum balik ke
  zona) dan `fav_before_touch_width_ratio` (jarak itu dibagi lebar zona
  `high-low`, bukan ATR — 500pt di zona lebar 100pt beda cerita dari 500pt
  di zona lebar 2000pt). Keduanya `0` kalau zona belum pernah tersentuh
  (sama aturan dengan `touch_depth_pts`/`bars_to_touch`). Validasi sendiri
  bukan outcome — itu kolom
  boolean terpisah (`validated`) di baris yang sama. `bars_to_validate`
  (bar dari CONFIRMED ke VALIDATED, floor 1 bar) dan `validate_sweep_count`
  (sama konsep sweep di atas, tapi terhadap `confirm_level` selama menunggu
  validasi, bukan terhadap `candidate.low`/`candidate.high` — bar yang
  wick-nya nembus `confirm_level` favorable TANPA close-nya ikut nembus,
  berarti percobaan validasi yang gagal tapi zona-nya belum mati) baru
  terisi di sini kalau zona sempat tervalidasi sebelum outcome ditulis —
  keduanya tetap `0` kalau zona gagal (`FAILED_OPPOSITE` dll.) sebelum
  sempat tervalidasi.

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
5. CheckRejectionRetests tetap resolve nasib tiap saved zone (break/trigger)
   terhadap bar historis, TAPI tidak pernah kirim order — harga sudah
   bergerak jauh dari momen historis itu, tidak ada fill yang valid
6. Zone quality tracker (`TrackZone`/`UpdateZoneTracking`) TETAP jalan
   selama replay — `g_zoneTracker[]` (dan label runway di chart) jadi
   mencerminkan histori replay yang sungguhan, bukan mulai dari nol pas
   restart. Yang di-skip cuma PENULISAN CSV-nya sendiri (baris CONFIRM,
   dan baris OUTCOME lewat parameter `isReplay` di `LogZoneOutcome`) plus
   probe excursion/drift — supaya CSV tidak dibanjiri baris duplikat tiap
   kali restart
7. DrawSavedLtfZones dipanggil SEKALI di akhir (bukan tiap bar historis) —
   zona yang sudah resolve selama replay langsung mendapat ujung kanan beku
   yang benar sejak gambar pertamanya, bukan "sekarang" yang salah
```
