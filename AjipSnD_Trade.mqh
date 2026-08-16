#ifndef AJIPSND_TRADE_MQH
#define AJIPSND_TRADE_MQH

//==================================================================
// OPEN MARKET WITH STRUCTURAL STOPS — rejection-entry mode.
// Unlike PlacePendingOrder, this fills immediately at the current market
// price rather than resting at a limit: the rejection has already happened
// by the time this is called (the bar that confirmed it just closed), so
// there is no edge left to wait at — price is already moving off the zone.
//
// slPrice is the caller's zone-anchored stop; TP is derived here from the
// SAME price this order actually transacts at, matching PlaceEntryForZone's
// pattern of sizing TP off the real stop distance rather than an independent
// figure.
//==================================================================
ulong OpenMarketWithStructuralStops(int dir, double slPrice, datetime zoneTime)
  {
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return(0);
   double price = (dir == 1) ? tick.ask : tick.bid;

   slPrice = ClampToStopsLevel(dir, price, slPrice, true);

   double tpPrice = 0.0;
   if(InpTakeProfitRR > 0 && slPrice > 0.0)
     {
      double riskDist = MathAbs(price - slPrice);
      double reach = InpTakeProfitRR * riskDist;
      tpPrice = (dir == 1)
                ? NormalizeDouble(price + reach, g_digits)
                : NormalizeDouble(price - reach, g_digits);
      tpPrice = ClampToStopsLevel(dir, price, tpPrice, false);
     }

   double slDistance = (slPrice > 0.0) ? ((dir == 1) ? (price - slPrice) : (slPrice - price)) : 0.0;
   if(slDistance <= 0.0)
     {
      Print("AjipSnD: Rejection entry skipped — non-positive SL distance");
      return(0);
     }

   double actualRisk = 0.0;
   double lot = LotForRisk(slDistance, actualRisk);
   if(lot <= 0.0) return(0);
   if(lot < g_volMin || lot > g_volMax)
     {
      PrintFormat("AjipSnD: Rejection entry skip — lot %.2f outside broker range", lot);
      return(0);
     }

   string comment = StringFormat("AjipSnD %s REJECT", dir == 1 ? "BUY" : "SELL");
   bool ok;
   if(dir == 1)
      ok = trade.Buy(lot, _Symbol, price, slPrice, tpPrice, comment);
   else
      ok = trade.Sell(lot, _Symbol, price, slPrice, tpPrice, comment);

   if(!ok)
     {
      PrintFormat("AjipSnD: Rejection entry failed. retcode=%d", trade.ResultRetcode());
      return(0);
     }

   ulong ticket = trade.ResultOrder();
   double fillPrice = PositionSelectByTicket(ticket) ? PositionGetDouble(POSITION_PRICE_OPEN) : price;
   PrintFormat("AjipSnD: %s market-filled (rejection). Ticket=%I64u, Lot=%.2f, Fill=%.5f, SL=%.5f, TP=%.5f",
               dir == 1 ? "BUY" : "SELL", ticket, lot, fillPrice, slPrice, tpPrice);

   PendingOrder po;
   ZeroMemory(po);
   po.ticket   = ticket;
   po.dir      = dir;
   po.price    = fillPrice;
   po.zoneTime = zoneTime;
   po.slPrice  = slPrice;
   po.tpPrice  = tpPrice;
   po.lot      = lot;
   po.riskUsd  = actualRisk;
   po.atrLtf   = GetAtrValue(false);
   AddEntry(ticket, dir, fillPrice, po);

   return(ticket);
  }

//==================================================================
// ADD ENTRY to tracking
//==================================================================
// The PendingOrder is passed through so the position inherits what the order
// already knew — its structural stop, the risk it was sized for, and the LTF
// zone that triggered it. Without that hand-off the link between a trade and
// its originating zone is lost at the moment of the fill, and the per-trade CSV
// has nothing to join back to the zone log on.
void AddEntry(ulong ticket, int dir, double entryPrice, const PendingOrder &po)
  {
   int sz = ArraySize(g_entries);
   ArrayResize(g_entries, sz + 1);
   g_entries[sz].ticket       = ticket;
   g_entries[sz].dir          = dir;
   g_entries[sz].entryPrice   = entryPrice;
   g_entries[sz].entryTime    = TimeCurrent();
   g_entries[sz].mfe          = 0.0;
   g_entries[sz].mae          = 0.0;
   g_entries[sz].atrAtEntry   = GetAtrValue(true);

   g_entries[sz].initialVolume   = PositionSelectByTicket(ticket)
                                   ? PositionGetDouble(POSITION_VOLUME)
                                   : po.lot;
   g_entries[sz].hasStructuralSl = (po.slPrice > 0.0);
   g_entries[sz].slPrice         = po.slPrice;
   g_entries[sz].tpPrice         = po.tpPrice;
   g_entries[sz].riskUsd         = po.riskUsd;
   g_entries[sz].atrLtfAtEntry   = po.atrLtf;
   g_entries[sz].zoneTime        = po.zoneTime;
  }

