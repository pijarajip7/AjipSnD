//+------------------------------------------------------------------+
//|                                                      AjipSnD.mq5 |
//|  Supply & Demand EA — single-timeframe zone-based trading on MT5. |
//|  Every LTF zone that confirms clean (no candidate-phase sweep)    |
//|  and validates is saved and watched, both directions, no bias     |
//|  gate. Entry fires on the FIRST wick back into a saved zone — no  |
//|  rejection pattern required — checked every tick, as a market     |
//|  order with structural SL/TP anchored to the zone's own edge.     |
//|  Exit via broker SL/TP or daily/final/session close-all.          |
//+------------------------------------------------------------------+
#property copyright   "AjipSMC"
#property link        ""
#property version     "1.05"
#property strict
#property description "AjipSnD — Supply & Demand zone-based EA"

// Bump this with any change that alters backtest output. OnInit prints it, so
// a stale .ex5 is visible in the Experts log instead of being inferred later
// from CSVs that match the previous run.
#define EA_BUILD "6.3-widthfilter"

#include <Trade\Trade.mqh>

//==================================================================
// INPUTS
//==================================================================
input group "Strategy"
input ENUM_TIMEFRAMES InpTimeframe       = PERIOD_M5;   // Entry timeframe — the only one this EA detects zones on
input int              InpCandlesInit    = 50;          // Lookback candles for initial trend
input int              InpMaxZones       = 10;           // Max active zones per type (demand/supply)
input double           InpMaxZoneWidthAtr = 0;      // Max zone width / ATR to allow entry (0=disabled)
input double           InpMinDispBodyAtr  = 0;      // Min confirming-bar body / ATR to allow entry (0=disabled)
// Min/max zone width in POINTS — a REAL entry gate (unlike InpMaxZoneWidthAtr/
// InpMinDispBodyAtr just above, which only feed the diagnostic qualityPass).
// Evaluated at TOUCH time, exactly like favW: a zone whose width (high−low) in
// points falls below the min or at/above the max is skipped (marked used, no
// order) but STAYS drawn on chart — it was already on the watch list. 0 = that
// side disabled.
input double InpMinZoneWidthPoints = 0;  // Min zone width (points) to allow entry (0=disabled)
input double InpMaxZoneWidthPoints = 0;  // Max zone width (points) to allow entry (0=disabled)
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
input double InpMinFavW = 3;  // Min favW (zone widths) to allow entry (0=disabled)
input double InpMaxFavW = 10; // Max favW (zone widths) to allow entry (0=disabled)

input group "Entry & Trade Sizing"
input bool   InpAllowHedging = false;   // Allow BUY & SELL open simultaneously (false=block opposite)
input ulong  InpDeviation    = 10;     // Slippage (points)
input long   InpMagicNumber  = 99002;  // Magic number
// Backtested 2025.08-2026.08 (XAUUSD+ M5): 15 and 30 both beat 0 on every
// metric (return, profit factor, max DD, expectancy) with no tradeoff, and
// are tied with each other — this system's trade cadence rarely produces a
// re-entry inside 30 minutes anyway, so 15 alone captures the effect.
input int    InpCooldownMinutes = 15;  // Block new entries this many minutes after ANY trade closes (0=disabled)

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
input double InpZoneSlBufferWidthMult = 2.0;   // SL buffer beyond breakLevel, in zone widths
// Risk per trade in account currency; lot is derived from it and the stop
// distance. 0 = sizing disabled, no trades. Default 15 rather than a smaller
// figure because the broker's minimum lot puts a floor under achievable risk:
// with 0.01 min lot and the measured XAUUSD stop distances, a $5 budget is
// unreachable on 64% of trades and the realised average lands near $10
// anyway. At $15 only 19% are floored and the realised average matches the
// target.
input double InpRiskPerTrade      = 50.0;  // Risk per trade ($; 0=disable sizing, no trades)
// TP as a multiple of the ACTUAL stop distance just computed (the zone's
// own structural edge + buffer), not an independent ATR figure — the two
// used to be sized from unrelated bases, so the realised reward:risk floated
// wherever they happened to land instead of being enforced. Default 2.0 is
// this project's own stated floor (0=no TP).
input double InpTakeProfitRR      = 4.0;   // TP = this many multiples of the actual SL distance (0=no TP)
// Counts open positions in the direction.
input int    InpMaxPositionsPerDir = 1;    // Max positions per direction (0=disabled)
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
input double InpBreakEvenOffsetPoints = 0;      // Points beyond entry for the BE stop (0=exact entry; used by invalidation TP->BE below)
// Fires once per position: the instant price pushes past the ORIGINATING
// ZONE's own breakLevel (the sweep-aware level that would have marked the
// zone BROKEN before entry) by InpInvalidationBufferZoneWidths zone-widths
// further out, move TP to breakeven. SL is left untouched — this only caps
// the upside once the setup looks like it's failing, on the confirmed
// tradeoff that risk/reward turns asymmetric from that point on rather than
// also tightening the stop or closing outright. The buffer must stay below
// InpZoneSlBufferWidthMult, otherwise this fires at/after the SL and never
// does anything before the position is stopped out.
input bool   InpInvalidationTpBeEnabled = true; // Move TP to breakeven when price pushes past the entry zone's breakLevel + buffer
input double InpInvalidationBufferZoneWidths = 1.0; // Zone widths beyond breakLevel before the position is considered invalid
// Trailing arms on every open position whenever this is on. Trigger/start/step
// are in ZONE WIDTHS derived from the position's own structural SL distance
// (slDistance = (1 + InpZoneSlBufferWidthMult) x zoneWidth) — see
// UpdateTrailingStop. Once floating profit reaches Trigger zone-widths past
// entry, the SL walks to Start zone-widths behind price and tightens in Step
// zone-width increments as price runs. The new SL is only ever applied once it
// is IN PROFIT (above entry for a BUY, below for a SELL) — a losing stop is
// never tightened.
input bool   InpTrailingStopEnabled = true;   // Enable trailing stop (all open positions; in-profit only)
input double InpTrailingStopTrigger = 2.0;    // Arm trailing once floating profit reaches this many zone widths past entry
input double InpTrailingStopStart   = 1.0;    // Trailing distance behind price, in zone widths
input double InpTrailingStopStep    = 1.0;    // Min SL improvement (zone widths) before re-modifying the broker

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
// orders. The timeframe is deliberately its own input, independent of
// InpTimeframe — the point is to measure a horizon the EA does not
// currently trade.
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

   // Parse session
   g_sessionStartMin = ParseMinutesFromMidnight(InpSessionStart);
   g_sessionEndMin   = ParseMinutesFromMidnight(InpSessionEnd);
   g_sessionFilterEnabled = (g_sessionStartMin >= 0 && g_sessionEndMin >= 0
                             && g_sessionStartMin != g_sessionEndMin);

   // Timezone offset
   g_timezoneOffsetSeconds = (int)(InpTimezoneOffset * 3600);

   // Capture starting balance
   CaptureStartingBalance();

   // ATR handle for zone quality metrics
   g_atrLtfHandle = iATR(_Symbol, InpTimeframe, 14);

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

   // 3. Daily close-all (target gated by news, max loss NEVER)
   if(!InNewsBlackout())
      CheckDailyTargetCloseAll();
   CheckDailyMaxLossCloseAll();

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

   ObjectsDeleteAll(0, g_objPrefix);
   Print("AjipSnD: EA removed. Reason=", reason);
  }
