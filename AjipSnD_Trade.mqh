#ifndef AJIPSND_TRADE_MQH
#define AJIPSND_TRADE_MQH

//==================================================================
// OPEN TRADE — fixed lot (InpFixedLot), no SL/TP
//==================================================================
ulong OpenTrade(bool isBuy, double entry)
  {
   double lot = NormalizeDouble(InpFixedLot, 8);
   if(lot < g_volMin || lot > g_volMax)
     {
      PrintFormat("AjipSnD: %s skip — InpFixedLot %.2f outside broker range [%.2f, %.2f]",
                  isBuy ? "BUY" : "SELL", lot, g_volMin, g_volMax);
      return(0);
     }

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return(0);

   bool ok;
   if(isBuy)
      ok = trade.Buy(lot, _Symbol, tick.ask, 0.0, 0.0, "AjipSnD BUY");
   else
      ok = trade.Sell(lot, _Symbol, tick.bid, 0.0, 0.0, "AjipSnD SELL");

   if(ok)
     {
      ulong ticket = trade.ResultOrder();
      double fillPrice = entry;
      if(PositionSelectByTicket(ticket))
         fillPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      PrintFormat("AjipSnD: %s opened. Ticket=%I64u, Lot=%.2f, Signal=%.5f, Fill=%.5f, SL=NONE, TP=NONE",
                  isBuy ? "BUY" : "SELL", ticket, lot, entry, fillPrice);
      return(ticket);
     }

   PrintFormat("AjipSnD: Order failed. retcode=%d (%s)",
               trade.ResultRetcode(), trade.ResultRetcodeDescription());
   return(0);
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
   g_entries[sz].partialClosed = false;
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

   // First entry of batch
   if(!g_batchActive)
     {
      g_batchActive = true;
      g_batchFirstEntryTime = TimeCurrent();
      g_batchAtrAtStart = GetAtrValue(true);
     }
   g_batchLastEntryTime = TimeCurrent();
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
// unchanged whenever risk sizing cannot apply, matching the fallback pattern
// InpPartialCloseAtr and InpBatchMaxProfitAtr already use.
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
// slPrice = 0.0 places a naked order, exactly as the batch architecture always
// has; a non-zero value attaches the structural stop from the outset so the
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

//---- Cancel ALL pending orders (called on close-all, except batch) ----
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
// ACCUMULATE BATCH STATS — fold closed position into batch.
// Tries live POSITION_PROFIT first (fast, accurate), falls back to
// history deals if position no longer selectable (e.g., CheckEntryCleanup).
// Returns the realised figure so the per-trade log can record the same number
// the batch accounting used, instead of deriving its own and disagreeing.
//==================================================================
double AccumulateBatchStats(int idx)
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

   g_batchCount++;
   g_batchRealizedPnl += realized;
   g_batchMfeSum += g_entries[idx].mfe;
   g_batchMaeSum += g_entries[idx].mae;

   if(realized > 0)       g_batchWins++;
   else if(realized < 0)  g_batchLosses++;
   else                   g_batchBreakEven++;

   return(realized);
  }

//==================================================================
// PER-TRADE CSV — one row per closed position.
//
// The batch CSV cannot answer this experiment's questions. Its CloseReason
// describes why a BATCH was flushed, so a stop-out and a target hit both
// arrive as BATCH_FLAT — the EA only notices the position is gone. And its
// P&L is in dollars, which stop being comparable across trades the moment lot
// size varies with stop distance. This log records the exit reason the broker
// actually used and normalises P&L by the risk the trade was sized for, so
// results are stated in R.
//
// ltf_zone_time is the join key back to the zone CSV: it is what finally
// connects a trade's outcome to the characteristics of the zone that produced
// it. Until now the two could only ever be measured separately.
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
   // applied. On the close-all path the deal may not have settled yet — that
   // is the timing gap the batch accounting already works around — so this is
   // best-effort and falls back to what the caller knows.
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

   // Deal figures include commission; the snapshot the batch path passes in
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
// CHECK ENTRY CLEANUP — positions closed outside close-all.
// If all entries gone AND batch has stats, flush CSV.
//==================================================================
void CheckEntryCleanup()
  {
   for(int i = ArraySize(g_entries) - 1; i >= 0; i--)
     {
      if(!PositionSelectByTicket(g_entries[i].ticket))
        {
         // Broker-side exits (SL, TP) land here, and here the closing deal has
         // settled — so this path yields the real exit reason, not a guess.
         double realized = AccumulateBatchStats(i);
         LogTradeCsv(i, realized, "CLOSED");
         RemoveEntry(i);
        }
     }

   // Batch went flat via natural closes (SL hit, aggregate SL, manual) —
   // flush CSV so stats aren't orphaned until the next CloseAllAndFlushBatch.
   if(ArraySize(g_entries) == 0 && g_batchCount > 0)
     {
      FlushBatchCSV("BATCH_FLAT");
      ResetBatchAccumulator();
      g_lastBatchEndTime = TimeCurrent();
     }
  }

