//+------------------------------------------------------------------+
//|                                                      AjipSnD.mq5 |
//|  Supply & Demand EA — single-timeframe zone-based trading on MT5. |
//|  Every LTF zone that confirms clean (no candidate-phase sweep)    |
//|  and validates is saved and watched, both directions, no bias     |
//|  gate. Entry fires on the FIRST wick back into a saved zone — no  |
//|  rejection pattern required — checked every tick, as a market     |
//|  order with structural SL/TP anchored to the zone's own edge.     |
//|  Exit via broker SL/TP or weekly/final close-all.                 |
//+------------------------------------------------------------------+
#property copyright   "AjipSMC"
#property link        ""
#property version     "1.05"
#property strict
#property description "AjipSnD — Supply & Demand zone-based EA"

// Bump this with any change that alters backtest output. OnInit prints it, so
// a stale .ex5 is visible in the Experts log instead of being inferred later
// from CSVs that match the previous run.
#define EA_BUILD "6.11-weekend-flat"

#include <Trade\Trade.mqh>

//==================================================================
// INPUTS
//==================================================================
input group "Strategy"
input ENUM_TIMEFRAMES InpTimeframe       = PERIOD_M1;   // Entry timeframe — the only one this EA detects zones on
input int              InpCandlesInit    = 500;          // Lookback candles for initial trend
input int              InpMaxZones       = 20;           // Max active zones per type (demand/supply)
input double           InpMaxZoneWidthAtr = 0;      // Max zone width / ATR to allow entry (0=disabled)
input double           InpMinDispBodyAtr  = 0;      // Min confirming-bar body / ATR to allow entry (0=disabled)
// Min/max zone width in POINTS — a REAL entry gate (unlike InpMaxZoneWidthAtr/
// InpMinDispBodyAtr just above, which only feed the diagnostic qualityPass).
// Evaluated at TOUCH time, exactly like favW: a zone whose width (high−low) in
// points falls below the min or at/above the max is skipped (marked used, no
// order) but STAYS drawn on chart — it was already on the watch list. 0 = that
// side disabled.
input double InpMinZoneWidthPoints = 100;  // Min zone width (points) to allow entry (0=disabled)
input double InpMaxZoneWidthPoints = 0.0;  // Max zone width (points) to allow entry (0=disabled)
// favW entry filter — the first real entry gate since the aggressive-only
// rewrite. favW = favorable pre-touch excursion in ZONE WIDTHS: how far price
// ran in the profitable direction after the zone confirmed, before coming back
// to touch it — the same ratio as the chart's "favW~x"/"favW x" runway label
// and the CSV's fav_before_touch_width_ratio column. A saved zone whose FIRST
// touch lands with favW below InpMinFavW or above InpMaxFavW is skipped
// (marked used, no order) — one-shot, consistent with aggressive entry: the
// metric is monotonic (maxFavPts only grows), so a later touch can only be
// further out of range. 0 = that side disabled. The metric is tracked by the
// zone-quality tracker, which now runs whenever this filter is on even if
// InpZoneQualityLog is off (CSV writes still require InpZoneQualityLog).
input double InpMinFavW = 2.0;  // Min favW (zone widths) to allow entry (0=disabled)
input double InpMaxFavW = 0.0; // Max favW (zone widths) to allow entry (0=disabled)

input group "Entry & Trade Sizing"
input bool   InpAllowHedging = true;   // Allow BUY & SELL open simultaneously (false=block opposite)
input ulong  InpDeviation    = 10;     // Slippage (points)
input long   InpMagicNumber  = 99002;  // Magic number
// Backtested 2025.08-2026.08 (XAUUSD+ M5): 15 and 30 both beat 0 on every
// metric (return, profit factor, max DD, expectancy) with no tradeoff, and
// are tied with each other — this system's trade cadence rarely produces a
// re-entry inside 30 minutes anyway, so 15 alone captures the effect.
input int    InpCooldownMinutes = 5;  // Block new entries this many minutes after ANY trade closes (0=disabled)

