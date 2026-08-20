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
   // How many separate CANDIDATE bars swept — not just whether one did
   // (sweepHigh/sweepLow > 0 already answers that): each bar whose wick
   // crosses candidate.high/low without the close confirming it counts,
   // even if it doesn't set a new sweepHigh/sweepLow extreme.
   int      sweepHighCount;  // bars that swept above candidate.high before confirmation
   int      sweepLowCount;   // bars that swept below candidate.low before confirmation
   double   confirmLevel;// confirming bar's high (demand) / low (supply) — follow-through validation level
   datetime time;        // bar time when zone was confirmed
   bool     isDemand;    // true=demand, false=supply
   int      index;       // index in the active zones array (for reference)
   //--- Quality gate (entry filter) ---
   bool     qualityPass;      // zone width + displacement passed the entry filter
   //--- Quality tracking (CSV backtest analysis) ---
   bool     isHtf;            // tracker key: always false now (single-timeframe EA) —
                               // kept for CSV schema stability, see entryPlaced below
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
   // Bars from the CONFIRM bar to the bar validation actually passed on.
   // Floor is 1, not 0: the confirm bar's own follow-through check already
   // ran (and found nothing pending yet) before this same bar's own
   // confirmation happens, so the earliest possible validation is the very
   // next bar. Counted with an independent incrementing counter
   // (g_ltfPendingBars), not a time delta — a weekend gap between the
   // confirm and validate bars would otherwise inflate the count.
   int      barsToValidate;      // bars from confirmation to validation (1=fastest)
   // Same sweep concept as sweepHighCount/sweepLowCount above, but against
   // confirmLevel during the confirm-to-validate window instead of against
   // candidate.high/low during candidate formation: a bar that wicks past
   // confirmLevel in the favorable direction without CLOSING past it (that
   // close would BE the validation, so this and "validated this bar" are
   // mutually exclusive for a given bar) — a failed validation attempt that
   // didn't kill the zone, just like a candidate sweep doesn't kill the
   // candidate.
   int      validateSweepCount;  // failed validation-attempt bars before actually validating
   int      barsSinceConfirm; // closed bars since confirmation
   int      barsToTouch;      // bars from confirmation to first touch (0=untouched)
   double   touchDepthPts;    // penetration depth of first touch (points)
   double   maxFavPts;        // max favorable excursion from confirmClose (points)
   double   maxAdvPts;        // max adverse excursion from confirmClose (points)
   // Snapshotted from maxFavPts at the exact moment of first touch — how far
   // price ran in the favorable direction before it ever came back to the
   // zone. widthRatio expresses the same distance as a multiple of the
   // zone's own width (high-low), since a 500pt excursion means something
   // different on a 100pt-wide zone than a 2000pt-wide one; 0 if width is 0
   // (ATR was unavailable at confirmation — see ComputeZoneMetrics). Both
   // stay 0 for a zone never touched (touched stays false, same convention
   // as touchDepthPts/barsToTouch).
   double   favBeforeTouchPts;         // max favorable excursion before first touch (points)
   double   favBeforeTouchWidthRatio;  // favBeforeTouchPts / zone width, in the same units
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
   double   initialVolume;   // volume at entry (lot sizing, CSV logging)
   bool     hasStructuralSl; // SL came from the zone at placement
   double   slPrice;         // structural SL price (0=none)
   double   tpPrice;         // structural TP price (0=none)
   double   riskUsd;         // intended risk at entry — denominator for R-multiples
   double   atrLtfAtEntry;   // LTF ATR frozen at entry — stop/target scale
   datetime zoneTime;        // LTF zone that triggered this entry — join key to the zone CSV
   bool     partialClosed;       // RR-triggered partial close + SL->BE already fired (one-shot)
   bool     partialCloseSkipped; // partial slice determined unbrokerable — stop retrying
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
// LTF (entry zones) — the only timeframe this EA detects zones on
SnDZone        g_ltfDemandZones[];
SnDZone        g_ltfSupplyZones[];
ENUM_TREND     g_ltfTrend          = TREND_DOWN;
SnDZone        g_ltfCandidate;
datetime       g_ltfLastBarTime    = 0;