//==================================================================
// PARTIAL CLOSE — one-time per position
//==================================================================
//---- Partial close trigger in account currency, for one position ----
// With InpPartialCloseAtr > 0 the target scales with the HTF ATR frozen at
// entry, so one setting behaves the same across volatility regimes. On XAUUSD
// a fixed $10 was reached by 33% of entries in a low-volatility year and 67%
// in a high-volatility one; at 1.5x ATR the two were 57% and 61%. The ATR is
// taken at entry rather than live, so a volatility spike cannot move the
// target away from a position already running.
double PartialCloseThreshold(double atrAtEntry, double volume)
  {
   if(InpPartialCloseAtr <= 0 || atrAtEntry <= 0)
      return(InpPartialCloseProfit);

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0 || tickSize <= 0)
      return(InpPartialCloseProfit);

   return(InpPartialCloseAtr * atrAtEntry * (tickValue / tickSize) * volume);
  }

void CheckPartialClose()
  {
   // Structural mode gives each trade exactly two outcomes, SL or TP, so that a
   // result can be stated in R. Partial close breaks that twice over: it splits
   // the realised P&L across two fills while riskUsd was computed for the whole
   // position, and its breakeven step calls PositionModify(ticket, entry, 0.0),
   // which zeroes the take profit outright.
   if(InpStructuralSlMode) return;

   if(InpPartialClosePercent <= 0) return;
   if(InpPartialCloseProfit <= 0 && InpPartialCloseAtr <= 0) return;

   for(int i = ArraySize(g_entries) - 1; i >= 0; i--)
     {
      if(g_entries[i].partialClosed) continue;

      if(!PositionSelectByTicket(g_entries[i].ticket))
        {
         double realized = AccumulateBatchStats(i);
         LogTradeCsv(i, realized, "CLOSED");
         RemoveEntry(i);
         continue;
        }

      double posVolume = PositionGetDouble(POSITION_VOLUME);
      double threshold = PartialCloseThreshold(g_entries[i].atrAtEntry, posVolume);
      if(threshold <= 0) continue;

      double posProfit = PositionGetDouble(POSITION_PROFIT);
      if(posProfit < threshold) continue;

      double closeVol = NormalizeDouble(posVolume * InpPartialClosePercent / 100.0, 8);
      double remainder = posVolume - closeVol;

      // Round to volume step
      closeVol = MathFloor(closeVol / g_volStep) * g_volStep;
      if(closeVol < g_volMin || remainder < g_volMin)
        {
         if(closeVol >= g_volMin)
            closeVol = posVolume; // close full instead
         else
            continue; // too small to split
        }

      double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      ulong ticket = g_entries[i].ticket;

      if(!trade.PositionClosePartial(ticket, closeVol))
        {
         PrintFormat("AjipSnD: Partial close failed ticket=%I64u retcode=%d",
                     ticket, trade.ResultRetcode());
         continue;
        }

      PrintFormat("AjipSnD: Partial close ticket=%I64u, closedVol=%.2f, profit=%.2f (target %.2f)",
                  ticket, closeVol, posProfit, threshold);

      // Move remaining to breakeven
      if(PositionSelectByTicket(ticket))
        {
         if(!trade.PositionModify(ticket, entryPrice, 0.0))
           {
            PrintFormat("AjipSnD: BE SL modify failed ticket=%I64u retcode=%d",
                        ticket, trade.ResultRetcode());
           }
        }

      g_entries[i].partialClosed = true;
     }
  }

