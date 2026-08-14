//+------------------------------------------------------------------+
//|                                                      AjipSnD.mq5 |
//|  Supply & Demand EA — zone-based trading on MT5.                 |
//|  HTF zones = retest areas, LTF zones = entry confirmation.        |
//|  Entry: LTF zone confirmed + price inside HTF active zone.        |
//|  No SL/TP at entry. Exit via partial close + batch/daily/final   |
//|  close-all + aggregate SL safety net.                            |
//+------------------------------------------------------------------+
#property copyright   "AjipSMC"
#property link        ""
#property version     "1.00"
#property strict
#property description "AjipSnD — Supply & Demand zone-based EA"

#include <Trade\Trade.mqh>

//==================================================================
// INPUTS
//==================================================================
input group "Strategy"
input ENUM_TIMEFRAMES InpTimeframe       = PERIOD_M1;   // LTF — entry timeframe
input ENUM_TIMEFRAMES InpHtfTimeframe    = PERIOD_M15;  // HTF — retest zones timeframe
input int              InpCandlesInit    = 50;          // Lookback candles for initial trend
input int              InpMaxZones       = 2;           // Max active zones per type (demand/supply)
input int              InpMinZoneGapPoints = 0;        // Min gap (points) to NEWEST opposite HTF zone for entry (0=disabled)
input bool             InpRequireZoneValidation = true; // Require HTF zone follow-through before active (LTF always on)
input double           InpMaxZoneWidthAtr = 1.25;      // Max HTF zone width / ATR to allow entry (0=disabled)
input double           InpMinDispBodyAtr  = 1.00;      // Min confirming-bar body / ATR to allow entry (0=disabled)
input bool             InpHtfMaFilter    = false;       // Enable HTF MA direction filter (BUY only above MA, SELL only below)
input int              InpHtfMaPeriod    = 50;          // HTF MA period (only if InpHtfMaFilter=true)
input ENUM_MA_METHOD   InpHtfMaMethod    = MODE_SMA;    // HTF MA method

input group "Entry & Trade Sizing"
input double InpFixedLot     = 0.02;   // Fixed lot size per entry
input double InpMaxTotalLots = 0.0;    // Max open volume per direction (0=disabled)
input bool   InpAllowHedging = true;   // Allow BUY & SELL open simultaneously (false=block opposite)
input double InpPosMaxLoss   = 0.0;    // Max floating loss per position ($) before setting TP to BE (0=disabled)
input ulong  InpDeviation    = 10;     // Slippage (points)
input long   InpMagicNumber  = 99002;  // Magic number

input group "Risk Management — Final"
input double InpFinalProfitTarget = 0.0;  // Overall profit target — close all + stop PERMANENTLY (0=disabled)
input double InpFinalMaxLoss      = 0.0;  // Overall max loss — close all + stop PERMANENTLY (0=disabled)
input double InpStartingBalance   = 0.0;  // Baseline for final target (0=auto-capture on first run)

input group "Risk Management — Daily"
input double InpDailyMaxProfit = 60.0;   // Daily target — close all + block entries rest of day (0=disabled)
input double InpDailyMaxLoss   = 280.0;  // Daily max loss — close all + block entries rest of day (0=disabled)

input group "Risk Management — Batch"
input double InpBatchMaxProfitAtr    = 1.0;   // Batch target as x HTF ATR frozen at batch start, x current open volume (0=use fixed $)
input double InpBatchMaxProfit       = 20.0;  // Fixed $ batch target — used when InpBatchMaxProfitAtr=0 (0=disabled)
input double InpBatchMaxLoss         = 0.0;   // Batch max loss — close batch only, new entries allowed (0=disabled)
input int    InpBatchCooldownMinutes = 11;     // Cooldown after batch flat before new batch (0=disabled)

input group "Partial Close"
input double InpPartialCloseAtr     = 1.5;   // Partial close target as x HTF ATR frozen at entry (0=use fixed $)
input double InpPartialCloseProfit  = 10.0;  // Fixed floating profit ($) trigger — used when InpPartialCloseAtr=0
input double InpPartialClosePercent = 50.0;  // % of volume to close at partial-close threshold

