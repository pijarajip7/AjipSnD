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

//==================================================================
// ALTERNATE REJECTION-CONFIRMATION PATTERNS — each an independent OR'd
// criterion CheckRejectionRetests can accept alongside (or instead of) the
// original close-back-out method. All three assume the shared gates already
// passed (zone wicked into, confirming bar's close back outside it) — they
// only judge whether the bar(s) LOOK like a real reversal.
//==================================================================

//---- Engulfing: confirming bar's body fully contains the previous bar's
// body, opposite colors, confirming bar itself strong enough ----
bool IsEngulfing(const MqlRates &cur, const MqlRates &prev, bool isDemand, double atrLtf)
  {
   if(prev.time == 0) return(false);   // not enough history yet (EA just started)

   if(isDemand)
     {
      if(!IsBullBar(cur) || !IsBearBar(prev)) return(false);
      if(!(cur.open <= prev.close && cur.close >= prev.open)) return(false);
     }
   else
     {
      if(!IsBearBar(cur) || !IsBullBar(prev)) return(false);
      if(!(cur.open >= prev.close && cur.close <= prev.open)) return(false);
     }

   double body = MathAbs(cur.close - cur.open);
   return(atrLtf > 0 && body / atrLtf >= InpEngulfingBodyAtr);
  }

//---- Pin bar / hammer: small body, long wick on the rejection side, short
// wick on the other — single bar, no history needed ----
bool IsPinBar(const MqlRates &cur, bool isDemand)
  {
   double body = MathAbs(cur.close - cur.open);
   if(body <= 0) body = _Point;   // avoid div-by-zero on a perfect doji
   double lowerWick = MathMin(cur.open, cur.close) - cur.low;
   double upperWick = cur.high - MathMax(cur.open, cur.close);

   if(isDemand)
      return(lowerWick >= InpPinBarWickRatio * body && lowerWick > upperWick);
   else
      return(upperWick >= InpPinBarWickRatio * body && upperWick > lowerWick);
  }