//==================================================================
// REMOVE ENTRY from tracking
//==================================================================
void RemoveEntry(int idx)
  {
   ArrayRemove(g_entries, idx, 1);
  }

//==================================================================
// GET FLOATING PNL — sum POSITION_PROFIT of all tracked entries
//==================================================================
double GetFloatingPnL()
  {
   double total = 0.0;
   for(int i = ArraySize(g_entries) - 1; i >= 0; i--)
     {
      if(PositionSelectByTicket(g_entries[i].ticket))
         total += PositionGetDouble(POSITION_PROFIT);
     }
   return(total);
  }

//==================================================================
// PENDING ORDER — BUY LIMIT / SELL LIMIT
//==================================================================

//---- Push an SL or TP out to the broker's minimum stop distance ----
// SYMBOL_TRADE_STOPS_LEVEL is the closest either level may sit to the order
// price; inside it the order is rejected outright. Structural levels are
// normally far wider, so this should rarely fire — but a zone edge nearly
// touching the limit price would otherwise cost the whole entry.
//
// isStopLoss flips which side of the price the level belongs on: an SL sits
// against the trade, a TP with it. For a BUY that means SL below and TP above;
// for a SELL the reverse. Widening is the only legal direction in both cases.
double ClampToStopsLevel(int dir, double price, double level, bool isStopLoss)
  {
   if(level <= 0.0) return(level);

   long stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(stopsLevel <= 0) return(level);

   int    side    = isStopLoss ? -dir : dir;   // +1 = level above price
   double minDist = stopsLevel * g_point;
   double dist    = side * (level - price);
   if(dist >= minDist) return(level);

   double widened = NormalizeDouble(price + side * minDist, g_digits);
   PrintFormat("AjipSnD: %s %.5f inside broker stops level (%.1f pts) — widened to %.5f",
               isStopLoss ? "SL" : "TP", level, (double)stopsLevel, widened);
   return(widened);
  }

//---- Lot sized so that hitting slDistance costs about InpRiskPerTrade ----
// Rounds DOWN to the broker's volume step: rounding up would spend more than
// the risk budget, and the budget is the whole point. Returns InpFixedLot
// unchanged whenever risk sizing cannot apply (InpRiskPerTrade=0 or no stop
// distance to size against).
//
// The broker's minimum lot puts a hard floor under achievable risk. When the
// computed lot lands under it the position can only be opened by risking more
// than the budget, so InpMaxRiskOvershoot decides: accept the floor while the
// overshoot stays within tolerance, otherwise return 0 and let the caller skip
// the entry. Either way the real figure comes back through actualRisk, so the
// overshoot is logged rather than hidden.
//
// Returns 0.0 to mean "do not trade this setup" — distinct from the fallback
// path above it, which returns InpFixedLot to mean "risk sizing does not apply
// here". Callers must treat 0.0 as a skip, not as a lot.
double LotForRisk(double slDistance, double &actualRisk)
  {
   actualRisk = 0.0;
   double fallback = NormalizeDouble(InpFixedLot, 8);

   if(InpRiskPerTrade <= 0 || slDistance <= 0) return(fallback);

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0 || tickSize <= 0) return(fallback);

   double lossPerLot = slDistance * (tickValue / tickSize);
   if(lossPerLot <= 0) return(fallback);

   double lot = InpRiskPerTrade / lossPerLot;
   if(g_volStep > 0)
      lot = MathFloor(lot / g_volStep) * g_volStep;

   if(lot < g_volMin)
     {
      double floorRisk = g_volMin * lossPerLot;
      if(InpMaxRiskOvershoot > 0
         && floorRisk > InpRiskPerTrade * InpMaxRiskOvershoot)
        {
         PrintFormat("AjipSnD: entry skipped — min lot %.2f on a %.1f pt stop risks %.2f, "
                     "budget %.2f, cap %.2f",
                     g_volMin, slDistance / g_point, floorRisk, InpRiskPerTrade,
                     InpRiskPerTrade * InpMaxRiskOvershoot);
         return(0.0);
        }
      lot = g_volMin;
     }

   if(lot > g_volMax) lot = g_volMax;

   lot = NormalizeDouble(lot, 8);
   actualRisk = lot * lossPerLot;
   return(lot);
  }

