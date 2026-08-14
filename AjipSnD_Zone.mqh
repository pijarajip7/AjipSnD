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
            if(bar.high > candidate.sweepHigh)
               candidate.sweepHigh = bar.high;
           }
         if(bar.low < candidate.low && bar.close >= candidate.low)
           {
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
            if(bar.low < candidate.sweepLow || candidate.sweepLow == 0)
               candidate.sweepLow = bar.low;
           }
         if(bar.high > candidate.high && bar.close <= candidate.high)
           {
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
              }
            else
               ZeroMemory(candidate);

            return(true);
           }
        }
     }
   
   return(false);
  }

//---- Manage active zones: insert, enforce max count, deactivate older if better ----
void AddDemandZone(SnDZone &zones[], const SnDZone &newZone)
  {
   // Check if new zone invalidates any existing
   for(int i = ArraySize(zones) - 1; i >= 0; i--)
     {
      if(newZone.low < zones[i].low)
        {
         // New zone is LOWER → old zone deactivated, cancel its pending
         LogZoneOutcome("REPLACED", zones[i].isHtf, zones[i].isDemand, zones[i].time);
         CancelPendingForZone(true, zones[i].time);
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
      LogZoneOutcome("EXPIRED", zones[0].isHtf, zones[0].isDemand, zones[0].time);
      ArrayRemove(zones, 0, 1);
     }
  }

void AddSupplyZone(SnDZone &zones[], const SnDZone &newZone)
  {
   for(int i = ArraySize(zones) - 1; i >= 0; i--)
     {
      if(newZone.high > zones[i].high)
        {
         // New zone is HIGHER → old zone deactivated, cancel its pending
         LogZoneOutcome("REPLACED", zones[i].isHtf, zones[i].isDemand, zones[i].time);
         CancelPendingForZone(false, zones[i].time);
         ArrayRemove(zones, i, 1);
        }
     }
  
   int sz = ArraySize(zones);
   ArrayResize(zones, sz + 1);
   zones[sz] = newZone;
  
   while(ArraySize(zones) > InpMaxZones)
     {
      LogZoneOutcome("EXPIRED", zones[0].isHtf, zones[0].isDemand, zones[0].time);
      ArrayRemove(zones, 0, 1);
     }
  }

//---- Check if price is inside any active demand zone ----
bool IsPriceInDemandZone(double price, const SnDZone &zones[])
  {
   for(int i = 0; i < ArraySize(zones); i++)
     {
      if(price <= zones[i].high && price >= zones[i].low)
         return(true);
     }
   return(false);
  }

//---- Check if price is inside any active supply zone ----
bool IsPriceInSupplyZone(double price, const SnDZone &zones[])
  {
   for(int i = 0; i < ArraySize(zones); i++)
     {
      if(price >= zones[i].low && price <= zones[i].high)
         return(true);
     }
   return(false);
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

//---- Invalidate HTF zones on new closed bar ----
// Returns true if any zone was removed (caller should redraw).
bool InvalidateHtfZones(const MqlRates &bar)
  {
   bool anyChange = false;

   // Check demand zones — invalid if support broken (close < sweepLow if swept, else close < low)
   for(int i = ArraySize(g_htfDemandZones) - 1; i >= 0; i--)
     {
      double breakLevel = (g_htfDemandZones[i].sweepLow > 0)
                          ? g_htfDemandZones[i].sweepLow
                          : g_htfDemandZones[i].low;
      if(bar.close < breakLevel)
        {
         if(InpEnableLog)
            PrintFormat("AjipSnD: HTF DEMAND zone INVALID [%.5f, %.5f] sweepLow=%.5f bar.close=%.5f",
                        g_htfDemandZones[i].low, g_htfDemandZones[i].high,
                        g_htfDemandZones[i].sweepLow, bar.close);
         LogZoneOutcome("INVALIDATED", true, g_htfDemandZones[i].isDemand, g_htfDemandZones[i].time);
         ArrayRemove(g_htfDemandZones, i, 1);
         anyChange = true;
        }
     }

   // Check supply zones — invalid if resistance broken (close > sweepHigh if swept, else close > high)
   for(int i = ArraySize(g_htfSupplyZones) - 1; i >= 0; i--)
     {
      double breakLevel = (g_htfSupplyZones[i].sweepHigh > 0)
                          ? g_htfSupplyZones[i].sweepHigh
                          : g_htfSupplyZones[i].high;
      if(bar.close > breakLevel)
        {
         if(InpEnableLog)
            PrintFormat("AjipSnD: HTF SUPPLY zone INVALID [%.5f, %.5f] sweepHigh=%.5f bar.close=%.5f",
                        g_htfSupplyZones[i].low, g_htfSupplyZones[i].high,
                        g_htfSupplyZones[i].sweepHigh, bar.close);
         LogZoneOutcome("INVALIDATED", true, g_htfSupplyZones[i].isDemand, g_htfSupplyZones[i].time);
         ArrayRemove(g_htfSupplyZones, i, 1);
         anyChange = true;
        }
     }

   return(anyChange);
  }

//---- Draw a single HTF zone rectangle ----
void DrawHtfZoneRect(string name, datetime time, double price1, double price2, color clr)
  {
   if(!ObjectCreate(0, name, OBJ_RECTANGLE, 0, time, price1, TimeCurrent(), price2))
      return;
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DOT);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_FILL, true);
  }