//---- Morning/evening star: big bar, small indecision bar, big reversal bar
// reclaiming back into the first bar's body ----
bool IsStar(const MqlRates &cur, const MqlRates &prev1, const MqlRates &prev2, bool isDemand)
  {
   if(prev1.time == 0 || prev2.time == 0) return(false);   // not enough history yet

   double bodyFirst  = MathAbs(prev2.close - prev2.open);
   double bodyMiddle = MathAbs(prev1.close - prev1.open);
   if(bodyFirst <= 0) return(false);
   if(bodyMiddle > InpStarMiddleRatio * bodyFirst) return(false);

   if(isDemand)
     {
      if(!IsBearBar(prev2) || !IsBullBar(cur)) return(false);
      double reclaimLevel = prev2.close + InpStarReclaimPct * bodyFirst;
      return(cur.close >= reclaimLevel);
     }
   else
     {
      if(!IsBullBar(prev2) || !IsBearBar(cur)) return(false);
      double reclaimLevel = prev2.close - InpStarReclaimPct * bodyFirst;
      return(cur.close <= reclaimLevel);
     }
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
   zone.atrAtConfirm = GetAtrValue(htf);

   // HTF trend at this moment. On an LTF zone this is the cross-timeframe
   // alignment attribute; trendAtConfirm cannot carry it, because a demand
   // zone only ever confirms out of a DOWN trend on its own timeframe and a
   // supply zone only out of an UP trend, making that field a restatement of
   // isDemand rather than information.
   zone.htfTrendAtConfirm = (int)g_htfTrend;

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
         // New zone is LOWER → old zone deactivated
         LogZoneOutcome("REPLACED", zones[i].isHtf, zones[i].isDemand, zones[i].time);
         ArrayRemove(zones, i, 1);
         continue;
        }
      // HTF only: a zone already touched (retested) goes stale the moment a
      // fresh HTF demand zone confirms, regardless of whether the new zone is
      // "lower" by the check above — the market has produced new structure,
      // so the old zone is trading yesterday's setup.
      if(zones[i].isHtf && zones[i].touched)
        {
         LogZoneOutcome("TOUCHED_SUPERSEDED", true, true, zones[i].time);
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
         // New zone is HIGHER → old zone deactivated
         LogZoneOutcome("REPLACED", zones[i].isHtf, zones[i].isDemand, zones[i].time);
         ArrayRemove(zones, i, 1);
         continue;
        }
      // HTF only — see AddDemandZone's matching comment.
      if(zones[i].isHtf && zones[i].touched)
        {
         LogZoneOutcome("TOUCHED_SUPERSEDED", true, false, zones[i].time);
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

//---- Index of the TRADEABLE zone containing price, or -1 ----
// Zones failing the quality gate stay in the array — they keep taking part in
// replacement, expiry and invalidation exactly as before, so zone lifecycle and
// the CSV log are unchanged — but they are not offered here.
// Used by MarkLtfValidationContext() for the htfContextValidated diagnostic.
//
// When several zones contain the price, the one whose FAR edge sits furthest
// away wins. That only matters to callers wanting the zone itself: a
// structural stop is placed beyond the far edge, so picking the furthest is
// the conservative choice — it never yields a stop tighter than some other
// equally valid zone would have justified.
int FindContainingZoneIdx(double price, const SnDZone &zones[], bool isDemand)
  {
   int    best     = -1;
   double bestEdge = 0.0;

   for(int i = 0; i < ArraySize(zones); i++)
     {
      if(!zones[i].qualityPass) continue;
      if(price < zones[i].low || price > zones[i].high) continue;

      // Demand: stop goes below, so the lowest low is furthest.
      // Supply: stop goes above, so the highest high is furthest.
      double farEdge = isDemand ? zones[i].low : zones[i].high;
      if(best < 0
         || (isDemand  && farEdge < bestEdge)
         || (!isDemand && farEdge > bestEdge))
        {
         best     = i;
         bestEdge = farEdge;
        }
     }
   return(best);
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
      // Live touch tracking — wick re-entry after the zone's own confirm bar.
      // .touched on g_zoneTracker[] is a separate copy updated elsewhere; this
      // is the only writer for the live HTF arrays, and it feeds the
      // touched+superseded invalidation in AddDemandZone/AddSupplyZone below.
      else if(!g_htfDemandZones[i].touched && bar.time > g_htfDemandZones[i].time
              && bar.low <= g_htfDemandZones[i].high)
         g_htfDemandZones[i].touched = true;
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
      else if(!g_htfSupplyZones[i].touched && bar.time > g_htfSupplyZones[i].time
              && bar.high >= g_htfSupplyZones[i].low)
         g_htfSupplyZones[i].touched = true;
     }

   return(anyChange);
  }

//---- Draw a single HTF zone rectangle ----
void DrawHtfZoneRect(string name, datetime time, double price1, double price2, color clr, datetime time2)
  {
   if(!ObjectCreate(0, name, OBJ_RECTANGLE, 0, time, price1, time2, price2))
      return;
   ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DOT);
   ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, name, OBJPROP_BACK, true);
   ObjectSetInteger(0, name, OBJPROP_FILL, true);
  }