//---- Place pending order at limit price ----
// A non-zero slPrice attaches the structural stop from the outset so the
// position is never unprotected, not even for the tick that fills it.
//
// Order matters here: the SL is clamped to the broker's stop level BEFORE the
// lot is sized, because the clamp can widen the stop and the lot has to be
// sized against the distance actually submitted, not the one first requested.
ulong PlacePendingOrder(int dir, double price, datetime zoneTime,
                        double slPrice, double tpPrice)
  {
   slPrice = ClampToStopsLevel(dir, price, slPrice, true);
   tpPrice = ClampToStopsLevel(dir, price, tpPrice, false);

   double slDistance = (slPrice > 0.0)
                       ? ((dir == 1) ? (price - slPrice) : (slPrice - price))
                       : 0.0;

   double actualRisk = 0.0;
   double lot = LotForRisk(slDistance, actualRisk);

   // 0.0 is LotForRisk's skip signal — the risk cap already logged the reason,
   // so returning quietly here avoids a second, misleading "outside broker
   // range" line for a decision that was deliberate.
   if(lot <= 0.0) return(0);

   if(lot < g_volMin || lot > g_volMax)
     {
      PrintFormat("AjipSnD: Pending %s skip — lot %.2f outside broker range",
                  dir == 1 ? "BUY LIMIT" : "SELL LIMIT", lot);
      return(0);
     }

   if(actualRisk > 0 && InpRiskPerTrade > 0
      && actualRisk > InpRiskPerTrade * 1.10)
      PrintFormat("AjipSnD: risk overshoot — min lot %.2f on a %.1f pt stop risks %.2f, budget %.2f",
                  lot, slDistance / g_point, actualRisk, InpRiskPerTrade);

   string comment = StringFormat("AjipSnD %s", dir == 1 ? "BUY LIMIT" : "SELL LIMIT");
   bool ok;
   if(dir == 1)
      ok = trade.BuyLimit(lot, price, _Symbol, slPrice, tpPrice, ORDER_TIME_GTC, 0, comment);
   else
      ok = trade.SellLimit(lot, price, _Symbol, slPrice, tpPrice, ORDER_TIME_GTC, 0, comment);

   if(!ok)
     {
      PrintFormat("AjipSnD: Pending order failed. retcode=%d", trade.ResultRetcode());
      return(0);
     }

   ulong ticket = trade.ResultOrder();
   PrintFormat("AjipSnD: %s placed. Ticket=%I64u, Lot=%.2f, Price=%.5f, SL=%.5f, TP=%.5f",
               dir == 1 ? "BUY LIMIT" : "SELL LIMIT", ticket, lot, price, slPrice, tpPrice);

   // Track pending order
   int sz = ArraySize(g_pendingOrders);
   ArrayResize(g_pendingOrders, sz + 1);
   g_pendingOrders[sz].ticket   = ticket;
   g_pendingOrders[sz].dir      = dir;
   g_pendingOrders[sz].price    = price;
   g_pendingOrders[sz].zoneTime = zoneTime;
   g_pendingOrders[sz].slPrice  = slPrice;
   g_pendingOrders[sz].tpPrice  = tpPrice;
   g_pendingOrders[sz].lot      = lot;
   g_pendingOrders[sz].riskUsd  = actualRisk;
   g_pendingOrders[sz].atrLtf   = GetAtrValue(false);

   return(ticket);
  }

//---- Cancel pending order for a specific zone (called when zone replaced) ----
void CancelPendingForZone(bool isDemand, datetime zoneTime)
  {
   for(int i = ArraySize(g_pendingOrders) - 1; i >= 0; i--)
     {
      int expectedDir = isDemand ? 1 : -1;
      if(g_pendingOrders[i].dir != expectedDir) continue;
      if(g_pendingOrders[i].zoneTime != zoneTime) continue;

      if(OrderSelect(g_pendingOrders[i].ticket))
        {
         if(trade.OrderDelete(g_pendingOrders[i].ticket))
            PrintFormat("AjipSnD: Cancelled pending ticket=%I64u (zone replaced)", g_pendingOrders[i].ticket);
        }
      ArrayRemove(g_pendingOrders, i, 1);
     }
  }

//---- Cancel pending orders resting inside a price range (HTF invalidation) ----
// CancelPendingForZone matches by the LTF zone's own confirm time — no help
// here, since a pending order only carries the LTF zone's zoneTime, never a
// reference to the HTF zone that hosted it. An HTF-caused invalidation has to
// find its orders by price instead.
//
// Call this AFTER the stale zone is already removed from g_htfDemandZones/
// g_htfSupplyZones: overlapping HTF zones can coexist (a newer zone only
// replaces an older one when it is strictly deeper/higher, so a shallower
// older zone can still overlap a newer one's range), so an order can still be
// legitimately backed by a surviving zone even though it also falls inside
// the one just invalidated. stillCovered re-checks the live arrays — after
// the removal — so that case is left alone instead of cancelled by mistake.
void CancelPendingInsideZone(bool isDemand, double zoneLow, double zoneHigh, string reason)
  {
   int expectedDir = isDemand ? 1 : -1;
   for(int i = ArraySize(g_pendingOrders) - 1; i >= 0; i--)
     {
      if(g_pendingOrders[i].dir != expectedDir) continue;
      if(g_pendingOrders[i].price < zoneLow || g_pendingOrders[i].price > zoneHigh) continue;

      bool stillCovered = isDemand
                          ? IsPriceInDemandZone(g_pendingOrders[i].price, g_htfDemandZones)
                          : IsPriceInSupplyZone(g_pendingOrders[i].price, g_htfSupplyZones);
      if(stillCovered) continue;

      if(OrderSelect(g_pendingOrders[i].ticket))
        {
         if(trade.OrderDelete(g_pendingOrders[i].ticket))
            PrintFormat("AjipSnD: Cancelled pending ticket=%I64u (%s)", g_pendingOrders[i].ticket, reason);
        }
      ArrayRemove(g_pendingOrders, i, 1);
     }
  }

