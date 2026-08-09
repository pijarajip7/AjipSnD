#ifndef AJIPSND_ENTRY_MQH
#define AJIPSND_ENTRY_MQH

//==================================================================
// RESTART RECOVERY — rebuild g_entries[] tracking for positions
// opened by an earlier run of this EA (reattach/recompile/restart).
//==================================================================
void RebuildTrackedPositions()
  {
   ArrayResize(g_entries, 0);

   datetime firstTime = 0;
   datetime lastTime  = 0;
   int      recovered = 0;

   int n = PositionsTotal();
   for(int i = 0; i < n; i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

      int      dir        = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      double   entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      datetime entryTime  = (datetime)PositionGetInteger(POSITION_TIME);

      int idx = ArraySize(g_entries);
      ArrayResize(g_entries, idx + 1);
      g_entries[idx].ticket        = ticket;
      g_entries[idx].dir           = dir;
      g_entries[idx].entryPrice    = entryPrice;
      g_entries[idx].entryTime     = entryTime;
      g_entries[idx].mfe           = PositionGetDouble(POSITION_PROFIT);
      g_entries[idx].mae           = PositionGetDouble(POSITION_PROFIT);
      g_entries[idx].partialClosed = false;

      if(firstTime == 0 || entryTime < firstTime) firstTime = entryTime;
      if(entryTime > lastTime) lastTime = entryTime;
      recovered++;
     }

   if(recovered == 0) return;

   g_batchActive         = true;
   g_batchFirstEntryTime = firstTime;
   g_batchLastEntryTime  = lastTime;

   if(InpEnableLog) PrintFormat("AjipSnD: Rebuilt tracking for %d pre-existing position(s) on restart.", recovered);
  }

//==================================================================
// ENTRY LOGIC — LTF zone confirmed + price inside HTF zone
//==================================================================

//---- Gate entry for bar-close path ----
bool EntryGateBlocked(int dir)
  {
   if(FinalTargetReached())
     {
      if(InpEnableLog) Print("AjipSnD: Entry blocked — Final target already reached");
      return(true);
     }
   if(FinalMaxLossReached())
     {
      if(InpEnableLog) Print("AjipSnD: Entry blocked — Final max loss already reached");
      return(true);
     }
   if(DailyLimitReached())
     {
      if(InpEnableLog) Print("AjipSnD: Entry blocked — Daily limit reached");
      return(true);
     }
   if(MaxTotalLotsReached(dir))
     {
      if(InpEnableLog) PrintFormat("AjipSnD: Entry blocked — Max total lots reached for %s",
                                   dir == 1 ? "BUY" : "SELL");
      return(true);
     }
   if(HedgeBlocked(dir))
     {
      if(InpEnableLog) PrintFormat("AjipSnD: Entry blocked — Hedging disabled, opposite side open for %s",
                                   dir == 1 ? "BUY" : "SELL");
      return(true);
     }
   if(BatchCooldownActive())
     {
      if(InpEnableLog) Print("AjipSnD: Entry blocked — Batch cooldown active");
      return(true);
     }
   if(!InSession())
     {
      if(InpEnableLog) Print("AjipSnD: Entry blocked — Outside trading session");
      return(true);
     }
   if(InpNewsFilterEnabled && InNewsBlackout())
     {
      if(InpEnableLog) Print("AjipSnD: Entry blocked — News blackout");
      return(true);
     }
   if(dir == 1 && HtfMaBlocksBuy())
     {
      if(InpEnableLog) Print("AjipSnD: Entry blocked — HTF close below MA (BUY only above MA)");
      return(true);
     }
   if(dir == -1 && HtfMaBlocksSell())
     {
      if(InpEnableLog) Print("AjipSnD: Entry blocked — HTF close above MA (SELL only below MA)");
      return(true);
     }
   return(false);
  }

//---- Check if LTF zone is inside any active HTF zone and entry ----
void CheckLTFZoneEntry(const MqlRates &bar)
  {
   // Must have active HTF zones
   int htfDemandCount = ArraySize(g_htfDemandZones);
   int htfSupplyCount = ArraySize(g_htfSupplyZones);

   if(htfDemandCount == 0 && htfSupplyCount == 0)
      return;

   // Check LTF demand zone confirmed → potential BUY
   SnDZone ltfConfirmed;
   ZeroMemory(ltfConfirmed);

   // Process the current bar for LTF zone detection
   // (UpdateLTFZone in Core.mqh already ran ProcessZoneBar and updates g_ltfTrend/candidate)
   // Here we just check if there's a fresh zone to trade

   // For BUY: LTF demand zone confirmed + price inside HTF demand zone
   if(g_ltfTrend == TREND_UP && htfDemandCount > 0 &&
      g_ltfCandidate.time != 0)  // There was an active candidate before flip
     {
      // The close price of this bar is the entry
      double entryPrice = bar.close;

      // Check if close is inside any HTF demand zone
      if(IsPriceInDemandZone(entryPrice, g_htfDemandZones))
        {
         // One-shot per LTF zone
         bool isNewZone = (ArraySize(g_ltfDemandZones) > 0 &&
                          g_ltfDemandZones[ArraySize(g_ltfDemandZones) - 1].time != g_ltfZoneEntryFiredTime);

         if(g_ltfZoneEntryFiredTime == 0 || isNewZone)
           {
            if(!EntryGateBlocked(1))  // 1 = BUY
              {
               ulong ticket = OpenTrade(true, entryPrice);
               if(ticket != 0)
                 {
                  AddEntry(ticket, 1, entryPrice);
                  if(ArraySize(g_ltfDemandZones) > 0)
                     g_ltfZoneEntryFiredTime = g_ltfDemandZones[ArraySize(g_ltfDemandZones) - 1].time;
                 }
              }
           }
        }
     }

   // For SELL: LTF supply zone confirmed + price inside HTF supply zone
   if(g_ltfTrend == TREND_DOWN && htfSupplyCount > 0 &&
      g_ltfCandidate.time != 0)
     {
      double entryPrice = bar.close;

      if(IsPriceInSupplyZone(entryPrice, g_htfSupplyZones))
        {
         bool isNewZone = (ArraySize(g_ltfSupplyZones) > 0 &&
                          g_ltfSupplyZones[ArraySize(g_ltfSupplyZones) - 1].time != g_ltfZoneEntryFiredTime);

         if(g_ltfZoneEntryFiredTime == 0 || isNewZone)
           {
            if(!EntryGateBlocked(-1))  // -1 = SELL
              {
               ulong ticket = OpenTrade(false, entryPrice);
               if(ticket != 0)
                 {
                  AddEntry(ticket, -1, entryPrice);
                  if(ArraySize(g_ltfSupplyZones) > 0)
                     g_ltfZoneEntryFiredTime = g_ltfSupplyZones[ArraySize(g_ltfSupplyZones) - 1].time;
                 }
              }
           }
        }
     }
  }

#endif // AJIPSND_ENTRY_MQH