input group "Stop Loss & Take Profit"
// Entry is always aggressive: the instant a wick first touches a saved
// zone, no rejection pattern required — checked every tick (not just LTF
// bar close), so entry doesn't wait for the current bar to finish. Formerly
// an opt-in mode alongside a wait-for-rejection alternative; made the only
// mode directly, not on measured results.
// SL sits at breakLevel (the zone's own structural edge) minus a buffer of
// this many zone-widths further out — default 2.0, so total SL distance
// from a touch near the zone's near edge comes out to roughly 3x the zone's
// own width (1x crossing the zone itself, 2x the buffer beyond it). Was
// ATR-based; changed to scale with the zone's own size directly instead.
input double InpZoneSlBufferWidthMult = 3.0;   // SL buffer beyond breakLevel, in zone widths
// Risk per trade in account currency; lot is derived from it and the stop
// distance. 0 = sizing disabled, no trades. Default 15 rather than a smaller
// figure because the broker's minimum lot puts a floor under achievable risk:
// with 0.01 min lot and the measured XAUUSD stop distances, a $5 budget is
// unreachable on 64% of trades and the realised average lands near $10
// anyway. At $15 only 19% are floored and the realised average matches the
// target.
input double InpRiskPerTrade      = 1000.0;  // Risk per trade ($; 0=disable sizing, no trades)
// TP as a multiple of the ACTUAL stop distance just computed (the zone's
// own structural edge + buffer), not an independent ATR figure — the two
// used to be sized from unrelated bases, so the realised reward:risk floated
// wherever they happened to land instead of being enforced. Default 2.0 is
// this project's own stated floor (0=no TP).
input double InpTakeProfitRR      = 4.0;   // TP = this many multiples of the actual SL distance (0=no TP)
// The broker's minimum lot puts a hard floor under achievable risk: once the
// stop is wide enough that the budget buys less than volMin, the position can
// only be opened by risking MORE than the budget. This caps how much more.
// Measured on run #4, where the floor was accepted unconditionally: 5.2% of
// trades exceeded the budget and the worst risked $38.26 against $15 — 2.5x.
// 1.25 is not a hard 1.00 because volume-step rounding puts many trades barely
// over the line; at 1.00 it would drop 5.8% of entries, at 1.25 only 3.4%,
// while still capping the observed tail at $18.73. 0 = accept any overshoot,
// which restores the run #4 behaviour for an unbiased measurement pass.
input double InpMaxRiskOvershoot   = 0;  // Max actual risk as a multiple of InpRiskPerTrade (0=no cap)

input group "Trailing Stop & Invalidation TP"
input double InpBreakEvenOffsetPoints = 200;      // Points beyond entry for the BE stop (0=exact entry; used by invalidation TP->BE below)
// Fires once per position: the instant price pushes past the ORIGINATING
// ZONE's own breakLevel (the sweep-aware level that would have marked the
// zone BROKEN before entry) by InpInvalidationBufferZoneWidths zone-widths
// further out, move TP to breakeven. SL is left untouched — this only caps
// the upside once the setup looks like it's failing, on the confirmed
// tradeoff that risk/reward turns asymmetric from that point on rather than
// also tightening the stop or closing outright. The buffer must stay below
// InpZoneSlBufferWidthMult, otherwise this fires at/after the SL and never
// does anything before the position is stopped out.
input bool   InpInvalidationTpBeEnabled = true; // Move TP to breakeven on invalidation: tick-level (breakLevel + buffer) OR bar-close past breakLevel
input double InpInvalidationBufferZoneWidths = 1.0; // Zone widths beyond breakLevel before the position is considered invalid
// If true, the invalidation move sets TP to breakeven AND removes the SL
// (sl=0) instead of leaving the structural stop in place. The downside is then
// handled by the account-level max-loss close-all (weekly/final/batch), NOT by
// a per-position stop — an experiment; if those max-loss inputs are all 0 the
// position has no downside protection after invalidation.
input bool   InpInvalidationRemoveSl = true;   // Also REMOVE the SL on invalidation (let max-loss handle the downside)
// Trailing arms on every open position whenever this is on. Trigger/start/step
// are in ZONE WIDTHS derived from the position's own structural SL distance
// (slDistance = (1 + InpZoneSlBufferWidthMult) x zoneWidth) — see
// UpdateTrailingStop. Once floating profit reaches Trigger zone-widths past
// entry, the SL walks to Start zone-widths behind price and tightens in Step
// zone-width increments as price runs. The new SL is only ever applied once it
// is IN PROFIT (above entry for a BUY, below for a SELL) — a losing stop is
// never tightened.
input bool   InpTrailingStopEnabled = true;   // Enable trailing stop (all open positions; in-profit only)
input double InpTrailingStopTrigger = 4.0;    // Arm trailing once floating profit reaches this many zone widths past entry
input double InpTrailingStopStart   = 2.0;    // Trailing distance behind price, in zone widths
input double InpTrailingStopStep    = 1.0;    // Min SL improvement (zone widths) before re-modifying the broker

