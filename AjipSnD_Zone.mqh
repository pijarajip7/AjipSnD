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
           }
        }
      
      if(candidate.time != 0)
        {
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
           }
        }
      
      if(candidate.time != 0)
        {
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
         CancelPendingForZone(false, zones[i].time);
         ArrayRemove(zones, i, 1);
        }
     }
   
   int sz = ArraySize(zones);
   ArrayResize(zones, sz + 1);
   zones[sz] = newZone;
   
   while(ArraySize(zones) > InpMaxZones)
     {
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
         ArrayRemove(g_htfSupplyZones, i, 1);
         anyChange = true;
        }
     }

   return(anyChange);
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

   for(int i = 0; i < ArraySize(g_htfDemandZones); i++)
     {
      string name = prefix + "Demand_" + IntegerToString(i);
      if(!ObjectCreate(0, name, OBJ_RECTANGLE, 0,
                       g_htfDemandZones[i].time, g_htfDemandZones[i].high,
                       TimeCurrent(), g_htfDemandZones[i].low))
         continue;
      ObjectSetInteger(0, name, OBJPROP_COLOR, clrDodgerBlue);
      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DOT);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
      ObjectSetInteger(0, name, OBJPROP_FILL, true);
     }

   for(int i = 0; i < ArraySize(g_htfSupplyZones); i++)
     {
      string name = prefix + "Supply_" + IntegerToString(i);
      if(!ObjectCreate(0, name, OBJ_RECTANGLE, 0,
                       g_htfSupplyZones[i].time, g_htfSupplyZones[i].low,
                       TimeCurrent(), g_htfSupplyZones[i].high))
         continue;
      ObjectSetInteger(0, name, OBJPROP_COLOR, clrOrangeRed);
      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DOT);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
      ObjectSetInteger(0, name, OBJPROP_FILL, true);
     }
  }

#endif // AJIPSND_ZONE_MQH
