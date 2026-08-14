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

      double curVol = PositionGetDouble(POSITION_VOLUME);
      double curSl  = PositionGetDouble(POSITION_SL);

      // Partial-close detection compares against InpFixedLot only in fixed-lot
      // mode. Under risk-based sizing the original volume varied per trade and
      // is not recoverable from the open position, so assume none was taken —
      // the worst case is one extra partial close on a recovered position,
      // whereas guessing "already partial-closed" would disable it for good.
      //
      // Gated on the mode, NOT on InpRiskPerTrade: that input is non-zero by
      // default, and lots only vary once a structural stop gives LotForRisk a
      // distance to size against. Testing the input here would change batch-mode
      // restart behaviour while the mode is switched off.
      if(InpStructuralSlMode)
        {
         g_entries[idx].partialClosed = false;
         g_entries[idx].initialVolume = curVol;
        }
      else
        {
         g_entries[idx].partialClosed = (curVol < InpFixedLot - g_volStep * 0.5);
         g_entries[idx].initialVolume = InpFixedLot;
        }

      // ATR at the original entry is not recoverable on restart — use the
      // current reading. If the handle is not calculated yet this returns 0
      // and PartialCloseThreshold falls back to the fixed dollar target.
      g_entries[idx].atrAtEntry     = GetAtrValue(true);
      g_entries[idx].atrLtfAtEntry  = GetAtrValue(false);

      // An SL already on the position is treated as structural in this mode, so
      // the aggregate-SL pass leaves it alone rather than overwriting a stop it
      // did not place and cannot reconstruct.
      g_entries[idx].hasStructuralSl = (InpStructuralSlMode && curSl != 0.0);
      g_entries[idx].slPrice         = curSl;
      g_entries[idx].tpPrice         = PositionGetDouble(POSITION_TP);
      g_entries[idx].zoneTime        = 0;   // originating zone is not recoverable

      // Reconstruct the risk this position represents from its live stop, so
      // R-multiples stay meaningful for trades that straddle a restart.
      double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      if(curSl != 0.0 && tickValue > 0 && tickSize > 0)
        {
         double dist = (dir == 1) ? (entryPrice - curSl) : (curSl - entryPrice);
         g_entries[idx].riskUsd = (dist > 0)
                                  ? dist * (tickValue / tickSize) * curVol
                                  : 0.0;
        }
      else
         g_entries[idx].riskUsd = 0.0;

      if(firstTime == 0 || entryTime < firstTime) firstTime = entryTime;
      if(entryTime > lastTime) lastTime = entryTime;
      recovered++;
     }

   if(recovered == 0) return;

   g_batchActive         = true;
   g_batchFirstEntryTime = firstTime;
   g_batchLastEntryTime  = lastTime;
   // Batch's original starting ATR is not recoverable on restart — use the
   // current reading, same fallback used for atrAtEntry above.
   g_batchAtrAtStart     = GetAtrValue(true);

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

//==== Zone gap gate: entry invalid if NEWEST opposite zone too close ====
bool ZoneGapBlocked(const SnDZone &zone)
  {
   if(InpMinZoneGapPoints <= 0) return(false);

   double minGap = InpMinZoneGapPoints * g_point;

   if(zone.isDemand)
     {
      double   newestSupplyLow  = 0;
      datetime newestSupplyTime = 0;
      int n = ArraySize(g_htfSupplyZones);
      for(int i = 0; i < n; i++)
        {
         if(g_htfSupplyZones[i].time > newestSupplyTime)
           {
            newestSupplyTime = g_htfSupplyZones[i].time;
            newestSupplyLow  = g_htfSupplyZones[i].low;
           }
        }
      // No supply zone → nothing to check → allow
      if(newestSupplyLow == 0)
         return(false);

      // supply.low < demand.high (supply below/overlap demand) → block entry
      if(newestSupplyLow < zone.high)
        {
         if(InpEnableLog)
            PrintFormat("AjipSnD: BUY entry blocked — newest supply.low %.5f < demand.high %.5f",
                        newestSupplyLow, zone.high);
         return(true);
        }

      if((newestSupplyLow - zone.high) < minGap)
        {
         if(InpEnableLog)
            PrintFormat("AjipSnD: BUY entry blocked — gap to newest supply %.1f pts < min %d pts",
                        (newestSupplyLow - zone.high) / g_point, InpMinZoneGapPoints);
         return(true);
        }
     }
   else
     {
      double   newestDemandHigh = 0;
      datetime newestDemandTime = 0;
      int n = ArraySize(g_htfDemandZones);
      for(int i = 0; i < n; i++)
        {
         if(g_htfDemandZones[i].time > newestDemandTime)
           {
            newestDemandTime = g_htfDemandZones[i].time;
            newestDemandHigh = g_htfDemandZones[i].high;
           }
        }
      // No demand zone → nothing to check → allow
      if(newestDemandHigh == 0)
         return(false);

      // supply.low < demand.high (demand above/overlap supply) → block entry
      if(newestDemandHigh > zone.low)
        {
         if(InpEnableLog)
            PrintFormat("AjipSnD: SELL entry blocked — newest demand.high %.5f > supply.low %.5f",
                        newestDemandHigh, zone.low);
         return(true);
        }

      if((zone.low - newestDemandHigh) < minGap)
        {
         if(InpEnableLog)
            PrintFormat("AjipSnD: SELL entry blocked — gap to newest demand %.1f pts < min %d pts",
                        (zone.low - newestDemandHigh) / g_point, InpMinZoneGapPoints);
         return(true);
        }
     }
   return(false);
  }

#endif // AJIPSND_ENTRY_MQH
