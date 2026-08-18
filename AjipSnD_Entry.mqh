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
      g_entries[idx].atrAtEntry     = GetAtrValue(true);
      g_entries[idx].atrLtfAtEntry  = GetAtrValue(false);

      // No SL/TP exists at placement anymore — whatever is on the position
      // now (curSl/curTp) only got there from this EA's own points-based
      // exit logic having already fired at least once before the restart.
      // hasStructuralSl is a slight misnomer here (kept for CSV schema
      // stability) — it really means "some SL was already on the position."
      g_entries[idx].hasStructuralSl = (curSl != 0.0);
      g_entries[idx].slPrice         = curSl;
      g_entries[idx].tpPrice         = PositionGetDouble(POSITION_TP);
      g_entries[idx].zoneTime        = 0;   // originating zone is not recoverable
      g_entries[idx].triggerReason   = "unknown";   // not recoverable either
      g_entries[idx].riskUsd         = 0.0;   // no risk-based sizing — always 0

      // Whether this position already armed TP->BE / partial-closed in an
      // earlier run is not recoverable either — same limitation as
      // atrAtEntry/zoneTime above. Worst case a restarted position gets one
      // more TP->BE-arm or partial-close shot than it should — both are
      // idempotent against a broker-side level already sitting at the same
      // price, so this costs a redundant PositionModify call, not a wrong
      // one. Trailing simply won't arm until partial-close fires.
      g_entries[idx].tpBeArmed           = false;
      g_entries[idx].partialClosed       = false;
      g_entries[idx].partialCloseSkipped = false;

      recovered++;
     }

   if(recovered == 0) return;

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

#endif // AJIPSND_ENTRY_MQH
