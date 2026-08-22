#ifndef AJIPSND_ZONE_MQH
#define AJIPSND_ZONE_MQH

//==================================================================
// SnD ZONE DETECTION — Supply & Demand zone finder with bar sweep.
//
// Algorithm:
//   Downtrend (looking for demand):
//     - bear candle → candidate = {high, low}
//     - any candle low < candidate.low → update candidate.low
//     - sweep: bar.high > candidate.high AND bar.close ≤ candidate.high
//       → record sweepHigh = max(sweepHigh, bar.high)
//     - confirmation: bar.close > (sweepHigh if swept else candidate.high)
//
//   Uptrend (looking for supply): mirror
//==================================================================

//---- Check if a bar is bearish ----
bool IsBearBar(const MqlRates &bar)
  {
   return(bar.close < bar.open);
  }

//---- Check if a bar is bullish ----
bool IsBullBar(const MqlRates &bar)
  {
   return(bar.close > bar.open);
  }

//---- Fill ATR-normalised metrics + evaluate the entry quality gate ----
// Runs for every confirmed zone regardless of InpZoneQualityLog, because
// qualityPass gates entries. Backtest over two separate 12-month XAUUSD
// periods: neither threshold does anything on its own — width alone and
// displacement alone both leave the MFE/MAE ratio at the baseline. Together
// they lift median MFE without moving MAE, and that held out of sample.
void ComputeZoneMetrics(SnDZone &zone, bool htf, const MqlRates &confirmBar)
  {
   zone.isHtf        = htf;
   zone.confirmClose = confirmBar.close;
   zone.atrAtConfirm = GetAtrValue();

   double width = zone.high - zone.low;
   double body  = MathAbs(confirmBar.close - confirmBar.open);
   double range = confirmBar.high - confirmBar.low;

   if(zone.atrAtConfirm <= 0)
     {
      // No ATR reading — metrics are unmeasurable. Fail open so a broken
      // indicator handle cannot silently stop all trading, but say so.
      zone.widthAtr = zone.dispBodyAtr = zone.dispRangeAtr = 0.0;
      zone.qualityPass = true;
      PrintFormat("AjipSnD: ATR unavailable on %s — zone quality gate skipped for this zone",
                  htf ? "HTF" : "LTF");
      return;
     }

   zone.widthAtr     = width / zone.atrAtConfirm;
   zone.dispBodyAtr  = body  / zone.atrAtConfirm;
   zone.dispRangeAtr = range / zone.atrAtConfirm;

   zone.qualityPass = (InpMaxZoneWidthAtr <= 0 || zone.widthAtr    <  InpMaxZoneWidthAtr)
                   && (InpMinDispBodyAtr  <= 0 || zone.dispBodyAtr >= InpMinDispBodyAtr);
  }

