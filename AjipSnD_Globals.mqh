#ifndef AJIPSND_GLOBALS_MQH
#define AJIPSND_GLOBALS_MQH

// ENUMS & STRUCTS
//==================================================================
enum ENUM_TREND
  {
   TREND_UP    = 1,
   TREND_DOWN  = -1
  };

enum ENUM_LIMIT_STATUS
  {
   LIMIT_STATUS_DISABLED,
   LIMIT_STATUS_ACTIVE,
   LIMIT_STATUS_TARGET_HIT,
   LIMIT_STATUS_MAXLOSS_HIT
  };

// Supply/Demand zone
struct SnDZone
  {
   double   high;        // zone top
   double   low;         // zone bottom
   double   sweepHigh;   // highest wick above high that failed to break (0=none)
   double   sweepLow;    // lowest wick below low that failed to break (0=none)
   double   confirmLevel;// confirming bar's high (demand) / low (supply) — follow-through validation level
   datetime time;        // bar time when zone was confirmed
   bool     isDemand;    // true=demand, false=supply
   int      index;       // index in the active zones array (for reference)
   //--- Quality gate (entry filter) ---
   bool     qualityPass;      // zone width + displacement passed the entry filter
   //--- Quality tracking (CSV backtest analysis) ---
   bool     isHtf;            // tracker key: which timeframe this zone belongs to
   int      htfTrendAtConfirm;// HTF trend when this zone confirmed (LTF: cross-TF alignment)
   bool     validated;        // follow-through validation passed
   int      trendAtConfirm;   // trend of this TF at confirmation (1=UP, -1=DOWN)
   // Bars the candidate stayed alive before confirming. Floor is 2, not 1: the
   // bar that creates a candidate already increments this to 1 and cannot
   // confirm itself (confirmation needs a close beyond its own high/low), so
   // the fastest possible origin takes two bars. Measured over 31,645 LTF
   // zones: 30.6% confirm at 2 bars, median 3, longest 181.
   int      baseBars;         // bars candidate stayed alive before confirmation (2=fastest)
   double   confirmClose;     // close of the confirming bar
   double   atrAtConfirm;     // ATR value at confirmation
   double   widthAtr;         // zone width / ATR
   double   dispBodyAtr;      // confirming bar body / ATR (displacement)
   double   dispRangeAtr;     // confirming bar range / ATR
   bool     trackingActive;   // true while outcome stats are being collected
   bool     entryPlaced;      // reserved — no writer since the rejection-only
                               // rewrite; always false. Kept for CSV schema
                               // stability.
   bool     touched;          // wick re-entered zone range after confirmation
   //--- LTF-only, snapshotted at the exact moment validation passes ---
   // Deliberately NOT derived from touched's final state: that reflects the
   // zone's whole tracking lifetime, which needs knowing the future to
   // compute and cannot be known in real time. See MarkLtfValidationContext().
   bool     touchedAtValidation;  // was 'touched' already true at that instant?
   bool     htfContextValidated;  // diagnostic only — was this LTF edge inside
                                   // an ACTIVE, VALIDATED HTF zone at that
                                   // instant? See MarkLtfValidationContext's
                                   // RESULT block in AjipSnD_Zone.mqh.
   int      barsSinceConfirm; // closed bars since confirmation
   int      barsToTouch;      // bars from confirmation to first touch (0=untouched)
   double   touchDepthPts;    // penetration depth of first touch (points)
   double   maxFavPts;        // max favorable excursion from confirmClose (points)
   double   maxAdvPts;        // max adverse excursion from confirmClose (points)
   double   favAfterTouchPts; // best favorable excursion after first touch (points)
  };

