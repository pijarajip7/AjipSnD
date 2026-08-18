#ifndef AJIPSND_PENDINGENTRY_MQH
#define AJIPSND_PENDINGENTRY_MQH

//==================================================================
// PENDING ORDER ENTRY — the EA's only entry mechanism. Every LTF zone saved
// under the current HTF bias gets an immediate resting limit order at its
// own midpoint — no rejection wait, no pattern match. Fixed lot
// (InpFixedLot), no SL/TP at placement: with no stop distance to size
// against, risk-based sizing has nothing to compute, so every entry uses
// the same lot. Exit is managed entirely after the fill, by the points-based
// logic in AjipSnD_Trade.mqh (CheckLossRecoveryTp, CheckPartialClose,
// UpdateTrailingStop).
//
// No time-based expiry: a resting order is cancelled only when its own
// zone leaves the watch list — touched, or superseded by a fresher
// same-direction zone (see ZoneStillWatched) — not after some fixed bar
// count.
//
// Unproven — written directly to spec, not measured first. No restart
// recovery: RebuildTrackedPositions only reconstructs g_entries (filled
// positions) from live position state, not g_pendingOrders — a resting
// order that was placed before an EA/terminal restart keeps working at
// the broker, but this EA loses track of it (won't cancel it if its zone
// leaves the watch list, and won't recognise it as this EA's own trade if
// it later fills).
//==================================================================

//---- Place one resting limit order at a saved LTF zone's midpoint ----
void PlacePendingOrderForZone(const SavedLtfZone &zone)
  {
   int dir = zone.isDemand ? 1 : -1;
   if(EntryGateBlocked(dir)) return;

   double lot = InpFixedLot;
   if(lot < g_volMin || lot > g_volMax)
     {
      if(InpEnableLog)
         PrintFormat("AjipSnD: Pending order skipped — InpFixedLot %.2f outside broker range [%.2f, %.2f]",
                     lot, g_volMin, g_volMax);
      return;
     }

   double midPrice = NormalizeDouble((zone.high + zone.low) / 2.0, g_digits);

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;
   // A limit order has to rest on the correct side of price — if the market
   // already moved through the zone's midpoint before this zone even
   // finished validating, there is no resting order left worth placing.
   if(dir == 1 && midPrice >= tick.bid) return;
   if(dir == -1 && midPrice <= tick.ask) return;

   string comment = StringFormat("AjipSnD %s PENDING", dir == 1 ? "BUY" : "SELL");
   bool ok;
   if(dir == 1)
      ok = trade.BuyLimit(lot, midPrice, _Symbol, 0, 0, ORDER_TIME_GTC, 0, comment);
   else
      ok = trade.SellLimit(lot, midPrice, _Symbol, 0, 0, ORDER_TIME_GTC, 0, comment);

   if(!ok)
     {
      if(InpEnableLog)
         PrintFormat("AjipSnD: Pending %s order FAILED at %.5f. retcode=%d",
                     dir == 1 ? "BUY" : "SELL", midPrice, trade.ResultRetcode());
      return;
     }

   ulong ticket = trade.ResultOrder();
   int sz = ArraySize(g_pendingOrders);
   ArrayResize(g_pendingOrders, sz + 1);
   g_pendingOrders[sz].ticket   = ticket;
   g_pendingOrders[sz].dir      = dir;
   g_pendingOrders[sz].lot      = lot;
   g_pendingOrders[sz].zoneTime = zone.time;

   if(InpEnableLog)
      PrintFormat("AjipSnD: Pending %s order placed at %.5f (zone mid), lot=%.2f (%d active)",
                  dir == 1 ? "BUY" : "SELL", midPrice, lot, sz + 1);
  }