//---- Draw saved (awaiting-rejection or resolved) LTF zones — the only chart
// objects. HTF is a directional bias, not a price range to draw — the LTF
// zone is the thing actually worth watching move to move. A zone still being
// watched (unused) gets its rectangle created (if new) and stretched to the
// current bar every call; once it resolves (used = true, whatever the
// reason) this stops touching it at all rather than deleting it, so
// whatever the rectangle looked like at that point stays on the chart and
// the touch/break pattern is still visible afterward. A zone that resolved
// during OnInit's replay (no per-bar drawing runs there — see UpdateLTF)
// never got a rectangle at all yet; g_ltfZoneDrawEnd (set at the same three
// spots g_savedLtfZones[].used is) gives it a correct frozen right edge the
// first time this runs after replay, instead of skipping it forever. Note:
// g_savedLtfZones only ever grows, so a long run accumulates one rectangle
// per zone ever watched — fine for inspecting a backtest visually, but
// worth trimming (or toggling InpDrawLines off) for anything long-running.
void DrawSavedLtfZones()
  {
   if(!InpDrawLines) return;

   string prefix = g_objPrefix + "LTF_";
   int n = ArraySize(g_savedLtfZones);
   for(int i = 0; i < n; i++)
     {
      string name = prefix + IntegerToString(i);
      color  clr  = g_savedLtfZones[i].isDemand ? clrDodgerBlue : clrOrangeRed;

      if(g_savedLtfZones[i].used)
        {
         // Resolved, possibly before ever being drawn (replay). Draw once
         // with its recorded freeze time, then leave it alone for good.
         if(ObjectFind(0, name) < 0 && g_ltfZoneDrawEnd[i] > 0)
            DrawHtfZoneRect(name, g_savedLtfZones[i].time,
                            g_savedLtfZones[i].high, g_savedLtfZones[i].low, clr,
                            g_ltfZoneDrawEnd[i]);
         continue;
        }

      if(ObjectFind(0, name) < 0)
         DrawHtfZoneRect(name, g_savedLtfZones[i].time,
                         g_savedLtfZones[i].high, g_savedLtfZones[i].low, clr, TimeCurrent());
      else
         ObjectSetInteger(0, name, OBJPROP_TIME, 1, TimeCurrent());
     }
  }

//---- Draw the HTF MA filter's own line, as connected trend-line segments
// (ChartIndicatorAdd failed with error 4114 in testing on this setup, not
// worth chasing further — this is the same approach DrawSavedLtfZones uses,
// already proven reliable here). First call backfills a lookback so the
// line isn't blank; after that, one new segment is appended per HTF bar
// close. Segments are never touched again once drawn, same "leave it
// there" philosophy as the zone rectangles above.
void DrawHtfMaLine()
  {
   if(!InpHtfMaFilter || !InpDrawLines) return;
   if(g_htfMaHandle == INVALID_HANDLE) return;

   string prefix = g_objPrefix + "MA_";

   if(g_maLineLastTime == 0)
     {
      int lookback = 100;
      double   maBuf[];
      datetime timeBuf[];
      ArraySetAsSeries(maBuf, true);
      ArraySetAsSeries(timeBuf, true);
      int copied = CopyBuffer(g_htfMaHandle, 0, 0, lookback, maBuf);
      if(copied <= 1) return;   // indicator not warmed up yet — retry next call
      if(CopyTime(_Symbol, InpHtfTimeframe, 0, copied, timeBuf) != copied) return;

      for(int i = copied - 1; i > 0; i--)
        {
         string name = prefix + IntegerToString((long)timeBuf[i-1]);
         if(ObjectFind(0, name) < 0)
           {
            ObjectCreate(0, name, OBJ_TREND, 0, timeBuf[i], maBuf[i], timeBuf[i-1], maBuf[i-1]);
            ObjectSetInteger(0, name, OBJPROP_COLOR, clrYellow);
            ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
            ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
            ObjectSetInteger(0, name, OBJPROP_RAY_LEFT, false);
            ObjectSetInteger(0, name, OBJPROP_BACK, true);
           }
        }
      g_maLineLastTime  = timeBuf[0];
      g_maLineLastValue = maBuf[0];
      return;
     }

   double   ma[1];
   datetime t[1];
   if(CopyBuffer(g_htfMaHandle, 0, 0, 1, ma) != 1) return;
   if(CopyTime(_Symbol, InpHtfTimeframe, 0, 1, t) != 1) return;
   if(t[0] == g_maLineLastTime) return;   // same HTF bar as last drawn point

   string name = prefix + IntegerToString((long)t[0]);
   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, OBJ_TREND, 0, g_maLineLastTime, g_maLineLastValue, t[0], ma[0]);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clrYellow);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
      ObjectSetInteger(0, name, OBJPROP_RAY_LEFT, false);
      ObjectSetInteger(0, name, OBJPROP_BACK, true);
     }
   g_maLineLastTime  = t[0];
   g_maLineLastValue = ma[0];
  }