//---- Cancel ALL pending orders (called on close-all) ----
void CancelAllPendingOrders()
  {
   for(int i = ArraySize(g_pendingOrders) - 1; i >= 0; i--)
     {
      if(OrderSelect(g_pendingOrders[i].ticket))
        {
         if(trade.OrderDelete(g_pendingOrders[i].ticket))
            PrintFormat("AjipSnD: Cancelled pending ticket=%I64u dir=%s (close-all)",
                        g_pendingOrders[i].ticket,
                        g_pendingOrders[i].dir == 1 ? "BUY LIMIT" : "SELL LIMIT");
        }
      ArrayRemove(g_pendingOrders, i, 1);
     }
  }

//---- Per-tick check: remove pendings outside HTF zone, detect fills ----
void CheckPendingOrders()
  {
   int n = ArraySize(g_pendingOrders);
   if(n == 0) return;

   MqlTick ticks[1];
   double bid = 0, ask = 0;
   if(CopyTicks(_Symbol, ticks, COPY_TICKS_ALL, 0, 1) == 1)
     {
      bid = ticks[0].bid;
      ask = ticks[0].ask;
     }
   else if(SymbolInfoTick(_Symbol, ticks[0]))
     {
      bid = ticks[0].bid;
      ask = ticks[0].ask;
     }

   for(int i = n - 1; i >= 0; i--)
     {
      // Check if order still exists
      if(!OrderSelect(g_pendingOrders[i].ticket))
        {
         // Order gone — likely filled. Check for new position.
         bool found = false;
         int npos = PositionsTotal();
         for(int j = 0; j < npos; j++)
           {
            ulong t = PositionGetTicket(j);
            if(t == 0) continue;
            if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
            if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

            // Check if this position is already tracked
            bool tracked = false;
            for(int k = 0; k < ArraySize(g_entries); k++)
              {
               if(g_entries[k].ticket == t) { tracked = true; break; }
              }
            if(tracked) continue;

            // New position — add to tracking
            int dir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
            // Match direction with pending
            if(dir != g_pendingOrders[i].dir) continue;

            AddEntry(t, dir, PositionGetDouble(POSITION_PRICE_OPEN), g_pendingOrders[i]);
            ExcursionMarkFilled(dir, g_pendingOrders[i].zoneTime);
            PrintFormat("AjipSnD: Pending filled! Ticket=%I64u dir=%s fill=%.5f",
                        t, dir == 1 ? "BUY" : "SELL",
                        PositionGetDouble(POSITION_PRICE_OPEN));
            found = true;
            break;
           }

         if(!found && InpEnableLog)
            PrintFormat("AjipSnD: Pending ticket=%I64u gone (cancelled/expired)", g_pendingOrders[i].ticket);

         ArrayRemove(g_pendingOrders, i, 1);
         continue;
        }

      // Order still pending — check if price is inside HTF zone
      double orderPrice = OrderGetDouble(ORDER_PRICE_OPEN);
      bool insideHtf = false;

      if(g_pendingOrders[i].dir == 1)  // BUY LIMIT → need demand zone
        {
         insideHtf = IsPriceInDemandZone(orderPrice, g_htfDemandZones);
        }
      else  // SELL LIMIT → need supply zone
        {
         insideHtf = IsPriceInSupplyZone(orderPrice, g_htfSupplyZones);
        }

      if(!insideHtf)
        {
         if(trade.OrderDelete(g_pendingOrders[i].ticket))
           {
            PrintFormat("AjipSnD: Cancelled pending ticket=%I64u dir=%s — outside HTF zone (orderPrice=%.5f)",
                        g_pendingOrders[i].ticket,
                        g_pendingOrders[i].dir == 1 ? "BUY LIMIT" : "SELL LIMIT", orderPrice);
           }
         ArrayRemove(g_pendingOrders, i, 1);
        }
     }
  }

//==================================================================
// GET PERIOD PNL — sum realized profit in [from, to]
//==================================================================
double GetPeriodPnL(datetime from, datetime to)
  {
   if(!HistorySelect(from, to)) return(0.0);

   double total = 0.0;
   int ndeals = HistoryDealsTotal();
   for(int i = 0; i < ndeals; i++)
     {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue;

      string dealSymbol = HistoryDealGetString(ticket, DEAL_SYMBOL);
      if(dealSymbol != _Symbol) continue;

      long dealMagic = HistoryDealGetInteger(ticket, DEAL_MAGIC);
      if(dealMagic != InpMagicNumber) continue;

      total += HistoryDealGetDouble(ticket, DEAL_PROFIT)
             + HistoryDealGetDouble(ticket, DEAL_SWAP)
             + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
     }
   return(total);
  }