// Entry tracking (multi-position, per-ticket)
struct EntryTracker
  {
   ulong    ticket;
   int      dir;            // 1=BUY, -1=SELL
   double   entryPrice;
   datetime entryTime;
   double   mfe;            // best POSITION_PROFIT seen ($)
   double   mae;            // worst POSITION_PROFIT seen ($)
   double   atrAtEntry;     // HTF ATR frozen at entry
   double   initialVolume;   // volume at entry (lot sizing, CSV logging)
   bool     hasStructuralSl; // SL came from the zone at placement
   double   slPrice;         // structural SL price (0=none)
   double   tpPrice;         // structural TP price (0=none)
   double   riskUsd;         // intended risk at entry — denominator for R-multiples
   double   atrLtfAtEntry;   // LTF ATR frozen at entry — stop/target scale
   datetime zoneTime;        // LTF zone that triggered this entry — join key to the zone CSV
  };

// Fill info handed from an order-placing function to AddEntry() — what the
// order already knew that the resulting position should inherit.
struct EntryFillInfo
  {
   ulong    ticket;
   int      dir;       // 1=BUY, -1=SELL
   double   price;     // fill price
   datetime zoneTime;  // LTF zone time that triggered this order
   double   slPrice;   // structural SL frozen at placement
   double   tpPrice;   // structural TP frozen at placement (0=none)
   double   lot;       // volume actually submitted
   double   riskUsd;   // intended risk this order was sized for (0=fixed-lot mode)
   double   atrLtf;    // LTF ATR at placement — carried through to the position
  };

//==================================================================
// GLOBALS
//==================================================================
CTrade         trade;
string         g_objPrefix    = "AjipSnD_";

// ---- Zone tracking ----
// HTF (retest zones)
SnDZone        g_htfDemandZones[];    // active demand zones on HTF
SnDZone        g_htfSupplyZones[];    // active supply zones on HTF
ENUM_TREND     g_htfTrend          = TREND_DOWN;  // current HTF trend for zone detection
SnDZone        g_htfCandidate;                  // unconfirmed zone candidate on HTF
datetime       g_htfLastBarTime    = 0;          // new-bar detection for HTF

// LTF (entry zones)
SnDZone        g_ltfDemandZones[];
SnDZone        g_ltfSupplyZones[];
ENUM_TREND     g_ltfTrend          = TREND_DOWN;
SnDZone        g_ltfCandidate;
datetime       g_ltfLastBarTime    = 0;

// ---- Zone follow-through validation ----
// LTF: always-on. HTF: gated by InpRequireZoneValidation.
SnDZone        g_ltfPendingZone;              // LTF zone awaiting follow-through validation
bool           g_ltfAwaitingValidation = false;
// Wick re-entry into g_ltfPendingZone's own range since it started waiting,
// tracked independently of g_zoneTracker (InpZoneQualityLog) so
// MarkLtfValidationContext gets an accurate touchedAtValidation even when
// quality tracking is off, or during the OnInit historical replay.
bool           g_ltfPendingTouched = false;
SnDZone        g_htfPendingZone;              // HTF zone awaiting follow-through validation
bool           g_htfAwaitingValidation = false;

// ---- Entry tracking (like AjipIDM) ----
EntryTracker   g_entries[];

// ---- Symbol info cache ----
int            g_digits;
double         g_point;
double         g_volMin, g_volMax, g_volStep;

// ---- ATR handles for zone quality metrics ----
int            g_atrLtfHandle = INVALID_HANDLE;
int            g_atrHtfHandle = INVALID_HANDLE;

// ---- Starting balance for Final target ----
double         g_startingBalance = 0.0;

// ---- Trading session ----
int            g_sessionStartMin      = 0;
int            g_sessionEndMin        = 0;
bool           g_sessionFilterEnabled = false;

// ---- Timezone offset for daily/weekly boundaries ----
int            g_timezoneOffsetSeconds = 0;

// ---- Heartbeat throttle ----
const int      HEARTBEAT_INTERVAL_SECONDS = 30;
datetime       g_lastHeartbeatTime = 0;

// ---- Zone quality tracker (live-confirmed zones, CSV backtest log) ----
SnDZone        g_zoneTracker[];