//---- Draw a buy/sell marker + trigger-reason label where a rejection was
// confirmed. Fires whenever CheckRejectionRetests finds a match, whether or
// not EntryGateBlocked later vetoes the actual order and whether this is a
// live bar or OnInit's replay — "confirmed" is about the pattern, not the
// fill, so the marker tracks the former. Never touched again once drawn,
// same as the zone rectangles and MA line above.
void DrawEntrySignal(datetime time, double price, int dir, string reason)
  {
   string tag  = IntegerToString((long)time) + (dir == 1 ? "B" : "S");
   string name = g_objPrefix + "SIG_" + tag;

   if(ObjectFind(0, name) < 0)
     {
      ObjectCreate(0, name, dir == 1 ? OBJ_ARROW_BUY : OBJ_ARROW_SELL, 0, time, price);
      ObjectSetInteger(0, name, OBJPROP_COLOR, dir == 1 ? clrLime : clrRed);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 2);
     }

   string labelName = g_objPrefix + "SIGTXT_" + tag;
   if(ObjectFind(0, labelName) < 0)
     {
      ObjectCreate(0, labelName, OBJ_TEXT, 0, time, price);
      ObjectSetString(0, labelName, OBJPROP_TEXT, reason);
      ObjectSetInteger(0, labelName, OBJPROP_COLOR, dir == 1 ? clrLime : clrRed);
      ObjectSetInteger(0, labelName, OBJPROP_FONTSIZE, 8);
      // Text drawn away from the arrow instead of on top of it — anchor at
      // the label's own top for a BUY marker (text grows downward, further
      // below the bar the arrow already sits under) and at its bottom for
      // a SELL marker (text grows upward, further above the bar).
      ObjectSetInteger(0, labelName, OBJPROP_ANCHOR, dir == 1 ? ANCHOR_UPPER : ANCHOR_LOWER);
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
         "swept_low", "swept_high", "validated", "entry_placed", "quality_pass",
         "bars_since", "bars_to_touch", "touched", "touch_depth_pts",
         "max_fav_pts", "max_adv_pts", "fav_after_touch_pts", "trend_at_confirm",
         "htf_trend", "touched_at_validation", "htf_context_validated");
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
      zone.qualityPass ? "1" : "0",
      IntegerToString(zone.barsSinceConfirm),
      IntegerToString(zone.barsToTouch),
      zone.touched ? "1" : "0",
      DoubleToString(zone.touchDepthPts, 1),
      DoubleToString(zone.maxFavPts, 1),
      DoubleToString(zone.maxAdvPts, 1),
      DoubleToString(zone.favAfterTouchPts, 1),
      zone.trendAtConfirm == TREND_UP ? "UP" : "DOWN",
      zone.htfTrendAtConfirm == (int)TREND_UP ? "UP" : "DOWN",
      zone.touchedAtValidation ? "1" : "0",
      zone.htfContextValidated ? "1" : "0");

   FileClose(handle);
  }