//==================================================================
// LOCAL DAY START — convert server time to local via timezone offset
//==================================================================
datetime GetLocalDayStart()
  {
   datetime localNow = TimeCurrent() + g_timezoneOffsetSeconds;
   MqlDateTime localDt;
   TimeToStruct(localNow, localDt);
   localDt.hour = 0;
   localDt.min  = 0;
   localDt.sec  = 0;
   datetime localMidnight = StructToTime(localDt);
   // Convert local midnight back to server time for HistorySelect
   return(localMidnight - g_timezoneOffsetSeconds);
  }

//==================================================================
// GET DAILY PNL
//==================================================================
double GetDailyPnL()
  {
   datetime dayStart = GetLocalDayStart();
   datetime dayEnd   = dayStart + 86400;
   return(GetPeriodPnL(dayStart, dayEnd));
  }

//==================================================================
// GET WEEK PNL
//==================================================================
double GetWeekPnL()
  {
   datetime localNow = TimeCurrent() + g_timezoneOffsetSeconds;
   MqlDateTime localDt;
   TimeToStruct(localNow, localDt);
   int daysFromMonday = localDt.day_of_week == 0 ? 6 : localDt.day_of_week - 1;

   localDt.hour = 0;
   localDt.min  = 0;
   localDt.sec  = 0;
   datetime localMidnight = StructToTime(localDt);
   datetime localMonday   = localMidnight - daysFromMonday * 86400;
   datetime mondayServer  = localMonday - g_timezoneOffsetSeconds;

   return(GetPeriodPnL(mondayServer, TimeCurrent()));
  }

//==================================================================
// GET MONTH PNL
//==================================================================
double GetMonthPnL()
  {
   datetime localNow = TimeCurrent() + g_timezoneOffsetSeconds;
   MqlDateTime localDt;
   TimeToStruct(localNow, localDt);
   localDt.day  = 1;
   localDt.hour = 0;
   localDt.min  = 0;
   localDt.sec  = 0;
   datetime localMonthStart = StructToTime(localDt);
   datetime monthStartServer = localMonthStart - g_timezoneOffsetSeconds;

   return(GetPeriodPnL(monthStartServer, TimeCurrent()));
  }

//==================================================================
// UPDATE MFE/MAE — called every tick
//==================================================================
void UpdateMfeMae()
  {
   for(int i = ArraySize(g_entries) - 1; i >= 0; i--)
     {
      if(!PositionSelectByTicket(g_entries[i].ticket))
         continue;
      double profit = PositionGetDouble(POSITION_PROFIT);
      if(profit > g_entries[i].mfe) g_entries[i].mfe = profit;
      if(profit < g_entries[i].mae) g_entries[i].mae = profit;
     }
  }

//==================================================================
// COMPUTE REALIZED PNL — for a position closed outside the explicit
// close-all path (broker-side SL/TP hit). Tries live POSITION_PROFIT
// first (fast, accurate), falls back to history deals if the position
// is no longer selectable.
//==================================================================
double ComputeRealizedPnl(int idx)
  {
   if(idx < 0 || idx >= ArraySize(g_entries)) return(0.0);

   double realized = 0.0;

   // Try live position profit (most accurate, avoids history-timing gap)
   if(PositionSelectByTicket(g_entries[idx].ticket))
     {
      realized = PositionGetDouble(POSITION_PROFIT)
               + PositionGetDouble(POSITION_SWAP);  // commission only on deal, not position
     }
   else
     {
      // Fallback: search history deals (already closed, deals settled)
      if(HistorySelect(g_entries[idx].entryTime, TimeCurrent() + 1))
        {
         int ndeals = HistoryDealsTotal();
         for(int i = 0; i < ndeals; i++)
           {
            ulong dticket = HistoryDealGetTicket(i);
            if(dticket == 0) continue;
            long dmagic = HistoryDealGetInteger(dticket, DEAL_MAGIC);
            if(dmagic != InpMagicNumber) continue;

            ulong dposition = HistoryDealGetInteger(dticket, DEAL_POSITION_ID);
            if(dposition != g_entries[idx].ticket) continue;

            realized += HistoryDealGetDouble(dticket, DEAL_PROFIT)
                      + HistoryDealGetDouble(dticket, DEAL_SWAP)
                      + HistoryDealGetDouble(dticket, DEAL_COMMISSION);
           }
        }
     }

   return(realized);
  }

