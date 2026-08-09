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
         ZeroMemory(g_ltfCandidate);
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
         ZeroMemory(g_htfCandidate);
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
            if(!EntryGateBlocked(1))
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
            if(!EntryGateBlocked(-1))
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

      // After zone confirmed, reset candidate for new trend
      ZeroMemory(g_ltfCandidate);
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
      ZeroMemory(g_htfCandidate);

      // Redraw HTF zone rectangles only (LTF uses arrows)
      DrawAllHtfZones();
     }
  }

//---- Draw info panel ----
void DrawPanel()
  {
   if(!InpShowPanel) return;
   
   string prefix = g_objPrefix + "Panel_";
   
   string trendStr = g_ltfTrend == TREND_UP ? "UP" : (g_ltfTrend == TREND_DOWN ? "DOWN" : "NONE");
   string htfTrendStr = g_htfTrend == TREND_UP ? "UP" : (g_htfTrend == TREND_DOWN ? "DOWN" : "NONE");
   
   string lines[];
   ArrayResize(lines, 0);
   
   int sz = ArraySize(lines);
   ArrayResize(lines, sz + 1); lines[sz] = "╔══════════════════════╗";
   sz = ArraySize(lines); ArrayResize(lines, sz + 1); lines[sz] = "║     AjipSnD v1.0     ║";
   sz = ArraySize(lines); ArrayResize(lines, sz + 1); lines[sz] = "╠══════════════════════╣";
   
   string ltfLine = StringFormat("║ LTF Trend: %-4s (%s)  ║", trendStr, EnumToString(InpTimeframe));
   sz = ArraySize(lines); ArrayResize(lines, sz + 1); lines[sz] = ltfLine;
   
   string htfLine = StringFormat("║ HTF Trend: %-4s (%s) ║", htfTrendStr, EnumToString(InpHtfTimeframe));
   sz = ArraySize(lines); ArrayResize(lines, sz + 1); lines[sz] = htfLine;
   
   string dZoneLine = StringFormat("║ HTF Demands: %-2d       ║", ArraySize(g_htfDemandZones));
   sz = ArraySize(lines); ArrayResize(lines, sz + 1); lines[sz] = dZoneLine;
   
   string sZoneLine = StringFormat("║ HTF Supplies: %-2d      ║", ArraySize(g_htfSupplyZones));
   sz = ArraySize(lines); ArrayResize(lines, sz + 1); lines[sz] = sZoneLine;
   
   string pnlLine = StringFormat("║ PnL Today: %-10.2f ║", GetDailyPnL() + GetFloatingPnL());
   sz = ArraySize(lines); ArrayResize(lines, sz + 1); lines[sz] = pnlLine;
   
   sz = ArraySize(lines); ArrayResize(lines, sz + 1); lines[sz] = "╚══════════════════════╝";
   
   int totalLines = ArraySize(lines);
   
   // ---- Background rectangle (behind text) ----
   string bgName = prefix + "BG";
   if(ObjectFind(0, bgName) < 0)
     {
      ObjectCreate(0, bgName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, bgName, OBJPROP_CORNER, (int)InpPanelCorner);
      ObjectSetInteger(0, bgName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, bgName, OBJPROP_HIDDEN, true);
     }
   // Position — wider than the text block (22 chars Consolas-9 ≈ 14px/char)
   int x1 = (int)InpPanelX - 8;
   int y1 = (int)InpPanelY - 6;
   int x2 = (int)InpPanelX + 260;
   int y2 = (int)InpPanelY + totalLines * 16 + 4;
   ObjectSetInteger(0, bgName, OBJPROP_XDISTANCE, x1);
   ObjectSetInteger(0, bgName, OBJPROP_YDISTANCE, y1);
   ObjectSetInteger(0, bgName, OBJPROP_XSIZE, x2 - x1);
   ObjectSetInteger(0, bgName, OBJPROP_YSIZE, y2 - y1);
   ObjectSetInteger(0, bgName, OBJPROP_BGCOLOR, clrBlack);
   ObjectSetInteger(0, bgName, OBJPROP_BORDER_COLOR, clrDimGray);
   ObjectSetInteger(0, bgName, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, bgName, OBJPROP_BACK, false);
   
   // ---- Text labels ----
   int corner = (int)InpPanelCorner;
   for(int i = 0; i < totalLines; i++)
     {
      string name = prefix + IntegerToString(i);
      if(ObjectFind(0, name) < 0)
        {
         ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
         ObjectSetInteger(0, name, OBJPROP_CORNER, corner);
         ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
        }
      ObjectSetInteger(0, name, OBJPROP_XDISTANCE, (int)InpPanelX);
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, (int)InpPanelY + i * 16);
      ObjectSetString(0, name, OBJPROP_TEXT, lines[i]);
      ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 9);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clrWhite);
     }
   
   // Clean up extra labels
   for(int i = totalLines; i < 20; i++)
     {
      string name = prefix + IntegerToString(i);
      ObjectDelete(0, name);
     }
  }

#endif // AJIPSND_CORE_MQH