//==================================================================
// TRAILING STOP — for positions that have been partial-closed to BE.
// Only trails SL forward (never backward). Fixed-step: SL stays
// InpTrailDistancePoints behind current price once profit exceeds
// InpTrailStartPoints from entry.
//==================================================================
void CheckTrailingStop()
  {
   // Would walk the structural stop away from the zone that justified it.
   if(InpStructuralSlMode) return;

   if(InpTrailStartPoints <= 0 || InpTrailDistancePoints <= 0) return;

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
   double trailDist  = InpTrailDistancePoints * g_point;
   double trailStart = InpTrailStartPoints * g_point;

   for(int i = ArraySize(g_entries) - 1; i >= 0; i--)
     {
      if(!g_entries[i].partialClosed) continue;  // only trail BE positions
      if(!PositionSelectByTicket(g_entries[i].ticket)) continue;

      double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSl      = PositionGetDouble(POSITION_SL);
      double curTp      = PositionGetDouble(POSITION_TP);

      if(g_entries[i].dir == 1)  // BUY
        {
         double profitPoints = bid - entryPrice;
         if(profitPoints < trailStart) continue;  // not enough profit yet

         double newSl = NormalizeDouble(bid - trailDist, g_digits);
         // Only move SL forward (never below current SL or below entry)
         if(newSl <= curSl + g_point * 0.5) continue;

         if(trade.PositionModify(g_entries[i].ticket, newSl, curTp))
            PrintFormat("AjipSnD: Trail SL BUY ticket=%I64u SL=%.5f (bid=%.5f dist=%d pts)",
                        g_entries[i].ticket, newSl, bid, InpTrailDistancePoints);
        }
      else  // SELL
        {
         double profitPoints = entryPrice - ask;
         if(profitPoints < trailStart) continue;

         double newSl = NormalizeDouble(ask + trailDist, g_digits);
         if(newSl >= curSl - g_point * 0.5) continue;

         if(trade.PositionModify(g_entries[i].ticket, newSl, curTp))
            PrintFormat("AjipSnD: Trail SL SELL ticket=%I64u SL=%.5f (ask=%.5f dist=%d pts)",
                        g_entries[i].ticket, newSl, ask, InpTrailDistancePoints);
        }
     }
  }

