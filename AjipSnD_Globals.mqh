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
   datetime time;        // bar time when zone was confirmed
   bool     isDemand;    // true=demand, false=supply
   int      index;       // index in the active zones array (for reference)
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
   bool     partialClosed;  // true once one-time partial close fired
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

// ---- Entry tracking (like AjipIDM) ----
EntryTracker   g_entries[];

// ---- Batch report accumulator ----
bool           g_batchActive         = false;
datetime       g_batchFirstEntryTime = 0;
datetime       g_batchLastEntryTime  = 0;
int            g_batchCount          = 0;
int            g_batchWins           = 0;
int            g_batchLosses         = 0;
int            g_batchBreakEven      = 0;
double         g_batchRealizedPnl    = 0.0;
double         g_batchMfeSum         = 0.0;
double         g_batchMaeSum         = 0.0;
datetime       g_lastBatchEndTime    = 0;

// ---- Symbol info cache ----
int            g_digits;
double         g_point;
double         g_volMin, g_volMax, g_volStep;

// ---- Starting balance for Final target ----
double         g_startingBalance = 0.0;

// ---- Trading session ----
int            g_sessionStartMin      = 0;
int            g_sessionEndMin        = 0;
bool           g_sessionFilterEnabled = false;

// ---- One-shot entry per zone ----
datetime       g_ltfZoneEntryFiredTime = 0;  // last LTF zone time that triggered entry

//==================================================================
// HELPER FUNCTIONS
//==================================================================

//---- Classify limit status (generic, reused for daily + batch) ----
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
   MqlDateTime srv;
   TimeCurrent(srv);
   int nowMin = srv.hour * 60 + srv.min;
   
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

//---- Max total lots reached per direction ----
bool MaxTotalLotsReached(int dir)
  {
   if(InpMaxTotalLots <= 0)
      return(false);
   double total = 0;
   for(int i = ArraySize(g_entries) - 1; i >= 0; i--)
     {
      if(g_entries[i].dir == dir)
        {
         if(!PositionSelectByTicket(g_entries[i].ticket))
           {
            // Stale entry — position closed outside tracking
            ArrayRemove(g_entries, i, 1);
            continue;
           }
         total += PositionGetDouble(POSITION_VOLUME);
        }
     }
   return(total + InpFixedLot > InpMaxTotalLots);
  }

//---- Batch cooldown active? ----
bool BatchCooldownActive()
  {
   if(InpBatchCooldownMinutes <= 0 || g_lastBatchEndTime == 0)
      return(false);
   return(TimeCurrent() < g_lastBatchEndTime + InpBatchCooldownMinutes * 60);
  }

//---- Float getters (forward-declared, implemented in Trade.mqh) ----
double GetDailyPnL();
double GetFloatingPnL();
double GetPeriodPnL(datetime from, datetime to);
void   CloseAllAndFlushBatch(string reason);
void   AccumulateBatchStats(int idx);
void   FlushBatchCSV(string reason);

#endif // AJIPSND_GLOBALS_MQH
