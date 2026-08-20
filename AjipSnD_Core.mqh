#ifndef AJIPSND_CORE_MQH
#define AJIPSND_CORE_MQH

//==================================================================
// CORE — InitStructure, UpdateStructure, OnTick dispatch
//==================================================================

//---- Save a just-validated LTF zone directly onto the rejection watch list —
// no bias gate: every zone that validates, either direction, gets watched.
// Called once, right at the zone's own validation instant (see UpdateLTF) —
// unlike the HTF-bias-gated version this replaces, there is no delay to
// backfill for, so this is a plain append, not a backward search.
//
// preTouched (= g_ltfPendingTouched at validation) filters out zones that
// were already wicked into during their own confirm-to-validate window —
// formed, but touched before ever finishing validation. Backtested (see the
// RESULT block on MarkLtfValidationContext in AjipSnD_Zone.mqh): a zone
// already touched by validation time hits at 56-58% at 5m/15m vs 75%+ for
// one that validated clean, so these are saved already `used=true` and
// `g_ltfZoneDrawFrozen=true` — a record stays in g_savedLtfZones[] (join
// key for the zone CSV etc.), but it never enters the rejection watch AND
// never gets drawn on chart at all: it was never a candidate CheckRejection-
// Retests would have watched, so there is nothing worth showing on chart
// either, unlike a zone that WAS watched for a while and later resolved.
void SaveLtfZoneForWatch(const SnDZone &zone, bool preTouched, datetime asOf)
  {
   int sz = ArraySize(g_savedLtfZones);
   ArrayResize(g_savedLtfZones, sz + 1);
   g_savedLtfZones[sz].high      = zone.high;
   g_savedLtfZones[sz].low       = zone.low;
   g_savedLtfZones[sz].sweepHigh = zone.sweepHigh;
   g_savedLtfZones[sz].sweepLow  = zone.sweepLow;
   g_savedLtfZones[sz].time      = zone.time;
   g_savedLtfZones[sz].isDemand  = zone.isDemand;
   g_savedLtfZones[sz].touched   = preTouched;
   g_savedLtfZones[sz].used      = preTouched;

   ArrayResize(g_ltfZoneDrawEnd, sz + 1);
   g_ltfZoneDrawEnd[sz] = preTouched ? asOf : 0;
   ArrayResize(g_ltfZoneDrawFrozen, sz + 1);
   g_ltfZoneDrawFrozen[sz] = preTouched;

   if(InpEnableLog)
     {
      if(preTouched)
         PrintFormat("AjipSnD: LTF %s zone validated [%.5f, %.5f] — touched before validation, marked used (no rejection watch, not drawn)",
                     zone.isDemand ? "DEMAND" : "SUPPLY", zone.low, zone.high);
      else
         PrintFormat("AjipSnD: LTF %s zone validated [%.5f, %.5f] — saved for rejection watch",
                     zone.isDemand ? "DEMAND" : "SUPPLY", zone.low, zone.high);
     }
  }

