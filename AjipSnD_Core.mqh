#ifndef AJIPSND_CORE_MQH
#define AJIPSND_CORE_MQH

//==================================================================
// CORE — InitStructure, UpdateStructure, OnTick dispatch
//==================================================================

//---- Save every matching LTF zone since the HTF zone's own origin bar ----
// Triggered by HTF VALIDATION, not by the LTF zone's own validation instant
// — an on-tick save (checking bias only at the moment the LTF zone itself
// validates) misses every LTF zone that validated before the HTF bias
// caught up to it, which is the common case, not the edge case: an HTF zone
// on a higher timeframe routinely takes many LTF bars to confirm, and LTF
// zones keep validating throughout that wait. Replays g_ltfValidatedHistory[] —
// already populated unconditionally for every validated LTF zone — back to
// the HTF zone's own origin bar. The dedup check guards a case that
// shouldn't arise given HTF zones strictly alternate direction at
// confirmation (so two same-direction validations can't share overlapping
// origins) — cheap insurance, not a known bug.
void SaveLtfZonesForHtfBias(const SnDZone &htfZone, bool isReplay, datetime htfBarTime)
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
      ArrayResize(g_ltfZoneDrawEnd, sz + 1);
      g_ltfZoneDrawEnd[sz] = 0;
      // Placing the order doesn't retire the zone — it stays watched (and
      // drawn live) exactly like rejection mode, until CheckPendingZoneTouches
      // (called from UpdateLTF) sees price actually reach it. Only the live
      // order itself is skipped during replay, same as
      // OpenMarketWithStructuralStops never firing there either.
      if(InpUsePendingOrderEntry && !isReplay)
         PlacePendingOrderForZone(g_savedLtfZones[sz], htfBarTime);
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
//
// isReplay (OnInit historical replay) still resolves a zone's fate exactly
// as live does — used=true on a break or a confirmed rejection — but never
// calls OpenMarketWithStructuralStops: by the time OnInit runs, price has
// already moved on from wherever a historical rejection bar closed, so
// there is no legitimate fill left to send at today's market price.
void CheckRejectionRetests(const MqlRates &bar, bool isReplay = false)
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
         g_ltfZoneDrawEnd[i] = bar.time;
         if(InpEnableLog)
            PrintFormat("AjipSnD: %s zone [%.5f, %.5f] BROKEN (close %.5f past %.5f) — invalidated",
                        isDemand ? "DEMAND" : "SUPPLY", zLow, zHigh, bar.close, breakLevel);
         continue;
        }

      bool wickedIn = isDemand ? (bar.low <= zHigh) : (bar.high >= zLow);
      if(!wickedIn) continue;   // not touched yet, still intact — keep waiting

      // Captured before the flag below flips it — pin bar is restricted to
      // the zone's very first touch (see the IsPinBar call further down): a
      // sharp single-bar rejection means something different the first time
      // price reaches a fresh level than it does after the level has
      // already been tested and held once.
      bool isFirstTouch = !g_savedLtfZones[i].touched;

      // Recorded even if this particular touch doesn't resolve anything —
      // SaveLtfZonesForHtfBias reads this to retire the zone the moment a
      // fresher same-direction one is saved, instead of it lingering touched
      // but never explicitly resolved.
      g_savedLtfZones[i].touched = true;

      // Shared gate across every criterion below: the confirming bar must
      // have closed back outside the zone. None of criteria 1/engulfing/pin
      // bar/star can fire on a bar that's still sitting inside the range.
      bool closedOut = isDemand ? (bar.close > zHigh) : (bar.close < zLow);
      if(!closedOut) continue;   // touched but hasn't closed back out yet — still watching

      bool   matched     = false;
      string patternName = "";
      int    patternBars = 1;   // how many trailing bars (incl. bar) feed the SL extreme

      if(InpCriteria1Enabled)
        {
         bool rightColor = isDemand ? IsBullBar(bar) : IsBearBar(bar);
         if(rightColor && bodyAtr >= InpRejectionBodyAtr)
           {
            matched = true; patternName = "criteria1"; patternBars = 1;
           }
        }
      if(!matched && InpEngulfingEnabled && IsEngulfing(bar, g_ltfRecentBars[1], isDemand, atrLtf))
        {
         matched = true; patternName = "engulfing"; patternBars = 2;
        }
      if(!matched && InpPinBarEnabled && isFirstTouch && IsPinBar(bar, isDemand))
        {
         matched = true; patternName = "pinbar"; patternBars = 1;
        }
      if(!matched && InpStarEnabled && IsStar(bar, g_ltfRecentBars[1], g_ltfRecentBars[2], isDemand))
        {
         matched = true; patternName = "star"; patternBars = 3;
        }
      if(!matched) continue;   // touched, closed out, but no enabled criterion confirmed — still watching

      if(InpMaxEntryDistanceZoneWidth > 0)
        {
         double zoneWidth     = zHigh - zLow;
         double entryDistance = isDemand ? (bar.close - zHigh) : (zLow - bar.close);
         if(zoneWidth > 0 && entryDistance > InpMaxEntryDistanceZoneWidth * zoneWidth)
           {
            if(InpEnableLog)
               PrintFormat("AjipSnD: %s rejection on %s zone [%.5f, %.5f] SKIPPED — entry %.5f too far "
                           "(dist=%.5f > %.1fx width=%.5f)",
                           patternName, isDemand ? "DEMAND" : "SUPPLY", zLow, zHigh, bar.close,
                           entryDistance, InpMaxEntryDistanceZoneWidth, zoneWidth);
            continue;   // too far to chase — keep watching, a closer rejection might still come
           }
        }

      g_savedLtfZones[i].used = true;
      g_ltfZoneDrawEnd[i] = bar.time;

      int    dir    = isDemand ? 1 : -1;
      if(InpDrawLines)
         DrawEntrySignal(bar.time, isDemand ? bar.low : bar.high, dir, patternName);

      double buffer = InpZoneSlBufferAtr * atrLtf;
      // Anchored to the rejection pattern's OWN extreme across however many
      // bars it spans, not the zone's static boundary — the wick(s) that
      // just got rejected are the actual proof the level held, and can sit
      // shallower or deeper than the zone's edge (wickedIn only requires
      // touching the range, not stopping at zLow/zHigh).
      double patternExtreme = isDemand ? bar.low : bar.high;
      if(patternBars >= 2)
         patternExtreme = isDemand ? MathMin(patternExtreme, g_ltfRecentBars[1].low)
                                    : MathMax(patternExtreme, g_ltfRecentBars[1].high);
      if(patternBars >= 3)
         patternExtreme = isDemand ? MathMin(patternExtreme, g_ltfRecentBars[2].low)
                                    : MathMax(patternExtreme, g_ltfRecentBars[2].high);
      double slPrice = isDemand
                       ? NormalizeDouble(patternExtreme - buffer, g_digits)
                       : NormalizeDouble(patternExtreme + buffer, g_digits);

      if(isReplay)
        {
         if(InpEnableLog)
            PrintFormat("AjipSnD: REJECTION confirmed (%s, init replay) on %s zone [%.5f, %.5f] bodyAtr=%.2f — resolved, no live order",
                        patternName, isDemand ? "DEMAND" : "SUPPLY", zLow, zHigh, bodyAtr);
         continue;
        }

      if(InpEnableLog)
         PrintFormat("AjipSnD: REJECTION confirmed (%s) on %s zone [%.5f, %.5f] bodyAtr=%.2f — entering %s market",
                     patternName, isDemand ? "DEMAND" : "SUPPLY", zLow, zHigh, bodyAtr, dir == 1 ? "BUY" : "SELL");

      if(!EntryGateBlocked(dir))
         OpenMarketWithStructuralStops(dir, slPrice, g_savedLtfZones[i].time, patternName);
     }
  }

