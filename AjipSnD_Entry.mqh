#ifndef AJIPSND_ENTRY_MQH
#define AJIPSND_ENTRY_MQH

//==================================================================
// RESTART RECOVERY — rebuild g_entries[] tracking for positions
// opened by an earlier run of this EA (reattach/recompile/restart).
//==================================================================
void RebuildTrackedPositions()
  {
   ArrayResize(g_entries, 0);

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

      g_entries[idx].initialVolume = curVol;

      // ATR at the original entry is not recoverable on restart — use the
      // current reading.
      g_entries[idx].atrLtfAtEntry  = GetAtrValue();

      // An SL already on the position came from the zone that justified it —
      // treated as structural since a recovered position's original placement
      // context is not reconstructable.
      g_entries[idx].hasStructuralSl = (curSl != 0.0);
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

      // Whether this position already partial-closed in an earlier run is not
      // recoverable either — same limitation as zoneTime above. Worst case a
      // restarted position gets one more partial-close shot than it should;
      // trailing simply won't arm until that fires.
      g_entries[idx].partialClosed       = false;
      g_entries[idx].partialCloseSkipped = false;

      // Unlike zoneTime/partialClosed above, invalidation TP->BE needs no
      // special restart handling at all: CheckInvalidationTpToBe derives
      // breakLevel from slPrice + entryPrice (both set just above from the
      // live broker position) rather than storing it, so it works
      // identically for a restart-recovered position.
      g_entries[idx].tpMovedToBe = false;

      recovered++;
     }

   if(recovered == 0) return;

   if(InpEnableLog) PrintFormat("AjipSnD: Rebuilt tracking for %d pre-existing position(s) on restart.", recovered);
  }

//==================================================================
// ENTRY LOGIC — LTF zone confirmed, then traded on the first touch of its retest
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
   if(MaxPositionsReached(dir))
     {
      if(InpEnableLog) PrintFormat("AjipSnD: Entry blocked — %d position(s) already open for %s",
                                   InpMaxPositionsPerDir, dir == 1 ? "BUY" : "SELL");
      return(true);
     }
   if(HedgeBlocked(dir))
     {
      if(InpEnableLog) PrintFormat("AjipSnD: Entry blocked — Hedging disabled, opposite side open for %s",
                                   dir == 1 ? "BUY" : "SELL");
      return(true);
     }
   if(CooldownBlocked())
     {
      if(InpEnableLog)
        {
         double remainSec = (double)(InpCooldownMinutes * 60 - (TimeCurrent() - g_lastTradeCloseTime));
         PrintFormat("AjipSnD: Entry blocked — Cooldown active, %.0fs remaining", remainSec);
        }
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
   return(false);
  }

#endif // AJIPSND_ENTRY_MQH
