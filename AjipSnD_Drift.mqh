//+------------------------------------------------------------------+
//|                                               AjipSnD_Drift.mqh |
//|       Forward-drift probe — does zone confirmation predict       |
//|                    anything, independent of entry?               |
//+------------------------------------------------------------------+
#property strict

//==================================================================
// WHY THIS EXISTS
//==================================================================
// Every prior instrument (MFE/MAE, the first-touch grid, the STOP/REJECT
// ladders) measures the same shape of question: "given a specific entry
// mechanism, what happens." All of them inherit that mechanism's fill
// timing, and a fill at the zone's edge is itself selected for price that
// is already moving — that selection is what the excursion work spent
// three runs isolating.
//
// This asks a different, more basic question, with no entry mechanism at
// all: at the moment a zone CONFIRMS, does price drift in the predicted
// direction over fixed forward horizons, more than it would from a random
// moment on the same chart? No SL, no TP, no fill — just price at t0 versus
// price at t0+h, for h in {5m, 15m, 1h, 4h, 1d}.
//
// Two populations are recorded through the identical mechanism so they are
// comparable without adjustment:
//   - ZONE:     armed at every LTF zone confirmation (both types, quality
//               gate ignored — the raw zone concept is what is on trial).
//   - BASELINE: armed at a random subset of LTF bar closes, unconditional
//               on zones or session, so it carries the same composition of
//               "market open at all" as the zone population and nothing
//               narrower.
// A zone population whose forward drift (direction-adjusted) is
// indistinguishable from the baseline's is direct evidence that
// displacement+retest, as currently defined, carries no information —
// independent of every entry-timing question already answered. Direction
// adjustment happens offline (raw deltas + isDemand are both logged), so
// the random-baseline null can be checked by permutation rather than
// asserted.
//
//------------------------------------------------------------------
// RESULT — run #9, XAUUSD M1/M15, 2024.08.01-2025.07.31
//------------------------------------------------------------------
// 31,645 LTF confirmations (the same population as run #8) against 7,241
// random-baseline draws. Direction-adjusted hit rate, by horizon:
//
//        demand   supply   COMBINED
//   5m   49.33%   48.10%    48.72%
//  15m   50.89%   48.32%    49.60%
//   1h   53.34%   45.96%    49.65%
//   4h   55.83%   43.86%    49.84%
//   1d   58.51%   41.14%    49.83%
//
// The combined column is a coin flip at every horizon. The per-side columns
// are the whole explanation: demand improves and supply decays with horizon
// by near-complementary amounts, which is XAUUSD's uptrend (baseline drift
// +5.39 ATR/day over a period where gold ran ~2445 -> ~3300) and nothing
// else. Reading demand alone at 1d would have looked like a 58% edge.
//
// No slice recovers it: displacement quartiles 48.85-50.67%, width halves
// 49.55-50.01%, HTF-aligned 49.06-49.41% vs HTF-opposed 50.23-50.27% (the
// confluence thesis lands slightly backwards, both sides noise). The one
// statistically significant cell is 5m at 48.72% (z=-4.6) — AGAINST the
// zone's own prediction, ~10 points, consistent with the adverse selection
// the run #4-#8 excursion work measured at the fill.
//
// Baseline validity: zone-population median LTF ATR 0.756 vs baseline 0.739
// (1.02x), so mu is measured on the same volatility regime.
//
// CONSEQUENCE: this closes zone-as-filter as well as zone-as-trigger. There
// is no directional information here to filter on, so refining entry timing
// or stacking gates on THIS zone definition cannot pay. Any further work on
// this signal family has to redefine what counts as a zone (volume,
// freshness/virgin-vs-touched, liquidity) — and should be screened with this
// probe before an execution layer is built on top of it.
//==================================================================

#define DRIFT_HORIZONS 5
// 5m, 15m, 1h, 4h, 1d — coarse enough that M1-bar polling (not tick polling)
// loses nothing worth having; see UpdateDriftRecords().
const int DriftHorizonSec[DRIFT_HORIZONS] = {300, 900, 3600, 14400, 86400};