//---- Pending-order mode's own touch bookkeeping — CheckRejectionRetests is
// skipped entirely in this mode (the order was already placed the instant
// the zone was saved; there is no rejection pattern left to look for), but
// the zone still needs to leave the "still watching" state once price
// actually reaches it, same as rejection mode's own touched/used lifecycle,
// so DrawSavedLtfZones freezes the rectangle there instead of stretching it
// forever. Deliberately does nothing about a zone whose pending order later
// expires without ever being touched — that zone's rectangle keeps growing
// until (if ever) price reaches it.
void CheckPendingZoneTouches(const MqlRates &bar)
  {
   int n = ArraySize(g_savedLtfZones);
   for(int i = 0; i < n; i++)
     {
      if(g_savedLtfZones[i].used) continue;
      if(bar.time <= g_savedLtfZones[i].time) continue;   // skip the zone's own confirm bar

      bool   isDemand = g_savedLtfZones[i].isDemand;
      double zLow     = g_savedLtfZones[i].low;
      double zHigh    = g_savedLtfZones[i].high;
      bool   wickedIn = isDemand ? (bar.low <= zHigh) : (bar.high >= zLow);
      if(!wickedIn) continue;

      g_savedLtfZones[i].touched = true;
      g_savedLtfZones[i].used    = true;
      g_ltfZoneDrawEnd[i] = bar.time;
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

   // Shift the rolling bar history BEFORE anything below reads it, so
   // CheckRejectionRetests sees "bar" as current and g_ltfRecentBars[1]/[2]
   // as one/two bars back — same order live ticks and the OnInit replay
   // both process bars in, so this stays correct either way.
   g_ltfRecentBars[2] = g_ltfRecentBars[1];
   g_ltfRecentBars[1] = g_ltfRecentBars[0];
   g_ltfRecentBars[0] = bar;

   // Quality tracker per-bar stats (excursions, first touch)
   if(InpZoneQualityLog && !isReplay)
      UpdateZoneTracking(bar, false);

   // Keep touch status current, independent of InpZoneQualityLog — the
   // history it updates is what SaveLtfZonesForHtfBias's backward replay reads
   // and what MarkLtfValidationContext's own touched+superseded check reads,
   // not the CSV.
   UpdateLtfValidatedHistoryTouch(bar);

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
         MarkLtfValidationContext(g_ltfPendingZone, g_ltfPendingTouched);
         // Nothing trades here: an LTF zone validating does not by itself earn
         // an order. Saving for the rejection watch is triggered by HTF
         // validation instead (SaveLtfZonesForHtfBias in UpdateHTF), replaying
         // g_ltfValidatedHistory back to the HTF zone's own origin, so an LTF
         // zone that validates before the matching HTF bias exists is still
         // caught rather than missed.
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
     }

   // Check every saved zone against this closed bar. Rejection matching is
   // skipped entirely in pending-order mode — the order was already placed
   // the moment the zone was saved (see SaveLtfZonesForHtfBias) — but the
   // zone still needs its own touch bookkeeping there, run regardless of
   // isReplay so a zone that resolves during the OnInit replay doesn't sit
   // "still watching" forever once live processing starts.
   // Redraw is skipped during replay — ReplayInitialStructure draws once at
   // the end instead of redrawing on every historical bar.
   if(!InpUsePendingOrderEntry)
      CheckRejectionRetests(bar, isReplay);
   else
      CheckPendingZoneTouches(bar);
   if(!isReplay)
     {
      DrawSavedLtfZones();
      DrawHtfMaLine();
     }
  }