//==================================================================
// PER-TRADE CSV — one row per closed position. Records the exit reason
// the broker actually used and normalises P&L by the risk the trade
// was sized for, so results are stated in R.
//
// ltf_zone_time is the join key back to the zone CSV: it is what
// connects a trade's outcome to the characteristics of the zone that
// produced it.
//==================================================================
string DealReasonText(long reason)
  {
   switch((int)reason)
     {
      case DEAL_REASON_CLIENT:   return("CLIENT");
      case DEAL_REASON_MOBILE:   return("MOBILE");
      case DEAL_REASON_WEB:      return("WEB");
      case DEAL_REASON_EXPERT:   return("EXPERT");
      case DEAL_REASON_SL:       return("SL");
      case DEAL_REASON_TP:       return("TP");
      case DEAL_REASON_SO:       return("STOPOUT");
      case DEAL_REASON_ROLLOVER: return("ROLLOVER");
      case DEAL_REASON_VMARGIN:  return("VMARGIN");
      case DEAL_REASON_SPLIT:    return("SPLIT");
     }
   return("OTHER");
  }

void LogTradeCsv(int idx, double fallbackPnl, string fallbackReason)
  {
   if(!InpTradeLog) return;
   if(idx < 0 || idx >= ArraySize(g_entries)) return;

   ulong  ticket   = g_entries[idx].ticket;
   double exitPx   = 0.0;
   double dealPnl  = 0.0;
   bool   haveDeal = false;
   string reason   = fallbackReason;

   // Closing deal carries both the exit price and the reason the broker
   // applied. On the close-all path the deal may not have settled yet, so
   // this is best-effort and falls back to what the caller knows.
   if(HistorySelect(g_entries[idx].entryTime, TimeCurrent() + 1))
     {
      int ndeals = HistoryDealsTotal();
      for(int i = 0; i < ndeals; i++)
        {
         ulong d = HistoryDealGetTicket(i);
         if(d == 0) continue;
         if(HistoryDealGetInteger(d, DEAL_MAGIC) != InpMagicNumber) continue;
         if((ulong)HistoryDealGetInteger(d, DEAL_POSITION_ID) != ticket) continue;

         dealPnl += HistoryDealGetDouble(d, DEAL_PROFIT)
                  + HistoryDealGetDouble(d, DEAL_SWAP)
                  + HistoryDealGetDouble(d, DEAL_COMMISSION);

         if(HistoryDealGetInteger(d, DEAL_ENTRY) == DEAL_ENTRY_OUT)
           {
            exitPx   = HistoryDealGetDouble(d, DEAL_PRICE);
            reason   = DealReasonText(HistoryDealGetInteger(d, DEAL_REASON));
            haveDeal = true;
           }
        }
     }

   // Deal figures include commission; the snapshot the caller passes in
   // does not. Prefer the deal when it settled — R is meant to be net.
   double pnl = haveDeal ? dealPnl : fallbackPnl;

   double risk    = g_entries[idx].riskUsd;
   double slDist  = 0.0;
   if(g_entries[idx].slPrice > 0.0)
      slDist = (g_entries[idx].dir == 1)
               ? (g_entries[idx].entryPrice - g_entries[idx].slPrice)
               : (g_entries[idx].slPrice - g_entries[idx].entryPrice);

   string filename = "AjipSnD_Trades_" + _Symbol + "_"
                   + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + ".csv";
   bool exists = FileIsExist(filename, FILE_COMMON);

   int h = FileOpen(filename,
                    FILE_COMMON | FILE_WRITE | FILE_READ | FILE_CSV | FILE_ANSI,
                    ',', CP_UTF8);
   if(h == INVALID_HANDLE)
     {
      PrintFormat("AjipSnD: Cannot open trade CSV %s", filename);
      return;
     }

   if(!exists)
      FileWrite(h,
                "entry_time", "exit_time", "dir", "entry_price", "exit_price",
                "sl_price", "tp_price", "sl_dist_pts", "sl_dist_atr",
                "lot", "risk_usd", "exit_reason", "pnl_usd", "pnl_r",
                "mfe_usd", "mae_usd", "mfe_r", "mae_r",
                "atr_ltf", "atr_htf", "structural", "ltf_zone_time");
   else
      FileSeek(h, 0, SEEK_END);

   FileWrite(h,
             TimeToString(g_entries[idx].entryTime, TIME_DATE | TIME_SECONDS),
             TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
             g_entries[idx].dir == 1 ? "BUY" : "SELL",
             DoubleToString(g_entries[idx].entryPrice, g_digits),
             DoubleToString(exitPx, g_digits),
             DoubleToString(g_entries[idx].slPrice, g_digits),
             DoubleToString(g_entries[idx].tpPrice, g_digits),
             DoubleToString(slDist / g_point, 1),
             DoubleToString(g_entries[idx].atrLtfAtEntry > 0
                            ? slDist / g_entries[idx].atrLtfAtEntry : 0.0, 3),
             DoubleToString(g_entries[idx].initialVolume, 2),
             DoubleToString(risk, 2),
             reason,
             DoubleToString(pnl, 2),
             DoubleToString(risk > 0 ? pnl / risk : 0.0, 3),
             DoubleToString(g_entries[idx].mfe, 2),
             DoubleToString(g_entries[idx].mae, 2),
             DoubleToString(risk > 0 ? g_entries[idx].mfe / risk : 0.0, 3),
             DoubleToString(risk > 0 ? g_entries[idx].mae / risk : 0.0, 3),
             DoubleToString(g_entries[idx].atrLtfAtEntry, g_digits),
             DoubleToString(g_entries[idx].atrAtEntry, g_digits),
             g_entries[idx].hasStructuralSl ? "1" : "0",
             TimeToString(g_entries[idx].zoneTime, TIME_DATE | TIME_SECONDS));

   FileClose(h);
  }

