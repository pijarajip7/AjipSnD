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

      // Detect if already partial-closed: volume < InpFixedLot
      double curVol = PositionGetDouble(POSITION_VOLUME);
      g_entries[idx].partialClosed = (curVol < InpFixedLot - g_volStep * 0.5);

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

//==== Zone gap gate: entry invalid if nearest opposite zone too close ====
bool ZoneGapBlocked(const SnDZone &zone)
  {
   if(InpMinZoneGapPoints <= 0) return(false);

   double minGap = InpMinZoneGapPoints * g_point;

   if(zone.isDemand)
     {
      double nearestSupplyLow = 0;
      int n = ArraySize(g_htfSupplyZones);
      for(int i = 0; i < n; i++)
        {
         if(g_htfSupplyZones[i].low <= zone.high) continue;
         if(nearestSupplyLow == 0 || g_htfSupplyZones[i].low < nearestSupplyLow)
            nearestSupplyLow = g_htfSupplyZones[i].low;
        }
      if(nearestSupplyLow > 0 && (nearestSupplyLow - zone.high) < minGap)
        {
         if(InpEnableLog)
            PrintFormat("AjipSnD: BUY entry blocked — zone gap %.1f pts < min %d pts",
                        (nearestSupplyLow - zone.high) / g_point, InpMinZoneGapPoints);
         return(true);
        }
     }
   else
     {
      double nearestDemandHigh = 0;
      int n = ArraySize(g_htfDemandZones);
      for(int i = 0; i < n; i++)
        {
         if(g_htfDemandZones[i].high >= zone.low) continue;
         if(nearestDemandHigh == 0 || g_htfDemandZones[i].high > nearestDemandHigh)
            nearestDemandHigh = g_htfDemandZones[i].high;
        }
      if(nearestDemandHigh > 0 && (zone.low - nearestDemandHigh) < minGap)
        {
         if(InpEnableLog)
            PrintFormat("AjipSnD: SELL entry blocked — zone gap %.1f pts < min %d pts",
                        (zone.low - nearestDemandHigh) / g_point, InpMinZoneGapPoints);
         return(true);
        }
     }
   return(false);
  }

#endif // AJIPSND_ENTRY_MQH