//---- Did this order ticket resolve into a filled position? ----
// Scoped to search history only from the zone time that produced the order
// — cheaper than scanning the whole account, and this order can't have a
// fill dated earlier than the zone that produced it.
bool OrderTriggeredToPosition(ulong orderTicket, datetime searchFrom, ulong &positionId, double &fillPrice)
  {
   if(!HistorySelect(searchFrom, TimeCurrent() + 1)) return(false);
   int total = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0) continue;
      if((ulong)HistoryDealGetInteger(d, DEAL_ORDER) != orderTicket) continue;
      if((int)HistoryDealGetInteger(d, DEAL_ENTRY) != DEAL_ENTRY_IN) continue;
      positionId = (ulong)HistoryDealGetInteger(d, DEAL_POSITION_ID);
      fillPrice  = HistoryDealGetDouble(d, DEAL_PRICE);
      return(true);
     }
   return(false);
  }

//---- Is the zone (by time+dir) behind this order still on the active watch
// list? False once CheckPendingZoneTouches or MarkLtfValidationContext has
// set its used flag — touched, or superseded by a fresher same-direction
// zone — or if the zone can't be found at all, which shouldn't happen but
// is treated the same way: nothing left to watch for. ----
bool ZoneStillWatched(datetime zoneTime, int dir)
  {
   bool isDemand = (dir == 1);
   int n = ArraySize(g_savedLtfZones);
   for(int i = 0; i < n; i++)
     {
      if(g_savedLtfZones[i].time == zoneTime && g_savedLtfZones[i].isDemand == isDemand)
         return(!g_savedLtfZones[i].used);
     }
   return(false);
  }

//---- Triggered orders fold into g_entries via AddEntry, same as any other
// fill; orders whose zone left the watch list get cancelled outright — no
// time-based expiry. Called once per closed LTF bar (see UpdateLTF), the
// same cadence CheckPendingZoneTouches updates zone state at, so a zone
// that stops being watched gets its order cancelled within one LTF bar
// instead of lagging up to a full HTF bar behind — and a filled order
// starts being tracked (MFE/MAE, partial-close, trailing) with the same
// short delay, which matters now that exits are managed by this EA rather
// than sitting on the broker as a resting SL/TP. ----
void ManagePendingOrders()
  {
   for(int i = ArraySize(g_pendingOrders) - 1; i >= 0; i--)
     {
      ulong ticket = g_pendingOrders[i].ticket;

      if(!OrderSelect(ticket))
        {
         ulong  positionId = 0;
         double fillPrice  = 0.0;
         if(OrderTriggeredToPosition(ticket, g_pendingOrders[i].zoneTime, positionId, fillPrice))
           {
            EntryFillInfo po;
            ZeroMemory(po);
            po.ticket        = positionId;
            po.dir           = g_pendingOrders[i].dir;
            po.price         = fillPrice;
            po.zoneTime      = g_pendingOrders[i].zoneTime;
            po.lot           = g_pendingOrders[i].lot;
            po.atrLtf        = GetAtrValue(false);
            po.triggerReason = "pendingorder";
            AddEntry(positionId, g_pendingOrders[i].dir, fillPrice, po);
            if(InpEnableLog)
               PrintFormat("AjipSnD: Pending order %I64u TRIGGERED -> position %I64u, fill=%.5f",
                           ticket, positionId, fillPrice);
           }
         else if(InpEnableLog)
            PrintFormat("AjipSnD: Pending order %I64u no longer active (cancelled/rejected) — dropped", ticket);

         ArrayRemove(g_pendingOrders, i, 1);
         continue;
        }

      if(!ZoneStillWatched(g_pendingOrders[i].zoneTime, g_pendingOrders[i].dir))
        {
         if(trade.OrderDelete(ticket))
           {
            if(InpEnableLog)
               PrintFormat("AjipSnD: Pending order %I64u — zone left the watch list, cancelled", ticket);
           }
         else if(InpEnableLog)
            PrintFormat("AjipSnD: Pending order %I64u cancel FAILED, error=%d", ticket, GetLastError());
         ArrayRemove(g_pendingOrders, i, 1);
        }
     }
  }

#endif
