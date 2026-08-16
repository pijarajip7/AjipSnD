#ifndef AJIPSND_CORE_MQH
#define AJIPSND_CORE_MQH

//==================================================================
// CORE — InitStructure, UpdateStructure, OnTick dispatch
//==================================================================

//---- Init LTF structure: fetch bars, find initial trend, replay ----
void InitLTFStructure()
  {
   MqlRates rates[];
   int copied = CopyRates(_Symbol, InpTimeframe, 0, InpCandlesInit, rates);
   if(copied < InpCandlesInit)
     {
      PrintFormat("AjipSnD: Init LTF — only %d bars copied (need %d)", copied, InpCandlesInit);
      if(copied < 10) return;
     }
   ArraySetAsSeries(rates, true);

   int count = MathMin(copied, InpCandlesInit);

   // Determine initial trend
   g_ltfTrend = DetermineInitialTrend(rates, count);
   ZeroMemory(g_ltfCandidate);

   PrintFormat("AjipSnD: LTF Init — %d bars, trend=%s", count,
               g_ltfTrend == TREND_DOWN ? "DOWN" : "UP");

   // Replay bars from oldest to newest to build initial zones
   ArraySetAsSeries(rates, false); // oldest first
   for(int i = 0; i < count; i++)
     {
      SnDZone confirmed;
      ZeroMemory(confirmed);
      if(ProcessZoneBar(rates[i], g_ltfTrend, g_ltfCandidate, confirmed))
        {
         // Replay zones are gated too, so the filter also applies right after
         // start. ATR here is the current reading rather than the one at this
         // historical bar — an approximation, but these seed zones are
         // short-lived and are replaced by live-measured ones.
         ComputeZoneMetrics(confirmed, false, rates[i]);

         if(confirmed.isDemand)
            AddDemandZone(g_ltfDemandZones, confirmed);
         else
            AddSupplyZone(g_ltfSupplyZones, confirmed);
         // Candidate seeded by ProcessZoneBar
        }
     }

   PrintFormat("AjipSnD: LTF zones after init — demands=%d supplies=%d",
               ArraySize(g_ltfDemandZones), ArraySize(g_ltfSupplyZones));

   // Set last bar time
   if(count > 0)
     {
      ArraySetAsSeries(rates, true);
      g_ltfLastBarTime = rates[1].time; // second-to-last (latest closed)
     }
  }

//---- Init HTF structure ----
void InitHTFStructure()
  {
   MqlRates rates[];
   int copied = CopyRates(_Symbol, InpHtfTimeframe, 0, InpCandlesInit, rates);
   if(copied < InpCandlesInit)
     {
      PrintFormat("AjipSnD: Init HTF — only %d bars copied (need %d)", copied, InpCandlesInit);
      if(copied < 10) return;
     }
   ArraySetAsSeries(rates, true);

   int count = MathMin(copied, InpCandlesInit);

   g_htfTrend = DetermineInitialTrend(rates, count);
   ZeroMemory(g_htfCandidate);

   PrintFormat("AjipSnD: HTF Init — %d bars, trend=%s", count,
               g_htfTrend == TREND_DOWN ? "DOWN" : "UP");

   ArraySetAsSeries(rates, false);
   for(int i = 0; i < count; i++)
     {
      SnDZone confirmed;
      ZeroMemory(confirmed);
      if(ProcessZoneBar(rates[i], g_htfTrend, g_htfCandidate, confirmed))
        {
         // Same approximation as the LTF replay above
         ComputeZoneMetrics(confirmed, true, rates[i]);

         if(confirmed.isDemand)
            AddDemandZone(g_htfDemandZones, confirmed);
         else
            AddSupplyZone(g_htfSupplyZones, confirmed);
         // Candidate seeded by ProcessZoneBar
        }

      // Invalidate zones broken by this bar (same logic as live HTF update)
      InvalidateHtfZones(rates[i]);
     }

   PrintFormat("AjipSnD: HTF zones after init — demands=%d supplies=%d",
               ArraySize(g_htfDemandZones), ArraySize(g_htfSupplyZones));

   // Clean up zones already broken by later bars during replay
   ArraySetAsSeries(rates, true);
   if(count >= 2)
      InvalidateHtfZones(rates[1]);  // last closed HTF bar

   if(count > 0)
     {
      g_htfLastBarTime = rates[1].time;
     }
  }

