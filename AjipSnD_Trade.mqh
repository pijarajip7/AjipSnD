#ifndef AJIPSND_TRADE_MQH
#define AJIPSND_TRADE_MQH

//==================================================================
// OPEN MARKET WITH STRUCTURAL STOPS — the EA's only entry path.
// Fills immediately at the current market price rather than resting at a
// limit: the trigger bar (rejection, or first touch under
// InpAggressiveEntry) has already closed by the time this is called, so
// there is no edge left to wait at — price is already moving off the zone.
//
// slPrice is the caller's stop, anchored to the trigger bar's own extreme;
// TP is derived here from the SAME price this order actually transacts at,
// so the realised reward:risk is enforced against the real fill rather than
// an independent figure.
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

   string comment = StringFormat("AjipSnD %s %s", dir == 1 ? "BUY" : "SELL",
                                 InpAggressiveEntry ? "AGGR" : "REJECT");
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

   EntryFillInfo po;
   ZeroMemory(po);
   po.ticket   = ticket;
   po.dir      = dir;
   po.price    = fillPrice;
   po.zoneTime = zoneTime;
   po.slPrice  = slPrice;
   po.tpPrice  = tpPrice;
   po.lot      = lot;
   po.riskUsd  = actualRisk;
   po.atrLtf   = GetAtrValue();
   AddEntry(ticket, dir, fillPrice, po);

   return(ticket);
  }

//==================================================================
// ADD ENTRY to tracking
//==================================================================
// The EntryFillInfo is passed through so the position inherits what the
// order already knew — its structural stop, the risk it was sized for, and
// the LTF zone that triggered it. Without that hand-off the link between a
// trade and its originating zone is lost at the moment of the fill, and the
// per-trade CSV has nothing to join back to the zone log on.
void AddEntry(ulong ticket, int dir, double entryPrice, const EntryFillInfo &po)
  {
   int sz = ArraySize(g_entries);
   ArrayResize(g_entries, sz + 1);
   g_entries[sz].ticket       = ticket;
   g_entries[sz].dir          = dir;
   g_entries[sz].entryPrice   = entryPrice;
   g_entries[sz].entryTime    = TimeCurrent();
   g_entries[sz].mfe          = 0.0;
   g_entries[sz].mae          = 0.0;

   g_entries[sz].initialVolume   = PositionSelectByTicket(ticket)
                                   ? PositionGetDouble(POSITION_VOLUME)
                                   : po.lot;
   g_entries[sz].hasStructuralSl = (po.slPrice > 0.0);
   g_entries[sz].slPrice         = po.slPrice;
   g_entries[sz].tpPrice         = po.tpPrice;
   g_entries[sz].riskUsd         = po.riskUsd;
   g_entries[sz].atrLtfAtEntry   = po.atrLtf;
   g_entries[sz].zoneTime        = po.zoneTime;
   g_entries[sz].partialClosed       = false;
   g_entries[sz].partialCloseSkipped = false;
  }