//==================================================================
// INVALID POSITION HANDLER — positions that are floating loss AND
// either outside active HTF zone or loss > InpPosMaxLoss.
// Sets TP to entry price (breakeven) — gives chance to exit at BE.
// One-shot: skips if TP already at entry price.
//==================================================================
void CheckInvalidPositions()
  {
   // Overwrites the take profit with a breakeven one. In structural mode the
   // stop already IS the invalidation rule — price leaving the HTF zone is
   // exactly what it is placed beyond — so this would be a second, competing
   // answer to the same question.
   if(InpStructuralSlMode) return;

   if(InpPosMaxLoss <= 0) return;  // feature disabled

   for(int i = ArraySize(g_entries) - 1; i >= 0; i--)
     {
      if(!PositionSelectByTicket(g_entries[i].ticket))
         continue;

      double posProfit   = PositionGetDouble(POSITION_PROFIT);
      double entryPrice  = PositionGetDouble(POSITION_PRICE_OPEN);
      double curTp       = PositionGetDouble(POSITION_TP);

      // Only handle floating LOSS positions
      if(posProfit >= 0) continue;

      // One-shot: TP already at entry → already handled
      if(MathAbs(curTp - entryPrice) < g_point * 0.5)
         continue;

      // Skip positions opened this bar — give them at least 1 full bar to settle
      // Prevents false triggers from bid/ask spread at zone boundaries on fresh entries
      if(g_entries[i].entryTime >= g_ltfLastBarTime)
         continue;

      bool invalid = false;
      string reason = "";

      // Condition 1: entry premise invalid — the HTF zone we entered on no longer exists.
      // Check if entryPrice is still inside any active zone of the same type.
      // If the zone was invalidated (removed by InvalidateHtfZones), entryPrice
      // will no longer be inside any active zone → position premise is broken.
      if(g_entries[i].dir == 1)  // BUY → entry was inside a demand zone
        {
         if(!IsPriceInDemandZone(entryPrice, g_htfDemandZones))
           {
            invalid = true;
            reason = "entry demand zone invalidated";
           }
        }
      else  // SELL → entry was inside a supply zone
        {
         if(!IsPriceInSupplyZone(entryPrice, g_htfSupplyZones))
           {
            invalid = true;
            reason = "entry supply zone invalidated";
           }
        }

      // Condition 2: floating loss exceeds threshold
      if(!invalid && MathAbs(posProfit) > InpPosMaxLoss)
        {
         invalid = true;
         reason = StringFormat("floating loss %.2f > InpPosMaxLoss %.2f",
                               MathAbs(posProfit), InpPosMaxLoss);
        }

      if(!invalid) continue;

      // Set TP to entry price (BE), keep existing SL
      double curSl = PositionGetDouble(POSITION_SL);

      if(!trade.PositionModify(g_entries[i].ticket, curSl, entryPrice))
        {
         PrintFormat("AjipSnD: Invalid pos BE-TP modify FAILED ticket=%I64u retcode=%d reason=%s",
                     g_entries[i].ticket, trade.ResultRetcode(), reason);
         continue;
        }

      PrintFormat("AjipSnD: Invalid pos ticket=%I64u dir=%s TP→BE (%.5f) reason=%s loss=%.2f",
                  g_entries[i].ticket,
                  g_entries[i].dir == 1 ? "BUY" : "SELL",
                  entryPrice, reason, MathAbs(posProfit));
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
// FLUSH BATCH CSV
//==================================================================
void FlushBatchCSV(string reason)
  {
   if(g_batchCount == 0) return;

   string filename = "AjipSnD_Batches_" + _Symbol + "_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + ".csv";
   bool exists = FileIsExist(filename, FILE_COMMON);

   // FILE_CSV makes FileWrite insert the delimiter between fields; with plain
   // FILE_TXT every field is concatenated into one unparseable string. The
   // header hid this, being a single comma-containing literal. FILE_ANSI is
   // what makes the CP_UTF8 codepage apply — without it the file is UTF-16.
   int handle = FileOpen(filename,
                         FILE_COMMON | FILE_WRITE | FILE_READ | FILE_CSV | FILE_ANSI,
                         ',', CP_UTF8);
   if(handle == INVALID_HANDLE)
     {
      PrintFormat("AjipSnD: Cannot open batch CSV %s", filename);
      return;
     }

   // Header if new file — one argument per column, so the delimiter count
   // always matches the data row below
   if(!exists)
     {
      FileWrite(handle,
                "CloseTime", "CloseReason", "PositionCount", "Wins", "Losses",
                "BreakEven", "TotalRealizedPnL", "SumMFE", "SumMAE",
                "FirstEntryTime", "LastEntryTime");
     }
   else
      FileSeek(handle, 0, SEEK_END);

   FileWrite(handle,
             TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS),
             reason, g_batchCount, g_batchWins, g_batchLosses, g_batchBreakEven,
             g_batchRealizedPnl, g_batchMfeSum, g_batchMaeSum,
             TimeToString(g_batchFirstEntryTime, TIME_DATE | TIME_SECONDS),
             TimeToString(g_batchLastEntryTime, TIME_DATE | TIME_SECONDS));

   FileClose(handle);
   PrintFormat("AjipSnD: Batch flushed — reason=%s count=%d PnL=%.2f", reason, g_batchCount, g_batchRealizedPnl);
  }

//==================================================================
// RESET BATCH ACCUMULATOR
//==================================================================
void ResetBatchAccumulator()
  {
   g_batchActive         = false;
   g_batchFirstEntryTime = 0;
   g_batchLastEntryTime  = 0;
   g_batchCount          = 0;
   g_batchWins           = 0;
   g_batchLosses         = 0;
   g_batchBreakEven      = 0;
   g_batchRealizedPnl    = 0.0;
   g_batchMfeSum         = 0.0;
   g_batchMaeSum         = 0.0;
   g_batchAtrAtStart     = 0.0;
  }

//==================================================================
// CLOSE ALL AND FLUSH BATCH.
// Snapshot POSITION_PROFIT BEFORE closing to avoid the history-timing gap
// where the deal hasn't settled yet, but only bank a position once the close
// has actually removed it. Flush once the batch is flat.
//==================================================================
void CloseAllAndFlushBatch(string reason)
  {
   int n = ArraySize(g_entries);

   // ---- Snapshot live P&L BEFORE closing ----
   // Once PositionClose succeeds the position is gone and the deal may not
   // have settled into history yet, so the open position is the only reliable
   // source for its profit. Index-aligned with g_entries; nothing between here
   // and the banking loop below resizes that array (CancelAllPendingOrders
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

   // ---- Cancel pending orders (except batch close-all — trading continues) ----
   if(StringFind(reason, "BATCH_") != 0)
      CancelAllPendingOrders();

   // ---- Close all positions ----
   CloseAllPositions();

   // ---- Bank ONLY what actually closed ----
   // A close can be rejected — market closed over a holiday, trade context
   // busy — and the position then survives the call. Banking it anyway (which
   // is what this function used to do, before CloseAllPositions was even
   // called) wrote a batch row for positions still open and reset the
   // accumulator; the next tick found the same trigger still true and repeated
   // the whole thing, so one stalled close produced hundreds of duplicate rows
   // carrying a zeroed FirstEntryTime. A 12-month XAUUSD backtest turned up 759
   // such rows over three holiday sessions, inflating position counts ~2.5x.
   // MathMin guards net[] against a future caller that adds entries mid-close:
   // an out-of-range read halts the EA outright, and only the snapshot's own
   // indices carry a P&L figure anyway.
   for(int i = MathMin(ArraySize(g_entries), n) - 1; i >= 0; i--)
     {
      if(PositionSelectByTicket(g_entries[i].ticket))
         continue;                      // still open — retry on the next tick

      g_batchCount++;
      g_batchRealizedPnl += net[i];
      g_batchMfeSum += g_entries[i].mfe;
      g_batchMaeSum += g_entries[i].mae;
      if(net[i] > 0)       g_batchWins++;
      else if(net[i] < 0)  g_batchLosses++;
      else                 g_batchBreakEven++;

      LogTradeCsv(i, net[i], reason);
      RemoveEntry(i);
     }

   // ---- Flush once the batch is actually flat ----
   // Waiting for flat keeps one CSV row per batch even when a close needed
   // several attempts, instead of fragmenting it into one row per attempt.
   // Every caller re-checks its trigger each tick, so a stalled close simply
   // retries until it lands; CheckEntryCleanup() flushes as BATCH_FLAT if the
   // positions go away by some other route first.
   int remaining = ArraySize(g_entries);
   if(remaining > 0)
     {
      PrintFormat("AjipSnD: %s close incomplete — %d position(s) still open, "
                  "batch flush deferred", reason, remaining);
      return;
     }

   if(g_batchCount > 0)
     {
      FlushBatchCSV(reason);
      ResetBatchAccumulator();
      g_lastBatchEndTime = TimeCurrent();
     }
  }

//---- Batch profit-close trigger in account currency ----
// With InpBatchMaxProfitAtr > 0 the target scales with the HTF ATR frozen at
// batch start AND the batch's current open volume, so a batch running more
// size needs a proportionally bigger move to close, and the target keeps its
// meaning whether XAUUSD is calm or volatile. A fixed dollar cap does
// neither: a live backtest comparison found BATCH_TARGET realizing ~$20 on
// average in every run regardless of regime or how many positions were in
// the batch — a hard cap always lands near itself, which is exactly why it
// discards whatever excursion advantage a larger or better-timed batch
// accumulated. ATR is taken at batch start rather than live, matching how
// InpPartialCloseAtr freezes ATR at position entry.
double BatchProfitThreshold()
  {
   if(InpBatchMaxProfitAtr <= 0 || g_batchAtrAtStart <= 0)
      return(InpBatchMaxProfit);

   double totalVolume = 0.0;
   for(int i = 0; i < ArraySize(g_entries); i++)
     {
      if(PositionSelectByTicket(g_entries[i].ticket))
         totalVolume += PositionGetDouble(POSITION_VOLUME);
     }
   if(totalVolume <= 0)
      return(InpBatchMaxProfit);

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0 || tickSize <= 0)
      return(InpBatchMaxProfit);

   return(InpBatchMaxProfitAtr * g_batchAtrAtStart * (tickValue / tickSize) * totalVolume);
  }