// Record kinds. Baseline must stay distinguishable from every signal kind: it
// is the population the others are measured against, so a signal row silently
// counted as baseline would corrupt the very null it is compared to.
#define DRIFT_BASELINE 0
#define DRIFT_ZONE     1
#define DRIFT_TREND    2

struct DriftRecord
  {
   int      kind;        // DRIFT_BASELINE / _ZONE / _TREND
   bool     isDemand;    // direction predicted: true=up. Baseline has none.
   datetime armTime;
   double   armPrice;
   double   atrLtf;
   datetime ltfZoneTime; // join key to the zone CSV; 0 otherwise
   double   maDistAtr;   // TREND only: (close - MA) / ATR at arm
   int      nextIdx;     // lowest unstamped horizon index
   double   fwdDelta[DRIFT_HORIZONS]; // (price_at_horizon - armPrice)/point
   bool     stamped[DRIFT_HORIZONS];
  };

DriftRecord g_drift[];

//---- When a bar's information actually becomes available -------------------
// MqlRates.time is the bar's OPEN time, but everything here is armed on a bar's
// CLOSE — the close price, a confirmation, an MA reading. Starting the horizon
// clock at the open therefore runs it early by one whole bar period.
//
// On M1 that is a 60s error against a 300s first horizon. On H1 it is fatal:
// arming a record whose clock already reads 3600s stamps the 5m, 15m AND 1h
// horizons instantly, all at the same price, and the measured drift is ~0 by
// construction. That is exactly what the first trend probe run produced —
// long-only scored 0.00% at 5m, which is impossible for real price data and is
// what exposed this.
datetime DriftBarCloseTime(const datetime barOpen, ENUM_TIMEFRAMES tf)
  {
   return(barOpen + PeriodSeconds(tf));
  }

// Trend probe state — its own MA handle and its own new-bar clock, because the
// probe's timeframe is deliberately independent of the EA's own entry
// timeframe. The whole point is to test a horizon the EA does not currently
// trade.
int      g_driftTrendMa      = INVALID_HANDLE;
datetime g_driftTrendLastBar = 0;

//==================================================================
// ARM
//==================================================================
//---- One record per LTF zone confirmation, gate-independent ----
void DriftArmZone(const SnDZone &zone)
  {
   if(!InpDriftLog) return;

   int sz = ArraySize(g_drift);
   ArrayResize(g_drift, sz + 1);

   g_drift[sz].kind        = DRIFT_ZONE;
   g_drift[sz].isDemand    = zone.isDemand;
   g_drift[sz].armTime     = DriftBarCloseTime(zone.time, InpTimeframe);
   g_drift[sz].armPrice    = zone.confirmClose;
   g_drift[sz].atrLtf      = zone.atrAtConfirm;
   g_drift[sz].ltfZoneTime = zone.time;
   g_drift[sz].maDistAtr   = 0.0;
   g_drift[sz].nextIdx     = 0;
   for(int k = 0; k < DRIFT_HORIZONS; k++)
     {
      g_drift[sz].fwdDelta[k] = 0.0;
      g_drift[sz].stamped[k]  = false;
     }
  }

