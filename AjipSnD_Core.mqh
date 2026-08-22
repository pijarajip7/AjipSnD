#ifndef AJIPSND_CORE_MQH
#define AJIPSND_CORE_MQH

//==================================================================
// CORE — InitStructure, UpdateStructure, OnTick dispatch
//==================================================================

//---- Save a just-validated LTF zone directly onto the saved-zone watch list —
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
// key for the zone CSV etc.), but it never enters the watch AND
// never gets drawn on chart at all: it was never a candidate CheckRejection-
// Retests would have watched, so there is nothing worth showing on chart
// either, unlike a zone that WAS watched for a while and later resolved.
//
// swept (= zone.sweepHigh > 0 || zone.sweepLow > 0) applies the exact same
// treatment to a zone whose CANDIDATE phase had a failed break attempt
// before it ever confirmed — a wick past candidate.high/low that didn't
// close through. Not measured yet, requested directly: only a clean
// confirmation (no sweep on the way there) gets drawn and watched.
void SaveLtfZoneForWatch(const SnDZone &zone, bool preTouched, datetime asOf)
  {
   bool swept = (zone.sweepHigh > 0 || zone.sweepLow > 0);
   bool skip  = preTouched || swept;

   int sz = ArraySize(g_savedLtfZones);
   ArrayResize(g_savedLtfZones, sz + 1);
   g_savedLtfZones[sz].high      = zone.high;
   g_savedLtfZones[sz].low       = zone.low;
   g_savedLtfZones[sz].sweepHigh = zone.sweepHigh;
   g_savedLtfZones[sz].sweepLow  = zone.sweepLow;
   g_savedLtfZones[sz].time      = zone.time;
   g_savedLtfZones[sz].isDemand  = zone.isDemand;
   g_savedLtfZones[sz].touched   = skip;
   g_savedLtfZones[sz].used      = skip;

   ArrayResize(g_ltfZoneDrawEnd, sz + 1);
   g_ltfZoneDrawEnd[sz] = skip ? asOf : 0;
   ArrayResize(g_ltfZoneDrawFrozen, sz + 1);
   g_ltfZoneDrawFrozen[sz] = skip;

   // Resolve once: this zone's CONFIRM-time entry in g_zoneTracker[], if
   // InpZoneQualityLog was on. TrackZone always appends there strictly
   // before this function runs for the same zone, so a backward search hits
   // it in only a few steps — the match is near the tail, not index 0.
   int trackerIdx = -1;
   for(int t = ArraySize(g_zoneTracker) - 1; t >= 0; t--)
     {
      if(g_zoneTracker[t].time == zone.time && g_zoneTracker[t].isDemand == zone.isDemand)
        {
         trackerIdx = t;
         break;
        }
     }
   ArrayResize(g_ltfZoneTrackerIdx, sz + 1);
   g_ltfZoneTrackerIdx[sz] = trackerIdx;

   if(InpEnableLog)
     {
      // trackerIdx == -1 here (with InpZoneQualityLog otherwise true) would
      // mean the backward search itself is broken — worth a dedicated line
      // since the runway label silently depends on this resolving, with no
      // other visible symptom. trackerIdx == -1 while InpZoneQualityLog is
      // false is normal — TrackZone never runs, so there is nothing to find.
      if(trackerIdx < 0 && InpZoneQualityLog)
         PrintFormat("AjipSnD: trackerIdx resolve FAILED — zone %s %s not found in g_zoneTracker (size=%d) — runway label won't show for this zone",
                     zone.isDemand ? "DEMAND" : "SUPPLY", TimeToString(zone.time), ArraySize(g_zoneTracker));

      if(preTouched && swept)
         PrintFormat("AjipSnD: LTF %s zone validated [%.5f, %.5f] — touched before validation AND swept on confirm, marked used (no watch, not drawn)",
                     zone.isDemand ? "DEMAND" : "SUPPLY", zone.low, zone.high);
      else if(preTouched)
         PrintFormat("AjipSnD: LTF %s zone validated [%.5f, %.5f] — touched before validation, marked used (no watch, not drawn)",
                     zone.isDemand ? "DEMAND" : "SUPPLY", zone.low, zone.high);
      else if(swept)
         PrintFormat("AjipSnD: LTF %s zone validated [%.5f, %.5f] — swept on confirm, marked used (no watch, not drawn)",
                     zone.isDemand ? "DEMAND" : "SUPPLY", zone.low, zone.high);
      else
         PrintFormat("AjipSnD: LTF %s zone validated [%.5f, %.5f] — saved for watch",
                     zone.isDemand ? "DEMAND" : "SUPPLY", zone.low, zone.high);
     }
  }