//==================================================================
// REMOVE ENTRY from tracking
//==================================================================
void RemoveEntry(int idx)
  {
   // Both call sites (CheckEntryCleanup, CloseAllAndLogTrades) only reach
   // here after confirming the position is actually gone, so this is the
   // one place that always sees a trade end — arm the cooldown gate here.
   g_lastTradeCloseTime = TimeCurrent();
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
// the risk budget, and the budget is the whole point. Returns 0.0 — meaning
// "do not trade this setup" — whenever risk cannot actually be sized
// (InpRiskPerTrade=0, no stop distance, or broker tick data unavailable).
// Callers must treat 0.0 as a skip, not as a lot.
//
// The broker's minimum lot puts a hard floor under achievable risk. When the
// computed lot lands under it the position can only be opened by risking more
// than the budget, so InpMaxRiskOvershoot decides: accept the floor while the
// overshoot stays within tolerance, otherwise return 0 and let the caller skip
// the entry. Either way the real figure comes back through actualRisk, so the
// overshoot is logged rather than hidden.
double LotForRisk(double slDistance, double &actualRisk)
  {
   actualRisk = 0.0;

   if(InpRiskPerTrade <= 0 || slDistance <= 0) return(0.0);

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0 || tickSize <= 0) return(0.0);

   double lossPerLot = slDistance * (tickValue / tickSize);
   if(lossPerLot <= 0) return(0.0);

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
// PARTIAL CLOSE — once floating profit reaches InpPartialCloseRR times the
// ORIGINAL stop distance (same price-distance RR convention OpenMarketWith-
// StructuralStops uses for InpTakeProfitRR), close a slice and move the
// remainder's SL to breakeven. One-shot: partialClosed gates it from firing
// twice, partialCloseSkipped gates a slice that can never be brokered.
//==================================================================

//---- Volume to carve off, respecting the broker's step/minimum. 0.0 means
// the requested percentage can't produce a valid split for this position —
// either the slice itself, or what it would leave behind, rounds under
// g_volMin — and the caller must treat that as "not workable," not "close
// nothing."
double PartialCloseVolume(double currentVol)
  {
   double vol = currentVol * (InpPartialClosePercent / 100.0);
   if(g_volStep > 0)
      vol = MathFloor(vol / g_volStep) * g_volStep;
   vol = NormalizeDouble(vol, 8);
   if(vol < g_volMin) return(0.0);

   double remainder = NormalizeDouble(currentVol - vol, 8);
   if(remainder < g_volMin) return(0.0);   // would leave no valid runner (or close everything)

   return(vol);
  }

//---- Check one entry against its RR trigger; close the slice + SL->BE ----
void CheckPartialClose(int idx)
  {
   if(g_entries[idx].partialClosed || g_entries[idx].partialCloseSkipped) return;
   if(!g_entries[idx].hasStructuralSl || g_entries[idx].slPrice <= 0.0) return;

   int    dir    = g_entries[idx].dir;
   double slDist = MathAbs(g_entries[idx].entryPrice - g_entries[idx].slPrice);
   if(slDist <= 0.0) return;

   double trigger = (dir == 1)
                    ? g_entries[idx].entryPrice + InpPartialCloseRR * slDist
                    : g_entries[idx].entryPrice - InpPartialCloseRR * slDist;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;
   double exitPrice = (dir == 1) ? tick.bid : tick.ask;   // side the position actually closes on
   bool   reached   = (dir == 1) ? (exitPrice >= trigger) : (exitPrice <= trigger);
   if(!reached) return;

   double currentVol = PositionGetDouble(POSITION_VOLUME);
   double closeVol    = PartialCloseVolume(currentVol);
   if(closeVol <= 0.0)
     {
      g_entries[idx].partialCloseSkipped = true;
      PrintFormat("AjipSnD: Partial close SKIPPED ticket=%I64u — %.0f%% of %.2f lot (step=%.2f min=%.2f) leaves no workable split",
                  g_entries[idx].ticket, InpPartialClosePercent, currentVol, g_volStep, g_volMin);
      return;
     }

   ulong ticket = g_entries[idx].ticket;
   if(!trade.PositionClosePartial(ticket, closeVol))
     {
      PrintFormat("AjipSnD: Partial close FAILED ticket=%I64u vol=%.2f retcode=%d",
                  ticket, closeVol, trade.ResultRetcode());
      return;   // retry next tick
     }

   g_entries[idx].partialClosed = true;
   PrintFormat("AjipSnD: Partial close ticket=%I64u — closed %.2f lot @ RR>=%.1f (price=%.5f)",
               ticket, closeVol, InpPartialCloseRR, exitPrice);

   if(!PositionSelectByTicket(ticket)) return;   // broker closed it outright despite the split — nothing left to move to BE

   double bePrice = (dir == 1)
                    ? g_entries[idx].entryPrice + InpBreakEvenOffsetPoints * g_point
                    : g_entries[idx].entryPrice - InpBreakEvenOffsetPoints * g_point;
   bePrice = NormalizeDouble(bePrice, g_digits);

   double curTp = PositionGetDouble(POSITION_TP);
   if(!trade.PositionModify(ticket, bePrice, curTp))
      PrintFormat("AjipSnD: SL->BE FAILED ticket=%I64u be=%.5f retcode=%d", ticket, bePrice, trade.ResultRetcode());
   else
      PrintFormat("AjipSnD: SL->BE ticket=%I64u -> %.5f", ticket, bePrice);
  }

//==================================================================
// TRAILING STOP — only for positions that already partial-closed (the
// "runner" half of the position). Tightens toward price in LTF-ATR steps and
// only ever tightens; InpTrailingStepAtr throttles how often it actually
// touches the broker so a trending market doesn't call PositionModify on
// every single tick for a fractional-point improvement.
//==================================================================
void UpdateTrailingStop(int idx)
  {
   ulong ticket = g_entries[idx].ticket;
   if(!PositionSelectByTicket(ticket)) return;

   int    dir      = g_entries[idx].dir;
   double atrLtf    = GetAtrValue();
   double trailDist = InpTrailingStopAtr * atrLtf;
   if(trailDist <= 0.0) return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;
   double price = (dir == 1) ? tick.bid : tick.ask;

   double newSl = (dir == 1)
                  ? NormalizeDouble(price - trailDist, g_digits)
                  : NormalizeDouble(price + trailDist, g_digits);

   double curSl = PositionGetDouble(POSITION_SL);
   bool improves = (curSl <= 0.0) || ((dir == 1) ? (newSl > curSl) : (newSl < curSl));
   if(!improves) return;

   double step = InpTrailingStepAtr * atrLtf;
   if(step > 0.0 && curSl > 0.0 && MathAbs(newSl - curSl) < step) return;   // too small a move yet

   long   stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist     = stopsLevel * g_point;
   double distFromPx  = (dir == 1) ? (price - newSl) : (newSl - price);
   if(stopsLevel > 0 && distFromPx < minDist) return;   // too close to price — wait for it to move further

   double curTp = PositionGetDouble(POSITION_TP);
   if(!trade.PositionModify(ticket, newSl, curTp))
     {
      PrintFormat("AjipSnD: Trailing SL FAILED ticket=%I64u newSl=%.5f retcode=%d", ticket, newSl, trade.ResultRetcode());
      return;
     }
   PrintFormat("AjipSnD: Trailing SL ticket=%I64u %.5f -> %.5f", ticket, curSl, newSl);
  }

//==================================================================
// DISPATCH — one pass over open entries: partial-close check, then trailing
// for whichever of them already partial-closed. Called every tick, same as
// UpdateMfeMae, since the RR trigger is a live price level, not a bar-close
// event.
//==================================================================
void ManagePartialCloseAndTrailing()
  {
   if(!InpPartialCloseEnabled && !InpTrailingStopEnabled) return;

   for(int i = ArraySize(g_entries) - 1; i >= 0; i--)
     {
      if(!PositionSelectByTicket(g_entries[i].ticket)) continue;

      if(InpPartialCloseEnabled)
         CheckPartialClose(i);

      if(InpTrailingStopEnabled && g_entries[i].partialClosed)
         UpdateTrailingStop(i);
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
                "atr_ltf", "structural", "ltf_zone_time");
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
             g_entries[idx].hasStructuralSl ? "1" : "0",
             TimeToString(g_entries[idx].zoneTime, TIME_DATE | TIME_SECONDS));

   FileClose(h);
  }

