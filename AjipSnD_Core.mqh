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
         if(confirmed.isDemand)
            AddDemandZone(g_htfDemandZones, confirmed);
         else
            AddSupplyZone(g_htfSupplyZones, confirmed);
         // Candidate seeded by ProcessZoneBar
        }
     }

   PrintFormat("AjipSnD: HTF zones after init — demands=%d supplies=%d",
               ArraySize(g_htfDemandZones), ArraySize(g_htfSupplyZones));

   if(count > 0)
     {
      ArraySetAsSeries(rates, true);
      g_htfLastBarTime = rates[1].time;
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

   // Check if this was the bar that confirmed a zone
   ENUM_TREND trendBefore = g_ltfTrend;
   SnDZone oldCandidate = g_ltfCandidate;

   SnDZone confirmed;
   ZeroMemory(confirmed);
   bool zoneConfirmed = ProcessZoneBar(bar, g_ltfTrend, g_ltfCandidate, confirmed);

   if(zoneConfirmed)
     {
      if(confirmed.isDemand)
        {
         AddDemandZone(g_ltfDemandZones, confirmed);
         PrintFormat("AjipSnD: LTF DEMAND zone confirmed! [%.5f, %.5f] at %s",
                     confirmed.low, confirmed.high, TimeToString(confirmed.time));
         // Draw up arrow BELOW the confirmation bar
         double arrowPrice = bar.low - (bar.high - bar.low) * 0.5;
         string arrowName = g_objPrefix + "LTF_Demand_" + TimeToString(confirmed.time);
         DrawZoneArrow(arrowName, bar.time, arrowPrice, true);
        }
      else
        {
         AddSupplyZone(g_ltfSupplyZones, confirmed);
         PrintFormat("AjipSnD: LTF SUPPLY zone confirmed! [%.5f, %.5f] at %s",
                     confirmed.low, confirmed.high, TimeToString(confirmed.time));
         // Draw down arrow ABOVE the confirmation bar
         double arrowPrice = bar.high + (bar.high - bar.low) * 0.5;
         string arrowName = g_objPrefix + "LTF_Supply_" + TimeToString(confirmed.time);
         DrawZoneArrow(arrowName, bar.time, arrowPrice, false);
        }

      // Check entry: is the close price inside an active HTF zone?
      double entryPrice = bar.close;

      // Demand zone confirmed → potential BUY (close inside HTF demand zone)
      if(confirmed.isDemand && ArraySize(g_htfDemandZones) > 0)
        {
         if(IsPriceInDemandZone(entryPrice, g_htfDemandZones))
           {
            PrintFormat("AjipSnD: LTF demand zone CONFIRMED + price=%.5f inside HTF demand zone → BUY signal",
                        entryPrice);
            if(!ZoneGapBlocked(confirmed) && !EntryGateBlocked(1))
              {
               ulong ticket = OpenTrade(true, entryPrice);
               if(ticket != 0)
                 {
                  AddEntry(ticket, 1, entryPrice);
                  g_ltfZoneEntryFiredTime = confirmed.time;
                 }
              }
           }
        }

      // Supply zone confirmed → potential SELL (close inside HTF supply zone)
      if(!confirmed.isDemand && ArraySize(g_htfSupplyZones) > 0)
        {
         if(IsPriceInSupplyZone(entryPrice, g_htfSupplyZones))
           {
            PrintFormat("AjipSnD: LTF supply zone CONFIRMED + price=%.5f inside HTF supply zone → SELL signal",
                        entryPrice);
            if(!ZoneGapBlocked(confirmed) && !EntryGateBlocked(-1))
              {
               ulong ticket = OpenTrade(false, entryPrice);
               if(ticket != 0)
                 {
                  AddEntry(ticket, -1, entryPrice);
                  g_ltfZoneEntryFiredTime = confirmed.time;
                 }
              }
           }
        }

      // Candidate is now seeded by ProcessZoneBar (confirming bar becomes first opposite candidate)
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

   // Invalidate zones that have been broken by price action
   bool anyChange = InvalidateHtfZones(bar);

   SnDZone confirmed;
   ZeroMemory(confirmed);
   if(ProcessZoneBar(bar, g_htfTrend, g_htfCandidate, confirmed))
     {
      if(confirmed.isDemand)
        {
         AddDemandZone(g_htfDemandZones, confirmed);
         PrintFormat("AjipSnD: HTF DEMAND zone confirmed! [%.5f, %.5f]",
                     confirmed.low, confirmed.high);
        }
      else
        {
         AddSupplyZone(g_htfSupplyZones, confirmed);
         PrintFormat("AjipSnD: HTF SUPPLY zone confirmed! [%.5f, %.5f]",
                     confirmed.low, confirmed.high);
        }
      // Candidate seeded by ProcessZoneBar
      anyChange = true;
     }

   // Redraw if anything changed (zone invalidated or new zone confirmed)
   if(anyChange)
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
   PANEL_LABEL(StringFormat("Demands:   %d", ArraySize(g_htfDemandZones)), clrWhite);
   PANEL_LABEL(StringFormat("Supplies:  %d", ArraySize(g_htfSupplyZones)), clrWhite);
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
   s = LimitTxt(InpBatchMaxProfit, InpBatchMaxLoss, g_batchRealizedPnl + floating);
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