//---- Place entry for a validated LTF zone (follow-through passed) ----
bool PlaceEntryForZone(const SnDZone &confirmed)
  {
   double limitPrice;
   int    dir;
   if(confirmed.isDemand)
     {
      limitPrice = confirmed.high;  // BUY LIMIT at demand.high
      dir = 1;
     }
   else
     {
      limitPrice = confirmed.low;   // SELL LIMIT at supply.low
      dir = -1;
     }

   // Limit price must sit inside an active (validated) HTF zone
   int htfIdx = confirmed.isDemand
                ? FindContainingZoneIdx(limitPrice, g_htfDemandZones, true)
                : FindContainingZoneIdx(limitPrice, g_htfSupplyZones, false);
   if(htfIdx < 0) return(false);

   // VISUAL OBSERVATION ONLY — see AjipSnD_Zone.mqh's RESULT block on
   // MarkLtfValidationContext(). Measured negative (48.00% direction-adjusted
   // hit rate at 1d, the only one of four cells below 50%) before this gate
   // existed; wired here only so the filtered population can be watched in
   // the Strategy Tester, not because the data supports trading it live.
   if(InpRequireNoTouchAtValidation)
     {
      int ti = FindTrackedZone(false, confirmed.isDemand, confirmed.time);
      if(ti < 0 || g_zoneTracker[ti].touchedAtValidation)
         return(false);
     }

   // ---- Structural SL: beyond the far edge of the HTF zone being retested ----
   // The LTF zone is only the trigger; the HTF zone is the thesis. Anchoring to
   // the LTF zone's far edge puts the stop inside ordinary noise — measured on
   // two 12-month XAUUSD periods, the median adverse excursion from entry
   // (3293 pts) exceeds the LTF zone's own width (1995 pts), so that stop is
   // touched ~59% of the time versus ~17% for the HTF anchor.
   double slPrice = 0.0;
   double tpPrice = 0.0;
   double atrLtf = GetAtrValue(false);
   if(atrLtf <= 0)
     {
      Print("AjipSnD: LTF ATR unavailable — structural SL cannot be sized, entry skipped");
      return(false);
     }
   double buffer = InpZoneSlBufferAtr * atrLtf;
   if(InpSlAnchorLtf)
      slPrice = confirmed.isDemand
                ? NormalizeDouble(confirmed.low  - buffer, g_digits)
                : NormalizeDouble(confirmed.high + buffer, g_digits);
   else
      slPrice = confirmed.isDemand
                ? NormalizeDouble(g_htfDemandZones[htfIdx].low  - buffer, g_digits)
                : NormalizeDouble(g_htfSupplyZones[htfIdx].high + buffer, g_digits);

   // Target derived from the ACTUAL stop distance, not an independent ATR
   // multiple, so the realised reward:risk is enforced rather than merely
   // aimed for.
   if(InpTakeProfitRR > 0)
     {
      double riskDist = MathAbs(limitPrice - slPrice);
      double reach = InpTakeProfitRR * riskDist;
      tpPrice = confirmed.isDemand
                ? NormalizeDouble(limitPrice + reach, g_digits)
                : NormalizeDouble(limitPrice - reach, g_digits);
     }

   // One-shot per LTF zone
   if(confirmed.time == g_ltfZonePendingTime) return(false);

   // Trigger label, not just a zone description: this function is now called
   // from two different causes, and a log line that always says "LTF zone
   // VALIDATED" regardless of which one fired is exactly what makes the two
   // paths visually indistinguishable in the Experts log — the LTF zone did
   // validate at some point either way, so that phrase alone proves nothing
   // about WHEN this order was actually decided.
   PrintFormat("AjipSnD: [%s] %s zone VALIDATED — placing %s LIMIT at %.5f (SL %.5f, TP %.5f)",
               InpHtfTriggeredEntry ? "HTF-TRIGGERED, backward LTF search" : "LTF's own validation",
               confirmed.isDemand ? "DEMAND" : "SUPPLY",
               dir == 1 ? "BUY" : "SELL", limitPrice, slPrice, tpPrice);

   // Evaluated once and reused so the excursion record carries the same verdict
   // the order path acts on. The && keeps the original short-circuit: the gate
   // is only consulted when the gap check passed, so its logging is unchanged.
   bool gapBlocked  = ZoneGapBlocked(confirmed);
   bool gateBlocked = (!gapBlocked) && EntryGateBlocked(dir);

   // Armed before the gates deliberately — a setup the cap or the session
   // filter rejected is still an observation about where price goes next, and
   // the surface is only decoupled from the exit policy if those are kept.
   ExcursionArm(dir, limitPrice, confirmed.time,
                confirmed.isDemand ? g_htfDemandZones[htfIdx].time
                                   : g_htfSupplyZones[htfIdx].time,
                slPrice, gapBlocked, gateBlocked, MaxPositionsReached(dir));

   if(!gapBlocked && !gateBlocked)
     {
      ulong ticket = PlacePendingOrder(dir, limitPrice, confirmed.time, slPrice, tpPrice);

      // Latch the zone either way: a setup rejected by the risk cap, the broker's
      // volume range or a failed send would be re-evaluated identically on the
      // next tick, so retrying only floods the log. The return value reports
      // whether an order actually exists — that is what feeds entry_placed in the
      // zone CSV, and it used to read 1 for orders that were never sent.
      g_ltfZonePendingTime = confirmed.time;
      return(ticket > 0);
     }
   return(false);
  }