//---- Check every saved zone against this closed bar: break, rejection, or
// (InpAggressiveEntry) the first touch itself ----
// A saved zone stays watchable through any number of weak/shallow touches —
// it is NOT one-shot on first contact. It only resolves two ways:
//   1. Structural break — a body CLOSE beyond the zone's far edge (or its
//      sweep level, if it had one at confirmation). Price didn't just
//      retest and fail, it went straight through — the thesis is gone.
//   2. Entry trigger — normally a REJECTION: wick re-enters the zone's
//      range AND this bar's own body is large relative to LTF ATR in the
//      favourable direction AND the close ends back outside the zone. All
//      three together, not just the close-back-out alone (which
//      InpRejectEntryProbe already showed is close to the weakest possible
//      bar of the "wick vs close" definitions this project has tried) — the
//      body requirement is what separates a genuine rejection from a wick
//      that grazed the level and drifted back on no momentum. With
//      InpAggressiveEntry on, the trigger is just the FIRST wick into the
//      zone, full stop — no body/close-back-out requirement at all.
// A touch that is neither a break nor a qualifying trigger resolves nothing
// on its own — the zone is still intact and still worth waiting on — but
// it is recorded (SavedLtfZone.touched) so MarkLtfValidationContext can
// retire it later if a fresher same-direction zone validates first. (Moot
// under InpAggressiveEntry: the first touch always triggers immediately,
// so a zone is never left "touched but still watching" there.)
//
// isReplay (OnInit historical replay) still resolves a zone's fate exactly
// as live does — used=true on a break or a confirmed trigger — but never
// calls OpenMarketWithStructuralStops: by the time OnInit runs, price has
// already moved on from wherever a historical trigger bar closed, so there
// is no legitimate fill left to send at today's market price.
void CheckRejectionRetests(const MqlRates &bar, bool isReplay = false)
  {
   int n = ArraySize(g_savedLtfZones);
   if(n == 0) return;

   double atrLtf = GetAtrValue();
   if(atrLtf <= 0) return;

   double bodyAtr = MathAbs(bar.close - bar.open) / atrLtf;

   for(int i = 0; i < n; i++)
     {
      if(g_savedLtfZones[i].used) continue;
      if(bar.time <= g_savedLtfZones[i].time) continue;   // skip the zone's own confirm bar

      bool   isDemand = g_savedLtfZones[i].isDemand;
      double zLow     = g_savedLtfZones[i].low;
      double zHigh    = g_savedLtfZones[i].high;

      double breakLevel = isDemand
                          ? (g_savedLtfZones[i].sweepLow  > 0 ? g_savedLtfZones[i].sweepLow  : zLow)
                          : (g_savedLtfZones[i].sweepHigh > 0 ? g_savedLtfZones[i].sweepHigh : zHigh);
      bool broken = isDemand ? (bar.close < breakLevel) : (bar.close > breakLevel);
      if(broken)
        {
         g_savedLtfZones[i].used = true;
         g_ltfZoneDrawEnd[i]     = bar.time;
         if(InpEnableLog)
            PrintFormat("AjipSnD: %s zone [%.5f, %.5f] BROKEN (close %.5f past %.5f) — invalidated",
                        isDemand ? "DEMAND" : "SUPPLY", zLow, zHigh, bar.close, breakLevel);
         continue;
        }

      bool wickedIn = isDemand ? (bar.low <= zHigh) : (bar.high >= zLow);
      if(!wickedIn) continue;   // not touched yet, still intact — keep waiting

      bool firstTouch = !g_savedLtfZones[i].touched;

      // Recorded even if this particular touch doesn't resolve anything —
      // MarkLtfValidationContext reads this to retire the zone the moment a
      // fresher same-direction one validates, instead of it lingering
      // touched but never explicitly resolved.
      g_savedLtfZones[i].touched = true;

      bool closedOut  = isDemand ? (bar.close > zHigh) : (bar.close < zLow);
      bool rightColor = isDemand ? IsBullBar(bar) : IsBearBar(bar);
      bool rejected   = closedOut && rightColor && (bodyAtr >= InpRejectionBodyAtr);
      bool triggered  = InpAggressiveEntry ? firstTouch : rejected;
      if(!triggered) continue;   // touched but no trigger yet — still watching

      g_savedLtfZones[i].used = true;
      g_ltfZoneDrawEnd[i]     = bar.time;

      int    dir    = isDemand ? 1 : -1;
      double buffer = InpZoneSlBufferAtr * atrLtf;
      double slPrice;
      if(InpAggressiveEntry)
        {
         // No rejection bar to anchor to — the touching bar can close
         // anywhere, including deep inside the zone, so its own wick is not
         // a reliable stop reference here. Anchored to the zone's own
         // structural edge instead: breakLevel, the same sweep-aware level
         // that decides BROKEN above — the point at which this zone's own
         // thesis is invalidated, not just wherever this one bar happened
         // to reach.
         slPrice = isDemand
                   ? NormalizeDouble(breakLevel - buffer, g_digits)
                   : NormalizeDouble(breakLevel + buffer, g_digits);
        }
      else
        {
         // Anchored to the rejection bar's own extreme, not the zone's
         // static boundary — the wick that just got rejected is the actual
         // proof of where the level held, and can sit shallower or deeper
         // than the zone's edge (wickedIn only requires touching the range,
         // not stopping at zLow/zHigh).
         slPrice = isDemand
                   ? NormalizeDouble(bar.low  - buffer, g_digits)
                   : NormalizeDouble(bar.high + buffer, g_digits);
        }

      if(isReplay)
        {
         if(InpEnableLog)
            PrintFormat("AjipSnD: %s confirmed (init replay) on %s zone [%.5f, %.5f] bodyAtr=%.2f — resolved, no live order",
                        InpAggressiveEntry ? "AGGRESSIVE ENTRY" : "REJECTION",
                        isDemand ? "DEMAND" : "SUPPLY", zLow, zHigh, bodyAtr);
         continue;
        }

      if(InpEnableLog)
         PrintFormat("AjipSnD: %s confirmed on %s zone [%.5f, %.5f] bodyAtr=%.2f — entering %s market",
                     InpAggressiveEntry ? "AGGRESSIVE ENTRY" : "REJECTION",
                     isDemand ? "DEMAND" : "SUPPLY", zLow, zHigh, bodyAtr, dir == 1 ? "BUY" : "SELL");

      if(!EntryGateBlocked(dir))
         OpenMarketWithStructuralStops(dir, slPrice, g_savedLtfZones[i].time);
     }
  }