//---- Process one bar for zone detection, return true if zone confirmed ----
bool ProcessZoneBar(const MqlRates &bar, ENUM_TREND &trend,
                    SnDZone &candidate, SnDZone &confirmed)
  {
   if(trend == TREND_DOWN)
     {
      // Looking for DEMAND zone — keep bear candle with LOWEST low
      if(IsBearBar(bar))
        {
         if(candidate.time == 0 || bar.low < candidate.low)
           {
            // New candidate: this bear has a lower low
            candidate.high     = bar.high;
            candidate.low      = bar.low;
            candidate.time     = bar.time;
            candidate.isDemand = true;
            candidate.sweepHigh = 0;
            candidate.sweepLow  = 0;
            candidate.sweepHighCount = 0;
            candidate.sweepLowCount  = 0;
            candidate.baseBars  = 0;
           }
        }

      if(candidate.time != 0)
        {
         candidate.baseBars++;
         // Update low if deeper wick
         if(bar.low < candidate.low)
            candidate.low = bar.low;

         // --- Bar sweep detection ---
         // Sweep above: wick above candidate.high, close stays below → liquidity grab.
         // Sweep below: wick below candidate.low, close stays above → support test.
         if(bar.high > candidate.high && bar.close <= candidate.high)
           {
            candidate.sweepHighCount++;
            if(bar.high > candidate.sweepHigh)
               candidate.sweepHigh = bar.high;
           }
         if(bar.low < candidate.low && bar.close >= candidate.low)
           {
            candidate.sweepLowCount++;
            if(bar.low < candidate.sweepLow || candidate.sweepLow == 0)
               candidate.sweepLow = bar.low;
           }

         // --- Confirmation ---
         // If swept: need close > sweepHigh (broke above the liquidity grab level).
         // If not swept: close > candidate.high as before.
         double breakLevel = (candidate.sweepHigh > 0)
                             ? candidate.sweepHigh
                             : candidate.high;

         if(bar.close > breakLevel)
           {
            confirmed = candidate;
            trend = TREND_UP;

            // Seed confirming bar as first supply candidate (anti fake-confirmation)
            if(IsBullBar(bar))
              {
               candidate.high     = bar.high;
               candidate.low      = bar.low;
               candidate.time     = bar.time;
               candidate.isDemand = false;
               candidate.sweepHigh = 0;
               candidate.sweepLow  = 0;
               candidate.sweepHighCount = 0;
               candidate.sweepLowCount  = 0;
              }
            else
               ZeroMemory(candidate);

            return(true);
           }
        }
     }
   else  // TREND_UP
     {
      // Looking for SUPPLY zone — keep bull candle with HIGHEST high
      if(IsBullBar(bar))
        {
         if(candidate.time == 0 || bar.high > candidate.high)
           {
            // New candidate: this bull has a higher high
            candidate.high     = bar.high;
            candidate.low      = bar.low;
            candidate.time     = bar.time;
            candidate.isDemand = false;
            candidate.sweepHigh = 0;
            candidate.sweepLow  = 0;
            candidate.sweepHighCount = 0;
            candidate.sweepLowCount  = 0;
            candidate.baseBars  = 0;
           }
        }

      if(candidate.time != 0)
        {
         candidate.baseBars++;
         if(bar.high > candidate.high)
            candidate.high = bar.high;

         // --- Bar sweep detection ---
         // Sweep below: wick below candidate.low, close stays above → liquidity grab.
         // Sweep above: wick above candidate.high, close stays below → resistance test.
         if(bar.low < candidate.low && bar.close >= candidate.low)
           {
            candidate.sweepLowCount++;
            if(bar.low < candidate.sweepLow || candidate.sweepLow == 0)
               candidate.sweepLow = bar.low;
           }
         if(bar.high > candidate.high && bar.close <= candidate.high)
           {
            candidate.sweepHighCount++;
            if(bar.high > candidate.sweepHigh || candidate.sweepHigh == 0)
               candidate.sweepHigh = bar.high;
           }

         // --- Confirmation ---
         // If swept: need close < sweepLow (broke below the liquidity grab level).
         // If not swept: close < candidate.low as before.
         double breakLevel = (candidate.sweepLow > 0)
                             ? candidate.sweepLow
                             : candidate.low;

         if(bar.close < breakLevel)
           {
            confirmed = candidate;
            trend = TREND_DOWN;

            // Seed confirming bar as first demand candidate (anti fake-confirmation)
            if(IsBearBar(bar))
              {
               candidate.high     = bar.high;
               candidate.low      = bar.low;
               candidate.time     = bar.time;
               candidate.isDemand = true;
               candidate.sweepHigh = 0;
               candidate.sweepLow  = 0;
               candidate.sweepHighCount = 0;
               candidate.sweepLowCount  = 0;
              }
            else
               ZeroMemory(candidate);

            return(true);
           }
        }
     }
   
   return(false);
  }