//---- HTF-triggered entry (InpHtfTriggeredEntry, visual observation only) ---
// Different trigger from the default flow above, not just an extra filter on
// top of it: the default places an order when an LTF zone VALIDATES,
// checking at that instant whether an active/validated HTF zone happens to
// contain it — so an LTF zone that validates before its HTF context exists
// never qualifies. This instead fires when the HTF zone validates, and
// searches BACKWARD through every LTF zone that has already validated since
// the HTF zone's own origin bar — so the temporal order is reversed, and an
// LTF zone that validated first is exactly the normal case, not an edge case.
//
// Every match gets an order — the user's call, not a quality filter: several
// LTF zones can sit inside one HTF zone, and MaxPositionsReached (via
// InpMaxPositionsPerDir) is what thins them, the same cap that already
// governs the default flow.
void PlaceEntriesForHtfValidatedZone(const SnDZone &htfZone)
  {
   int n = ArraySize(g_ltfValidatedHistory);
   if(InpEnableLog)
      PrintFormat("AjipSnD: >>> HTF %s zone VALIDATED [%.5f, %.5f] at %s — searching %d LTF zone(s) validated since then",
                  htfZone.isDemand ? "DEMAND" : "SUPPLY", htfZone.low, htfZone.high,
                  TimeToString(htfZone.time, TIME_DATE | TIME_MINUTES), n);
   int matches = 0;
   for(int i = 0; i < n; i++)
     {
      if(g_ltfValidatedHistory[i].isDemand != htfZone.isDemand) continue;
      if(g_ltfValidatedHistory[i].time < htfZone.time) continue;      // must postdate the HTF zone's own origin
      // touchedEver, not touchedAtValidation: this search runs at HTF
      // validation time, which is later than the LTF zone's own validation —
      // checking the frozen at-validation snapshot would miss a touch that
      // happened in between. touchedEver is a strict superset (anything true
      // at validation is already true here), so this alone covers both.
      if(InpRequireNoTouchAtValidation && g_ltfValidatedHistory[i].touchedEver) continue;

      double limitPrice = htfZone.isDemand ? g_ltfValidatedHistory[i].high
                                            : g_ltfValidatedHistory[i].low;
      if(limitPrice < htfZone.low || limitPrice > htfZone.high) continue;  // inside the HTF box

      SnDZone ltf;
      ZeroMemory(ltf);
      ltf.isDemand = g_ltfValidatedHistory[i].isDemand;
      ltf.high     = g_ltfValidatedHistory[i].high;
      ltf.low      = g_ltfValidatedHistory[i].low;
      ltf.time     = g_ltfValidatedHistory[i].time;
      matches++;
      PlaceEntryForZone(ltf);
     }
   if(InpEnableLog && matches == 0)
      PrintFormat("AjipSnD: >>> HTF %s zone VALIDATED at %s — no qualifying LTF zone found",
                  htfZone.isDemand ? "DEMAND" : "SUPPLY", TimeToString(htfZone.time, TIME_DATE | TIME_MINUTES));
  }