// ---- Zone follow-through validation (always-on) ----
SnDZone        g_ltfPendingZone;              // LTF zone awaiting follow-through validation
bool           g_ltfAwaitingValidation = false;
// Wick re-entry into g_ltfPendingZone's own range since it started waiting,
// tracked independently of g_zoneTracker (InpZoneQualityLog) so
// MarkLtfValidationContext gets an accurate touchedAtValidation even when
// quality tracking is off, or during the OnInit historical replay.
bool           g_ltfPendingTouched = false;
// Bars g_ltfPendingZone has been awaiting validation — feeds
// SnDZone.barsToValidate at the moment validation passes. See that field's
// comment for why this is a counter, not a time delta.
int            g_ltfPendingBars = 0;
// Failed validation-attempt bars since g_ltfPendingZone started waiting —
// feeds SnDZone.validateSweepCount. See that field's comment.
int            g_ltfPendingSweepCount = 0;

// ---- Entry tracking (like AjipIDM) ----
EntryTracker   g_entries[];

// ---- Symbol info cache ----
int            g_digits;
double         g_point;
double         g_volMin, g_volMax, g_volStep;

// ---- ATR handle for zone quality metrics ----
int            g_atrLtfHandle = INVALID_HANDLE;

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

// ---- Cooldown gate — stamped in RemoveEntry() on every confirmed trade
// close (broker SL/TP or a close-all), whichever direction. 0 = no trade
// has closed yet this run.
datetime       g_lastTradeCloseTime = 0;

// ---- Zone quality tracker (live-confirmed zones, CSV backtest log) ----
SnDZone        g_zoneTracker[];

// ---- Rejection-entry mode — the EA's only entry mechanism ----
// Every LTF zone that validates is saved directly onto the watch list, both
// directions, no bias gate — see SaveLtfZoneForWatch() in AjipSnD_Core.mqh.
// A saved zone then waits for ITS OWN retest + rejection (wick back in,
// closed back out, with real momentum) before anything is traded — no zone
// is ever traded straight off its own validation. Unproven — written
// directly to spec, not measured first.
struct SavedLtfZone
  {
   double   high;
   double   low;
   double   sweepHigh;   // carried from the zone's own SnDZone at validation (0=no sweep)
   double   sweepLow;    // same
   datetime time;
   bool     isDemand;
   bool     touched;     // live: any wick has re-entered the range, whether or not it resolved
   bool     used;        // resolved (rejected+traded, structurally broken, or superseded) — stop checking
  };
SavedLtfZone g_savedLtfZones[];

// ---- Drawing-only shadow of g_savedLtfZones, same size, grown in lockstep,
// index-aligned. 0 = zone still live. Non-zero = the bar time it stopped
// being watched (touched+rejected, structurally broken, or superseded) —
// DrawSavedLtfZones reads this to give a resolved zone a correct frozen
// right edge instead of continuing to extend it to "now" forever. Zones are
// never deleted from the chart once drawn, only frozen. Kept separate from
// SavedLtfZone itself so the trading struct stays exactly what it was
// before this existed. ----
datetime g_ltfZoneDrawEnd[];
// true once a zone's rectangle has been (re)drawn with its FINAL frozen end
// time — DrawSavedLtfZones skips these entirely on every later call, since a
// resolved zone's rectangle never changes again. A still-live zone (never
// set true here) keeps getting redrawn every call so its right edge can
// keep extending. Without this, redraw cost would grow with every zone ever
// confirmed, not just the ones still being watched. ----
bool     g_ltfZoneDrawFrozen[];

//==================================================================
// HELPER FUNCTIONS
//==================================================================

//---- Get ATR value (last closed bar) for zone quality metrics ----
double GetAtrValue()
  {
   if(g_atrLtfHandle == INVALID_HANDLE) return(0.0);
   double buf[1];
   if(CopyBuffer(g_atrLtfHandle, 0, 1, 1, buf) != 1) return(0.0);
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

//---- Cooldown gate: any trade close arms it, blocking ALL new entries
// (both directions) until InpCooldownMinutes elapses ----
bool CooldownBlocked()
  {
   if(InpCooldownMinutes <= 0 || g_lastTradeCloseTime <= 0)
      return(false);
   return(TimeCurrent() - g_lastTradeCloseTime < InpCooldownMinutes * 60);
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

#endif // AJIPSND_GLOBALS_MQH