input group "Risk Management — Final"
input double InpFinalProfitTarget = 0.0;  // Overall profit target — close all + stop PERMANENTLY (0=disabled)
input double InpFinalMaxLoss      = 0.0;  // Overall max loss — close all + stop PERMANENTLY (0=disabled)
input double InpStartingBalance   = 0.0;  // Baseline for final target (0=auto-capture on first run)

input group "Risk Management — Weekly"
input double InpWeeklyMaxProfit = 0.0;   // Weekly target — close all + block entries rest of week (0=disabled)
input double InpWeeklyMaxLoss   = 30000.0;  // Weekly max loss — close all + block entries rest of week (0=disabled)

input group "Session Filter"
input double InpTimezoneOffset = 4.0;       // UTC offset in hours for daily/weekly boundaries (e.g., -4=EST, +2=CEST)
input ENUM_DAY_OF_WEEK InpSessionStartDay = MONDAY;  // Session start day
input string InpSessionStart   = "12:00";   // Session start HH:MM (local time)
input ENUM_DAY_OF_WEEK InpSessionEndDay   = FRIDAY;  // Session end day
input string InpSessionEnd     = "12:00";   // Session end HH:MM — outside this weekly window: no new entries

input group "Session-End Close (Weekend Flat)"
input bool   InpSessionEndCloseEnabled = true;    // Force flat after session end — no positions over the weekend
input string InpSessionEndPhase1Time  = "20:00";  // Phase 1 ends (HH:MM on session-end day): close all if floating PnL > 0
input string InpSessionEndPhase2Time  = "23:00";  // Phase 2 ends (HH:MM): close all if week PnL + floating > 0; after this force close

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

input group "MA Filter & Display"
input bool InpMaFilterEnabled = false; // Double-MA trend filter: BUY only when fast>slow, SELL only when fast<slow (symmetric)
input bool InpShowMaLines  = true;   // Draw fast/slow SMA lines on chart (display only — not an entry gate by itself)
input int  InpMaFastPeriod = 20;     // Fast SMA period (filter + display)
input int  InpMaSlowPeriod = 100;     // Slow SMA period (filter + display)

input group "Diagnostics"
input bool InpEnableLog = true;  // Enable Print/PrintFormat output
input bool InpZoneQualityLog = true;
// One row per closed position: exit reason the broker actually used, and P&L
// normalised by the risk the trade was sized for (pnl_r), so results are
// comparable across trades regardless of lot size.
input bool InpTradeLog       = false;  // Log per-trade CSV for backtest analysis
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
// orders. The timeframe is deliberately its own input, independent of
// InpTimeframe — the point is to measure a horizon the EA does not
// currently trade.
input bool            InpDriftTrendProbe    = false;      // Also observe an MA-trend probe (measurement only)
input ENUM_TIMEFRAMES InpDriftTrendTf       = PERIOD_H1;  // Timeframe for the trend probe
input int             InpDriftTrendMaPeriod = 50;         // MA period on that timeframe