//---- Rejection-entry mode (InpRejectionEntryMode, experimental) ----------
//---- Save every matching LTF zone since the HTF zone's own origin bar ----
// Triggered by HTF VALIDATION, not by the LTF zone's own validation instant
// — an on-tick save (checking bias only at the moment the LTF zone itself
// validates) misses every LTF zone that validated before the HTF bias
// caught up to it, which on this project's own prior evidence is the common
// case, not the edge case (see PlaceEntriesForHtfValidatedZone's identical
// reasoning for InpHtfTriggeredEntry). Replays g_ltfValidatedHistory[] —
// already populated unconditionally for every validated LTF zone — back to
// the HTF zone's own origin bar, same boundary PlaceEntriesForHtfValidatedZone
// uses. The dedup check guards a case that shouldn't arise given HTF zones
// strictly alternate direction at confirmation (so two same-direction
// validations can't share overlapping origins) — cheap insurance, not a
// known bug.
void SaveLtfZonesForHtfBias(const SnDZone &htfZone)
  {
   int n = ArraySize(g_ltfValidatedHistory);
   int candidates = 0;   // matched direction + postdates the HTF zone's origin
   int matches    = 0;   // of those, newly saved (not already saved)
   for(int i = 0; i < n; i++)
     {
      if(g_ltfValidatedHistory[i].isDemand != htfZone.isDemand) continue;
      if(g_ltfValidatedHistory[i].time < htfZone.time) continue;
      // Already touched by the time a newer same-direction zone validated —
      // stale, the market has moved on. See MarkLtfValidationContext.
      if(g_ltfValidatedHistory[i].superseded) continue;
      candidates++;

      bool already = false;
      for(int j = 0; j < ArraySize(g_savedLtfZones); j++)
        {
         if(g_savedLtfZones[j].time == g_ltfValidatedHistory[i].time
            && g_savedLtfZones[j].isDemand == g_ltfValidatedHistory[i].isDemand)
           {
            already = true;
            break;
           }
        }
      if(already) continue;

      // Retiring touched-then-superseded g_savedLtfZones entries now happens
      // in MarkLtfValidationContext instead — at LTF validation, the moment
      // this rule's trigger condition is actually met, rather than deferred
      // to whenever the next HTF validation happens to call this function.

      int sz = ArraySize(g_savedLtfZones);
      ArrayResize(g_savedLtfZones, sz + 1);
      g_savedLtfZones[sz].high      = g_ltfValidatedHistory[i].high;
      g_savedLtfZones[sz].low       = g_ltfValidatedHistory[i].low;
      g_savedLtfZones[sz].sweepHigh = g_ltfValidatedHistory[i].sweepHigh;
      g_savedLtfZones[sz].sweepLow  = g_ltfValidatedHistory[i].sweepLow;
      g_savedLtfZones[sz].time      = g_ltfValidatedHistory[i].time;
      g_savedLtfZones[sz].isDemand  = g_ltfValidatedHistory[i].isDemand;
      g_savedLtfZones[sz].touched   = false;
      g_savedLtfZones[sz].used      = false;
      matches++;
     }

   if(InpEnableLog)
      PrintFormat("AjipSnD: HTF bias -> %s — %d LTF zone(s) matched since %s, saved %d for rejection watch",
                  htfZone.isDemand ? "DEMAND" : "SUPPLY", candidates,
                  TimeToString(htfZone.time, TIME_DATE | TIME_MINUTES), matches);
  }