//---- Update HTF on new closed bar ----
// isReplay=true is the OnInit historical replay — see UpdateLTF's matching
// comment for what that does and doesn't skip.
void UpdateHTF(const MqlRates &bar, bool isReplay = false)
  {
   if(bar.time == g_htfLastBarTime)
      return;

   g_htfLastBarTime = bar.time;

   // Quality tracker per-bar stats BEFORE invalidation, so the
   // invalidating bar's excursion is captured in the OUTCOME row
   if(InpZoneQualityLog && !isReplay)
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

         // HTF validation sets a pure directional bias, not a price range to
         // sit inside, then immediately replays LTF history for zones already
         // validated since this HTF zone's own origin bar
         // (SaveLtfZonesForHtfBias logs the bias change and the replay result
         // together).
         g_htfBiasDir      = g_htfPendingZone.isDemand ? 1 : -1;
         g_htfBiasZoneHigh = g_htfPendingZone.high;
         g_htfBiasZoneLow  = g_htfPendingZone.low;
         SaveLtfZonesForHtfBias(g_htfPendingZone, isReplay, bar.time);
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
      if(InpZoneQualityLog && !isReplay)
        {
         SnDZone tracked = confirmed;
         TrackZone(tracked, true);
         ZoneCsvWrite("CONFIRM", tracked, "");
        }
     }

   // Nothing drawn here — HTF is a directional bias, not a chart object.
   // DrawSavedLtfZones (called from UpdateLTF) is what actually matters on
   // screen.

   // Pending-order mode's own upkeep — fold triggered orders into
   // g_entries, cancel ones that timed out. Once per closed HTF bar (the
   // unit InpPendingOrderExpiryHtfBars counts in), live only: replay has no
   // real orders to manage, and RebuildTrackedPositions doesn't reconstruct
   // g_pendingOrders on restart, so there is nothing to do differently for
   // a fresh EA start either.
   if(InpUsePendingOrderEntry && !isReplay)
      ManagePendingOrders(bar.time);
  }

