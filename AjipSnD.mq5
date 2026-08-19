//+------------------------------------------------------------------+
//|                                                      AjipSnD.mq5 |
//|  Supply & Demand EA — zone-based trading on MT5.                 |
//|  HTF zone validation sets a directional bias, not a price range   |
//|  to currently sit inside — but only LTF zones fully contained     |
//|  inside THAT HTF zone's own range qualify to trade off it. Each   |
//|  gets an immediate resting limit order, fixed lot, at its own     |
//|  midpoint — no rejection wait, no pattern match, no SL/TP at      |
//|  placement. Exit is managed entirely by this EA in points from    |
//|  entry: a loss-side breakeven safety net, a profit-side partial-  |
//|  close + breakeven, then an HTF-ATR trailing stop — or            |
//|  daily/final/session close-all.                                  |
//+------------------------------------------------------------------+
#property copyright   "AjipSMC"
#property link        ""
#property version     "1.05"
#property strict
#property description "AjipSnD — Supply & Demand zone-based EA"

// Bump this with any change that alters backtest output. OnInit prints it, so
// a stale .ex5 is visible in the Experts log instead of being inferred later
// from CSVs that match the previous run.
#define EA_BUILD "6.3-weeklysession"

#include <Trade\Trade.mqh>

//==================================================================
// INPUTS
//==================================================================
input group "Strategy"
input ENUM_TIMEFRAMES InpTimeframe       = PERIOD_M5;   // LTF — entry timeframe
input ENUM_TIMEFRAMES InpHtfTimeframe    = PERIOD_M15;  // HTF — retest zones timeframe
input int              InpCandlesInit    = 100;          // Lookback candles for initial trend
input int              InpMaxZones       = 50;           // Max active zones per type (demand/supply)
input bool             InpRequireZoneValidation = true; // Require HTF zone follow-through before active (LTF always on)
input double           InpMaxZoneWidthAtr = 0;      // Max HTF zone width / ATR to allow entry (0=disabled)
input double           InpMinDispBodyAtr  = 0;      // Min confirming-bar body / ATR to allow entry (0=disabled)
// Backtested across five 2-year windows spanning 2017-2026 (XAUUSD+ M5):
// with the filter on, period=20 beat filter-off on profit factor in all
// five windows and matched or beat period=50/100/200 in four of five —
// the one exception (2025-2026) trails period=50 by a hair. Also cuts max
// drawdown well below filter-off in every window tested.
input bool             InpHtfMaFilter    = false;        // Enable HTF MA direction filter (BUY only above MA, SELL only below)
input int              InpHtfMaPeriod    = 20;           // HTF MA period (only if InpHtfMaFilter=true)
input ENUM_MA_METHOD   InpHtfMaMethod    = MODE_SMA;    // HTF MA method

// Used by InpTradeMode below. Declared here rather than alongside the
// project's other enums in AjipSnD_Globals.mqh because that include happens
// AFTER all inputs — an enum used as an input's type must already be
// declared by the time that input line compiles.
// No "both" option — this EA only ever runs one direction at a time now.
// Deliberate, no neutral default: pick one.
enum ENUM_DIRECTION_MODE
  {
   DIRECTION_BUY_ONLY  = 0,   // BUY only
   DIRECTION_SELL_ONLY = 1    // SELL only
  };

input group "Entry & Trade Sizing"
input ulong  InpDeviation    = 10;     // Slippage (points)
input long   InpMagicNumber  = 99002;  // Magic number
input ENUM_DIRECTION_MODE InpTradeMode = DIRECTION_BUY_ONLY;  // Which direction this EA trades — no "both" mode
// Backtested 2025.08-2026.08 (XAUUSD+ M5): 15 and 30 both beat 0 on every
// metric (return, profit factor, max DD, expectancy) with no tradeoff, and
// are tied with each other — this system's trade cadence rarely produces a
// re-entry inside 30 minutes anyway, so 15 alone captures the effect.
input int    InpCooldownMinutes = 0;  // Block new entries this many minutes after ANY trade closes (0=disabled)
// No risk-based sizing — there is no SL at placement to size a stop
// distance against (see "Exit Management" below), so the FIRST entry in a
// direction always uses this lot regardless of price or zone width
// (InpMartingaleStepPoints below can double it for later entries in the
// same direction). Unvalidated: 0.01 (broker minimum) is the safest
// starting point precisely BECAUSE no per-position stop caps the downside
// — raise it only once the points-based exit thresholds below are tuned
// and trusted.
input double InpFixedLot = 0.01;   // Base lot size — the first entry in a direction, and the martingale floor
// Martingale add-on: this only changes the LOT for a zone-triggered pending
// order — it never creates an entry on its own, entries still come
// exclusively from qualifying LTF zones, exactly as always. Before placing
// a new order, checks how far past the highest (BUY) / lowest (SELL)
// currently OPEN (filled) same-direction position THIS ORDER'S OWN resting
// price sits — not wherever the market happens to be trading right now,
// since a limit order may not fill for a while. Every full
// InpMartingaleStepPoints crossed doubles the lot again (compounding:
// 1 level = 2x, 2 levels = 4x, 3 = 8x...). 0 = disabled, always InpFixedLot.
// Resets naturally once a direction has no open positions left — the next
// entry there is a fresh "first" one, back at InpFixedLot. Unvalidated —
// starting values from the spec, not measured ones.
input double InpMartingaleStepPoints = 1000.0;  // Points past the extreme open position that doubles the next entry's lot (0=disabled)
// Uncapped, this compounds fast — level 10 is already 1024x InpFixedLot —
// and every one of those lots carries no SL. 0 = uncapped, which is a real
// risk, not a placeholder for "no limit needed."
input int    InpMartingaleMaxLevels = 10;  // Cap on how many times the lot can double (0=uncapped)
// Counts open positions in the direction.
input int    InpMaxPositionsPerDir = 500;    // Max positions per direction (0=disabled)