//---- Check every saved zone against this closed bar: break, or rejection ----
// A saved zone stays watchable through any number of weak/shallow touches —
// it is NOT one-shot on first contact. It only resolves two ways:
//   1. Structural break — a body CLOSE beyond the zone's far edge (or its
//      sweep level, if it had one at confirmation), exactly the rule
//      InvalidateHtfZones already uses for HTF zones. Price didn't just
//      retest and fail, it went straight through — the thesis is gone.
//   2. Rejection — wick re-enters the zone's range AND this bar's own body
//      is large relative to LTF ATR in the favourable direction AND the
//      close ends back outside the zone. All three together, not just the
//      close-back-out alone (which InpRejectEntryProbe already showed is
//      close to the weakest possible bar of the "wick vs close" definitions
//      this project has tried) — the body requirement is what separates a
//      genuine rejection from a wick that grazed the level and drifted back
//      on no momentum.
// A touch that is neither a break nor a qualifying rejection resolves
// nothing on its own — the zone is still intact and still worth waiting
// on — but it is recorded (SavedLtfZone.touched) so SaveLtfZonesForHtfBias
// can retire it later if a fresher same-direction zone shows up first.
void CheckRejectionRetests(const MqlRates &bar)
  {
   int n = ArraySize(g_savedLtfZones);
   if(n == 0) return;

   double atrLtf = GetAtrValue(false);
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
         if(InpEnableLog)
            PrintFormat("AjipSnD: %s zone [%.5f, %.5f] BROKEN (close %.5f past %.5f) — invalidated",
                        isDemand ? "DEMAND" : "SUPPLY", zLow, zHigh, bar.close, breakLevel);
         continue;
        }

      bool wickedIn = isDemand ? (bar.low <= zHigh) : (bar.high >= zLow);
      if(!wickedIn) continue;   // not touched yet, still intact — keep waiting

      // Recorded even if this particular touch doesn't resolve anything —
      // SaveLtfZonesForHtfBias reads this to retire the zone the moment a
      // fresher same-direction one is saved, instead of it lingering touched
      // but never explicitly resolved.
      g_savedLtfZones[i].touched = true;

      bool closedOut  = isDemand ? (bar.close > zHigh) : (bar.close < zLow);
      bool rightColor = isDemand ? IsBullBar(bar) : IsBearBar(bar);
      bool rejected   = closedOut && rightColor && (bodyAtr >= InpRejectionBodyAtr);
      if(!rejected) continue;   // touched but no clean rejection yet — still watching

      g_savedLtfZones[i].used = true;

      int    dir    = isDemand ? 1 : -1;
      double buffer = InpZoneSlBufferAtr * atrLtf;
      double slPrice = isDemand
                       ? NormalizeDouble(zLow  - buffer, g_digits)
                       : NormalizeDouble(zHigh + buffer, g_digits);

      if(InpEnableLog)
         PrintFormat("AjipSnD: REJECTION confirmed on %s zone [%.5f, %.5f] bodyAtr=%.2f — entering %s market",
                     isDemand ? "DEMAND" : "SUPPLY", zLow, zHigh, bodyAtr, dir == 1 ? "BUY" : "SELL");

      if(!EntryGateBlocked(dir))
         OpenMarketWithStructuralStops(dir, slPrice, g_savedLtfZones[i].time);
     }
  }

