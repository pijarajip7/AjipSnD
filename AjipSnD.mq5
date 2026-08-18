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
#define EA_BUILD "5.1-htfcontainment"

#include <Trade\Trade.mqh>

//==================================================================
// INPUTS
//==================================================================
input group "Strategy"
input ENUM_TIMEFRAMES InpTimeframe       = PERIOD_M5;   // LTF — entry timeframe
input ENUM_TIMEFRAMES InpHtfTimeframe    = PERIOD_H1;  // HTF — retest zones timeframe
input int              InpCandlesInit    = 50;          // Lookback candles for initial trend
input int              InpMaxZones       = 10;           // Max active zones per type (demand/supply)
input bool             InpRequireZoneValidation = true; // Require HTF zone follow-through before active (LTF always on)
input double           InpMaxZoneWidthAtr = 0;      // Max HTF zone width / ATR to allow entry (0=disabled)
input double           InpMinDispBodyAtr  = 0;      // Min confirming-bar body / ATR to allow entry (0=disabled)
// Backtested across five 2-year windows spanning 2017-2026 (XAUUSD+ M5):
// with the filter on, period=20 beat filter-off on profit factor in all
// five windows and matched or beat period=50/100/200 in four of five —
// the one exception (2025-2026) trails period=50 by a hair. Also cuts max
// drawdown well below filter-off in every window tested.
input bool             InpHtfMaFilter    = true;        // Enable HTF MA direction filter (BUY only above MA, SELL only below)
input int              InpHtfMaPeriod    = 20;           // HTF MA period (only if InpHtfMaFilter=true)
input ENUM_MA_METHOD   InpHtfMaMethod    = MODE_SMA;    // HTF MA method

input group "Entry & Trade Sizing"
input bool   InpAllowHedging = false;   // Allow BUY & SELL open simultaneously (false=block opposite)
input ulong  InpDeviation    = 10;     // Slippage (points)
input long   InpMagicNumber  = 99002;  // Magic number
// Backtested 2025.08-2026.08 (XAUUSD+ M5): 15 and 30 both beat 0 on every
// metric (return, profit factor, max DD, expectancy) with no tradeoff, and
// are tied with each other — this system's trade cadence rarely produces a
// re-entry inside 30 minutes anyway, so 15 alone captures the effect.
input int    InpCooldownMinutes = 15;  // Block new entries this many minutes after ANY trade closes (0=disabled)
// No risk-based sizing — there is no SL at placement to size a stop
// distance against (see "Exit Management" below), so every entry uses the
// same lot regardless of price or zone width. Unvalidated: 0.01 (broker
// minimum) is the safest starting point precisely BECAUSE no per-position
// stop caps the downside — raise it only once the points-based exit
// thresholds below are tuned and trusted.
input double InpFixedLot = 0.01;   // Fixed lot size for every entry
// Counts open positions in the direction.
input int    InpMaxPositionsPerDir = 1;    // Max positions per direction (0=disabled)

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
input double InpLossPointsSetTpBe = 300;  // Loss (points) that arms a TP at breakeven (0=disabled)
// Profit side: once floating profit reaches this many points, close a
// slice and move the remainder's SL to breakeven.
input bool   InpPartialCloseEnabled   = true;   // Enable partial close at profit target + SL->breakeven
input double InpPartialClosePoints    = 300;    // Profit (points) that triggers partial close + SL->breakeven
input double InpPartialClosePercent   = 50.0;   // Percent of position volume closed at the profit target
input double InpBreakEvenOffsetPoints = 0;      // Points beyond entry for the BE stop/TP (0=exact entry)
// Trailing only ever arms AFTER the partial close above has fired on that
// position — the remainder is the "runner." Distance/step are in HTF ATR.
input bool   InpTrailingStopEnabled   = true;   // Enable trailing stop on partial-closed remainders
input double InpTrailingStopAtr       = 1.5;    // Trailing distance behind price, in HTF ATR
input double InpTrailingStepAtr       = 0.1;    // Min SL improvement (HTF ATR) before re-modifying the broker

input group "Risk Management — Final"
input double InpFinalProfitTarget = 0.0;  // Overall profit target — close all + stop PERMANENTLY (0=disabled)
input double InpFinalMaxLoss      = 0.0;  // Overall max loss — close all + stop PERMANENTLY (0=disabled)
input double InpStartingBalance   = 0.0;  // Baseline for final target (0=auto-capture on first run)

input group "Risk Management — Daily"
input double InpDailyMaxProfit = 0.0;   // Daily target — close all + block entries rest of day (0=disabled)
input double InpDailyMaxLoss   = 0.0;  // Daily max loss — close all + block entries rest of day (0=disabled)