//==================================================================
// CHECK ENTRY CLEANUP — positions closed outside close-all (SL/TP hit).
// Each individual close here also fires the rotation handoff signal, so
// the orchestrator switches accounts after every trade, not just when a
// daily target/max-loss is hit.
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
         WriteHandoffSignal("TRADE_CLOSED", realized);
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
   // source for its profit. Index-aligned with g_entries; CloseAllPositions
   // below does not resize that array, so the indices stay valid through the
   // logging loop.
   double net[];
   ArrayResize(net, n);
   for(int i = 0; i < n; i++)
     {
      net[i] = 0.0;
      if(PositionSelectByTicket(g_entries[i].ticket))
         net[i] = PositionGetDouble(POSITION_PROFIT)
                + PositionGetDouble(POSITION_SWAP);  // commission is on the deal, not the position
     }

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
// WRITE HANDOFF SIGNAL — fired on every trade close (reason=TRADE_CLOSED,
// pnl=that trade's own P&L) so the orchestrator rotates accounts after
// each trade, and also when daily target/max-loss is hit
// (reason=DAILY_TARGET/DAILY_MAX_LOSS, pnl=daily total) — that account
// should sit out the rest of the day.
//==================================================================
void WriteHandoffSignal(const string reason, double pnl)
  {
   if(!InpHandoffEnabled) return;

   int handle = FileOpen(InpHandoffFile, FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON);
   if(handle == INVALID_HANDLE)
     {
      if(InpEnableLog) PrintFormat("AjipSnD: WriteHandoffSignal — failed to open %s, error=%d", InpHandoffFile, GetLastError());
      return;
     }

   string line = StringFormat("login=%d\nreason=%s\npnl=%.2f\nsymbol=%s\nmagic=%d\ntime=%s\n",
                               (int)AccountInfoInteger(ACCOUNT_LOGIN), reason, pnl, _Symbol, InpMagicNumber,
                               TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS));
   FileWriteString(handle, line);
   FileClose(handle);

   if(InpEnableLog) PrintFormat("AjipSnD: Handoff signal written — login=%d reason=%s pnl=%.2f file=%s",
               (int)AccountInfoInteger(ACCOUNT_LOGIN), reason, pnl, InpHandoffFile);
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