//==================================================================
// CHECK BATCH CLOSE-ALL — TARGET only (gated by news)
//==================================================================
void CheckBatchTargetCloseAll()
  {
   // The batch target is the old architecture's primary exit and would close
   // positions before their own take profit, at a threshold scaled by HTF ATR
   // — roughly 4.1x the LTF ATR the target is expressed in. Gated in code
   // rather than left to the preset, because a preset that forgot it would
   // still run and quietly measure the wrong thing.
   if(InpStructuralSlMode) return;

   if(InpBatchMaxProfit <= 0 && InpBatchMaxProfitAtr <= 0) return;
   double threshold = BatchProfitThreshold();
   if(threshold <= 0) return;

   double total = g_batchRealizedPnl + GetFloatingPnL();
   if(total >= threshold)
     {
      PrintFormat("AjipSnD: BATCH TARGET HIT (%.2f >= %.2f) — closing batch", total, threshold);
      CloseAllAndFlushBatch("BATCH_TARGET");
     }
  }

//==================================================================
// CHECK BATCH MAX LOSS — NEVER gated by news
//==================================================================
void CheckBatchMaxLossCloseAll()
  {
   if(InpBatchMaxLoss <= 0) return;
   double total = g_batchRealizedPnl + GetFloatingPnL();
   if(total <= -InpBatchMaxLoss)
     {
      PrintFormat("AjipSnD: BATCH MAX LOSS HIT (%.2f <= %.2f) — closing batch", total, -InpBatchMaxLoss);
      CloseAllAndFlushBatch("BATCH_MAX_LOSS");
     }
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
      CloseAllAndFlushBatch("DAILY_TARGET");
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
      CloseAllAndFlushBatch("DAILY_MAX_LOSS");
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
      CloseAllAndFlushBatch("SESSION_END");
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
      CloseAllAndFlushBatch("FINAL_TARGET");
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
      CloseAllAndFlushBatch("FINAL_MAX_LOSS");
     }
  }