//---- favW entry filter helpers ----
// favW = favorable pre-touch excursion in zone widths (the chart's runway
// label and the CSV's fav_before_touch_width_ratio). The metric lives in the
// zone-quality tracker (maxFavPts), so these helpers reach across to
// g_zoneTracker[] via the index resolved once at save time.

// True when the zone-quality tracker must run: either for the CSV (quality
// log) or because the favW entry filter needs the in-memory maxFavPts.
// CSV writes stay gated on InpZoneQualityLog alone — see the ZoneCsvWrite
// call sites — so enabling only the filter tracks in memory, no disk writes.
bool NeedsZoneTracking()
  {
   return(InpZoneQualityLog || InpMinFavW > 0 || InpMaxFavW > 0);
  }

// favW ratio for a saved zone, or -1 if unavailable (no tracker entry, or a
// zero-width zone). The negative sentinel lets callers fail open.
double SavedZoneFavW(int savedIdx)
  {
   if(savedIdx < 0 || savedIdx >= ArraySize(g_ltfZoneTrackerIdx)) return(-1.0);
   int tIdx = g_ltfZoneTrackerIdx[savedIdx];
   if(tIdx < 0 || tIdx >= ArraySize(g_zoneTracker)) return(-1.0);
   double widthPts = (g_savedLtfZones[savedIdx].high - g_savedLtfZones[savedIdx].low) / g_point;
   if(widthPts <= 0) return(-1.0);
   return(g_zoneTracker[tIdx].maxFavPts / widthPts);
  }

// True when this zone's first touch should be skipped: favW falls below
// InpMinFavW or above InpMaxFavW. Filter off (both 0) or no metric -> false.
bool FavWFilterBlocks(int savedIdx)
  {
   if(InpMinFavW <= 0 && InpMaxFavW <= 0) return(false);
   double favW = SavedZoneFavW(savedIdx);
   if(favW < 0) return(false);
   if(InpMinFavW > 0 && favW < InpMinFavW) return(true);
   if(InpMaxFavW > 0 && favW > InpMaxFavW) return(true);
   return(false);
  }

// True when this zone's width (in points) falls outside [min, max] and its
// first touch should be skipped. Filter off (both 0) -> false. Evaluated at
// TOUCH time, exactly like favW above: the zone stays on the watch list and
// drawn on chart, it just never enters.
bool WidthFilterBlocks(int savedIdx)
  {
   if(InpMinZoneWidthPoints <= 0 && InpMaxZoneWidthPoints <= 0) return(false);
   double widthPts = (g_savedLtfZones[savedIdx].high - g_savedLtfZones[savedIdx].low) / g_point;
   if(InpMinZoneWidthPoints > 0 && widthPts <  InpMinZoneWidthPoints) return(true);
   if(InpMaxZoneWidthPoints > 0 && widthPts >= InpMaxZoneWidthPoints) return(true);
   return(false);
  }

