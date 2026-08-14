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
#property version     "1.05"
#property strict
#property description "AjipSnD — Supply & Demand zone-based EA"

// Bump this with any change that alters backtest output. OnInit prints it, so
// a stale .ex5 is visible in the Experts log instead of being inferred later
// from CSVs that match the previous run.
#define EA_BUILD "1.06-stopprobe"

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

input group "Structural Stop Loss (experimental)"
// Master switch. When false every code path added for this mode is skipped and
// behaviour is identical to the batch architecture. The two live side by side
// in one binary so the Strategy Tester can A/B them without recompiling.
input bool   InpStructuralSlMode  = false; // Enable structural SL mode (false=batch architecture, unchanged)
input double InpZoneSlBufferAtr   = 0.5;   // SL buffer beyond the HTF zone's far edge, in LTF ATR
// Risk per trade in account currency; lot is derived from it and the stop
// distance. 0 = fall back to InpFixedLot (same pattern as InpPartialCloseAtr /
// InpBatchMaxProfitAtr). Default 15 rather than a smaller figure because the
// broker's minimum lot puts a floor under achievable risk: with 0.01 min lot and
// the measured XAUUSD stop distances, a $5 budget is unreachable on 64% of
// trades and the realised average lands near $10 anyway. At $15 only 19% are
// floored and the realised average matches the target.
input double InpRiskPerTrade      = 15.0;  // Risk per trade ($, structural mode; 0=use InpFixedLot)
// Target distance in LTF ATR. Deliberately NOT reusing InpBatchMaxProfitAtr:
// that one is scaled by HTF ATR, which measures ~4.1x the LTF ATR, so a value
// of 1.0 there is a ~4.1 LTF-ATR target. Against a stop at the HTF zone's far
// edge, targets of 2.0 LTF ATR and beyond are unreachable — the share of
// entries that ever travel that far (61%) is already below the win rate such a
// reward:risk needs to break even (66%).
input double InpTakeProfitAtr     = 1.0;   // TP distance in LTF ATR (0=no TP)
// Counts open positions AND resting limit orders in the direction. 0 keeps the
// batch architecture's unlimited accumulation; the structural preset sets 1.
// Separate from InpMaxTotalLots, which caps volume — and volume stops mapping
// to a position count the moment lot size varies with stop distance.
input int    InpMaxPositionsPerDir = 0;    // Max positions+pendings per direction (0=disabled)
// The broker's minimum lot puts a hard floor under achievable risk: once the
// stop is wide enough that the budget buys less than volMin, the position can
// only be opened by risking MORE than the budget. This caps how much more.
// Measured on run #4, where the floor was accepted unconditionally: 5.2% of
// trades exceeded the budget and the worst risked $38.26 against $15 — 2.5x.
// 1.25 is not a hard 1.00 because volume-step rounding puts many trades barely
// over the line; at 1.00 it would drop 5.8% of entries, at 1.25 only 3.4%,
// while still capping the observed tail at $18.73. 0 = accept any overshoot,
// which restores the run #4 behaviour for an unbiased measurement pass.
input double InpMaxRiskOvershoot   = 1.25;  // Max actual risk as a multiple of InpRiskPerTrade (0=no cap)

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
input bool InpZoneQualityLog = true;
// One row per closed position. Written in both architectures: the batch CSV
// records why a BATCH closed, which cannot distinguish a stop-out from a target
// hit, and its dollar P&L stops being comparable across trades once lot size
// varies with stop distance. pnl_r is empty in batch mode, where no per-trade
// risk was ever defined.
input bool InpTradeLog       = true;  // Log zone quality metrics to CSV for backtest analysis
// First-touch grid logger. Pure observation — it places no orders and changes
// no decision — but it is the only record that preserves WHICH of two levels
// price reached first, which is what any (SL, TP) pair actually asks. One run
// with this on yields the whole expectancy surface offline, including targets
// the EA never traded. Off by default: it writes a row per opportunity and
// costs a few comparisons per tick.
input bool InpExcursionLog   = false; // Log first-touch grid per entry opportunity (offline SL/TP surface)
input int  InpExcursionBars  = 240;   // Horizon tracked after the limit is touched (M1 bars)
input int  InpExcursionArmBars = 60;  // How long an untouched limit stays armed (M1 bars)
// Arms a STOP-entry ladder alongside the traded limit on every zone: same edge,
// opposite direction of fill, plus 0.25/0.50/1.00 ATR of demanded proof. Costs
// four extra observation records per zone and places no orders. This is the one
// entry axis run #5 could not rank, because only the limit was ever observed.
input bool InpStopEntryProbe = false; // Also observe stop-entry variants (measurement only)

input group "Multi-Account Orchestrator"
input bool   InpHandoffEnabled = false;                   // Write handoff signal when daily target/max-loss hit
input string InpHandoffFile    = "AjipSnD_Handoff.csv";   // Written to Common\Files (FILE_COMMON)
input string InpHeartbeatFile  = "AjipSnD_Heartbeat.csv"; // "I'm alive" signal, written ~30s, overwritten each tick

//==================================================================
// INCLUDES
//==================================================================
#include "AjipSnD_Globals.mqh"
#include "AjipSnD_Excursion.mqh"
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
   // Build banner — always printed, never gated by InpEnableLog.
   // Run #5 was lost to a stale .ex5: the tester silently reran the previous
   // binary, and the only way that surfaced was three CSVs that matched the
   // previous run byte for byte. A version line and the state of the inputs
   // that only exist in newer builds makes a stale binary visible in one
   // glance at the Experts log, before hours of tester time are spent.
   PrintFormat("AjipSnD build %s | structural=%s riskCap=%.2f excursion=%s (%d/%d bars) stopProbe=%s | %s %s",
               EA_BUILD,
               InpStructuralSlMode ? "ON" : "off",
               InpMaxRiskOvershoot,
               InpExcursionLog ? "ON" : "off",
               InpExcursionBars, InpExcursionArmBars,
               InpStopEntryProbe ? "ON" : "off",
               _Symbol, EnumToString((ENUM_TIMEFRAMES)InpTimeframe));

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

   // 1a. First-touch grid (diagnostic only — observes, never decides)
   UpdateExcursions();

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

   // Excursion records still inside their horizon — the tail of the run is
   // otherwise lost, and on a backtest that tail is the final trading day.
   FlushExcursions();

   // Release ATR handles
   if(g_atrLtfHandle != INVALID_HANDLE) IndicatorRelease(g_atrLtfHandle);
   if(g_atrHtfHandle != INVALID_HANDLE) IndicatorRelease(g_atrHtfHandle);

   ObjectsDeleteAll(0, g_objPrefix);
   Print("AjipSnD: EA removed. Reason=", reason);
  }