// ---- LTF validation history, searched backward on every HTF bias change ----
// Every LTF zone that ever validates gets appended here and stays forever —
// unlike g_ltfDemandZones/g_ltfSupplyZones, which are capped at InpMaxZones
// and evict old entries, this is a plain history SaveLtfZonesForHtfBias
// searches BACKWARD through, so an LTF zone must still be findable long
// after it would have been evicted from the active array.
struct LtfValidatedZone
  {
   double   high;
   double   low;
   double   sweepHigh;   // carried from the zone's own SnDZone at validation (0=no sweep)
   double   sweepLow;    // same
   datetime time;
   bool     isDemand;
   bool     touchedAtValidation;  // frozen snapshot: touched by ITS OWN validation instant
   bool     touchedEver;          // live, updated every LTF bar: touched by NOW, whenever "now" is
   bool     superseded;           // was already touched when a newer same-direction zone validated
  };
LtfValidatedZone g_ltfValidatedHistory[];

// ---- Rejection-entry mode — the EA's only entry mechanism ----
// HTF here is a pure directional bias, not a price range to sit inside: an
// HTF zone validating sets g_htfBiasDir, and only LTF zones matching that
// direction get saved. A saved zone waits for ITS OWN retest + rejection
// (wick back in, closed back out, with real momentum) before anything is
// traded — no zone is ever traded straight off its own validation. Unproven
// — written directly to spec, not measured first.
int g_htfBiasDir = 0;   // 0=none yet, 1=demand/bullish bias, -1=supply/bearish bias

struct SavedLtfZone
  {
   double   high;
   double   low;
   double   sweepHigh;   // 0=no sweep — see LtfValidatedZone
   double   sweepLow;    // same
   datetime time;
   bool     isDemand;
   bool     touched;     // live: any wick has re-entered the range, whether or not it resolved
   bool     used;        // resolved (rejected+traded, structurally broken, or superseded) — stop checking
  };
SavedLtfZone g_savedLtfZones[];

//==================================================================
// HELPER FUNCTIONS
//==================================================================

//---- Get ATR value (last closed bar) for zone quality metrics ----
double GetAtrValue(bool htf)
  {
   int handle = htf ? g_atrHtfHandle : g_atrLtfHandle;
   if(handle == INVALID_HANDLE) return(0.0);
   double buf[1];
   if(CopyBuffer(handle, 0, 1, 1, buf) != 1) return(0.0);
   return(buf[0]);
  }

//---- Classify limit status (generic, reused for final + daily) ----
ENUM_LIMIT_STATUS ClassifyLimitStatus(double total, double maxProfit, double maxLoss)
  {
   if(maxProfit <= 0 && maxLoss <= 0)
      return(LIMIT_STATUS_DISABLED);
   if(maxLoss > 0 && total <= -maxLoss)
      return(LIMIT_STATUS_MAXLOSS_HIT);
   if(maxProfit > 0 && total >= maxProfit)
      return(LIMIT_STATUS_TARGET_HIT);
   return(LIMIT_STATUS_ACTIVE);
  }

//---- Parse HH:MM to minutes since midnight ----
int ParseMinutesFromMidnight(string timeStr)
  {
   string parts[];
   if(StringSplit(timeStr, ':', parts) != 2)
      return(-1);
   int h = (int)StringToInteger(parts[0]);
   int m = (int)StringToInteger(parts[1]);
   if(h < 0 || h > 23 || m < 0 || m > 59)
      return(-1);
   return(h * 60 + m);
  }

//---- Are we inside the trading session? ----
bool InSession()
  {
   if(!g_sessionFilterEnabled)
      return(true);
   // Use local time (server + timezone offset) for session comparison
   datetime localNow = TimeCurrent() + g_timezoneOffsetSeconds;
   MqlDateTime local;
   TimeToStruct(localNow, local);
   int nowMin = local.hour * 60 + local.min;
   
   if(g_sessionStartMin <= g_sessionEndMin)
      return(nowMin >= g_sessionStartMin && nowMin < g_sessionEndMin);
   else
      return(nowMin >= g_sessionStartMin || nowMin < g_sessionEndMin);
  }