//---- Check every saved zone against this closed bar: break, or the first
// touch itself ----
// A saved zone resolves two ways:
//   1. Structural break — a body CLOSE beyond the zone's far edge (or its
//      sweep level, if it had one at confirmation). Price didn't just
//      retest and fail, it went straight through — the thesis is gone.
//   2. Entry trigger — the FIRST wick into the zone, full stop. No
//      body/close-back-out requirement — formerly one of two modes
//      (alongside waiting for a confirmed rejection bar), now the only one,
//      so a zone is never left "touched but still watching": the first
//      touch always triggers immediately.
//
// isReplay (OnInit historical replay) still resolves a zone's fate exactly
// as live does — used=true on a break or a confirmed trigger — but never
// calls OpenMarketWithStructuralStops: by the time OnInit runs, price has
// already moved on from wherever a historical trigger bar closed, so there
// is no legitimate fill left to send at today's market price.
//---- Entry decision shared by both entry paths (tick + bar-close). Replaces
// the old "one position per direction" cap: a direction with no open position
// enters normally; a direction already in recovery (a position moved to BE)
// may add an averaging-down position; otherwise the touch is skipped.
void TryEntry(int dir, double slPrice, datetime zoneTime)
  {
   if(EntryGateBlocked(dir)) return;   // all gates still apply (MA, session, news, hedge, cooldown, final/weekly)

   if(DirectionalExposureCount(dir) == 0)
     {
      OpenMarketWithStructuralStops(dir, slPrice, zoneTime);
      return;
     }

   // Direction occupied: recovery adds only, and only once a position there
   // has been invalidated (TP->BE). A still-normal position means no second entry.
   if(!RecoveryModeActive(dir))
     {
      if(InpEnableLog)
         PrintFormat("AjipSnD: %s touch skipped — position open but not in recovery mode",
                     dir == 1 ? "BUY" : "SELL");
      return;
     }

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;
   double price = (dir == 1) ? tick.bid : tick.ask;   // "beyond all entries" reference

   if(!PriceBeyondAllEntries(dir, price))
     {
      if(InpEnableLog)
         PrintFormat("AjipSnD: %s recovery skipped — price %.5f not beyond all open entries",
                     dir == 1 ? "BUY" : "SELL", price);
      return;
     }

   // Lot matches the existing position (all recovery positions are identical lot).
   double lot = 0.0;
   for(int i = 0; i < ArraySize(g_entries); i++)
     {
      if(g_entries[i].dir == dir && PositionSelectByTicket(g_entries[i].ticket))
        {
         lot = PositionGetDouble(POSITION_VOLUME);
         break;
        }
     }
   if(lot <= 0.0) return;

   if(OpenRecoveryPosition(dir, lot, zoneTime) == 0) return;

   // Converge every position in the direction to the new average breakeven TP.
   ReaverageTpToBreakEven(dir);
  }

void CheckRejectionRetests(const MqlRates &bar, bool isReplay = false)
  {
   int n = ArraySize(g_savedLtfZones);
   if(n == 0) return;

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

      if(FavWFilterBlocks(i))
        {
         g_savedLtfZones[i].touched = true;
         g_savedLtfZones[i].used    = true;
         g_ltfZoneDrawEnd[i]        = bar.time;
         if(InpEnableLog)
            PrintFormat("AjipSnD: %s zone [%.5f, %.5f] first touch SKIPPED by favW filter (favW=%.2f outside [%.2f, %.2f])",
                        isDemand ? "DEMAND" : "SUPPLY", zLow, zHigh, SavedZoneFavW(i), InpMinFavW, InpMaxFavW);
         continue;
        }

      if(WidthFilterBlocks(i))
        {
         g_savedLtfZones[i].touched = true;
         g_savedLtfZones[i].used    = true;
         g_ltfZoneDrawEnd[i]        = bar.time;
         if(InpEnableLog)
            PrintFormat("AjipSnD: %s zone [%.5f, %.5f] first touch SKIPPED by width filter (%.1f pts outside [%.0f, %.0f])",
                        isDemand ? "DEMAND" : "SUPPLY", zLow, zHigh,
                        (zHigh - zLow) / g_point, InpMinZoneWidthPoints, InpMaxZoneWidthPoints);
         continue;
        }

      g_savedLtfZones[i].touched = true;
      g_savedLtfZones[i].used    = true;
      g_ltfZoneDrawEnd[i]        = bar.time;

      int    dir       = isDemand ? 1 : -1;
      double zoneWidth = zHigh - zLow;
      double buffer    = InpZoneSlBufferWidthMult * zoneWidth;
      // No rejection bar to anchor to — the touching bar can close anywhere,
      // including deep inside the zone, so its own wick is not a reliable
      // stop reference here. Anchored to the zone's own structural edge
      // instead: breakLevel, the same sweep-aware level that decides BROKEN
      // above — the point at which this zone's own thesis is invalidated,
      // not just wherever this one bar happened to reach. Buffer scales with
      // the zone's own width rather than ATR, so a wider zone gets more room.
      double slPrice = isDemand
                       ? NormalizeDouble(breakLevel - buffer, g_digits)
                       : NormalizeDouble(breakLevel + buffer, g_digits);

      if(isReplay)
        {
         if(InpEnableLog)
            PrintFormat("AjipSnD: AGGRESSIVE ENTRY confirmed (init replay) on %s zone [%.5f, %.5f] — resolved, no live order",
                        isDemand ? "DEMAND" : "SUPPLY", zLow, zHigh);
         continue;
        }

      TryEntry(dir, slPrice, g_savedLtfZones[i].time);
     }
  }