//==================================================================
// CHECK ENTRY CLEANUP — positions closed outside close-all (SL/TP hit).
//==================================================================
void CheckEntryCleanup()
  {
   for(int i = ArraySize(g_entries) - 1; i >= 0; i--)
     {
      if(!PositionSelectByTicket(g_entries[i].ticket))
        {
         // Broker-side exits (SL, TP) land here, and here the closing deal has
         // settled — so this path yields the real exit reason, not a guess.
         double realized = ComputeRealizedPnl(i);
         LogTradeCsv(i, realized, "CLOSED");
         RemoveEntry(i);
        }
     }
  }

//==================================================================
// CLOSE ALL POSITIONS (this symbol + magic)
//==================================================================
void CloseAllPositions()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

      if(!trade.PositionClose(ticket))
         PrintFormat("AjipSnD: Close %I64u failed retcode=%d", ticket, trade.ResultRetcode());
     }
  }

//==================================================================
// CLOSE ALL AND LOG TRADES.
// Snapshot POSITION_PROFIT BEFORE closing to avoid the history-timing gap
// where the deal hasn't settled yet, but only log a position once the
// close has actually removed it.
//==================================================================
void CloseAllAndLogTrades(string reason)
  {
   int n = ArraySize(g_entries);

   // ---- Snapshot live P&L BEFORE closing ----
   // Once PositionClose succeeds the position is gone and the deal may not
   // have settled into history yet, so the open position is the only reliable
   // source for its profit. Index-aligned with g_entries; nothing between here
   // and the logging loop below resizes that array (CancelAllPendingOrders
   // touches g_pendingOrders, CloseAllPositions touches neither).
   double net[];
   ArrayResize(net, n);
   for(int i = 0; i < n; i++)
     {
      net[i] = 0.0;
      if(PositionSelectByTicket(g_entries[i].ticket))
         net[i] = PositionGetDouble(POSITION_PROFIT)
                + PositionGetDouble(POSITION_SWAP);  // commission is on the deal, not the position
     }

   CancelAllPendingOrders();
   CloseAllPositions();

   // ---- Log ONLY what actually closed ----
   // A close can be rejected — market closed over a holiday, trade context
   // busy — and the position then survives the call. Logging it anyway (which
   // is what this function used to do, before CloseAllPositions was even
   // called) wrote a row for positions still open; the next tick found the
   // same trigger still true and repeated the whole thing, producing
   // duplicate rows. MathMin guards net[] against a future caller that adds
   // entries mid-close: an out-of-range read halts the EA outright, and only
   // the snapshot's own indices carry a P&L figure anyway.
   for(int i = MathMin(ArraySize(g_entries), n) - 1; i >= 0; i--)
     {
      if(PositionSelectByTicket(g_entries[i].ticket))
         continue;                      // still open — retry on the next tick

      LogTradeCsv(i, net[i], reason);
      RemoveEntry(i);
     }

   int remaining = ArraySize(g_entries);
   if(remaining > 0)
      PrintFormat("AjipSnD: %s close incomplete — %d position(s) still open, retrying", reason, remaining);
  }

//==================================================================
// CHECK DAILY CLOSE-ALL — TARGET only (gated by news)
//==================================================================
void CheckDailyTargetCloseAll()
  {
   if(InpDailyMaxProfit <= 0) return;
   double total = GetDailyPnL() + GetFloatingPnL();
   if(total >= InpDailyMaxProfit)
     {
      PrintFormat("AjipSnD: DAILY TARGET HIT (%.2f >= %.2f) — closing all", total, InpDailyMaxProfit);
      WriteHandoffSignal("DAILY_TARGET", total);
      CloseAllAndLogTrades("DAILY_TARGET");
     }
  }

//==================================================================
// CHECK DAILY MAX LOSS — NEVER gated by news
//==================================================================
void CheckDailyMaxLossCloseAll()
  {
   if(InpDailyMaxLoss <= 0) return;
   double total = GetDailyPnL() + GetFloatingPnL();
   if(total <= -InpDailyMaxLoss)
     {
      PrintFormat("AjipSnD: DAILY MAX LOSS HIT (%.2f <= %.2f) — closing all", total, -InpDailyMaxLoss);
      WriteHandoffSignal("DAILY_MAX_LOSS", total);
      CloseAllAndLogTrades("DAILY_MAX_LOSS");
     }
  }

//==================================================================
// CHECK SESSION CLOSE-ALL (gated by news blackout — profit-taking only)
//==================================================================
void CheckSessionCloseAll()
  {
   if(!g_sessionFilterEnabled) return;
   if(InSession()) return;

   double total = GetDailyPnL() + GetFloatingPnL();
   if(total > 0)
     {
      PrintFormat("AjipSnD: SESSION END — profit=%.2f, closing all", total);
      CloseAllAndLogTrades("SESSION_END");
     }
  }

