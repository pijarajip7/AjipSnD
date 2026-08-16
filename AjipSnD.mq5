//+------------------------------------------------------------------+
//|                                                      AjipSnD.mq5 |
//|  Supply & Demand EA — zone-based trading on MT5.                 |
//|  HTF zones = retest areas, LTF zones = entry confirmation.        |
//|  Entry: LTF zone confirmed + price inside HTF active zone.        |
//|  Structural SL/TP attached at placement. Exit via broker SL/TP   |
//|  or daily/final/session close-all.                               |
//+------------------------------------------------------------------+
#property copyright   "AjipSMC"
#property link        ""
#property version     "1.05"
#property strict
#property description "AjipSnD — Supply & Demand zone-based EA"

// Bump this with any change that alters backtest output. OnInit prints it, so
// a stale .ex5 is visible in the Experts log instead of being inferred later
// from CSVs that match the previous run.
#define EA_BUILD "2.0-structuralonly"

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
input ulong  InpDeviation    = 10;     // Slippage (points)
input long   InpMagicNumber  = 99002;  // Magic number

input group "Stop Loss & Take Profit"
input double InpZoneSlBufferAtr   = 0.5;   // SL buffer beyond the anchor zone's far edge, in LTF ATR
// off (default): SL beyond the HTF zone's far edge — measured touched ~17%
// of the time vs ~59% for the LTF zone's own edge (median adverse excursion
// from entry, 3293 pts on two 12-month XAUUSD periods, exceeds the LTF
// zone's own width of 1995 pts). on: SL at the LTF zone's own swing instead
// — tighter, and known from that same measurement to get hit far more often.
input bool   InpSlAnchorLtf       = false; // Anchor SL to the LTF zone's own swing instead of the HTF zone's far edge
// VISUAL OBSERVATION ONLY -- see AjipSnD_Zone.mqh's RESULT block on
// MarkLtfValidationContext(). Measured negative (48.00% direction-adjusted
// hit rate at 1d, worst of four cells tested, on period A) before this input
// existed. Wired only so the filtered population can be watched running in
// the Strategy Tester -- not a recommendation to trade it.
// Meaning depends on which trigger is active. Default flow: checked at the
// LTF zone's OWN validation instant (measured negative; visual use only).
// InpHtfTriggeredEntry: checked LIVE at HTF validation time instead, since
// that can be much later — an LTF zone untouched at its own validation could
// still get touched before the HTF search ever looks at it.
input bool   InpRequireNoTouchAtValidation = false; // Entry only if the LTF zone hasn't been touched (visual use only)
// VISUAL OBSERVATION ONLY. Replaces the trigger, not just an added filter:
// off (default) places an order when an LTF zone validates, checking then
// whether an active/validated HTF zone happens to contain it. On, the
// trigger becomes the HTF zone's OWN validation, which searches BACKWARD
// through every LTF zone already validated since the HTF zone's origin bar
// and places an order for every match (InpMaxPositionsPerDir does the
// thinning) -- see PlaceEntriesForHtfValidatedZone() in AjipSnD_Core.mqh.
input bool   InpHtfTriggeredEntry = false; // Trigger entries on HTF validation + backward LTF search, not LTF's own validation (visual use only)
// EXPERIMENTAL, mutually exclusive with the trigger above (takes priority if
// both are on) — a different philosophy again, not a filter on either one.
// HTF stops being a price range to sit inside and becomes a pure directional
// bias: an HTF zone validating only says which side is worth watching. An
// LTF zone matching that side gets SAVED, not traded — it waits for its own
// retest, and only enters once that retest is REJECTED (wick back into the
// zone, closed back out, with a real-bodied bar behind it), as a market
// order rather than a resting limit, since by the time the rejection bar has
// closed price has already moved off the zone edge. Unproven — written
// directly to spec, not measured first.
input bool   InpRejectionEntryMode = false; // Save LTF zones on HTF-bias match, enter only on retest rejection (experimental)
// How strong the rejection bar's body must be, relative to LTF ATR, in the
// favourable direction, to count as a real rejection rather than a wick that
// grazed the zone and drifted back. No prior measurement for this specific
// threshold exists — starting value, not a validated one.
input double InpRejectionBodyAtr   = 0.5;   // Min rejection-bar body/ATR in the favourable direction
// Risk per trade in account currency; lot is derived from it and the stop
// distance. 0 = fall back to InpFixedLot. Default 15 rather than a smaller
// figure because the broker's minimum lot puts a floor under achievable risk:
// with 0.01 min lot and the measured XAUUSD stop distances, a $5 budget is
// unreachable on 64% of trades and the realised average lands near $10
// anyway. At $15 only 19% are floored and the realised average matches the
// target.
input double InpRiskPerTrade      = 15.0;  // Risk per trade ($; 0=use InpFixedLot)
// TP as a multiple of the ACTUAL stop distance just computed (HTF far edge +
// buffer), not an independent ATR figure — the two used to be sized from
// unrelated bases, so the realised reward:risk floated wherever they happened
// to land instead of being enforced. Default 2.0 is this project's own stated
// floor (0=no TP).
input double InpTakeProfitRR      = 2.0;   // TP = this many multiples of the actual SL distance (0=no TP)
// Counts open positions AND resting limit orders in the direction.
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
   PrintFormat("AjipSnD build %s | riskCap=%.2f slAnchor=%s tpRR=%.1f htfTriggeredEntry=%s noTouchFilter=%s rejectionEntry=%s (bodyAtr=%.2f) excursion=%s (%d/%d bars) stopProbe=%s rejectProbe=%s driftProbe=%s (p=%.3f) | %s %s",
               EA_BUILD,
               InpMaxRiskOvershoot,
               InpSlAnchorLtf ? "LTF(tighter,touched~59%)" : "HTF(wider,touched~17%)",
               InpTakeProfitRR,
               InpHtfTriggeredEntry ? "ON(VISUAL-ONLY)" : "off",
               InpRequireNoTouchAtValidation ? "ON(VISUAL-ONLY)" : "off",
               InpRejectionEntryMode ? "ON(EXPERIMENTAL)" : "off",
               InpRejectionBodyAtr,
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

   // Init LTF & HTF
   InitLTFStructure();
   InitHTFStructure();

   // Initial chart draw. Skipped in rejection-entry mode: UpdateHTF never
   // redraws HTF zones in that mode (see its own guard), so an unconditional
   // draw here would leave a one-time, never-cleared, never-updated set of
   // HTF rectangles stuck on the chart for the rest of the run.
   if(InpDrawLines && !InpRejectionEntryMode)
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

   // 1a2. Trend probe — arms on its own timeframe's bar close, so it is checked
   // per tick and self-gates. Observation only; places no orders.
   DriftArmTrend();

   // 1b. Check pending orders — remove if outside HTF zone, detect fills
   CheckPendingOrders();

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

   // 4. Session close-all (gated by news — profit-taking only)
   if(!InNewsBlackout())
      CheckSessionCloseAll();

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

   ObjectsDeleteAll(0, g_objPrefix);
   Print("AjipSnD: EA removed. Reason=", reason);
  }