input group "Direction-Wide Profit Target"
// Sum of floating (unrealized) P&L across ALL open positions in ONE
// direction — independent of the points-based per-position exit below,
// and independent of the other direction's own total. Reaching this
// closes every open position in that direction AND cancels every resting
// pending order in that direction too — otherwise a resting BuyLimit
// (likely a bigger martingale lot than what just closed) would just
// reopen exposure on the same side right after the group closed for a
// win. Checked every tick, gated by news same as the account-level
// targets below. 0 = disabled.
input double InpDirectionUnrealizedTarget = 500.0;  // Unrealized P&L ($) per direction that closes that whole direction (0=disabled)

input group "Exit Management (Points-Based)"
// No SL/TP exists at placement (see AjipSnD_PendingEntry.mqh) — every exit
// below is this EA moving the broker-side SL/TP itself, in points from
// entry. Unvalidated thresholds throughout this group — starting values,
// not measured ones.
//
// Loss side: once floating loss reaches this many points, rest a TP at
// breakeven so the position closes there if it ever recovers, rather than
// needing a full profit target after already being this far underwater.
// Does NOT cap the loss — there is still no SL. 0 = disabled, in which case
// a losing position has no exit at all besides the account-level
// daily/final max-loss close-all below (both off by default).
input double InpLossPointsSetTpBe = 0;  // Loss (points) that arms a TP at breakeven (0=disabled)
// Profit side: once floating profit reaches this many points, close a
// slice and move the remainder's SL to breakeven.
input bool   InpPartialCloseEnabled   = false;   // Enable partial close at profit target + SL->breakeven
input double InpPartialClosePoints    = 2000.0;    // Profit (points) that triggers partial close + SL->breakeven
input double InpPartialClosePercent   = 50.0;   // Percent of position volume closed at the profit target
input double InpBreakEvenOffsetPoints = 0;      // Points beyond entry for the BE stop/TP (0=exact entry)
// Trailing only ever arms AFTER the partial close above has fired on that
// position — the remainder is the "runner." Distance/step are in HTF ATR.
input bool   InpTrailingStopEnabled   = false;   // Enable trailing stop on partial-closed remainders
input double InpTrailingStopAtr       = 1.5;    // Trailing distance behind price, in HTF ATR
input double InpTrailingStepAtr       = 0.1;    // Min SL improvement (HTF ATR) before re-modifying the broker

input group "Risk Management — Final"
input double InpFinalProfitTarget = 0.0;  // Overall profit target — close all + stop PERMANENTLY (0=disabled)
input double InpFinalMaxLoss      = 0.0;  // Overall max loss — close all + stop PERMANENTLY (0=disabled)
input double InpStartingBalance   = 0.0;  // Baseline for final target (0=auto-capture on first run)

input group "Risk Management — Daily"
input double InpDailyMaxProfit = 2000.0;   // Daily target — close all + block entries rest of day (0=disabled)
input double InpDailyMaxLoss   = 0.0;  // Daily max loss — close all + block entries rest of day (0=disabled)

input group "Session Filter"
// One session = one week. Outside [start day+time, end day+time]: no new
// entries; if unrealized PnL>0 when the week ends, close all + cancel
// pending (see CheckSessionEndProfitClose). Same day+time on both = no filter.
input double           InpTimezoneOffset   = 7.0;      // UTC offset in hours for the weekly session boundary (e.g., -4=EST, +2=CEST)
input ENUM_DAY_OF_WEEK InpSessionStartDay  = MONDAY;    // Session start day (local time)
input string           InpSessionStartTime = "00:00";  // Session start time HH:MM (local time)
input ENUM_DAY_OF_WEEK InpSessionEndDay    = FRIDAY;    // Session end day (local time)
input string           InpSessionEndTime   = "23:00";  // Session end time HH:MM (local time)