//---- Manage active zones: insert, enforce max count, deactivate older if
// better. isReplay forwards to LogZoneOutcome so eviction during OnInit
// replay still stops tracking (trackingActive=false) without writing a CSV
// row for a zone that only ever existed inside the replay window — avoids
// re-dumping duplicate REPLACED/EXPIRED rows on every EA restart. ----
void AddDemandZone(SnDZone &zones[], const SnDZone &newZone, bool isReplay = false)
  {
   // Check if new zone invalidates any existing
   for(int i = ArraySize(zones) - 1; i >= 0; i--)
     {
      if(newZone.low < zones[i].low)
        {
         // New zone is LOWER → old zone deactivated
         LogZoneOutcome("REPLACED", zones[i].isHtf, zones[i].isDemand, zones[i].time, isReplay);
         ArrayRemove(zones, i, 1);
         continue;
        }
      // HTF only: a zone already touched (retested) goes stale the moment a
      // fresh HTF demand zone confirms, regardless of whether the new zone is
      // "lower" by the check above — the market has produced new structure,
      // so the old zone is trading yesterday's setup.
      if(zones[i].isHtf && zones[i].touched)
        {
         LogZoneOutcome("TOUCHED_SUPERSEDED", true, true, zones[i].time, isReplay);
         ArrayRemove(zones, i, 1);
        }
     }

   // Add new zone
   int sz = ArraySize(zones);
   ArrayResize(zones, sz + 1);
   zones[sz] = newZone;

   // Enforce InpMaxZones
   while(ArraySize(zones) > InpMaxZones)
     {
      // Remove oldest (index 0)
      LogZoneOutcome("EXPIRED", zones[0].isHtf, zones[0].isDemand, zones[0].time, isReplay);
      ArrayRemove(zones, 0, 1);
     }
  }

void AddSupplyZone(SnDZone &zones[], const SnDZone &newZone, bool isReplay = false)
  {
   for(int i = ArraySize(zones) - 1; i >= 0; i--)
     {
      if(newZone.high > zones[i].high)
        {
         // New zone is HIGHER → old zone deactivated
         LogZoneOutcome("REPLACED", zones[i].isHtf, zones[i].isDemand, zones[i].time, isReplay);
         ArrayRemove(zones, i, 1);
         continue;
        }
      // HTF only — see AddDemandZone's matching comment.
      if(zones[i].isHtf && zones[i].touched)
        {
         LogZoneOutcome("TOUCHED_SUPERSEDED", true, false, zones[i].time, isReplay);
         ArrayRemove(zones, i, 1);
        }
     }

   int sz = ArraySize(zones);
   ArrayResize(zones, sz + 1);
   zones[sz] = newZone;

   while(ArraySize(zones) > InpMaxZones)
     {
      LogZoneOutcome("EXPIRED", zones[0].isHtf, zones[0].isDemand, zones[0].time, isReplay);
      ArrayRemove(zones, 0, 1);
     }
  }

//---- Count zones that passed the quality gate (panel display) ----
int CountTradeableZones(const SnDZone &zones[])
  {
   int n = 0;
   for(int i = 0; i < ArraySize(zones); i++)
      if(zones[i].qualityPass) n++;
   return(n);
  }

//---- Find initial trend from N bars: highest first = DOWN, lowest first = UP ----
ENUM_TREND DetermineInitialTrend(const MqlRates &rates[], int count)
  {
   int highIdx = 0, lowIdx = 0;
   double highest = rates[0].high;
   double lowest  = rates[0].low;
   
   for(int i = 1; i < count; i++)
     {
      if(rates[i].high > highest)
        {
         highest = rates[i].high;
         highIdx = i;
        }
      if(rates[i].low < lowest)
        {
         lowest = rates[i].low;
         lowIdx = i;
        }
     }
   
   if(highIdx < lowIdx)
      return(TREND_DOWN);
   return(TREND_UP);
  }

//---- Replay bars from originIdx to build initial zones ----
void ReplayZoneBars(const MqlRates &rates[], int startIdx, int count,
                    ENUM_TREND &trend, SnDZone &demandZones[],
                    SnDZone &supplyZones[], SnDZone &candidate)
  {
   trend = DetermineInitialTrend(rates, startIdx + 1);
   
   for(int i = startIdx + 1; i < count; i++)
     {
      SnDZone confirmed;
      ZeroMemory(confirmed);
      if(ProcessZoneBar(rates[i], trend, candidate, confirmed))
        {
         if(confirmed.isDemand)
            AddDemandZone(demandZones, confirmed);
         else
            AddSupplyZone(supplyZones, confirmed);
         
         // Candidate already seeded by ProcessZoneBar
        }
     }
  }