//---- Randomly sampled baseline, unconditional on zones or session ----
// Drawn on every LTF bar close so its time-of-day/session composition
// matches the zone population exactly (zone confirmation itself is not
// session-gated — only order placement is). InpDriftBaselineProb trades
// sample size against CSV size; ATR gate matches what a zone record
// requires, so both populations need the same instrument to exist.
void DriftArmBaseline(const MqlRates &bar)
  {
   if(!InpDriftLog || InpDriftBaselineProb <= 0.0) return;
   if(MathRand() / 32767.0 >= InpDriftBaselineProb) return;

   double atr = GetAtrValue();
   if(atr <= 0) return;

   int sz = ArraySize(g_drift);
   ArrayResize(g_drift, sz + 1);

   g_drift[sz].kind        = DRIFT_BASELINE;
   g_drift[sz].isDemand    = false;
   g_drift[sz].armTime     = DriftBarCloseTime(bar.time, InpTimeframe);
   g_drift[sz].armPrice    = bar.close;
   g_drift[sz].atrLtf      = atr;
   g_drift[sz].ltfZoneTime = 0;
   g_drift[sz].maDistAtr   = 0.0;
   g_drift[sz].nextIdx     = 0;
   for(int k = 0; k < DRIFT_HORIZONS; k++)
     {
      g_drift[sz].fwdDelta[k] = 0.0;
      g_drift[sz].stamped[k]  = false;
     }
  }

//==================================================================
// TREND PROBE — the candidate run #9 pointed at
//==================================================================
// Nine runs went into fading price INTO a level. The only real directional
// effect anywhere in that data was the market's own trend (demand-side accuracy
// reached 58.5% at the 1d horizon purely from XAUUSD's uptrend), which is the
// opposite stance to the one the EA takes. This probe tests it directly.
//
// Definition is deliberately the plainest available — close versus a moving
// average on the probe's own timeframe — because the question being asked is
// whether the DIRECTION carries information, not whether some particular
// indicator tuning does. A definition with knobs would invite fitting them.
//
// The comparison that matters is against the baseline, not against zero: in a
// year when gold rose, "price above its MA" points up most of the time, so an
// uncorrected reading would restate the trend rather than test the timing.
// Offline the record is corrected by +mu when long and -mu when short, and the
// two sides are reported separately, exactly as the zone analysis does.
void DriftArmTrend()
  {
   if(!InpDriftLog || !InpDriftTrendProbe) return;
   if(g_driftTrendMa == INVALID_HANDLE) return;

   MqlRates rates[];
   if(CopyRates(_Symbol, InpDriftTrendTf, 0, 3, rates) < 2) return;
   ArraySetAsSeries(rates, true);

   MqlRates bar = rates[1];                 // last CLOSED bar on the probe TF
   if(bar.time == g_driftTrendLastBar) return;
   g_driftTrendLastBar = bar.time;

   double ma[1];
   if(CopyBuffer(g_driftTrendMa, 0, 1, 1, ma) != 1) return;
   if(ma[0] <= 0) return;

   double atr = GetAtrValue();
   if(atr <= 0) return;

   // Exactly on the MA carries no direction — skip rather than coin-flip it.
   if(bar.close == ma[0]) return;

   int sz = ArraySize(g_drift);
   ArrayResize(g_drift, sz + 1);

   g_drift[sz].kind        = DRIFT_TREND;
   g_drift[sz].isDemand    = (bar.close > ma[0]);   // above MA = predict up
   g_drift[sz].armTime     = DriftBarCloseTime(bar.time, InpDriftTrendTf);
   g_drift[sz].armPrice    = bar.close;
   g_drift[sz].atrLtf      = atr;
   g_drift[sz].ltfZoneTime = 0;
   g_drift[sz].maDistAtr   = (bar.close - ma[0]) / atr;
   g_drift[sz].nextIdx     = 0;
   for(int k = 0; k < DRIFT_HORIZONS; k++)
     {
      g_drift[sz].fwdDelta[k] = 0.0;
      g_drift[sz].stamped[k]  = false;
     }
  }