input group "Trailing Stop"
input int    InpTrailStartPoints    = 0;     // Min profit (points) from entry before trail activates (0=disabled)
input int    InpTrailDistancePoints = 0;     // SL distance (points) behind current price

input group "Session Filter"
input double InpTimezoneOffset = 0.0;       // UTC offset in hours for daily/weekly boundaries (e.g., -4=EST, +2=CEST)
input string InpSessionStart   = "02:00";   // Session start HH:MM (local time) — start==end = no filter
input string InpSessionEnd     = "20:00";   // Session end HH:MM — outside: no entries; if PnL>0 → close all

input group "News Filter"
input bool                           InpNewsFilterEnabled = true;                    // Block entries + profit exits around high-impact news
input ENUM_CALENDAR_EVENT_IMPORTANCE InpNewsMinImportance = CALENDAR_IMPORTANCE_HIGH; // Minimum event importance
input int                            InpNewsMinutesBefore = 30;                       // Minutes before event to start blocking
input int                            InpNewsMinutesAfter  = 30;                       // Minutes after event to keep blocking

input group "Chart Display"
input bool             InpDrawLines   = true;               // Draw zone rectangles on chart
input bool             InpShowPanel   = true;               // Show info panel
input ENUM_BASE_CORNER InpPanelCorner = CORNER_LEFT_UPPER;  // Panel corner
input int              InpPanelX      = 20;                 // Panel X offset
input int              InpPanelY      = 50;                 // Panel Y offset

input group "Diagnostics"
input bool InpEnableLog = true;  // Enable Print/PrintFormat output
input bool InpZoneQualityLog = true;  // Log zone quality metrics to CSV for backtest analysis

input group "Multi-Account Orchestrator"
input bool   InpHandoffEnabled = false;                   // Write handoff signal when daily target/max-loss hit
input string InpHandoffFile    = "AjipSnD_Handoff.csv";   // Written to Common\Files (FILE_COMMON)
input string InpHeartbeatFile  = "AjipSnD_Heartbeat.csv"; // "I'm alive" signal, written ~30s, overwritten each tick

//==================================================================
// INCLUDES
//==================================================================
#include "AjipSnD_Globals.mqh"
#include "AjipSnD_Zone.mqh"
#include "AjipSnD_News.mqh"
#include "AjipSnD_Trade.mqh"
#include "AjipSnD_Entry.mqh"
#include "AjipSnD_Core.mqh"

//==================================================================
// ON INIT
//==================================================================
int OnInit()
  {
   // Cache symbol info
   g_digits   = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_point    = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_volMin   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   g_volMax   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   g_volStep  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   // Configure trade object
   trade.SetDeviationInPoints(InpDeviation);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetExpertMagicNumber(InpMagicNumber);

   // Parse session
   g_sessionStartMin = ParseMinutesFromMidnight(InpSessionStart);
   g_sessionEndMin   = ParseMinutesFromMidnight(InpSessionEnd);
   g_sessionFilterEnabled = (g_sessionStartMin >= 0 && g_sessionEndMin >= 0
                             && g_sessionStartMin != g_sessionEndMin);

   // Timezone offset
   g_timezoneOffsetSeconds = (int)(InpTimezoneOffset * 3600);

   // Capture starting balance
   CaptureStartingBalance();

   // ATR handles for zone quality metrics
   g_atrLtfHandle = iATR(_Symbol, InpTimeframe, 14);
   g_atrHtfHandle = iATR(_Symbol, InpHtfTimeframe, 14);

   // Recover tracking for positions from earlier EA run
   RebuildTrackedPositions();

   // Init LTF & HTF
   InitLTFStructure();
   InitHTFStructure();

   // Initial chart draw
   if(InpDrawLines)
      DrawAllHtfZones();

   Print("══════════════════════════════════════");
   Print("AjipSnD initialized successfully");
   PrintFormat("  LTF=%s, HTF=%s, MaxZones=%d, FixedLot=%.2f",
               EnumToString(InpTimeframe), EnumToString(InpHtfTimeframe),
               InpMaxZones, InpFixedLot);
   PrintFormat("  Session: %s-%s (%s), Timezone UTC%+.0f",
               InpSessionStart, InpSessionEnd,
               g_sessionFilterEnabled ? "ENABLED" : "ALL DAY",
               InpTimezoneOffset);
   Print("══════════════════════════════════════");

   return(INIT_SUCCEEDED);
  }

