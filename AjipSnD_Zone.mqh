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
// qualityPass gates entries directly — this is core sizing logic, not
// diagnostics. Backtest over two separate 12-month XAUUSD periods: neither
// threshold does anything on its own — width alone and displacement alone
// both leave the MFE/MAE ratio at the baseline. Together they lift median
// MFE without moving MAE, and that held out of sample.
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
         ArrayRemove(zones, i, 1);
         continue;
        }
      // HTF only: a zone already touched (retested) goes stale the moment a
      // fresh HTF demand zone confirms, regardless of whether the new zone is
      // "lower" by the check above — the market has produced new structure,
      // so the old zone is trading yesterday's setup.
      if(zones[i].isHtf && zones[i].touched)
         ArrayRemove(zones, i, 1);
     }

   // Add new zone
   int sz = ArraySize(zones);
   ArrayResize(zones, sz + 1);
   zones[sz] = newZone;

   // Enforce InpMaxZones
   while(ArraySize(zones) > InpMaxZones)
      ArrayRemove(zones, 0, 1);   // remove oldest (index 0)
  }

void AddSupplyZone(SnDZone &zones[], const SnDZone &newZone)
  {
   for(int i = ArraySize(zones) - 1; i >= 0; i--)
     {
      if(newZone.high > zones[i].high)
        {
         // New zone is HIGHER → old zone deactivated
         ArrayRemove(zones, i, 1);
         continue;
        }
      // HTF only — see AddDemandZone's matching comment.
      if(zones[i].isHtf && zones[i].touched)
         ArrayRemove(zones, i, 1);
     }

   int sz = ArraySize(zones);
   ArrayResize(zones, sz + 1);
   zones[sz] = newZone;

   while(ArraySize(zones) > InpMaxZones)
      ArrayRemove(zones, 0, 1);
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
         ArrayRemove(g_htfDemandZones, i, 1);
         anyChange = true;
        }
      // Live touch tracking — wick re-entry after the zone's own confirm bar.
      // This is the only writer for the live HTF arrays' .touched, and it
      // feeds the touched+superseded invalidation in AddDemandZone/AddSupplyZone
      // below.
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

//---- Draw saved (awaiting-touch or resolved) LTF zones — the only chart
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


//---- LTF-only: core superseded-marking + history append, keyed off whether
// this zone was already touched at the exact instant it validated.
//------------------------------------------------------------------
// RESULT (past research, XAUUSD M1/M15, 21,372 validated LTF zones): tested
// whether a zone validating before ever being touched, inside an
// already-validated HTF zone, predicts direction. It doesn't — HTF context
// added nothing, and the touch-timing split that looked promising at 5m/15m
// (75%+ vs ~57%) decayed through 1h/4h and reversed by 1d, the same
// circularity already found in the plain 'validated' flag: a zone that
// reaches confirmLevel without dipping back did so via a sharp, immediate
// move, so a snapshot minutes later is still measuring THAT move, not
// predicting a new one. Nothing left to build on here — noted so it isn't
// re-tried the same way.
//------------------------------------------------------------------
// touchedAtValidation is passed in rather than derived from anything
// re-read off the zone later: it has to be a snapshot taken at exactly
// this instant (see the RESULT note above this function), and the OnInit
// historical replay reaches this same function too, so whatever it uses
// has to hold up there as well. The caller (UpdateLTF) tracks
// g_ltfPendingTouched independently for exactly this reason.
void MarkLtfValidationContext(const SnDZone &confirmed, bool touchedAtValidation)
  {
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
// Called once per closed LTF bar. g_ltfValidatedHistory entries outlive
// eviction from the active zone arrays by design (see its own struct
// comment) — a zone the HTF trigger searches for next month must still have
// an accurate answer to "touched since?", long after it would otherwise be
// gone. Skips entries already true (nothing left to detect) entirely, and
// each entry's own confirm bar (the definition 'touched' already uses
// everywhere else in this file: re-entry AFTER confirmation, not on it).
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

#endif // AJIPSND_ZONE_MQH