//---- Update LTF on new closed bar ----
// isReplay=true is the OnInit historical replay (see ReplayInitialStructure):
// it skips CSV/diagnostic writes (UpdateZoneTracking, TrackZone+ZoneCsvWrite,
// the excursion/drift probes) and per-bar chart redraws, since those either
// write to disk or are meaningless replayed against bars that already
// happened — but every core structural/decision step (zone detection,
// validation, touch tracking, superseded-marking, the rejection watch list)
// still runs exactly as it does live, via the SAME code path, so replay ends
// in the same state continuous live operation would have reached.
void UpdateLTF(const MqlRates &bar, bool isReplay = false)
  {
   if(bar.time == g_ltfLastBarTime)
      return;

   g_ltfLastBarTime = bar.time;

   // Quality tracker per-bar stats (excursions, first touch)
   if(InpZoneQualityLog && !isReplay)
      UpdateZoneTracking(bar, false);

   if(!isReplay)
     {
      // Rejection-entry confirmation: the one check that must run on a closed
      // bar rather than a tick — see UpdateExcursionRejects() for why.
      UpdateExcursionRejects(bar);

      // Forward-drift probe: baseline draw + horizon stamping, every bar,
      // independent of whether a zone confirms on it.
      DriftArmBaseline(bar);
      UpdateDriftRecords(bar);
     }

   // Bars g_ltfPendingZone has spent awaiting validation, incremented every
   // bar it stays pending — feeds SnDZone.barsToValidate below. Runs before
   // the validation check so a zone that validates THIS bar still counts it.
   if(g_ltfAwaitingValidation)
      g_ltfPendingBars++;

   // Failed validation-attempt count: a bar that wicks past confirmLevel in
   // the favorable direction without CLOSING past it (that close would BE
   // the validation, so this and "validates this bar" are mutually
   // exclusive) — the same sweep concept ProcessZoneBar already applies to
   // candidate.high/low during candidate formation, just against
   // confirmLevel during this later confirm-to-validate window instead.
   // Also runs before the validation check so this bar counts either way.
   if(g_ltfAwaitingValidation)
     {
      bool sweptConfirmLevel = g_ltfPendingZone.isDemand
                               ? (bar.high > g_ltfPendingZone.confirmLevel && bar.close <= g_ltfPendingZone.confirmLevel)
                               : (bar.low  < g_ltfPendingZone.confirmLevel && bar.close >= g_ltfPendingZone.confirmLevel);
      if(sweptConfirmLevel) g_ltfPendingSweepCount++;
     }

   // Wick re-entry into the currently-pending zone, tracked independently of
   // g_zoneTracker so MarkLtfValidationContext gets an accurate
   // touchedAtValidation whether or not CSV tracking is on. Runs before the
   // validation check below so this same closing bar's own wick counts.
   if(g_ltfAwaitingValidation && !g_ltfPendingTouched)
     {
      bool wickedIntoPending = g_ltfPendingZone.isDemand
                               ? (bar.low <= g_ltfPendingZone.high)
                               : (bar.high >= g_ltfPendingZone.low);
      if(wickedIntoPending) g_ltfPendingTouched = true;
     }

   //---- Follow-through validation (LTF always-on) ----
   if(g_ltfAwaitingValidation)
     {
      bool passed = g_ltfPendingZone.isDemand
                    ? (bar.close > g_ltfPendingZone.confirmLevel)
                    : (bar.close < g_ltfPendingZone.confirmLevel);
      if(passed)
        {
         MarkZoneValidated(false, g_ltfPendingZone.isDemand, g_ltfPendingZone.time);
         MarkLtfValidationContext(g_ltfPendingZone, g_ltfPendingTouched, g_ltfPendingBars, g_ltfPendingSweepCount);
         SaveLtfZoneForWatch(g_ltfPendingZone, g_ltfPendingTouched, bar.time);
         g_ltfAwaitingValidation = false;
        }
     }

   //---- Process this bar for zone confirmation ----
   SnDZone confirmed;
   ZeroMemory(confirmed);
   bool zoneConfirmed = ProcessZoneBar(bar, g_ltfTrend, g_ltfCandidate, confirmed);

   if(zoneConfirmed)
     {
      // Opposite zone formed before validation → pending zone fails (no entry)
      if(g_ltfAwaitingValidation && confirmed.isDemand != g_ltfPendingZone.isDemand)
        {
         if(InpEnableLog)
            PrintFormat("AjipSnD: LTF %s zone validation FAILED — opposite zone formed first",
                        g_ltfPendingZone.isDemand ? "DEMAND" : "SUPPLY");
         LogZoneOutcome("FAILED_OPPOSITE", false, g_ltfPendingZone.isDemand, g_ltfPendingZone.time);
         g_ltfAwaitingValidation = false;
        }

      confirmed.confirmLevel = confirmed.isDemand ? bar.high : bar.low;

      // Metrics + quality gate — before the zone is stored anywhere
      ComputeZoneMetrics(confirmed, false, bar);

      if(!isReplay)
         // Forward-drift probe: arm on every confirmation, gate ignored — the
         // raw zone concept is what is on trial, not our entry filter.
         DriftArmZone(confirmed);

      // Add to zone array (data-only — keeps count/logging consistent)
      if(confirmed.isDemand)
        {
         AddDemandZone(g_ltfDemandZones, confirmed);
         if(InpEnableLog)
            PrintFormat("AjipSnD: LTF DEMAND zone confirmed! [%.5f, %.5f] at %s",
                        confirmed.low, confirmed.high, TimeToString(confirmed.time));
        }
      else
        {
         AddSupplyZone(g_ltfSupplyZones, confirmed);
         if(InpEnableLog)
            PrintFormat("AjipSnD: LTF SUPPLY zone confirmed! [%.5f, %.5f] at %s",
                        confirmed.low, confirmed.high, TimeToString(confirmed.time));
        }

      // Quality tracking: metrics + CONFIRM row (tracker copy carries isHtf=false)
      if(InpZoneQualityLog && !isReplay)
        {
         SnDZone tracked = confirmed;
         TrackZone(tracked, false);
         ZoneCsvWrite("CONFIRM", tracked, "");
        }

      // Hold for follow-through validation
      g_ltfPendingZone = confirmed;
      g_ltfAwaitingValidation = true;
      g_ltfPendingTouched = false;
      g_ltfPendingBars = 0;
      g_ltfPendingSweepCount = 0;
     }

   // Check every saved zone against this closed bar. Redraw is skipped during
   // replay — ReplayInitialStructure draws once at the end instead of
   // redrawing on every historical bar.
   CheckRejectionRetests(bar, isReplay);
   if(!isReplay)
      DrawSavedLtfZones();
  }