//---- Draw a single zone rectangle ----
void DrawZoneRect(string name, datetime time, datetime endTime, double price1, double price2, color clr)
  {
   if(!ObjectCreate(0, name, OBJ_RECTANGLE, 0, time, price1, endTime, price2))
      return;
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DOT);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_FILL, true);
  }

//---- Draw a small text label anchored on its RIGHT side at (time, price) —
// text extends leftward from that point, so anchoring at a zone's right
// edge keeps the whole label inside the rectangle instead of spilling past
// it. Used for diagnostic-tracker fields that only become meaningful
// partway through a zone's watch life (e.g. favBeforeTouchWidthRatio,
// unknown until first touch). ----
void DrawZoneLabel(string name, datetime time, double price, string text, color clr)
  {
   if(!ObjectCreate(0, name, OBJ_TEXT, 0, time, price))
     {
      // Diagnostic only, not spammed per-bar: this path should essentially
      // never trigger, so a hit here is real signal that the label isn't a
      // pure rendering/visibility issue but an actual creation failure.
      if(InpEnableLog)
         PrintFormat("AjipSnD: label ObjectCreate FAILED for %s at %s / %.5f (err=%d)",
                     name, TimeToString(time), price, GetLastError());
      return;
     }
   ObjectSetString(0, name, OBJPROP_TEXT, text);
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, name, OBJPROP_ZORDER, 100);
   ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_RIGHT);
  }

//---- Draw every saved LTF zone — the only chart objects. Never deleted once
// drawn: a still-watched zone's right edge keeps extending to "now" every
// call, and a resolved one (g_ltfZoneDrawEnd[i] != 0 — traded,
// structurally broken, or superseded) freezes at the bar it resolved on,
// instead of vanishing or continuing to extend.
//
// A zone already drawn in that final frozen form (g_ltfZoneDrawFrozen[i])
// is skipped outright — its rectangle never changes again, so there is
// nothing left to update. Only still-live zones, plus whichever zone just
// resolved THIS call, actually touch the object manager — redraw cost
// tracks the (small, bounded) watch list, not the ever-growing total of
// every zone this EA has ever confirmed. ----
void DrawSavedLtfZones()
  {
   if(!InpDrawLines) return;

   string prefix = g_objPrefix + "LTF_";
   int n = ArraySize(g_savedLtfZones);
   for(int i = 0; i < n; i++)
     {
      if(g_ltfZoneDrawFrozen[i]) continue;

      bool resolved = (g_ltfZoneDrawEnd[i] > 0);
      datetime endTime = resolved ? g_ltfZoneDrawEnd[i] : TimeCurrent();
      color    clr     = g_savedLtfZones[i].isDemand ? clrDodgerBlue : clrOrangeRed;

      string name = prefix + IntegerToString(i);
      ObjectDelete(0, name);   // no-op if this zone hasn't been drawn yet
      DrawZoneRect(name, g_savedLtfZones[i].time, endTime,
                   g_savedLtfZones[i].high, g_savedLtfZones[i].low, clr);

      // Before first touch there is no favBeforeTouchWidthRatio yet (that
      // field only gets set AT touch) — but the running maxFavPts it will be
      // built from is already live, updated every bar regardless of touch
      // state. Show that as a "~"-prefixed preview, recomputed fresh every
      // redraw, so the number is visible while it is still moving. Once
      // touched, switch to the frozen, officially-recorded value (the same
      // one that lands in the CSV) — the two are identical at the exact
      // touch bar, so the switch never jumps, only stops moving.
      string lblName = name + "_ratio";
      ObjectDelete(0, lblName);
      int tIdx = g_ltfZoneTrackerIdx[i];
      if(tIdx >= 0 && tIdx < ArraySize(g_zoneTracker))
        {
         // Zone width (points) is the favW denominator — fixed at save time,
         // no tracker dependency — so it is shown alongside the ratio. The
         // ratio is live ("~") until first touch, then frozen; the width is
         // constant for the zone's whole life.
         double widthPts = (g_savedLtfZones[i].high - g_savedLtfZones[i].low) / g_point;
         string txt;
         if(g_zoneTracker[tIdx].touched)
            txt = StringFormat("favW %.2f · %.0fpts", g_zoneTracker[tIdx].favBeforeTouchWidthRatio, widthPts);
         else
           {
            double liveRatio = (widthPts > 0) ? (g_zoneTracker[tIdx].maxFavPts / widthPts) : 0.0;
            txt = StringFormat("favW~%.2f · %.0fpts", liveRatio, widthPts);
           }
         // clrWhite, not the zone's own clr: the rectangle is a SOLID fill
         // in that same color (OBJPROP_FILL=true), so same-color text on
         // top of it has zero contrast and is invisible regardless of
         // z-order or position — confirmed from a live screenshot where
         // the rectangles render as fully opaque blocks.
         double midPrice = (g_savedLtfZones[i].high + g_savedLtfZones[i].low) / 2.0;
         DrawZoneLabel(lblName, endTime, midPrice, txt, clrWhite);
        }

      if(resolved)
         g_ltfZoneDrawFrozen[i] = true;   // final form — never touched again
     }
  }