input group "Multi-Account Orchestrator"
input bool   InpHandoffEnabled = false;                   // Write handoff signal when weekly target/max-loss hit
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
   PrintFormat("AjipSnD build %s | riskCap=%.2f tpRR=%.1f excursion=%s (%d/%d bars) stopProbe=%s rejectProbe=%s driftProbe=%s (p=%.3f) | %s %s",
               EA_BUILD,
               InpMaxRiskOvershoot,
               InpTakeProfitRR,
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

   // Parse session (weekly window: day-of-week + HH:MM -> minute-of-week)
   int sessionStartMin = ParseMinutesFromMidnight(InpSessionStart);
   int sessionEndMin   = ParseMinutesFromMidnight(InpSessionEnd);
   if(sessionStartMin >= 0 && sessionEndMin >= 0)
     {
      g_sessionStartWeekMin = MonIndexOf((int)InpSessionStartDay) * 1440 + sessionStartMin;
      g_sessionEndWeekMin   = MonIndexOf((int)InpSessionEndDay)   * 1440 + sessionEndMin;
     }
   else
     {
      g_sessionStartWeekMin = -1;
      g_sessionEndWeekMin   = -1;
     }
   g_sessionFilterEnabled = (g_sessionStartWeekMin >= 0 && g_sessionEndWeekMin >= 0
                             && g_sessionStartWeekMin != g_sessionEndWeekMin);

   // Session-end close (weekend flat): phase deadlines as minutes after the
   // session end, on the session-end day. Normalized so phase2 >= phase1.
   g_sessionEndCloseEnabled = InpSessionEndCloseEnabled;
   int endDayIdx = MonIndexOf((int)InpSessionEndDay);
   int phase1Min = ParseMinutesFromMidnight(InpSessionEndPhase1Time);
   int phase2Min = ParseMinutesFromMidnight(InpSessionEndPhase2Time);
   g_phase1DeltaMin = (phase1Min >= 0) ? (endDayIdx * 1440 + phase1Min) - g_sessionEndWeekMin : 0;
   g_phase2DeltaMin = (phase2Min >= 0) ? (endDayIdx * 1440 + phase2Min) - g_sessionEndWeekMin : 0;
   if(g_phase1DeltaMin < 0) g_phase1DeltaMin = 0;
   if(g_phase2DeltaMin < g_phase1DeltaMin) g_phase2DeltaMin = g_phase1DeltaMin;

   // Timezone offset
   g_timezoneOffsetSeconds = (int)(InpTimezoneOffset * 3600);

   // Capture starting balance
   CaptureStartingBalance();

   // ATR handle for zone quality metrics
   g_atrLtfHandle = iATR(_Symbol, InpTimeframe, 14);

   // Double-SMA handles — needed by the MA trend filter and/or the chart lines
   if(InpShowMaLines || InpMaFilterEnabled)
     {
      g_maFastHandle = iMA(_Symbol, InpTimeframe, InpMaFastPeriod, 0, MODE_SMA, PRICE_CLOSE);
      g_maSlowHandle = iMA(_Symbol, InpTimeframe, InpMaSlowPeriod, 0, MODE_SMA, PRICE_CLOSE);
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

   // Replay LTF history chronologically so the EA starts with its real zone
   // structure / saved watch list instead of waiting for the first live
   // validation.
   ReplayInitialStructure();

   Print("══════════════════════════════════════");
   Print("AjipSnD initialized successfully");
   PrintFormat("  LTF=%s, MaxZones=%d, RiskPerTrade=%.2f",
               EnumToString(InpTimeframe),
               InpMaxZones, InpRiskPerTrade);
   PrintFormat("  Session: %s %s - %s %s (%s), Timezone UTC%+.0f",
               EnumToString(InpSessionStartDay), InpSessionStart,
               EnumToString(InpSessionEndDay), InpSessionEnd,
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

   // 1b. Trailing stop + invalidation TP->BE on open positions. Must run before
   // the target/loss close-all checks below so their PnL gates see the
   // just-updated position state.
   ManageOpenPositions();

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

   // 3. Weekly close-all (target gated by news, max loss NEVER)
   if(!InNewsBlackout())
      CheckWeeklyTargetCloseAll();
   CheckWeeklyMaxLossCloseAll();

   // 3b. Session-end close (weekend flat) — NEVER gated by news
   CheckSessionEndClose();

   // 3a. Aggressive-mode entries react on the tick itself, not the bar
   // close — placed after the account-level close-all checks above so a
   // target/loss hit this same tick isn't immediately followed by a fresh
   // entry, same ordering the LTF bar-close entry path already respects.
   CheckAggressiveTickEntries();

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

   // Draw diagnostic SMA lines (new bar only — closed-bar MA values are stable)
   if(InpShowMaLines)
      DrawMaLines();
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

   // Release ATR handle
   if(g_atrLtfHandle != INVALID_HANDLE) IndicatorRelease(g_atrLtfHandle);
   if(g_driftTrendMa != INVALID_HANDLE) IndicatorRelease(g_driftTrendMa);
   if(g_maFastHandle != INVALID_HANDLE) IndicatorRelease(g_maFastHandle);
   if(g_maSlowHandle != INVALID_HANDLE) IndicatorRelease(g_maSlowHandle);

   ObjectsDeleteAll(0, g_objPrefix);
   Print("AjipSnD: EA removed. Reason=", reason);
  }
