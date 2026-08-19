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
   //--- Quality tracking metrics — computed by ComputeZoneMetrics; not read
   // back by anything now that the zone-quality CSV writer is gone, kept
   // on the struct rather than trimmed given how widely SnDZone is passed
   // around the zone-detection core ---
   bool     isHtf;            // which timeframe this zone belongs to
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
                               // rewrite; always false.
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
   double   initialVolume;   // volume at entry (fixed lot)
   double   atrLtfAtEntry;   // LTF ATR frozen at entry — stop/target scale
   string   triggerReason;      // always "pendingorder" ("unknown" if recovered across a restart)
   bool     tpBeArmed;           // loss-side TP->BE already armed (one-shot) — see CheckLossRecoveryTp
   bool     partialClosed;       // profit-side partial close + SL->BE already fired (one-shot)
   bool     partialCloseSkipped; // partial slice determined unbrokerable — stop retrying
  };

// Fill info handed from an order-placing function to AddEntry() — what the
// order already knew that the resulting position should inherit.
struct EntryFillInfo
  {
   ulong    ticket;
   int      dir;       // 1=BUY, -1=SELL
   double   price;     // fill price
   double   lot;       // volume actually submitted (InpFixedLot)
   double   atrLtf;    // LTF ATR at placement — carried through to the position
   string   triggerReason; // always "pendingorder"
  };

// See AjipSnD_PendingEntry.mqh — one entry per resting limit order, from
// placement until it either triggers (folds into EntryTracker via AddEntry,
// same as any other fill) or expires/is cancelled.
struct PendingOrderTracker
  {
   ulong    ticket;
   int      dir;       // 1=BUY, -1=SELL
   double   lot;        // InpFixedLot
   datetime zoneTime;   // LTF zone time — join key into g_savedLtfZones (see ZoneStillWatched)
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
// Wick re-entry into g_ltfPendingZone's own range since it started waiting —
// so MarkLtfValidationContext gets an accurate touchedAtValidation even
// during the OnInit historical replay.
bool           g_ltfPendingTouched = false;
SnDZone        g_htfPendingZone;              // HTF zone awaiting follow-through validation
bool           g_htfAwaitingValidation = false;

// ---- Entry tracking (like AjipIDM) ----
EntryTracker   g_entries[];

// ---- Pending-order tracking ----
PendingOrderTracker g_pendingOrders[];

// ---- Symbol info cache ----
int            g_digits;
double         g_point;
double         g_volMin, g_volMax, g_volStep;

// ---- ATR handles for zone quality metrics ----
int            g_atrLtfHandle = INVALID_HANDLE;
int            g_atrHtfHandle = INVALID_HANDLE;

// ---- HTF MA filter handle — created in OnInit; GetHtfMaValue() below and
// DrawHtfMaLine() (AjipSnD_Zone.mqh) both just read it ----
int            g_htfMaHandle = INVALID_HANDLE;

// ---- DrawHtfMaLine's own state (chart-drawing only, no bearing on the
// filter logic above) — the last point drawn, so each new HTF bar close
// only needs one new trend-line segment appended, not a full redraw ----
datetime       g_maLineLastTime  = 0;
double         g_maLineLastValue = 0.0;

// ---- Starting balance for Final target ----
double         g_startingBalance = 0.0;

// ---- Trading session — now a WEEKLY window (e.g. Monday 00:00 through
// Friday 23:00), not a daily one. Both boundaries are stored as minutes
// since Monday 00:00 (0..10079) so InSession() is one wraparound check
// across the whole week instead of juggling day-of-week and time-of-day
// separately. ----
int            g_sessionStartWeekMin  = 0;
int            g_sessionEndWeekMin    = 0;
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

// ---- Entry mechanism — pending-order entry, see AjipSnD_PendingEntry.mqh ----
// g_htfBiasDir itself is just a direction flag, not a price range — it never
// gates entries on whether price is CURRENTLY inside any HTF zone. But which
// LTF zones qualify to save under that bias does still use the specific HTF
// zone's own range: an HTF zone validating sets g_htfBiasDir, and only
// same-direction LTF zones whose own [low, high] sits entirely inside THAT
// HTF zone's [low, high] get saved (see SaveLtfZonesForHtfBias). A saved
// zone gets a resting limit order at its midpoint immediately — no
// rejection wait, no pattern match. Unproven — written directly to spec,
// not measured first.
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
   bool     used;        // resolved (touched, or superseded) — stop checking
  };
SavedLtfZone g_savedLtfZones[];

