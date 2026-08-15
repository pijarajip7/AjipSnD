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

   // ---- Structural SL: beyond the far edge of the HTF zone being retested ----
   // The LTF zone is only the trigger; the HTF zone is the thesis. Anchoring to
   // the LTF zone's far edge puts the stop inside ordinary noise — measured on
   // two 12-month XAUUSD periods, the median adverse excursion from entry
   // (3293 pts) exceeds the LTF zone's own width (1995 pts), so that stop is
   // touched ~59% of the time versus ~17% for the HTF anchor.
   double slPrice = 0.0;
   double tpPrice = 0.0;
   if(InpStructuralSlMode)
     {
      double atrLtf = GetAtrValue(false);
      if(atrLtf <= 0)
        {
         Print("AjipSnD: LTF ATR unavailable — structural SL cannot be sized, entry skipped");
         return(false);
        }
      double buffer = InpZoneSlBufferAtr * atrLtf;
      slPrice = confirmed.isDemand
                ? NormalizeDouble(g_htfDemandZones[htfIdx].low  - buffer, g_digits)
                : NormalizeDouble(g_htfSupplyZones[htfIdx].high + buffer, g_digits);

      // Target measured from the entry in LTF ATR, not from the zone: the stop
      // is anchored to structure, the target to how far price actually travels.
      if(InpTakeProfitAtr > 0)
        {
         double reach = InpTakeProfitAtr * atrLtf;
         tpPrice = confirmed.isDemand
                   ? NormalizeDouble(limitPrice + reach, g_digits)
                   : NormalizeDouble(limitPrice - reach, g_digits);
        }
     }

   // (the old ArraySize()==0 guard here is redundant: htfIdx >= 0 can only come
   //  from a non-empty array)

   // One-shot per LTF zone
   if(confirmed.time == g_ltfZonePendingTime) return(false);

   PrintFormat("AjipSnD: LTF %s zone VALIDATED — placing %s LIMIT at %.5f (SL %.5f, TP %.5f)",
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
         if(PlaceEntryForZone(g_ltfPendingZone))
            MarkZoneEntryPlaced(g_ltfPendingZone.isDemand, g_ltfPendingZone.time);
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
   // pending zone drawn in distinct color.
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

string CooldownTxt()
  {
   if(InpBatchCooldownMinutes <= 0) return("disabled");
   if(!BatchCooldownActive())       return("clear");
   int remainingSec = (int)(g_lastBatchEndTime + InpBatchCooldownMinutes * 60 - TimeCurrent());
   return(StringFormat("%dm left", (remainingSec + 59) / 60));
  }
color CooldownCol()
  {
   if(InpBatchCooldownMinutes <= 0) return(clrSilver);
   return(BatchCooldownActive() ? clrTomato : clrLimeGreen);
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
   const int totalLines = 22;
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
   // BatchProfitThreshold(), not raw InpBatchMaxProfit — otherwise this
   // status lags/misreads once InpBatchMaxProfitAtr is active, since the
   // real trigger is a live ATR x volume figure, not the fixed $ input.
   s = LimitTxt(BatchProfitThreshold(), InpBatchMaxLoss, g_batchRealizedPnl + floating);
   PANEL_LABEL("Batch:     " + s, LimitCol(s));
   
   // ---- Cooldown / Session / News ----
   PANEL_LABEL("", clrWhite);
   PANEL_LABEL("Cooldown:  " + CooldownTxt(), CooldownCol());
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