//---- Replay LTF bars to seed the EA's initial structure AND the
// rejection-entry watch list — so it starts with the same g_savedLtfZones it
// would have accumulated running continuously through the lookback window,
// instead of sitting with an empty watch list until the first live LTF
// validation.
//
// Reuses UpdateLTF (isReplay=true) rather than a parallel replay path, so
// there is exactly one definition of what a validated LTF zone is — see its
// own comment for what isReplay skips (CSV/diagnostic writes, per-bar chart
// redraws) and what it never skips (zone detection, follow-through
// validation, touch/superseded bookkeeping, the rejection watch list). It
// never places a real order: CheckRejectionRetests still resolves every
// saved zone's fate against the historical bars that follow it, but
// isReplay suppresses the actual market fill, since by the time this runs
// price has already moved on from wherever a historical rejection closed.
void ReplayInitialStructure()
  {
   // start_pos=1 skips the current, still-forming bar — replaying a
   // not-yet-closed bar as if it were final could confirm or invalidate a
   // zone on incomplete data.
   MqlRates ltfRates[];
   int ltfCount = CopyRates(_Symbol, InpTimeframe, 1, InpCandlesInit, ltfRates);
   if(ltfCount < 10)
     {
      PrintFormat("AjipSnD: Init replay — only %d LTF bars copied (need >=10) — skipped, no initial structure", ltfCount);
      return;
     }
   ArraySetAsSeries(ltfRates, true);           // index 0 = newest, for trend determination
   g_ltfTrend = DetermineInitialTrend(ltfRates, ltfCount);
   ZeroMemory(g_ltfCandidate);
   ArraySetAsSeries(ltfRates, false);          // index 0 = oldest, for the forward walk

   PrintFormat("AjipSnD: Init replay — %d LTF bars, LTF trend=%s",
               ltfCount, g_ltfTrend == TREND_DOWN ? "DOWN" : "UP");

   for(int i = 0; i < ltfCount; i++)
      UpdateLTF(ltfRates[i], true);

   PrintFormat("AjipSnD: Init replay complete — %d LTF zone(s) saved and watching",
               ArraySize(g_savedLtfZones));

   if(InpDrawLines)
      DrawSavedLtfZones();
  }