//==================================================================
// ZONE QUALITY TRACKER — CSV backtest analysis log.
// Live-confirmed zones are tracked from confirmation to outcome.
// One row per event; CONFIRM + OUTCOME join via TF/isDemand/zone_time.
//==================================================================

//---- CSV filename (Common\Files) ----
string ZoneCsvFilename()
  {
   return("AjipSnD_Zones_" + _Symbol + "_"
          + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + ".csv");
  }

//---- Append one zone event row ----
void ZoneCsvWrite(string action, const SnDZone &zone, string outcome)
  {
   string filename = ZoneCsvFilename();
   bool exists = FileIsExist(filename, FILE_COMMON);

   // FILE_CSV makes FileWrite insert the delimiter between fields; with plain
   // FILE_TXT every field is concatenated into one unparseable string.
   // FILE_ANSI is what makes the CP_UTF8 codepage apply — without it the file
   // is written as UTF-16.
   int handle = FileOpen(filename,
                         FILE_COMMON | FILE_WRITE | FILE_READ | FILE_CSV | FILE_ANSI,
                         ',', CP_UTF8);
   if(handle == INVALID_HANDLE)
     {
      if(InpEnableLog)
         PrintFormat("AjipSnD: Cannot open zone CSV %s", filename);
      return;
     }

   // Header if new file — one argument per column, so the delimiter count
   // always matches the data rows below
   if(!exists)
     {
      FileWrite(handle,
         "action", "outcome", "tf", "type", "zone_time",
         "high", "low", "confirm_close", "confirm_level",
         "atr", "width_atr", "disp_body_atr", "disp_range_atr", "base_bars",
         "swept_low", "swept_high", "sweep_low_count", "sweep_high_count",
         "validated", "entry_placed", "quality_pass",
         "bars_since", "bars_to_touch", "touched", "touch_depth_pts",
         "max_fav_pts", "max_adv_pts", "fav_before_touch_pts", "fav_before_touch_width_ratio",
         "fav_after_touch_pts", "trend_at_confirm",
         "touched_at_validation", "bars_to_validate", "validate_sweep_count");
     }
   else
      FileSeek(handle, 0, SEEK_END);

   FileWrite(handle,
      action, outcome,
      zone.isHtf ? "HTF" : "LTF",
      zone.isDemand ? "DEMAND" : "SUPPLY",
      TimeToString(zone.time, TIME_DATE | TIME_SECONDS),
      DoubleToString(zone.high, g_digits),
      DoubleToString(zone.low, g_digits),
      DoubleToString(zone.confirmClose, g_digits),
      DoubleToString(zone.confirmLevel, g_digits),
      DoubleToString(zone.atrAtConfirm, g_digits),
      DoubleToString(zone.widthAtr, 2),
      DoubleToString(zone.dispBodyAtr, 2),
      DoubleToString(zone.dispRangeAtr, 2),
      IntegerToString(zone.baseBars),
      zone.sweepLow > 0 ? "1" : "0",
      zone.sweepHigh > 0 ? "1" : "0",
      IntegerToString(zone.sweepLowCount),
      IntegerToString(zone.sweepHighCount),
      zone.validated ? "1" : "0",
      zone.entryPlaced ? "1" : "0",
      zone.qualityPass ? "1" : "0",
      IntegerToString(zone.barsSinceConfirm),
      IntegerToString(zone.barsToTouch),
      zone.touched ? "1" : "0",
      DoubleToString(zone.touchDepthPts, 1),
      DoubleToString(zone.maxFavPts, 1),
      DoubleToString(zone.maxAdvPts, 1),
      DoubleToString(zone.favBeforeTouchPts, 1),
      DoubleToString(zone.favBeforeTouchWidthRatio, 3),
      DoubleToString(zone.favAfterTouchPts, 1),
      zone.trendAtConfirm == TREND_UP ? "UP" : "DOWN",
      zone.touchedAtValidation ? "1" : "0",
      IntegerToString(zone.barsToValidate),
      IntegerToString(zone.validateSweepCount));

   FileClose(handle);
  }