//---- Tick-level entry — reacts to a zone touch the instant it happens,
// without waiting for the current LTF bar to close.
// The trigger (first wick into a saved zone) needs no bar CLOSE to
// evaluate, unlike structural break (which inherently needs a finished bar
// — there is no such thing as a tick "close"), so only the touch trigger
// moves to tick granularity here. Break detection stays exactly where
// CheckRejectionRetests already runs it, once per closed bar.
//
// Never called during OnInit's historical replay (there are no live ticks
// to react to there); CheckRejectionRetests' own bar-close trigger check is
// what resolves a zone's fate during replay instead. In live operation this
// function almost always wins the race — many ticks land inside a single
// LTF bar, so a touch is normally caught here well before that bar ever
// closes — but the bar-close branch is harmless leftover coverage, not a
// conflict: both check g_savedLtfZones[i].used first, so whichever fires
// first is final.
void CheckAggressiveTickEntries()
  {
   int n = ArraySize(g_savedLtfZones);
   if(n == 0) return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;

   for(int i = 0; i < n; i++)
     {
      if(g_savedLtfZones[i].used) continue;

      bool   isDemand = g_savedLtfZones[i].isDemand;
      double zLow     = g_savedLtfZones[i].low;
      double zHigh    = g_savedLtfZones[i].high;

      // tick.bid for both directions — the same reference MT5 builds
      // bar.low/bar.high from by default, so this lines up with what
      // CheckRejectionRetests' own wickedIn check already means.
      bool wickedIn = isDemand ? (tick.bid <= zHigh) : (tick.bid >= zLow);
      if(!wickedIn) continue;

      if(FavWFilterBlocks(i))
        {
         g_savedLtfZones[i].used    = true;
         g_savedLtfZones[i].touched = true;
         g_ltfZoneDrawEnd[i]        = TimeCurrent();
         if(InpEnableLog)
            PrintFormat("AjipSnD: %s zone [%.5f, %.5f] first touch SKIPPED by favW filter (favW=%.2f outside [%.2f, %.2f])",
                        isDemand ? "DEMAND" : "SUPPLY", zLow, zHigh, SavedZoneFavW(i), InpMinFavW, InpMaxFavW);
         continue;
        }

      if(WidthFilterBlocks(i))
        {
         g_savedLtfZones[i].used    = true;
         g_savedLtfZones[i].touched = true;
         g_ltfZoneDrawEnd[i]        = TimeCurrent();
         if(InpEnableLog)
            PrintFormat("AjipSnD: %s zone [%.5f, %.5f] first touch SKIPPED by width filter (%.1f pts outside [%.0f, %.0f])",
                        isDemand ? "DEMAND" : "SUPPLY", zLow, zHigh,
                        (zHigh - zLow) / g_point, InpMinZoneWidthPoints, InpMaxZoneWidthPoints);
         continue;
        }

      g_savedLtfZones[i].used    = true;
      g_savedLtfZones[i].touched = true;
      g_ltfZoneDrawEnd[i]        = TimeCurrent();

      double breakLevel = isDemand
                          ? (g_savedLtfZones[i].sweepLow  > 0 ? g_savedLtfZones[i].sweepLow  : zLow)
                          : (g_savedLtfZones[i].sweepHigh > 0 ? g_savedLtfZones[i].sweepHigh : zHigh);

      int    dir       = isDemand ? 1 : -1;
      double zoneWidth = zHigh - zLow;
      double buffer    = InpZoneSlBufferWidthMult * zoneWidth;
      // Same zone-edge anchor as the bar-close aggressive path — see its
      // own comment above for why the trigger point itself isn't used.
      double slPrice = isDemand
                       ? NormalizeDouble(breakLevel - buffer, g_digits)
                       : NormalizeDouble(breakLevel + buffer, g_digits);

      TryEntry(dir, slPrice, g_savedLtfZones[i].time);
     }
  }