input group "Session Filter"
input double InpTimezoneOffset = 7.0;       // UTC offset in hours for daily/weekly boundaries (e.g., -4=EST, +2=CEST)
input string InpSessionStart   = "06:00";   // Session start HH:MM (local time) — start==end = no filter
input string InpSessionEnd     = "00:00";   // Session end HH:MM — outside: no entries; if PnL>0 → close all

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
// One row per closed position: exit reason the broker actually used, and P&L
// normalised by the risk the trade was sized for (pnl_r), so results are
// comparable across trades regardless of lot size.
input bool InpTradeLog       = true;  // Log per-trade CSV for backtest analysis
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
// Arms a REJECT-entry ladder at the same edge and the same four offsets as the
// stop ladder. The difference is timing, not price: STOP fires on the first
// tick that crosses the threshold, mid-bar, with no requirement on how price
// got there. REJECT only fires when the LTF bar that just closed settled past
// it — a wick that stabs through and snaps back before the bar closes does not
// count. Same thresholds, different confirmation rule; that is the whole
// comparison. Requires InpExcursionLog=true. Places no orders.
input bool InpRejectEntryProbe = false; // Also observe rejection-entry variants (measurement only)
// Forward-drift probe: at zone confirmation, does price move in the
// predicted direction over fixed horizons (5m/15m/1h/4h/1d) — no entry, no
// SL/TP, just price at t0 vs t0+h. A random-time baseline is recorded
// through the identical mechanism so the zone population is checkable
// against a null, not asserted against it. See AjipSnD_Drift.mqh.
input bool   InpDriftLog          = false; // Log forward-drift probe (zone confirm vs random baseline)
input double InpDriftBaselineProb = 0.03;  // Per-bar draw probability for the random baseline (0=baseline off)
// Trend probe. Run #9 found the only real directional effect in the data was
// the market's own trend, which is the opposite stance to the zone logic. This
// arms a record on every closed bar of its own timeframe, pointing the way
// price sits relative to a moving average. Requires InpDriftLog=true; places no
// orders. The timeframe is separate from InpHtfTimeframe on purpose — the point
// is to measure a horizon the EA does not currently trade.
input bool            InpDriftTrendProbe    = false;      // Also observe an MA-trend probe (measurement only)
input ENUM_TIMEFRAMES InpDriftTrendTf       = PERIOD_H1;  // Timeframe for the trend probe
input int             InpDriftTrendMaPeriod = 50;         // MA period on that timeframe

input group "Multi-Account Orchestrator"
input bool   InpHandoffEnabled = false;                   // Write handoff signal when daily target/max-loss hit
input string InpHandoffFile    = "AjipSnD_Handoff.csv";   // Written to Common\Files (FILE_COMMON)
input string InpHeartbeatFile  = "AjipSnD_Heartbeat.csv"; // "I'm alive" signal, written ~30s, overwritten each tick

//==================================================================
// INCLUDES
//==================================================================
#include "AjipSnD_Globals.mqh"
#include "AjipSnD_Excursion.mqh"
#include "AjipSnD_Drift.mqh"
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
   PrintFormat("AjipSnD build %s | lot=%.2f lossBEpts=%.0f partialPts=%.0f excursion=%s (%d/%d bars) stopProbe=%s rejectProbe=%s driftProbe=%s (p=%.3f) | %s %s",
               EA_BUILD,
               InpFixedLot,
               InpLossPointsSetTpBe,
               InpPartialClosePoints,
               InpExcursionLog ? "ON" : "off",
               InpExcursionBars, InpExcursionArmBars,
               InpStopEntryProbe ? "ON" : "off",
               InpRejectEntryProbe ? "ON" : "off",
               InpDriftLog ? "ON" : "off",
               InpDriftBaselineProb,
               _Symbol, EnumToString((ENUM_TIMEFRAMES)InpTimeframe));
   PrintFormat("AjipSnD trendProbe=%s tf=%s ma=%d",
               InpDriftTrendProbe ? "ON" : "off",
               EnumToString(InpDriftTrendTf), InpDriftTrendMaPeriod);

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

   // Trend probe MA — its own handle on its own timeframe
   if(InpDriftLog && InpDriftTrendProbe)
     {
      g_driftTrendMa = iMA(_Symbol, InpDriftTrendTf, InpDriftTrendMaPeriod,
                           0, MODE_SMA, PRICE_CLOSE);
      if(g_driftTrendMa == INVALID_HANDLE)
         PrintFormat("AjipSnD: trend probe MA handle FAILED on %s — probe will record nothing",
                     EnumToString(InpDriftTrendTf));
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

   // 1a2. Trend probe — arms on its own timeframe's bar close, so it is checked
   // per tick and self-gates. Observation only; places no orders.
   DriftArmTrend();

   // 1b. Partial close (RR target -> SL to BE) + trailing stop on runners that
   // already partial-closed. Must run before the target/loss close-all checks
   // below so their PnL gates see the just-updated position state.
   ManagePartialCloseAndTrailing();

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
   // Flush zone quality tracker rows that never reached an outcome
   if(InpZoneQualityLog)
      FlushUnresolvedZoneOutcomes();

   // Excursion records still inside their horizon — the tail of the run is
   // otherwise lost, and on a backtest that tail is the final trading day.
   FlushExcursions();

   // Drift probe: same reasoning — partial stamps for in-flight records are
   // still useful rows, not lost data.
   FlushDriftRecords();

   // Release ATR handles
   if(g_atrLtfHandle != INVALID_HANDLE) IndicatorRelease(g_atrLtfHandle);
   if(g_atrHtfHandle != INVALID_HANDLE) IndicatorRelease(g_atrHtfHandle);
   if(g_driftTrendMa != INVALID_HANDLE) IndicatorRelease(g_driftTrendMa);
   if(g_htfMaHandle  != INVALID_HANDLE) IndicatorRelease(g_htfMaHandle);

   ObjectsDeleteAll(0, g_objPrefix);
   Print("AjipSnD: EA removed. Reason=", reason);
  }