//==================================================================
// RECALCULATE AGGREGATE SL — safety net, broker-side.
// Budget = tightest active max loss, applied to ALL positions in a
// direction as a single pool (not split per-position). Same slPoints
// for every position in the direction — mirrors AjipIDM.
//==================================================================
void RecalculateAggregateSL()
  {
   // Find smallest active max loss
   double budget = 0.0;
   if(InpBatchMaxLoss > 0)
      budget = (budget == 0) ? InpBatchMaxLoss : MathMin(budget, InpBatchMaxLoss);
   if(InpDailyMaxLoss > 0)
      budget = (budget == 0) ? InpDailyMaxLoss : MathMin(budget, InpDailyMaxLoss);
   if(InpFinalMaxLoss > 0)
      budget = (budget == 0) ? InpFinalMaxLoss : MathMin(budget, InpFinalMaxLoss);

   if(budget <= 0) return;

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0 || tickSize <= 0) return;

   double valuePerPointPerLot = (tickValue / tickSize) * g_point;
   if(valuePerPointPerLot <= 0) return;

   int n = ArraySize(g_entries);

   // Apply per direction — each direction gets the FULL budget independently
   for(int dir = -1; dir <= 1; dir += 2)
     {
      if(dir == 0) continue;

      // Sum total volume + weighted entry sum (same filter)
      double totalVolume = 0.0;
      double weightedSum = 0.0;
      for(int i = 0; i < n; i++)
        {
         if(g_entries[i].dir != dir) continue;
         if(!PositionSelectByTicket(g_entries[i].ticket)) continue;
         // A structural stop is the position's own risk statement — the pooled
         // budget must neither move it nor count its volume, or the shared
         // slPoints figure would be computed against size it does not govern.
         if(g_entries[i].hasStructuralSl) continue;
         // Skip if already has a protective SL (partialClosed + SL != 0 = safe)
         if(g_entries[i].partialClosed && PositionGetDouble(POSITION_SL) != 0.0) continue;
         double vol = PositionGetDouble(POSITION_VOLUME);
         totalVolume += vol;
         weightedSum += PositionGetDouble(POSITION_PRICE_OPEN) * vol;
        }

      if(totalVolume <= 0.0) continue;
      double avgEntry = weightedSum / totalVolume;

      // Same slPoints for ALL positions in this direction
      double slPoints = budget / (totalVolume * valuePerPointPerLot);
      if(slPoints <= 0.0) continue;

      // Same SL price for ALL positions in this direction
      double commonSl = (dir == 1)
                        ? NormalizeDouble(avgEntry - slPoints * g_point, g_digits)
                        : NormalizeDouble(avgEntry + slPoints * g_point, g_digits);

      for(int i = 0; i < n; i++)
        {
         if(g_entries[i].dir != dir) continue;
         if(!PositionSelectByTicket(g_entries[i].ticket)) continue;
         if(g_entries[i].hasStructuralSl) continue;   // same reason as the sum above
         if(g_entries[i].partialClosed && PositionGetDouble(POSITION_SL) != 0.0) continue;

         double curSl = PositionGetDouble(POSITION_SL);
         // Skip if already within 0.5 point of common SL
         if(MathAbs(curSl - commonSl) < g_point * 0.5) continue;

         double curTp = PositionGetDouble(POSITION_TP);

         if(trade.PositionModify(g_entries[i].ticket, commonSl, curTp))
            PrintFormat("AjipSnD: Aggregate SL set ticket=%I64u SL=%.5f (budget=%.2f totalVol=%.2f)",
                        g_entries[i].ticket, commonSl, budget, totalVolume);
         else
            PrintFormat("AjipSnD: Aggregate SL FAILED ticket=%I64u retcode=%d SL=%.5f",
                        g_entries[i].ticket, trade.ResultRetcode(), commonSl);
        }
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