//---- Check if daily limit reached (realized only, gate entry) ----
bool DailyLimitReached()
  {
   if(InpDailyMaxProfit <= 0 && InpDailyMaxLoss <= 0)
      return(false);
   double total = GetDailyPnL() + GetFloatingPnL();
   if(InpDailyMaxLoss > 0 && total <= -InpDailyMaxLoss)
      return(true);
   if(InpDailyMaxProfit > 0 && total >= InpDailyMaxProfit)
      return(true);
   return(false);
  }

//---- Check hedge blocked ----
bool HedgeBlocked(int dir)
  {
   if(InpAllowHedging)
      return(false);
   for(int i = 0; i < ArraySize(g_entries); i++)
     {
      if(g_entries[i].dir == -dir)  // opposite side open
         return(true);
     }
   return(false);
  }

//---- Open positions in a direction ----
int DirectionalExposureCount(int dir)
  {
   int n = 0;
   for(int i = 0; i < ArraySize(g_entries); i++)
      if(g_entries[i].dir == dir && PositionSelectByTicket(g_entries[i].ticket))
         n++;
   return(n);
  }

//---- Position count cap per direction reached? ----
bool MaxPositionsReached(int dir)
  {
   if(InpMaxPositionsPerDir <= 0) return(false);
   return(DirectionalExposureCount(dir) >= InpMaxPositionsPerDir);
  }

//---- Float getters (forward-declared, implemented in Trade.mqh) ----
double GetDailyPnL();
double GetFloatingPnL();
double GetPeriodPnL(datetime from, datetime to);
void   CloseAllAndLogTrades(string reason);
double ComputeRealizedPnl(int idx);

//---- Get HTF MA value (cached per bar, recalculated on new HTF close) ----
double GetHtfMaValue()
  {
   if(!InpHtfMaFilter || InpHtfMaPeriod <= 0)
      return(0.0);

   static datetime lastCalcTime = 0;
   static double   lastMaValue  = 0.0;
   static int      maHandle     = INVALID_HANDLE;

   if(maHandle == INVALID_HANDLE)
      maHandle = iMA(_Symbol, InpHtfTimeframe, InpHtfMaPeriod, 0, InpHtfMaMethod, PRICE_CLOSE);

   // Only recalculate on new HTF bar close
   MqlRates rates[1];
   if(CopyRates(_Symbol, InpHtfTimeframe, 0, 1, rates) != 1)
      return(lastMaValue);

   datetime currentBarTime = rates[0].time;
   if(currentBarTime != lastCalcTime)
     {
      lastCalcTime = currentBarTime;
      double ma[1];
      if(CopyBuffer(maHandle, 0, 0, 1, ma) > 0)
         lastMaValue = ma[0];
     }

   return(lastMaValue);
  }

//---- HTF MA direction gate for entry ----
bool HtfMaBlocksBuy()
  {
   if(!InpHtfMaFilter) return(false);
   double ma = GetHtfMaValue();
   if(ma <= 0) return(false);

   MqlRates rates[1];
   if(CopyRates(_Symbol, InpHtfTimeframe, 0, 1, rates) == 1)
      return(rates[0].close <= ma);  // block BUY if HTF below/at MA
   return(false);
  }

bool HtfMaBlocksSell()
  {
   if(!InpHtfMaFilter) return(false);
   double ma = GetHtfMaValue();
   if(ma <= 0) return(false);

   MqlRates rates[1];
   if(CopyRates(_Symbol, InpHtfTimeframe, 0, 1, rates) == 1)
      return(rates[0].close >= ma);  // block SELL if HTF above/at MA
   return(false);
  }

#endif // AJIPSND_GLOBALS_MQH