//---- Draw all active HTF zones as rectangles ----
void DrawAllHtfZones()
  {
   if(!InpDrawLines) return;

   string prefix = g_objPrefix + "HTF_";
   // Clean old objects  
   for(int i = ObjectsTotal(0) - 1; i >= 0; i--)
     {
      string objName = ObjectName(0, i);
      if(StringFind(objName, prefix) == 0)
         ObjectDelete(0, objName);
     }

   // Validated demand zones (blue)
   for(int i = 0; i < ArraySize(g_htfDemandZones); i++)
      DrawHtfZoneRect(prefix + "Demand_" + IntegerToString(i),
                      g_htfDemandZones[i].time, g_htfDemandZones[i].high,
                      g_htfDemandZones[i].low, clrDodgerBlue);

   // Validated supply zones (red)
   for(int i = 0; i < ArraySize(g_htfSupplyZones); i++)
      DrawHtfZoneRect(prefix + "Supply_" + IntegerToString(i),
                      g_htfSupplyZones[i].time, g_htfSupplyZones[i].low,
                      g_htfSupplyZones[i].high, clrOrangeRed);

   // Pending (unvalidated) zone — distinct colour
   if(InpRequireZoneValidation && g_htfAwaitingValidation)
     {
      if(g_htfPendingZone.isDemand)
         DrawHtfZoneRect(prefix + "Demand_PENDING", g_htfPendingZone.time,
                         g_htfPendingZone.high, g_htfPendingZone.low, clrSteelBlue);
      else
         DrawHtfZoneRect(prefix + "Supply_PENDING", g_htfPendingZone.time,
                         g_htfPendingZone.low, g_htfPendingZone.high, clrIndianRed);
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

   int handle = FileOpen(filename, FILE_COMMON | FILE_WRITE | FILE_READ | FILE_TXT, 0, CP_UTF8);
   if(handle == INVALID_HANDLE)
     {
      if(InpEnableLog)
         PrintFormat("AjipSnD: Cannot open zone CSV %s", filename);
      return;
     }

   // Header if new file
   if(!exists)
     {
      FileWrite(handle,
         "action,outcome,tf,type,zone_time,high,low,confirm_close,confirm_level",
         "atr,width_atr,disp_body_atr,disp_range_atr,base_bars",
         "swept_low,swept_high,validated,entry_placed",
         "bars_since,bars_to_touch,touched,touch_depth_pts",
         "max_fav_pts,max_adv_pts,fav_after_touch_pts,trend_at_confirm");
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
      zone.validated ? "1" : "0",
      zone.entryPlaced ? "1" : "0",
      IntegerToString(zone.barsSinceConfirm),
      IntegerToString(zone.barsToTouch),
      zone.touched ? "1" : "0",
      DoubleToString(zone.touchDepthPts, 1),
      DoubleToString(zone.maxFavPts, 1),
      DoubleToString(zone.maxAdvPts, 1),
      DoubleToString(zone.favAfterTouchPts, 1),
      zone.trendAtConfirm == TREND_UP ? "UP" : "DOWN");

   FileClose(handle);
  }

//---- Fill quality metrics + register in tracker ----
void TrackZone(SnDZone &zone, bool htf, const MqlRates &confirmBar)
  {
   zone.isHtf          = htf;
   zone.trendAtConfirm = htf ? g_htfTrend : g_ltfTrend;
   zone.confirmClose   = confirmBar.close;
   zone.validated      = false;
   zone.entryPlaced    = false;
   zone.trackingActive = true;
   zone.touched        = false;
   zone.barsSinceConfirm  = 0;
   zone.barsToTouch       = 0;
   zone.touchDepthPts     = 0.0;
   zone.maxFavPts         = 0.0;
   zone.maxAdvPts         = 0.0;
   zone.favAfterTouchPts  = 0.0;

   zone.atrAtConfirm = GetAtrValue(htf);
   double width = zone.high - zone.low;
   double body  = MathAbs(confirmBar.close - confirmBar.open);
   double range = confirmBar.high - confirmBar.low;
   if(zone.atrAtConfirm > 0)
     {
      zone.widthAtr     = width / zone.atrAtConfirm;
      zone.dispBodyAtr  = body  / zone.atrAtConfirm;
      zone.dispRangeAtr = range / zone.atrAtConfirm;
     }

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
int FindTrackedZone(bool htf, bool isDemand, datetime zoneTime)
  {
   for(int i = 0; i < ArraySize(g_zoneTracker); i++)
     {
      if(g_zoneTracker[i].isHtf == htf &&
         g_zoneTracker[i].isDemand == isDemand &&
         g_zoneTracker[i].time == zoneTime)
         return(i);
     }
   return(-1);
  }

//---- Log outcome + stop tracking ----
void LogZoneOutcome(string outcome, bool htf, bool isDemand, datetime zoneTime)
  {
   int i = FindTrackedZone(htf, isDemand, zoneTime);
   if(i < 0) return;

   ZoneCsvWrite("OUTCOME", g_zoneTracker[i], outcome);
   g_zoneTracker[i].trackingActive = false;
  }

//---- Mark a tracked zone as validated (still collecting outcome) ----
void MarkZoneValidated(bool htf, bool isDemand, datetime zoneTime)
  {
   int i = FindTrackedZone(htf, isDemand, zoneTime);
   if(i >= 0) g_zoneTracker[i].validated = true;
  }

//---- Mark entry placed for a tracked LTF zone ----
void MarkZoneEntryPlaced(bool isDemand, datetime zoneTime)
  {
   int i = FindTrackedZone(false, isDemand, zoneTime);
   if(i >= 0) g_zoneTracker[i].entryPlaced = true;
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