//---- Short timeframe name (strip PERIOD_ prefix) ----
string ShortTF(ENUM_TIMEFRAMES tf)
  {
   string s = EnumToString(tf);
   if(StringFind(s, "PERIOD_") == 0)
      return(StringSubstr(s, 7));
   return(s);
  }

//==================================================================
// PANEL HELPERS — file-scope (MQL5 no nested functions)
//==================================================================
color PnlCol(double v) { return(v > 0 ? clrLimeGreen : (v < 0 ? clrTomato : clrSilver)); }

string LimitTxt(double limitProfit, double limitLoss, double total)
  {
   if(limitProfit > 0 && total >= limitProfit) return("TARGET");
   if(limitLoss   > 0 && total <= -limitLoss) return("MAX LOSS");
   if(limitProfit <= 0 && limitLoss <= 0)     return("disabled");
   return("active");
  }
color LimitCol(string s)
  {
   if(s == "TARGET")   return(clrLimeGreen);
   if(s == "MAX LOSS") return(clrTomato);
   if(s == "disabled") return(clrSilver);
   return(clrLimeGreen);
  }

string SessionTxt()
  {
   if(!g_sessionFilterEnabled) return("all day");
   return(InSession() ? "OPEN" : "CLOSED");
  }
color SessionCol()
  {
   if(!g_sessionFilterEnabled) return(clrSilver);
   return(InSession() ? clrLimeGreen : clrTomato);
  }

string NewsTxt()
  {
   if(!InpNewsFilterEnabled) return("disabled");
   return(InNewsBlackout() ? "BLOCKED" : "clear");
  }
color NewsCol()
  {
   if(!InpNewsFilterEnabled) return(clrSilver);
   return(InNewsBlackout() ? clrTomato : clrLimeGreen);
  }