//---- Register a zone in the quality tracker ----
// Metrics must already be filled by ComputeZoneMetrics().
void TrackZone(SnDZone &zone, bool htf)
  {
   zone.trendAtConfirm = g_ltfTrend;
   zone.validated      = false;
   zone.entryPlaced    = false;
   zone.trackingActive = true;
   zone.touched        = false;
   zone.barsSinceConfirm  = 0;
   zone.barsToTouch       = 0;
   zone.touchDepthPts     = 0.0;
   zone.maxFavPts         = 0.0;
   zone.maxAdvPts         = 0.0;
   zone.favBeforeTouchPts         = 0.0;
   zone.favBeforeTouchWidthRatio  = 0.0;
   zone.favAfterTouchPts  = 0.0;
   zone.touchedAtValidation = false;
   zone.barsToValidate      = 0;   // not yet known — filled in by MarkLtfValidationContext
   zone.validateSweepCount  = 0;   // not yet known — filled in by MarkLtfValidationContext

   int sz = ArraySize(g_zoneTracker);
   ArrayResize(g_zoneTracker, sz + 1);
   g_zoneTracker[sz] = zone;
  }

//---- Per-bar stats: excursions, first touch ----
void UpdateZoneTracking(const MqlRates &bar, bool htf)
  {
   int n = ArraySize(g_zoneTracker);
   for(int i = 0; i < n; i++)
     {
      if(!g_zoneTracker[i].trackingActive) continue;
      if(g_zoneTracker[i].isHtf != htf) continue;
      if(bar.time <= g_zoneTracker[i].time) continue; // skip confirmation bar itself

      g_zoneTracker[i].barsSinceConfirm++;
      double base = g_zoneTracker[i].confirmClose;

      if(g_zoneTracker[i].isDemand)
        {
         // Favorable = up (BUY side) — stored in points
         double fav  = (bar.high - base) / g_point;
         double adv  = (base - bar.low) / g_point;
         if(fav > g_zoneTracker[i].maxFavPts) g_zoneTracker[i].maxFavPts = fav;
         if(adv > g_zoneTracker[i].maxAdvPts) g_zoneTracker[i].maxAdvPts = adv;

         // First touch: wick re-enters zone range [low, high]
         if(!g_zoneTracker[i].touched && bar.low <= g_zoneTracker[i].high)
           {
            g_zoneTracker[i].touched       = true;
            g_zoneTracker[i].barsToTouch   = g_zoneTracker[i].barsSinceConfirm;
            double depth = (g_zoneTracker[i].high - bar.low) / g_point;
            if(depth < 0) depth = 0;
            g_zoneTracker[i].touchDepthPts = depth;

            // How far price ran favorably before coming back, vs the zone's
            // own width — maxFavPts is already updated for this same bar
            // above, so this is "as of the bar that touched."
            g_zoneTracker[i].favBeforeTouchPts = g_zoneTracker[i].maxFavPts;
            double widthPts = (g_zoneTracker[i].high - g_zoneTracker[i].low) / g_point;
            g_zoneTracker[i].favBeforeTouchWidthRatio =
               (widthPts > 0) ? (g_zoneTracker[i].favBeforeTouchPts / widthPts) : 0.0;
           }
         if(g_zoneTracker[i].touched)
           {
            double favT = (bar.high - base) / g_point;
            if(favT > g_zoneTracker[i].favAfterTouchPts)
               g_zoneTracker[i].favAfterTouchPts = favT;
           }
        }
      else
        {
         // Favorable = down (SELL side) — stored in points
         double fav  = (base - bar.low) / g_point;
         double adv  = (bar.high - base) / g_point;
         if(fav > g_zoneTracker[i].maxFavPts) g_zoneTracker[i].maxFavPts = fav;
         if(adv > g_zoneTracker[i].maxAdvPts) g_zoneTracker[i].maxAdvPts = adv;

         // First touch: wick re-enters zone range [low, high]
         if(!g_zoneTracker[i].touched && bar.high >= g_zoneTracker[i].low)
           {
            g_zoneTracker[i].touched       = true;
            g_zoneTracker[i].barsToTouch   = g_zoneTracker[i].barsSinceConfirm;
            double depth = (bar.high - g_zoneTracker[i].low) / g_point;
            if(depth < 0) depth = 0;
            g_zoneTracker[i].touchDepthPts = depth;

            // How far price ran favorably before coming back, vs the zone's
            // own width — maxFavPts is already updated for this same bar
            // above, so this is "as of the bar that touched."
            g_zoneTracker[i].favBeforeTouchPts = g_zoneTracker[i].maxFavPts;
            double widthPts = (g_zoneTracker[i].high - g_zoneTracker[i].low) / g_point;
            g_zoneTracker[i].favBeforeTouchWidthRatio =
               (widthPts > 0) ? (g_zoneTracker[i].favBeforeTouchPts / widthPts) : 0.0;
           }
         if(g_zoneTracker[i].touched)
           {
            double favT = (base - bar.low) / g_point;
            if(favT > g_zoneTracker[i].favAfterTouchPts)
               g_zoneTracker[i].favAfterTouchPts = favT;
           }
        }
     }
  }

