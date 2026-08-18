#ifndef AJIPSND_PENDINGENTRY_MQH
#define AJIPSND_PENDINGENTRY_MQH

//==================================================================
// PENDING ORDER ENTRY — the EA's only entry mechanism. Every LTF zone saved
// under the current HTF bias gets an immediate resting limit order at its
// own midpoint — no rejection wait, no pattern match. SL sits beyond the
// HTF bias zone's own far edge (g_htfBiasZoneHigh/Low) + an HTF-ATR
// buffer — the same stop for every pending order sharing that bias, not a
// per-zone stop. Risk is InpPendingOrderTotalRisk split evenly across
// however many pending orders are active AT THE MOMENT a new one is
// placed — fixed then, not rebalanced as the count later changes, so
// actual total risk in flight drifts around the target rather than
// holding it exactly.
//
// Unproven — written directly to spec, not measured first. No restart
// recovery: RebuildTrackedPositions only reconstructs g_entries (filled
// positions) from live position state, not g_pendingOrders — a resting
// order that was placed before an EA/terminal restart keeps working at
// the broker, but this EA loses track of it (won't count it in the risk
// split for new orders, won't expire it, and won't recognise it as this
// EA's own trade if it later fills).
//==================================================================

//---- Place one resting limit order at a saved LTF zone's midpoint ----
void PlacePendingOrderForZone(const SavedLtfZone &zone, datetime htfBarTime)
  {
   if(g_htfBiasZoneHigh <= 0.0 || g_htfBiasZoneLow <= 0.0) return;   // no HTF reference yet

   int dir = zone.isDemand ? 1 : -1;
   if(EntryGateBlocked(dir)) return;

   double atrHtf = GetAtrValue(true);
   if(atrHtf <= 0) return;
   double buffer = InpHtfSlBufferAtr * atrHtf;
   double slPrice = dir == 1
                    ? NormalizeDouble(g_htfBiasZoneLow  - buffer, g_digits)
                    : NormalizeDouble(g_htfBiasZoneHigh + buffer, g_digits);

   double midPrice = NormalizeDouble((zone.high + zone.low) / 2.0, g_digits);

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;
   // A limit order has to rest on the correct side of price — if the market
   // already moved through the zone's midpoint before this zone even
   // finished validating, there is no resting order left worth placing.
   if(dir == 1 && midPrice >= tick.bid) return;
   if(dir == -1 && midPrice <= tick.ask) return;

   double slDistance = dir == 1 ? (midPrice - slPrice) : (slPrice - midPrice);
   if(slDistance <= 0.0) return;

   int activeCount = ArraySize(g_pendingOrders);
   double riskThisOrder = InpPendingOrderTotalRisk / (activeCount + 1);

   double actualRisk = 0.0;
   double lot = LotForRisk(slDistance, actualRisk, riskThisOrder);
   if(lot <= 0.0) return;
   if(lot < g_volMin || lot > g_volMax) return;

   double tpPrice = 0.0;
   if(InpTakeProfitRR > 0)
     {
      double reach = InpTakeProfitRR * slDistance;
      tpPrice = dir == 1
               ? NormalizeDouble(midPrice + reach, g_digits)
               : NormalizeDouble(midPrice - reach, g_digits);
     }

   string comment = StringFormat("AjipSnD %s PENDING", dir == 1 ? "BUY" : "SELL");
   bool ok;
   if(dir == 1)
      ok = trade.BuyLimit(lot, midPrice, _Symbol, slPrice, tpPrice, ORDER_TIME_GTC, 0, comment);
   else
      ok = trade.SellLimit(lot, midPrice, _Symbol, slPrice, tpPrice, ORDER_TIME_GTC, 0, comment);

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
   g_pendingOrders[sz].ticket           = ticket;
   g_pendingOrders[sz].dir              = dir;
   g_pendingOrders[sz].riskUsd          = actualRisk;
   g_pendingOrders[sz].lot              = lot;
   g_pendingOrders[sz].slPrice          = slPrice;
   g_pendingOrders[sz].tpPrice          = tpPrice;
   g_pendingOrders[sz].placedHtfBarTime = htfBarTime;
   g_pendingOrders[sz].zoneTime         = zone.time;

   if(InpEnableLog)
      PrintFormat("AjipSnD: Pending %s order placed at %.5f (zone mid), SL=%.5f TP=%.5f lot=%.2f risk=%.2f (%d active)",
                  dir == 1 ? "BUY" : "SELL", midPrice, slPrice, tpPrice, lot, actualRisk, sz + 1);
  }

//---- Did this order ticket resolve into a filled position? ----
// Scoped to search history only from this order's own placement — cheaper
// than scanning the whole account, and this order can't have a fill dated
// earlier than the moment it was placed.
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

//---- Triggered orders fold into g_entries via AddEntry, same as any other
// fill; expired ones get cancelled outright. Called once per closed HTF
// bar, live only (see UpdateHTF) — expiry is measured in HTF bars, so
// nothing here needs finer granularity. ----
void ManagePendingOrders(datetime currentHtfBarTime)
  {
   int htfBarSeconds = PeriodSeconds(InpHtfTimeframe);

   for(int i = ArraySize(g_pendingOrders) - 1; i >= 0; i--)
     {
      ulong ticket = g_pendingOrders[i].ticket;

      if(!OrderSelect(ticket))
        {
         ulong  positionId = 0;
         double fillPrice  = 0.0;
         if(OrderTriggeredToPosition(ticket, g_pendingOrders[i].placedHtfBarTime, positionId, fillPrice))
           {
            EntryFillInfo po;
            ZeroMemory(po);
            po.ticket        = positionId;
            po.dir           = g_pendingOrders[i].dir;
            po.price         = fillPrice;
            po.zoneTime      = g_pendingOrders[i].zoneTime;
            po.slPrice       = g_pendingOrders[i].slPrice;
            po.tpPrice       = g_pendingOrders[i].tpPrice;
            po.lot           = g_pendingOrders[i].lot;
            po.riskUsd       = g_pendingOrders[i].riskUsd;
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

      if(InpPendingOrderExpiryHtfBars > 0)
        {
         int barsElapsed = (int)((currentHtfBarTime - g_pendingOrders[i].placedHtfBarTime) / htfBarSeconds);
         if(barsElapsed >= InpPendingOrderExpiryHtfBars)
           {
            if(trade.OrderDelete(ticket))
              {
               if(InpEnableLog)
                  PrintFormat("AjipSnD: Pending order %I64u EXPIRED after %d HTF bars — cancelled",
                              ticket, barsElapsed);
              }
            else if(InpEnableLog)
               PrintFormat("AjipSnD: Pending order %I64u expiry cancel FAILED, error=%d", ticket, GetLastError());
            ArrayRemove(g_pendingOrders, i, 1);
           }
        }
     }
  }

#endif