//==================================================================
// CSV — one row per record (zone or baseline), written once all five
// horizons are stamped or the record is flushed early at deinit.
//==================================================================
void DriftCsvWrite(int i)
  {
   string filename = "AjipSnD_Drift_" + _Symbol + "_"
                   + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + ".csv";
   bool exists = FileIsExist(filename, FILE_COMMON);

   int h = FileOpen(filename,
                    FILE_COMMON | FILE_WRITE | FILE_READ | FILE_CSV | FILE_ANSI,
                    ',', CP_UTF8);
   if(h == INVALID_HANDLE)
     {
      PrintFormat("AjipSnD: Cannot open drift CSV %s", filename);
      return;
     }

   // 'kind' is the authoritative column; 'is_zone' is kept so the run #9
   // analyses keep parsing unchanged. Note they are NOT interchangeable — a
   // TREND row has is_zone=0 but is not baseline, so anything computing the
   // baseline must filter on kind.
   if(!exists)
      FileWrite(h,
                "kind", "is_zone", "is_demand", "arm_time", "arm_price", "atr_ltf",
                "ltf_zone_time", "d05m", "d15m", "d1h", "d4h", "d1d", "ma_dist_atr");
   else
      FileSeek(h, 0, SEEK_END);

   FileWrite(h,
             g_drift[i].kind == DRIFT_ZONE  ? "ZONE"  :
             g_drift[i].kind == DRIFT_TREND ? "TREND" : "BASELINE",
             g_drift[i].kind == DRIFT_ZONE ? "1" : "0",
             g_drift[i].kind == DRIFT_BASELINE
                ? "" : (g_drift[i].isDemand ? "1" : "0"),
             TimeToString(g_drift[i].armTime, TIME_DATE | TIME_SECONDS),
             DoubleToString(g_drift[i].armPrice, g_digits),
             DoubleToString(g_drift[i].atrLtf, 3),
             g_drift[i].kind == DRIFT_ZONE
                ? TimeToString(g_drift[i].ltfZoneTime, TIME_DATE | TIME_SECONDS)
                : "",
             g_drift[i].stamped[0] ? DoubleToString(g_drift[i].fwdDelta[0], 1) : "",
             g_drift[i].stamped[1] ? DoubleToString(g_drift[i].fwdDelta[1], 1) : "",
             g_drift[i].stamped[2] ? DoubleToString(g_drift[i].fwdDelta[2], 1) : "",
             g_drift[i].stamped[3] ? DoubleToString(g_drift[i].fwdDelta[3], 1) : "",
             g_drift[i].stamped[4] ? DoubleToString(g_drift[i].fwdDelta[4], 1) : "",
             g_drift[i].kind == DRIFT_TREND
                ? DoubleToString(g_drift[i].maDistAtr, 3) : "");

   FileClose(h);
  }

//==================================================================
// UPDATE — called once per closed LTF bar (not per tick: the shortest
// horizon is 5 minutes, so bar-close resolution loses nothing worth having
// and avoids walking a multi-thousand-row array on every tick).
//==================================================================
void UpdateDriftRecords(const MqlRates &bar)
  {
   if(!InpDriftLog) return;
   int n = ArraySize(g_drift);

   // The price being stamped is this bar's CLOSE, so the reading belongs to the
   // bar's close time — the same convention every arm uses.
   datetime now = DriftBarCloseTime(bar.time, InpTimeframe);

   for(int i = n - 1; i >= 0; i--)
     {
      int elapsed = (int)(now - g_drift[i].armTime);

      while(g_drift[i].nextIdx < DRIFT_HORIZONS
            && elapsed >= DriftHorizonSec[g_drift[i].nextIdx])
        {
         int k = g_drift[i].nextIdx;
         g_drift[i].fwdDelta[k] = (bar.close - g_drift[i].armPrice) / g_point;
         g_drift[i].stamped[k]  = true;
         g_drift[i].nextIdx++;
        }

      if(g_drift[i].nextIdx >= DRIFT_HORIZONS)
        {
         DriftCsvWrite(i);
         ArrayRemove(g_drift, i, 1);
        }
     }
  }

//---- Flush whatever is still in flight on deinit — partial stamps are
// still useful rows (matches FlushExcursions()) ----
void FlushDriftRecords()
  {
   if(!InpDriftLog) return;
   for(int i = ArraySize(g_drift) - 1; i >= 0; i--)
      DriftCsvWrite(i);
   ArrayResize(g_drift, 0);
  }
//+------------------------------------------------------------------+