//---- Find a tracked zone by TF + type + confirmation time ----
// Only zones still collecting stats are matched. A resolved zone keeps its
// slot in the array, and matching it again would write a second OUTCOME row
// carrying frozen stats (UpdateZoneTracking skips inactive entries).
int FindTrackedZone(bool htf, bool isDemand, datetime zoneTime)
  {
   for(int i = 0; i < ArraySize(g_zoneTracker); i++)
     {
      if(g_zoneTracker[i].trackingActive &&
         g_zoneTracker[i].isHtf == htf &&
         g_zoneTracker[i].isDemand == isDemand &&
         g_zoneTracker[i].time == zoneTime)
         return(i);
     }
   return(-1);
  }

//---- Log outcome + stop tracking ----
// isReplay: skip the CSV write (a zone evicted purely inside the OnInit
// replay window would otherwise re-dump a duplicate OUTCOME row on every EA
// restart) but still stop tracking it — same as live, just silent on disk.
void LogZoneOutcome(string outcome, bool htf, bool isDemand, datetime zoneTime, bool isReplay = false)
  {
   int i = FindTrackedZone(htf, isDemand, zoneTime);
   if(i < 0) return;

   if(InpZoneQualityLog && !isReplay)
      ZoneCsvWrite("OUTCOME", g_zoneTracker[i], outcome);
   g_zoneTracker[i].trackingActive = false;
  }

//---- Mark a tracked zone as validated (still collecting outcome) ----
void MarkZoneValidated(bool htf, bool isDemand, datetime zoneTime)
  {
   int i = FindTrackedZone(htf, isDemand, zoneTime);
   if(i >= 0) g_zoneTracker[i].validated = true;
  }