//==================================================================
// ON TICK
//==================================================================
void OnTick()
  {
   //══════════════════════════════════════════════════════════════
   // Per-tick checks (order matters)
   //══════════════════════════════════════════════════════════════

   // 0. Heartbeat (not gated by new-bar, self-throttled ~30s)
   WriteHeartbeat();

   // 1. Update MFE/MAE
   UpdateMfeMae();

   // 1b. Check pending orders — remove if outside HTF zone, detect fills
   CheckPendingOrders();

   // 1c. Trailing stop for partial-closed (BE) positions
   CheckTrailingStop();

   // 2. Partial close check (skip during news blackout — profit-taking blocked)
   if(!InNewsBlackout())
      CheckPartialClose();

   // 3. Final target check (blocked during news blackout)
   if(!InNewsBlackout())
     {
      CheckFinalTargetCloseAll();
      if(FinalTargetReached())
         return;
     }

   // 3b. Final max loss (NEVER gated — kill switch)
   CheckFinalMaxLossCloseAll();
   if(FinalMaxLossReached())
      return;

   // 4. Batch close-all (target gated by news, max loss NEVER)
   if(!InNewsBlackout())
      CheckBatchTargetCloseAll();
   CheckBatchMaxLossCloseAll();

   // 5. Daily close-all (target gated by news, max loss NEVER)
   if(!InNewsBlackout())
      CheckDailyTargetCloseAll();
   CheckDailyMaxLossCloseAll();

   // 6. Session close-all (gated by news — profit-taking only)
   if(!InNewsBlackout())
      CheckSessionCloseAll();

   // 7. Aggregate SL
   RecalculateAggregateSL();

   //══════════════════════════════════════════════════════════════
   // HTF update (separate bar detection)
   //══════════════════════════════════════════════════════════════
   {
      MqlRates htfRates[];
      int htfCopied = CopyRates(_Symbol, InpHtfTimeframe, 0, 3, htfRates);
      if(htfCopied >= 2)
        {
         ArraySetAsSeries(htfRates, true);
         UpdateHTF(htfRates, htfCopied);
        }
   }

   //══════════════════════════════════════════════════════════════
   // LTF update (new closed bar)
   //══════════════════════════════════════════════════════════════
   MqlRates ltfRates[];
   int ltfCopied = CopyRates(_Symbol, InpTimeframe, 0, 3, ltfRates);
   if(ltfCopied < 2) return;

   ArraySetAsSeries(ltfRates, true);

   // New bar gate
   if(ltfRates[1].time == g_ltfLastBarTime) return;

   // Process the closed bar
   UpdateLTF(ltfRates, ltfCopied);

   // Invalid position check — floating loss outside zone or > InpPosMaxLoss → TP→BE
   // Runs per LTF bar close, not per-tick, to avoid spread/flicker false triggers
   CheckInvalidPositions();

   // Entry cleanup (positions closed outside close-all)
   CheckEntryCleanup();

   // Update panel
   if(InpShowPanel)
      DrawPanel();
  }

//==================================================================
// ON DEINIT
//==================================================================
void OnDeinit(const int reason)
  {
   // Flush zone quality tracker rows that never reached an outcome
   if(InpZoneQualityLog)
      FlushUnresolvedZoneOutcomes();

   // Release ATR handles
   if(g_atrLtfHandle != INVALID_HANDLE) IndicatorRelease(g_atrLtfHandle);
   if(g_atrHtfHandle != INVALID_HANDLE) IndicatorRelease(g_atrHtfHandle);

   ObjectsDeleteAll(0, g_objPrefix);
   Print("AjipSnD: EA removed. Reason=", reason);
  }