//---- Draw info panel ----
void DrawPanel()
  {
   if(!InpShowPanel) return;
   
   string prefix = g_objPrefix + "Panel_";
   
   string trendStr = g_ltfTrend == TREND_UP ? "UP" : (g_ltfTrend == TREND_DOWN ? "DOWN" : "NONE");

   const int lineH = 16;
   int y = 0;
   
   // ---- Pre-compute PnL values ----
   double todayPnl  = GetDailyPnL();
   double weekPnl   = GetWeekPnL();
   double monthPnl  = GetMonthPnL();
   double floating  = GetFloatingPnL();
   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   
   // ---- Open MFE/MAE ----
   double openMfe = 0.0, openMae = 0.0;
   int    nOpen   = ArraySize(g_entries);
   for(int i = 0; i < nOpen; i++)
     {
      openMfe += g_entries[i].mfe;
      openMae += g_entries[i].mae;
     }
   
   // ---- Background rectangle ----
   string bgName = prefix + "BG";
   if(ObjectFind(0, bgName) < 0)
     {
      ObjectCreate(0, bgName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, bgName, OBJPROP_CORNER, (int)InpPanelCorner);
      ObjectSetInteger(0, bgName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, bgName, OBJPROP_HIDDEN, true);
     }
   const int totalLines = 19;
   ObjectSetInteger(0, bgName, OBJPROP_XDISTANCE, (int)InpPanelX - 6);
   ObjectSetInteger(0, bgName, OBJPROP_YDISTANCE, (int)InpPanelY - 6);
   ObjectSetInteger(0, bgName, OBJPROP_XSIZE, 185);
   ObjectSetInteger(0, bgName, OBJPROP_YSIZE, lineH * totalLines + 12);
   ObjectSetInteger(0, bgName, OBJPROP_BGCOLOR, clrBlack);
   ObjectSetInteger(0, bgName, OBJPROP_BORDER_COLOR, clrDimGray);
   ObjectSetInteger(0, bgName, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, bgName, OBJPROP_BACK, false);
   
   // ---- Text labels ----
   int corner = (int)InpPanelCorner;
   int idx = 0;
   
   #define PANEL_LABEL(text, color) \
     { \
      string name = prefix + IntegerToString(idx); \
      if(ObjectFind(0, name) < 0) \
        { \
         ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0); \
         ObjectSetInteger(0, name, OBJPROP_CORNER, corner); \
         ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false); \
         ObjectSetInteger(0, name, OBJPROP_HIDDEN, true); \
         ObjectSetString(0, name, OBJPROP_FONT, "Consolas"); \
         ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 9); \
        } \
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, (int)InpPanelX); \
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, (int)InpPanelY + y); \
      ObjectSetString(0, name, OBJPROP_TEXT, text); \
      ObjectSetInteger(0, name, OBJPROP_COLOR, color); \
      y += lineH; \
      idx++; \
     }
   
   // ---- Title + structure ----
   PANEL_LABEL("AjipSnD v1.0", clrWhite);
   PANEL_LABEL("", clrWhite);
   PANEL_LABEL(StringFormat("LTF Trend: %s (%s)", trendStr, ShortTF(InpTimeframe)), clrWhite);
   // "tradeable/total" — zones failing the quality gate still exist as
   // structure but are not offered as entry areas.
   int demTradeable = CountTradeableZones(g_ltfDemandZones);
   int supTradeable = CountTradeableZones(g_ltfSupplyZones);
   PANEL_LABEL(StringFormat("Demands:   %d/%d", demTradeable, ArraySize(g_ltfDemandZones)), clrWhite);
   PANEL_LABEL(StringFormat("Supplies:  %d/%d", supTradeable, ArraySize(g_ltfSupplyZones)), clrWhite);
   PANEL_LABEL(StringFormat("Entries:   %d", nOpen), clrWhite);
   
   // ---- PnL section ----
   PANEL_LABEL("", clrWhite);
   PANEL_LABEL(StringFormat("Today P/L: %.2f", todayPnl + floating), PnlCol(todayPnl + floating));
   PANEL_LABEL(StringFormat("Week P/L:  %.2f", weekPnl  + floating), PnlCol(weekPnl  + floating));
   PANEL_LABEL(StringFormat("Month P/L: %.2f", monthPnl + floating), PnlCol(monthPnl + floating));
   
   // ---- Limit statuses ----
   PANEL_LABEL("", clrWhite);
   string s = LimitTxt(InpFinalProfitTarget, InpFinalMaxLoss, balance - g_startingBalance + floating);
   PANEL_LABEL("Final:     " + s, LimitCol(s));
   s = LimitTxt(InpDailyMaxProfit, InpDailyMaxLoss, todayPnl + floating);
   PANEL_LABEL("Daily:     " + s, LimitCol(s));

   // ---- Session / News ----
   PANEL_LABEL("", clrWhite);
   PANEL_LABEL("Session:   " + SessionTxt(), SessionCol());
   PANEL_LABEL("News:      " + NewsTxt(), NewsCol());
   
   // ---- MFE/MAE ----
   PANEL_LABEL("", clrWhite);
   PANEL_LABEL(StringFormat("Open MFE:  %.2f", openMfe), PnlCol(openMfe));
   PANEL_LABEL(StringFormat("Open MAE:  %.2f", openMae), PnlCol(openMae));
   
   #undef PANEL_LABEL
   
   // Clean up extra labels
   for(int i = idx; i < 30; i++)
     {
      string name = prefix + IntegerToString(i);
      ObjectDelete(0, name);
     }
  }

#endif // AJIPSND_CORE_MQH