//---- LTF-only: snapshot touch state at the exact validation instant, and
// retire any stale same-direction watch-list entry.
// Must be called right after MarkZoneValidated(false, ...) at the same call
// site, while 'confirmed' is still the pending zone that just passed.
//------------------------------------------------------------------
// touchedAtValidation formerly had a paired htfContextValidated diagnostic —
// dropped along with the rest of the HTF mechanism, but the finding that
// justified dropping it is worth keeping: period A, XAUUSD M1/M15, 21,372
// validated LTF zones. Tested whether a zone that validates before ever
// being touched, inside an already-validated HTF zone, predicts direction.
// Four cells (touched-at-validation x htf-context), direction-adjusted hit
// rate at 5m/15m/1h/4h/1d — HTF context added nothing: the no-touch rows
// tracked each other within a point at every horizon, and so did the
// touched rows. The touch-timing split alone showed a real gap at 5m/15m
// (75%+ vs ~57%) that decayed through 1h/4h and reversed at 1d — the
// signature of the same circularity already found in the plain 'validated'
// flag (a sharp confirming move measured again minutes later, not a fresh
// prediction). touchedAtValidation stays as a reusable, real-time-honest
// primitive; htfContextValidated added nothing and had nothing left to
// compute against once g_htfDemandZones/g_htfSupplyZones were removed.
//------------------------------------------------------------------
// touchedAtValidation is passed in rather than read from g_zoneTracker: that
// tracker only exists when InpZoneQualityLog is on (TrackZone is what
// creates the slot FindTrackedZone below looks up), so deriving it from
// there made the superseded-marking below — not just the CSV diagnostic
// field — silently stop working the moment quality logging was switched
// off. The caller (UpdateLTF) now tracks g_ltfPendingTouched independently
// for exactly this reason, and the same value feeds the OnInit historical
// replay, which never runs TrackZone at all. barsToValidate/
// validateSweepCount have no bearing on the supersede-marking below
// (CSV-diagnostic only), but are threaded the same way for consistency,
// sourced from the caller's own g_ltfPendingBars/g_ltfPendingSweepCount.
void MarkLtfValidationContext(const SnDZone &confirmed, bool touchedAtValidation,
                              int barsToValidate, int validateSweepCount)
  {
   // CSV-diagnostic fields — safe no-op when this zone isn't being tracked
   // (InpZoneQualityLog=false, or the OnInit replay). The loop below is core
   // state and must run regardless.
   int i = FindTrackedZone(false, confirmed.isDemand, confirmed.time);
   if(i >= 0)
     {
      g_zoneTracker[i].touchedAtValidation = touchedAtValidation;
      g_zoneTracker[i].barsToValidate      = barsToValidate;
      g_zoneTracker[i].validateSweepCount  = validateSweepCount;
     }

   // A same-direction watch-list entry already touched by now is stale the
   // moment this fresher zone validates — the earliest possible trigger
   // point (any LTF zone validating), so it is retired here rather than
   // lingering until its own break/touch eventually resolves it.
   for(int j = 0; j < ArraySize(g_savedLtfZones); j++)
     {
      if(g_savedLtfZones[j].used) continue;
      if(g_savedLtfZones[j].isDemand != confirmed.isDemand) continue;
      if(g_savedLtfZones[j].touched)
        {
         g_savedLtfZones[j].used = true;
         g_ltfZoneDrawEnd[j]     = confirmed.time;
         if(InpEnableLog)
            PrintFormat("AjipSnD: %s watch zone [%.5f, %.5f] touched+superseded by fresher zone — retired",
                        g_savedLtfZones[j].isDemand ? "DEMAND" : "SUPPLY",
                        g_savedLtfZones[j].low, g_savedLtfZones[j].high);
        }
     }
  }

//---- Flush unresolved trackers on EA deinit ----
void FlushUnresolvedZoneOutcomes()
  {
   for(int i = 0; i < ArraySize(g_zoneTracker); i++)
     {
      if(!g_zoneTracker[i].trackingActive) continue;
      ZoneCsvWrite("OUTCOME", g_zoneTracker[i], "UNRESOLVED");
      g_zoneTracker[i].trackingActive = false;
     }
   ArrayFree(g_zoneTracker);
  }

#endif // AJIPSND_ZONE_MQH