//---- Update LTF on new closed bar ----
void UpdateLTF(const MqlRates &rates[], int count)
  {
   // rates is series=true, rates[1] is latest closed bar
   if(count < 2) return;

   MqlRates bar = rates[1];

   if(bar.time == g_ltfLastBarTime)
      return;

   g_ltfLastBarTime = bar.time;

   // Quality tracker per-bar stats (excursions, first touch)
   if(InpZoneQualityLog)
      UpdateZoneTracking(bar, false);

   // Keep touch status current, independent of InpZoneQualityLog — the
   // history it updates is what PlaceEntriesForHtfValidatedZone reads (for
   // InpHtfTriggeredEntry) and what MarkLtfValidationContext's own
   // touched+superseded check reads (for InpRejectionEntryMode), not the CSV.
   if(InpHtfTriggeredEntry || InpRejectionEntryMode)
      UpdateLtfValidatedHistoryTouch(bar);

   // Rejection-entry confirmation: the one check that must run on a closed
   // bar rather than a tick — see UpdateExcursionRejects() for why.
   UpdateExcursionRejects(bar);

   // Forward-drift probe: baseline draw + horizon stamping, every bar,
   // independent of whether a zone confirms on it.
   DriftArmBaseline(bar);
   UpdateDriftRecords(bar);

   //---- Follow-through validation (LTF always-on) ----
   if(g_ltfAwaitingValidation)
     {
      bool passed = g_ltfPendingZone.isDemand
                    ? (bar.close > g_ltfPendingZone.confirmLevel)
                    : (bar.close < g_ltfPendingZone.confirmLevel);
      if(passed)
        {
         MarkZoneValidated(false, g_ltfPendingZone.isDemand, g_ltfPendingZone.time);
         MarkLtfValidationContext(g_ltfPendingZone);
         // Three trigger philosophies, mutually exclusive — running more than
         // one would let the same LTF zone earn independent order attempts
         // under different rules, which is not an A/B, it's a merge.
         // InpRejectionEntryMode does nothing at this call site at all: it
         // neither trades nor saves at LTF validation — saving is triggered
         // by HTF validation instead (SaveLtfZonesForHtfBias in UpdateHTF),
         // replaying g_ltfValidatedHistory back to the HTF zone's own origin,
         // so an LTF zone that validates before the matching HTF bias exists
         // is still caught rather than missed.
         if(!InpRejectionEntryMode && !InpHtfTriggeredEntry)
           {
            if(PlaceEntryForZone(g_ltfPendingZone))
               MarkZoneEntryPlaced(g_ltfPendingZone.isDemand, g_ltfPendingZone.time);
           }
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
      if(InpZoneQualityLog)
        {
         SnDZone tracked = confirmed;
         TrackZone(tracked, false);
         ZoneCsvWrite("CONFIRM", tracked, "");
        }

      // Hold for follow-through validation
      g_ltfPendingZone = confirmed;
      g_ltfAwaitingValidation = true;
     }

   // Rejection-entry mode: check every saved zone against this closed bar,
   // and redraw — the saved zones are what stands in for HTF zones on the
   // chart in this mode (see AjipSnD_Zone.mqh's DrawSavedLtfZones).
   if(InpRejectionEntryMode)
     {
      CheckRejectionRetests(bar);
      DrawSavedLtfZones();
     }
  }

//---- Update HTF on new closed bar ----
void UpdateHTF(const MqlRates &rates[], int count)
  {
   if(count < 2) return;

   MqlRates bar = rates[1];

   if(bar.time == g_htfLastBarTime)
      return;

   g_htfLastBarTime = bar.time;

   // Quality tracker per-bar stats BEFORE invalidation, so the
   // invalidating bar's excursion is captured in the OUTCOME row
   if(InpZoneQualityLog)
      UpdateZoneTracking(bar, true);

   // Invalidate active zones broken by price action
   InvalidateHtfZones(bar);

   //---- Follow-through validation (HTF gated by input) ----
   if(InpRequireZoneValidation && g_htfAwaitingValidation)
     {
      bool passed = g_htfPendingZone.isDemand
                    ? (bar.close > g_htfPendingZone.confirmLevel)
                    : (bar.close < g_htfPendingZone.confirmLevel);
      if(passed)
        {
         MarkZoneValidated(true, g_htfPendingZone.isDemand, g_htfPendingZone.time);
         if(g_htfPendingZone.isDemand)
           {
            AddDemandZone(g_htfDemandZones, g_htfPendingZone);
            if(InpEnableLog)
               PrintFormat("AjipSnD: HTF DEMAND zone VALIDATED [%.5f, %.5f]",
                           g_htfPendingZone.low, g_htfPendingZone.high);
           }
         else
           {
            AddSupplyZone(g_htfSupplyZones, g_htfPendingZone);
            if(InpEnableLog)
               PrintFormat("AjipSnD: HTF SUPPLY zone VALIDATED [%.5f, %.5f]",
                           g_htfPendingZone.low, g_htfPendingZone.high);
           }
         g_htfAwaitingValidation = false;

         if(InpHtfTriggeredEntry)
            PlaceEntriesForHtfValidatedZone(g_htfPendingZone);

         // Rejection-entry mode: HTF validation sets a pure directional bias,
         // not a price range — see InpRejectionEntryMode's input comment —
         // then immediately replays LTF history for zones already validated
         // since this HTF zone's own origin bar (SaveLtfZonesForHtfBias logs
         // the bias change and the replay result together).
         if(InpRejectionEntryMode)
           {
            g_htfBiasDir = g_htfPendingZone.isDemand ? 1 : -1;
            SaveLtfZonesForHtfBias(g_htfPendingZone);
           }
        }
     }

   //---- Process this bar for zone confirmation ----
   SnDZone confirmed;
   ZeroMemory(confirmed);
   if(ProcessZoneBar(bar, g_htfTrend, g_htfCandidate, confirmed))
     {
      confirmed.confirmLevel = confirmed.isDemand ? bar.high : bar.low;

      // Metrics + quality gate — also sets isHtf, the tracker key for outcome
      // logging. Must run before the zone is held as pending or activated.
      ComputeZoneMetrics(confirmed, true, bar);

      if(InpRequireZoneValidation)
        {
         // Opposite zone formed before validation → pending zone fails
         if(g_htfAwaitingValidation && confirmed.isDemand != g_htfPendingZone.isDemand)
           {
            if(InpEnableLog)
               PrintFormat("AjipSnD: HTF %s zone validation FAILED — opposite zone formed first",
                           g_htfPendingZone.isDemand ? "DEMAND" : "SUPPLY");
            LogZoneOutcome("FAILED_OPPOSITE", true, g_htfPendingZone.isDemand, g_htfPendingZone.time);
            g_htfAwaitingValidation = false;
           }

         // Hold for validation (unvalidated → drawn in pending color)
         g_htfPendingZone = confirmed;
         g_htfAwaitingValidation = true;
        }
      else
        {
         // Validation disabled → activate immediately
         if(confirmed.isDemand)
           {
            AddDemandZone(g_htfDemandZones, confirmed);
            if(InpEnableLog)
               PrintFormat("AjipSnD: HTF DEMAND zone confirmed! [%.5f, %.5f]",
                           confirmed.low, confirmed.high);
           }
         else
           {
            AddSupplyZone(g_htfSupplyZones, confirmed);
            if(InpEnableLog)
               PrintFormat("AjipSnD: HTF SUPPLY zone confirmed! [%.5f, %.5f]",
                           confirmed.low, confirmed.high);
           }
        }

      // Quality tracking: metrics + CONFIRM row
      if(InpZoneQualityLog)
        {
         SnDZone tracked = confirmed;
         TrackZone(tracked, true);
         ZoneCsvWrite("CONFIRM", tracked, "");
        }
     }

   // Redraw every HTF bar close — validated zones extend to current time,
   // pending zone drawn in distinct color. Skipped in rejection-entry mode:
   // HTF is a directional bias there, not a chart object — DrawSavedLtfZones
   // (called from UpdateLTF) is what actually matters on screen in that mode.
   if(!InpRejectionEntryMode)
      DrawAllHtfZones();
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
   string htfTrendStr = g_htfTrend == TREND_UP ? "UP" : (g_htfTrend == TREND_DOWN ? "DOWN" : "NONE");
   
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
   const int totalLines = 20;
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
   PANEL_LABEL(StringFormat("HTF Trend: %s (%s)", htfTrendStr, ShortTF(InpHtfTimeframe)), clrWhite);
   // "tradeable/total" — zones failing the quality gate still exist as
   // structure but are not offered as entry areas
   int demTradeable = CountTradeableZones(g_htfDemandZones);
   int supTradeable = CountTradeableZones(g_htfSupplyZones);
   PANEL_LABEL(StringFormat("Demands:   %d/%d", demTradeable, ArraySize(g_htfDemandZones)), clrWhite);
   PANEL_LABEL(StringFormat("Supplies:  %d/%d", supTradeable, ArraySize(g_htfSupplyZones)), clrWhite);
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