//==================================================================
// CAPTURE STARTING BALANCE
//==================================================================
void CaptureStartingBalance()
  {
   if(InpStartingBalance > 0)
     {
      g_startingBalance = InpStartingBalance;
     }
   else
     {
      // Auto-capture and persist via GlobalVariable
      string gvName = "AjipSnD_StartingBalance_" + IntegerToString(InpMagicNumber);
      if(GlobalVariableCheck(gvName))
         g_startingBalance = GlobalVariableGet(gvName);
      else
        {
         g_startingBalance = AccountInfoDouble(ACCOUNT_BALANCE);
         GlobalVariableSet(gvName, g_startingBalance);
        }
     }
   PrintFormat("AjipSnD: Starting balance = %.2f", g_startingBalance);
  }

//==================================================================
// CHECK FINAL TARGET / MAX LOSS
//==================================================================
bool FinalTargetReached()
  {
   if(InpFinalProfitTarget <= 0) return(false);
   return((AccountInfoDouble(ACCOUNT_BALANCE) - g_startingBalance + GetFloatingPnL()) >= InpFinalProfitTarget);
  }

bool FinalMaxLossReached()
  {
   if(InpFinalMaxLoss <= 0) return(false);
   return((AccountInfoDouble(ACCOUNT_BALANCE) - g_startingBalance + GetFloatingPnL()) <= -InpFinalMaxLoss);
  }

//==================================================================
// CHECK FINAL TARGET (gated by news)
//==================================================================
void CheckFinalTargetCloseAll()
  {
   if(InpFinalProfitTarget <= 0) return;
   if((AccountInfoDouble(ACCOUNT_BALANCE) - g_startingBalance + GetFloatingPnL()) >= InpFinalProfitTarget)
     {
      PrintFormat("AjipSnD: FINAL TARGET REACHED — closing all PERMANENTLY");
      CloseAllAndLogTrades("FINAL_TARGET");
     }
  }

//==================================================================
// CHECK FINAL MAX LOSS (NEVER gated by news)
//==================================================================
void CheckFinalMaxLossCloseAll()
  {
   if(InpFinalMaxLoss <= 0) return;
   if((AccountInfoDouble(ACCOUNT_BALANCE) - g_startingBalance + GetFloatingPnL()) <= -InpFinalMaxLoss)
     {
      PrintFormat("AjipSnD: FINAL MAX LOSS REACHED — closing all PERMANENTLY");
      CloseAllAndLogTrades("FINAL_MAX_LOSS");
     }
  }

//==================================================================
// WRITE HANDOFF SIGNAL — fired when daily target/max-loss is hit.
// This account should sit out the rest of the day.
//==================================================================
void WriteHandoffSignal(const string reason, double dailyTotal)
  {
   if(!InpHandoffEnabled) return;

   int handle = FileOpen(InpHandoffFile, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(handle == INVALID_HANDLE)
     {
      if(InpEnableLog) PrintFormat("AjipSnD: WriteHandoffSignal — failed to open %s, error=%d", InpHandoffFile, GetLastError());
      return;
     }

   string line = StringFormat("login=%d\nreason=%s\npnl=%.2f\nsymbol=%s\nmagic=%d\ntime=%s\n",
                               (int)AccountInfoInteger(ACCOUNT_LOGIN), reason, dailyTotal, _Symbol, InpMagicNumber,
                               TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS));
   FileWriteString(handle, line);
   FileClose(handle);

   if(InpEnableLog) PrintFormat("AjipSnD: Handoff signal written — login=%d reason=%s pnl=%.2f file=%s",
               (int)AccountInfoInteger(ACCOUNT_LOGIN), reason, dailyTotal, InpHandoffFile);
  }

//==================================================================
// WRITE HEARTBEAT — "I'm alive on THIS account" signal.
// Overwrites file every ~30s. Gated by InpHandoffEnabled.
//==================================================================
void WriteHeartbeat()
  {
   if(!InpHandoffEnabled) return;
   if(TimeCurrent() - g_lastHeartbeatTime < HEARTBEAT_INTERVAL_SECONDS) return;
   g_lastHeartbeatTime = TimeCurrent();

   int handle = FileOpen(InpHeartbeatFile, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(handle == INVALID_HANDLE)
     {
      if(InpEnableLog) PrintFormat("AjipSnD: WriteHeartbeat — failed to open %s, error=%d", InpHeartbeatFile, GetLastError());
      return;
     }

   string line = StringFormat("login=%d\nsymbol=%s\nmagic=%d\ntime=%s\n",
                               (int)AccountInfoInteger(ACCOUNT_LOGIN), _Symbol, InpMagicNumber,
                               TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS));
   FileWriteString(handle, line);
   FileClose(handle);
  }

#endif // AJIPSND_TRADE_MQH