//---- Replay LTF + HTF bars together, chronologically, to seed the EA's
// initial structure AND the rejection-entry bias/history/save state — so it
// starts with the same g_htfBiasDir/g_savedLtfZones it would have accumulated
// running continuously through the lookback window, instead of sitting with
// no bias until the first LIVE HTF validation.
//
// Reuses UpdateHTF/UpdateLTF (isReplay=true) rather than a parallel replay
// path, so there is exactly one definition of what a validated HTF/LTF zone
// is — see their own comments for what isReplay skips (CSV/diagnostic writes,
// per-bar chart redraws) and what it never skips (zone detection, follow-
// through validation, touch/superseded bookkeeping, the rejection watch
// list). It never places a real order: CheckRejectionRetests still resolves
// every saved zone's fate against the historical bars that follow it, but
// isReplay suppresses the actual market fill, since by the time this runs
// price has already moved on from wherever a historical rejection closed.
//
// Interleaving the two streams by close time, not replaying LTF then HTF (or
// vice versa) in two separate passes, is required for correctness, not just
// tidiness: SaveLtfZonesForHtfBias's backward search and
// MarkLtfValidationContext's superseded-marking both depend on
// g_ltfValidatedHistory reflecting only what had already validated as of
// that same real-time moment — a two-pass replay would let an HTF bias see
// LTF zones that, chronologically, validated after it did.
void ReplayInitialStructure()
  {
   // ---- HTF bars first: they set how far back the whole replay reaches ----
   // start_pos=1 skips the current, still-forming HTF bar — replaying a
   // not-yet-closed bar as if it were final could confirm or invalidate a
   // zone on incomplete data.
   MqlRates htfRates[];
   int htfCount = CopyRates(_Symbol, InpHtfTimeframe, 1, InpCandlesInit, htfRates);
   if(htfCount < 10)
     {
      PrintFormat("AjipSnD: Init replay — only %d HTF bars copied (need >=10) — skipped, no initial bias", htfCount);
      return;
     }
   ArraySetAsSeries(htfRates, true);           // index 0 = newest, for trend determination
   g_htfTrend = DetermineInitialTrend(htfRates, htfCount);
   ZeroMemory(g_htfCandidate);
   ArraySetAsSeries(htfRates, false);          // index 0 = oldest, for the forward walk
   datetime windowStart = htfRates[0].time;

   // ---- LTF bars covering the SAME calendar span, not just InpCandlesInit ----
   // A fixed LTF bar count would badly under-cover the HTF window whenever
   // InpTimeframe is much finer than InpHtfTimeframe (e.g. M5 LTF under an H1
   // HTF: InpCandlesInit=50 gives ~50 hours of HTF but only ~4 hours of LTF).
   // SaveLtfZonesForHtfBias's backward search needs LTF history reaching back
   // to the OLDEST HTF zone's own origin bar, so the LTF fetch is keyed off
   // that same start time instead of a bar count.
   MqlRates ltfRates[];
   int ltfCount = CopyRates(_Symbol, InpTimeframe, windowStart, TimeCurrent(), ltfRates);
   if(ltfCount < 10)
     {
      PrintFormat("AjipSnD: Init replay — only %d LTF bars copied since %s — skipped, no initial bias",
                  ltfCount, TimeToString(windowStart, TIME_DATE | TIME_MINUTES));
      return;
     }
   ArraySetAsSeries(ltfRates, true);
   // Drop the newest LTF bar if it hasn't closed yet — an open-ended
   // stop_time (TimeCurrent()) can return the bar still forming right now.
   if(ltfRates[0].time + PeriodSeconds(InpTimeframe) > TimeCurrent())
     {
      ArrayRemove(ltfRates, 0, 1);
      ltfCount--;
     }
   int ltfTrendCount = MathMin(ltfCount, InpCandlesInit);
   g_ltfTrend = DetermineInitialTrend(ltfRates, ltfTrendCount);  // same short recent-window convention as before
   ZeroMemory(g_ltfCandidate);
   ArraySetAsSeries(ltfRates, false);          // oldest first

   PrintFormat("AjipSnD: Init replay — %d HTF bars since %s, %d LTF bars, HTF trend=%s LTF trend=%s",
               htfCount, TimeToString(windowStart, TIME_DATE | TIME_MINUTES), ltfCount,
               g_htfTrend == TREND_DOWN ? "DOWN" : "UP",
               g_ltfTrend == TREND_DOWN ? "DOWN" : "UP");

   // ---- Merge-walk both streams in true close-time order ----
   int hi = 0, li = 0;
   while(hi < htfCount || li < ltfCount)
     {
      bool takeHtf;
      if(hi >= htfCount)      takeHtf = false;
      else if(li >= ltfCount) takeHtf = true;
      else
        {
         datetime htfClose = htfRates[hi].time + PeriodSeconds(InpHtfTimeframe);
         datetime ltfClose = ltfRates[li].time + PeriodSeconds(InpTimeframe);
         takeHtf = (htfClose <= ltfClose);
        }

      if(takeHtf) { UpdateHTF(htfRates[hi], true); hi++; }
      else        { UpdateLTF(ltfRates[li], true); li++; }
     }

   PrintFormat("AjipSnD: Init replay complete — bias=%s, %d LTF zone(s) saved and watching",
               g_htfBiasDir == 1 ? "DEMAND" : (g_htfBiasDir == -1 ? "SUPPLY" : "none"),
               ArraySize(g_savedLtfZones));

   if(InpDrawLines)
     {
      DrawSavedLtfZones();
      DrawHtfMaLine();
     }
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
   // structure but are not offered as entry areas. LTF, not HTF: HTF is a
   // directional bias only now, never geometrically meaningful, while LTF
   // zones are what actually gets watched and traded.
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