//---- Register a zone in the quality tracker ----
// Metrics must already be filled by ComputeZoneMetrics().
void TrackZone(SnDZone &zone, bool htf)
  {
   zone.trendAtConfirm = htf ? g_htfTrend : g_ltfTrend;
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
   zone.touchedAtValidation = false;
   zone.htfContextValidated = false;

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

//---- LTF-only: snapshot touch/HTF-context state at the exact validation instant
// Must be called right after MarkZoneValidated(false, ...) at the same call
// site, while 'confirmed' is still the pending zone that just passed.
// htfContextValidated is diagnostic-only now (see the RESULT block below) —
// FindContainingZoneIdx against the ACTIVE, already-validated HTF arrays (an
// HTF zone only enters g_htfDemandZones/g_htfSupplyZones once it has itself
// validated), recorded standalone in the zone CSV rather than feeding any
// live decision.
//------------------------------------------------------------------
// RESULT — period A, XAUUSD M1/M15, 21,372 validated LTF zones
//------------------------------------------------------------------
// Tested: does a zone that validates before ever being touched, inside an
// already-validated HTF zone, predict direction? Four cells (touched-at-
// validation x htf-context), direction-adjusted hit rate:
//
//                              5m     15m      1h      4h      1d
//   no-touch + HTF (proposal) 75.77  62.96  56.63  53.74  48.00
//   no-touch + no-HTF         75.92  62.55  54.88  52.15  52.02
//   touched  + HTF            57.60  60.57  55.65  54.36  50.25
//   touched  + no-HTF         56.48  61.37  54.97  52.06  51.00
//
// HTF context adds nothing: the two no-touch rows track each other within a
// point at every horizon, and so do the two touched rows. The touch-timing
// split shows a real gap at 5m/15m (75%+ vs ~57%) that decays through 1h/4h
// and, at 1d, REVERSES — the proposal cell finishes lowest of the four
// (48.00%, the only one below 50). That shape is the signature of the same
// circularity already found in the plain 'validated' flag: a zone that
// reaches confirmLevel without dipping back did so via a sharp, immediate
// move, so a snapshot minutes later is still measuring THAT move, not
// predicting a new one. Demand/supply near-balanced in all four cells
// (46-54%), so this is not the H1 trend probe's imbalance artifact repeating.
//
// CONSEQUENCE: no real information here either. touchedAtValidation and
// htfContextValidated stay in the tracker as reusable, real-time-honest
// primitives — the mistake worth avoiding next time is deriving either from
// touched's whole-lifetime state instead of snapshotting at the decision
// moment, not the existence of the fields.
//------------------------------------------------------------------
// touchedAtValidation is passed in rather than read from g_zoneTracker: that
// tracker only exists when InpZoneQualityLog is on (TrackZone is what
// creates the slot FindTrackedZone below looks up), so deriving it from
// there made the ENTIRE rejection-entry mechanism below — superseded-marking
// and the g_ltfValidatedHistory append, not just the CSV diagnostic fields —
// silently stop working the moment quality logging was switched off. The
// caller (UpdateLTF) now tracks g_ltfPendingTouched independently for
// exactly this reason, and the same value feeds the OnInit historical
// replay, which never runs TrackZone at all.
void MarkLtfValidationContext(const SnDZone &confirmed, bool touchedAtValidation)
  {
   // CSV-diagnostic fields — safe no-op when this zone isn't being tracked
   // (InpZoneQualityLog=false, or the OnInit replay). Everything below this
   // block is core state and must run regardless.
   int i = FindTrackedZone(false, confirmed.isDemand, confirmed.time);
   if(i >= 0)
     {
      g_zoneTracker[i].touchedAtValidation = touchedAtValidation;

      double limitPrice = confirmed.isDemand ? confirmed.high : confirmed.low;
      int htfIdx = confirmed.isDemand
                   ? FindContainingZoneIdx(limitPrice, g_htfDemandZones, true)
                   : FindContainingZoneIdx(limitPrice, g_htfSupplyZones, false);
      g_zoneTracker[i].htfContextValidated = (htfIdx >= 0);
     }

   // A same-direction zone already touched by now is stale the moment this
   // new one validates — same TOUCHED_SUPERSEDED rule AddDemandZone/
   // AddSupplyZone already apply to HTF zones, needed here too. This is the
   // earliest possible trigger point (any LTF zone validating, not just the
   // next HTF validation), so it is where both places this rule matters get
   // cleaned up in one pass:
   //   - g_ltfValidatedHistory: flagged (not removed — it is a permanent
   //     record by design), so SaveLtfZonesForHtfBias's backward replay
   //     never offers up a zone the market has already moved past just
   //     because it is still sitting in the history.
   //   - g_savedLtfZones: marked used, so a zone already on the chart/watch
   //     list is retired here rather than waiting for the next HTF
   //     validation to notice.
   for(int j = 0; j < ArraySize(g_ltfValidatedHistory); j++)
     {
      if(g_ltfValidatedHistory[j].isDemand != confirmed.isDemand) continue;
      if(g_ltfValidatedHistory[j].superseded) continue;
      if(g_ltfValidatedHistory[j].touchedEver)
         g_ltfValidatedHistory[j].superseded = true;
     }
   for(int j = 0; j < ArraySize(g_savedLtfZones); j++)
     {
      if(g_savedLtfZones[j].used) continue;
      if(g_savedLtfZones[j].isDemand != confirmed.isDemand) continue;
      if(g_savedLtfZones[j].touched)
        {
         g_savedLtfZones[j].used = true;
         // No bar handy here — confirmed.time (the fresher zone that just
         // superseded this one) is the moment we learned it's stale, close
         // enough for a frozen right edge.
         g_ltfZoneDrawEnd[j] = confirmed.time;
         if(InpEnableLog)
            PrintFormat("AjipSnD: %s watch zone [%.5f, %.5f] touched+superseded by fresher zone — dropped",
                        g_savedLtfZones[j].isDemand ? "DEMAND" : "SUPPLY",
                        g_savedLtfZones[j].low, g_savedLtfZones[j].high);
        }
     }

   // Every validated LTF zone joins the searchable history unconditionally —
   // the HTF bias needs zones that validated before it existed to look back
   // on (SaveLtfZonesForHtfBias's backward replay).
   int hsz = ArraySize(g_ltfValidatedHistory);
   ArrayResize(g_ltfValidatedHistory, hsz + 1);
   g_ltfValidatedHistory[hsz].high      = confirmed.high;
   g_ltfValidatedHistory[hsz].low       = confirmed.low;
   g_ltfValidatedHistory[hsz].sweepHigh = confirmed.sweepHigh;
   g_ltfValidatedHistory[hsz].sweepLow  = confirmed.sweepLow;
   g_ltfValidatedHistory[hsz].time      = confirmed.time;
   g_ltfValidatedHistory[hsz].isDemand  = confirmed.isDemand;
   g_ltfValidatedHistory[hsz].touchedAtValidation = touchedAtValidation;
   // touchedEver starts from the SAME instant, not from false: the zone's
   // confirm-to-validate window already happened, so anything already true in
   // touchedAtValidation is already true here too — starting this at false
   // would let a zone that WAS touched before validation quietly count as
   // untouched the instant it joins the history.
   g_ltfValidatedHistory[hsz].touchedEver = touchedAtValidation;
   g_ltfValidatedHistory[hsz].superseded  = false;
  }

//---- Keep touchedEver current for every zone in the persistent history ----
// Called once per closed LTF bar. g_zoneTracker's own 'touched' stops updating
// the moment a zone is REPLACED/EXPIRED and evicted, but g_ltfValidatedHistory
// entries outlive that by design — a zone the HTF trigger searches for next
// month must still have an accurate answer to "touched since?", long after its
// tracker slot is gone. Skips entries already true (nothing left to detect)
// entirely, and match's own confirm bar (the definition 'touched' already
// uses everywhere else in this file: re-entry AFTER confirmation, not on it).
void UpdateLtfValidatedHistoryTouch(const MqlRates &bar)
  {
   int n = ArraySize(g_ltfValidatedHistory);
   for(int i = 0; i < n; i++)
     {
      if(g_ltfValidatedHistory[i].touchedEver) continue;
      if(bar.time <= g_ltfValidatedHistory[i].time) continue;

      bool touched = g_ltfValidatedHistory[i].isDemand
                     ? (bar.low <= g_ltfValidatedHistory[i].high)
                     : (bar.high >= g_ltfValidatedHistory[i].low);
      if(touched)
         g_ltfValidatedHistory[i].touchedEver = true;
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