input group "News Filter"
input bool                           InpNewsFilterEnabled = false;                    // Block entries + profit exits around high-impact news
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
input bool InpEnableLog = false;  // Enable Print/PrintFormat output

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
#include "AjipSnD_PendingEntry.mqh"
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
   PrintFormat("AjipSnD build %s | lot=%.2f lossBEpts=%.0f partialPts=%.0f | %s %s",
               EA_BUILD,
               InpFixedLot,
               InpLossPointsSetTpBe,
               InpPartialClosePoints,
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

   // Parse session — weekly window, expressed as minutes since Monday 00:00
   // (see InSession() in AjipSnD_Globals.mqh)
   int sessionStartTimeMin = ParseMinutesFromMidnight(InpSessionStartTime);
   int sessionEndTimeMin   = ParseMinutesFromMidnight(InpSessionEndTime);
   g_sessionFilterEnabled = false;
   if(sessionStartTimeMin >= 0 && sessionEndTimeMin >= 0)
     {
      g_sessionStartWeekMin = MondayRelativeDay(InpSessionStartDay) * 1440 + sessionStartTimeMin;
      g_sessionEndWeekMin   = MondayRelativeDay(InpSessionEndDay)   * 1440 + sessionEndTimeMin;
      g_sessionFilterEnabled = (g_sessionStartWeekMin != g_sessionEndWeekMin);
     }

   // Timezone offset
   g_timezoneOffsetSeconds = (int)(InpTimezoneOffset * 3600);

   // Capture starting balance
   CaptureStartingBalance();

   // ATR handles for zone quality metrics
   g_atrLtfHandle = iATR(_Symbol, InpTimeframe, 14);
   g_atrHtfHandle = iATR(_Symbol, InpHtfTimeframe, 14);

   // HTF MA filter — handle created here (not lazily) so it's ready before
   // the first tick, whether or not the line ends up drawn (DrawHtfMaLine
   // in AjipSnD_Zone.mqh draws it manually as chart objects — ChartIndicatorAdd
   // failed with error 4114 in testing, not worth chasing further).
   if(InpHtfMaFilter && InpHtfMaPeriod > 0)
     {
      g_htfMaHandle = iMA(_Symbol, InpHtfTimeframe, InpHtfMaPeriod, 0, InpHtfMaMethod, PRICE_CLOSE);
      if(g_htfMaHandle == INVALID_HANDLE)
         PrintFormat("AjipSnD: HTF MA handle FAILED on %s period=%d — filter will not block anything",
                     EnumToString(InpHtfTimeframe), InpHtfMaPeriod);
     }

   // Recover tracking for positions from earlier EA run
   RebuildTrackedPositions();

   // Init LTF & HTF, and replay them together chronologically so the EA
   // starts with a real bias / saved LTF zones instead of waiting for the
   // first live HTF validation.
   ReplayInitialStructure();

   Print("══════════════════════════════════════");
   Print("AjipSnD initialized successfully");
   PrintFormat("  LTF=%s, HTF=%s, MaxZones=%d, FixedLot=%.2f",
               EnumToString(InpTimeframe), EnumToString(InpHtfTimeframe),
               InpMaxZones, InpFixedLot);
   PrintFormat("  Session: %s %s - %s %s (%s), Timezone UTC%+.0f",
               EnumToString(InpSessionStartDay), InpSessionStartTime,
               EnumToString(InpSessionEndDay), InpSessionEndTime,
               g_sessionFilterEnabled ? "ENABLED" : "ALL WEEK",
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

   // 1b. Loss-side TP->BE, profit-side partial close -> SL to BE, then
   // trailing stop on runners that already partial-closed. Must run before
   // the target/loss close-all checks below so their PnL gates see the
   // just-updated position state.
   ManagePartialCloseAndTrailing();

   // 1c. Direction-wide unrealized profit target — finer-grained than the
   // account-level targets below, so checked first; gated by news, same
   // convention as other profit-taking closes.
   if(!InNewsBlackout())
      CheckDirectionUnrealizedTarget();

   // 2. Final target check (blocked during news blackout)
   if(!InNewsBlackout())
     {
      CheckFinalTargetCloseAll();
      if(FinalTargetReached())
         return;
     }

   // 2b. Final max loss (NEVER gated — kill switch)
   CheckFinalMaxLossCloseAll();
   if(FinalMaxLossReached())
      return;

   // 3. Daily close-all (target gated by news, max loss NEVER)
   if(!InNewsBlackout())
      CheckDailyTargetCloseAll();
   CheckDailyMaxLossCloseAll();

   // 3b. Session ended in profit -> close all + cancel pending (gated by news)
   if(!InNewsBlackout())
      CheckSessionEndProfitClose();

   //══════════════════════════════════════════════════════════════
   // HTF update (separate bar detection)
   //══════════════════════════════════════════════════════════════
   {
      MqlRates htfRates[];
      int htfCopied = CopyRates(_Symbol, InpHtfTimeframe, 0, 3, htfRates);
      if(htfCopied >= 2)
        {
         ArraySetAsSeries(htfRates, true);
         UpdateHTF(htfRates[1]);
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
   UpdateLTF(ltfRates[1]);

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
   // Release ATR handles
   if(g_atrLtfHandle != INVALID_HANDLE) IndicatorRelease(g_atrLtfHandle);
   if(g_atrHtfHandle != INVALID_HANDLE) IndicatorRelease(g_atrHtfHandle);
   if(g_htfMaHandle  != INVALID_HANDLE) IndicatorRelease(g_htfMaHandle);

   ObjectsDeleteAll(0, g_objPrefix);
   Print("AjipSnD: EA removed. Reason=", reason);
  }