//---- Update LTF on new closed bar ----
// isReplay=true is the OnInit historical replay (see ReplayInitialStructure):
// it skips CSV/diagnostic writes (UpdateZoneTracking, TrackZone+ZoneCsvWrite,
// the excursion/drift probes) and per-bar chart redraws, since those either
// write to disk or are meaningless replayed against bars that already
// happened — but every core structural/decision step (zone detection,
// validation, touch tracking, superseded-marking, the saved-zone watch list)
// still runs exactly as it does live, via the SAME code path, so replay ends
// in the same state continuous live operation would have reached.
void UpdateLTF(const MqlRates &bar, bool isReplay = false)
  {
   if(bar.time == g_ltfLastBarTime)
      return;

   g_ltfLastBarTime = bar.time;

   // Quality tracker per-bar stats (excursions, first touch) — runs during
   // OnInit replay too (pure in-memory struct mutation, no disk write) so a
   // zone seeded from historical bars gets an accurate maxFavPts/touched
   // instead of starting cold at EA restart. See TrackZone's own call site
   // below for why the CSV row itself stays live-only.
   if(NeedsZoneTracking())
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
         LogZoneOutcome("FAILED_OPPOSITE", false, g_ltfPendingZone.isDemand, g_ltfPendingZone.time, isReplay);
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
         AddDemandZone(g_ltfDemandZones, confirmed, isReplay);
         if(InpEnableLog)
            PrintFormat("AjipSnD: LTF DEMAND zone confirmed! [%.5f, %.5f] at %s",
                        confirmed.low, confirmed.high, TimeToString(confirmed.time));
        }
      else
        {
         AddSupplyZone(g_ltfSupplyZones, confirmed, isReplay);
         if(InpEnableLog)
            PrintFormat("AjipSnD: LTF SUPPLY zone confirmed! [%.5f, %.5f] at %s",
                        confirmed.low, confirmed.high, TimeToString(confirmed.time));
        }

      // Quality tracking: g_zoneTracker[] entry (tracker copy carries
      // isHtf=false) is created even during OnInit replay — so a zone
      // confirmed on a historical bar still gets tracked, feeding both the
      // eventual OUTCOME row (if it resolves live) and the chart's runway
      // label. Only the CSV row itself stays live-only: writing it during
      // replay would re-dump the same historical zone's CONFIRM row to disk
      // on every EA restart.
      if(NeedsZoneTracking())
        {
         SnDZone tracked = confirmed;
         TrackZone(tracked, false);
         if(InpZoneQualityLog && !isReplay)
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
     {
      // Bar-close invalidation TP->BE — structural counterpart to the per-tick
      // CheckInvalidationTpToBe. Gated on the same feature flag; never runs
      // during OnInit replay (no live positions to act on, and historical
      // closes must not touch restart-recovered positions).
      if(InpInvalidationTpBeEnabled)
         CheckBarCloseInvalidation(bar);
      DrawSavedLtfZones();
     }
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
// validation, touch/superseded bookkeeping, the saved-zone watch list). It
// never places a real order: CheckRejectionRetests still resolves every
// saved zone's fate against the historical bars that follow it, but
// isReplay suppresses the actual market fill, since by the time this runs
// price has already moved on from wherever a historical trigger closed.
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
   s = LimitTxt(InpWeeklyMaxProfit, InpWeeklyMaxLoss, weekPnl + floating);
   PANEL_LABEL("Weekly:    " + s, LimitCol(s));

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