// ---- Drawing-only shadow of g_savedLtfZones, same size, grown in lockstep,
// index-aligned. 0 = zone still live. Non-zero = the bar time it stopped
// being watched (touched+rejected, broken, or superseded) — DrawSavedLtfZones
// reads this to give an already-used zone a correct frozen right edge even
// when it resolved during OnInit's replay, when no per-bar drawing runs.
// Kept separate from SavedLtfZone itself so the trading struct stays exactly
// what it was before this existed. ----
datetime g_ltfZoneDrawEnd[];

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

//---- Day-of-week (0=Sunday..6=Saturday, same numbering as ENUM_DAY_OF_WEEK
// and MqlDateTime.day_of_week) rebased so the week starts at Monday=0 —
// lets a "day + time" moment collapse into one minutes-since-Monday value ----
int MondayRelativeDay(int dayOfWeek)
  {
   return((dayOfWeek + 6) % 7);
  }

//---- Are we inside the trading session? The session is a WEEKLY window —
// e.g. Monday 00:00 through Friday 23:00 — so both "now" and the two
// boundaries are expressed as minutes since Monday 00:00 (0..10079) and
// compared with the same wraparound shape the old daily version used, just
// on a 7-day modulus instead of a 1-day one. ----
bool InSession()
  {
   if(!g_sessionFilterEnabled)
      return(true);
   // Use local time (server + timezone offset) for session comparison
   datetime localNow = TimeCurrent() + g_timezoneOffsetSeconds;
   MqlDateTime local;
   TimeToStruct(localNow, local);
   int nowWeekMin = MondayRelativeDay(local.day_of_week) * 1440 + local.hour * 60 + local.min;

   if(g_sessionStartWeekMin <= g_sessionEndWeekMin)
      return(nowWeekMin >= g_sessionStartWeekMin && nowWeekMin < g_sessionEndWeekMin);
   else
      return(nowWeekMin >= g_sessionStartWeekMin || nowWeekMin < g_sessionEndWeekMin);
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

//---- Highest (dir=1/BUY) or lowest (dir=-1/SELL) entry price among
// currently open, EA-tracked positions in this direction. 0.0 if none —
// the caller then knows this would be the first position in that
// direction. Used by MartingaleLotForDirection (AjipSnD_PendingEntry.mqh);
// "open position" here means an actual filled position (g_entries), never
// a still-resting pending order (g_pendingOrders isn't consulted).
double ExtremeOpenEntryPrice(int dir)
  {
   double extreme = 0.0;
   for(int i = 0; i < ArraySize(g_entries); i++)
     {
      if(g_entries[i].dir != dir) continue;
      if(!PositionSelectByTicket(g_entries[i].ticket)) continue;   // closed since last check
      if(extreme == 0.0
         || (dir == 1  && g_entries[i].entryPrice > extreme)
         || (dir == -1 && g_entries[i].entryPrice < extreme))
         extreme = g_entries[i].entryPrice;
     }
   return(extreme);
  }

//---- Float getters (forward-declared, implemented in Trade.mqh) ----
double GetDailyPnL();
double GetFloatingPnL();
double GetFloatingPnLByDirection(int dir);
double GetPeriodPnL(datetime from, datetime to);
void   CloseAllAndUntrack(string reason, int dirFilter = 0);
double ComputeRealizedPnl(int idx);

//---- Forward-declared, implemented in AjipSnD_PendingEntry.mqh ----
void   CancelAllPendingOrders();

//---- Get HTF MA value (cached per bar, recalculated on new HTF close) ----
double GetHtfMaValue()
  {
   if(!InpHtfMaFilter || InpHtfMaPeriod <= 0)
      return(0.0);

   static datetime lastCalcTime = 0;
   static double   lastMaValue  = 0.0;

   // Normally already created in OnInit (so it can also be attached to the
   // chart there); this is just a defensive fallback.
   if(g_htfMaHandle == INVALID_HANDLE)
      g_htfMaHandle = iMA(_Symbol, InpHtfTimeframe, InpHtfMaPeriod, 0, InpHtfMaMethod, PRICE_CLOSE);

   // Only recalculate on new HTF bar close
   MqlRates rates[1];
   if(CopyRates(_Symbol, InpHtfTimeframe, 0, 1, rates) != 1)
      return(lastMaValue);

   datetime currentBarTime = rates[0].time;
   if(currentBarTime != lastCalcTime)
     {
      lastCalcTime = currentBarTime;
      double ma[1];
      if(CopyBuffer(g_htfMaHandle, 0, 0, 1, ma) > 0)
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
