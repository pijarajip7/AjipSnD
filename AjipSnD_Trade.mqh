#ifndef AJIPSND_TRADE_MQH
#define AJIPSND_TRADE_MQH

//==================================================================
// ADD ENTRY to tracking
//==================================================================
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
   g_entries[sz].atrAtEntry   = GetAtrValue(true);

   g_entries[sz].initialVolume   = PositionSelectByTicket(ticket)
                                   ? PositionGetDouble(POSITION_VOLUME)
                                   : po.lot;
   g_entries[sz].atrLtfAtEntry   = po.atrLtf;
   g_entries[sz].triggerReason   = po.triggerReason;
   g_entries[sz].tpBeArmed           = false;
   g_entries[sz].partialClosed       = false;
   g_entries[sz].partialCloseSkipped = false;
  }

//==================================================================
// REMOVE ENTRY from tracking
//==================================================================
void RemoveEntry(int idx)
  {
   // Both call sites (CheckEntryCleanup, CloseAllAndUntrack) only reach
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
// GET FLOATING PNL BY DIRECTION — same as above, restricted to one
// direction. Used by CheckDirectionUnrealizedTarget for the per-direction
// profit target — deliberately the same POSITION_PROFIT-only accounting
// as GetFloatingPnL (no swap), not ComputeRealizedPnl's fuller one, since
// this is read every tick against still-open positions.
//==================================================================
double GetFloatingPnLByDirection(int dir)
  {
   double total = 0.0;
   for(int i = ArraySize(g_entries) - 1; i >= 0; i--)
     {
      if(g_entries[i].dir != dir) continue;
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
// POINTS-BASED EXIT MANAGEMENT — no SL/TP exists at placement (fixed lot,
// no stop distance to size or anchor either one against — see
// AjipSnD_PendingEntry.mqh), so everything below is what actually closes a
// position: either this EA modifying the broker-side SL/TP itself, or the
// account-level daily/final max-loss close-all as a last resort. There is
// no per-position protective stop until one of CheckLossRecoveryTp or
// CheckPartialClose sets one.
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

//---- Adverse-side safety net: once floating loss reaches InpLossPointsSetTpBe,
// rest a TP at breakeven so the position closes there the instant (if ever)
// price recovers, instead of needing to run all the way to a full profit
// target after having already been this far underwater. Does not cap the
// loss itself — there is no SL here, only a TP the position may never reach.
// One-shot (tpBeArmed); skipped entirely once partialClosed, since the
// remainder's SL is already at or better than breakeven by then (see
// CheckPartialClose) — a TP resting exactly at breakeven at that point
// would only ever fire on the way back DOWN through it, undercutting
// whatever the trailing stop has already locked in above breakeven.
//==================================================================
void CheckLossRecoveryTp(int idx)
  {
   if(InpLossPointsSetTpBe <= 0) return;
   if(g_entries[idx].tpBeArmed || g_entries[idx].partialClosed) return;

   ulong ticket = g_entries[idx].ticket;
   if(!PositionSelectByTicket(ticket)) return;

   int    dir        = g_entries[idx].dir;
   double entryPrice = g_entries[idx].entryPrice;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;
   double curPrice = (dir == 1) ? tick.bid : tick.ask;   // side the position actually closes on

   double lossPoints = (dir == 1)
                       ? (entryPrice - curPrice) / g_point
                       : (curPrice - entryPrice) / g_point;
   if(lossPoints < InpLossPointsSetTpBe) return;

   double bePrice = (dir == 1)
                    ? entryPrice + InpBreakEvenOffsetPoints * g_point
                    : entryPrice - InpBreakEvenOffsetPoints * g_point;
   bePrice = NormalizeDouble(bePrice, g_digits);

   double curSl = PositionGetDouble(POSITION_SL);
   if(!trade.PositionModify(ticket, curSl, bePrice))
     {
      PrintFormat("AjipSnD: TP->BE FAILED ticket=%I64u be=%.5f retcode=%d", ticket, bePrice, trade.ResultRetcode());
      return;   // retry next tick
     }

   g_entries[idx].tpBeArmed = true;
   PrintFormat("AjipSnD: TP->BE armed ticket=%I64u (loss %.1f pts >= %.1f) -> TP %.5f",
               ticket, lossPoints, InpLossPointsSetTpBe, bePrice);
  }

//---- Favourable-side: once floating profit reaches InpPartialClosePoints,
// close a slice and move the remainder's SL to breakeven. One-shot:
// partialClosed gates it from firing twice, partialCloseSkipped gates a
// slice that can never be brokered. ----
void CheckPartialClose(int idx)
  {
   if(g_entries[idx].partialClosed || g_entries[idx].partialCloseSkipped) return;

   int    dir        = g_entries[idx].dir;
   double entryPrice = g_entries[idx].entryPrice;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;
   double exitPrice = (dir == 1) ? tick.bid : tick.ask;   // side the position actually closes on

   double profitPoints = (dir == 1)
                         ? (exitPrice - entryPrice) / g_point
                         : (entryPrice - exitPrice) / g_point;
   if(profitPoints < InpPartialClosePoints) return;

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
   PrintFormat("AjipSnD: Partial close ticket=%I64u — closed %.2f lot @ profit>=%.1f pts (price=%.5f)",
               ticket, closeVol, InpPartialClosePoints, exitPrice);

   if(!PositionSelectByTicket(ticket)) return;   // broker closed it outright despite the split — nothing left to move to BE

   double bePrice = (dir == 1)
                    ? entryPrice + InpBreakEvenOffsetPoints * g_point
                    : entryPrice - InpBreakEvenOffsetPoints * g_point;
   bePrice = NormalizeDouble(bePrice, g_digits);

   double curTp = PositionGetDouble(POSITION_TP);
   if(!trade.PositionModify(ticket, bePrice, curTp))
      PrintFormat("AjipSnD: SL->BE FAILED ticket=%I64u be=%.5f retcode=%d", ticket, bePrice, trade.ResultRetcode());
   else
      PrintFormat("AjipSnD: SL->BE ticket=%I64u -> %.5f", ticket, bePrice);
  }

//==================================================================
// TRAILING STOP — only for positions that already partial-closed (the
// "runner" half of the position). Tightens toward price in HTF-ATR steps and
// only ever tightens; InpTrailingStepAtr throttles how often it actually
// touches the broker so a trending market doesn't call PositionModify on
// every single tick for a fractional-point improvement.
//==================================================================
void UpdateTrailingStop(int idx)
  {
   ulong ticket = g_entries[idx].ticket;
   if(!PositionSelectByTicket(ticket)) return;

   int    dir      = g_entries[idx].dir;
   double atrHtf    = GetAtrValue(true);
   double trailDist = InpTrailingStopAtr * atrHtf;
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

   double step = InpTrailingStepAtr * atrHtf;
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
// DISPATCH — one pass over open entries: loss-recovery TP, then partial-close,
// then trailing for whichever already partial-closed. Called every tick, same
// as UpdateMfeMae, since every trigger here is a live price level, not a
// bar-close event.
//==================================================================
void ManagePartialCloseAndTrailing()
  {
   if(InpLossPointsSetTpBe <= 0 && !InpPartialCloseEnabled && !InpTrailingStopEnabled) return;

   for(int i = ArraySize(g_entries) - 1; i >= 0; i--)
     {
      if(!PositionSelectByTicket(g_entries[i].ticket)) continue;

      CheckLossRecoveryTp(i);

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
         // Broker-side exits (SL, TP) land here, and the closing deal has
         // settled by now, so ComputeRealizedPnl's deal-history fallback is
         // reliable if the live position lookup already came up empty.
         double realized = ComputeRealizedPnl(i);
         WriteHandoffSignal("TRADE_CLOSED", realized);
         RemoveEntry(i);
        }
     }
  }

//==================================================================
// CLOSE ALL POSITIONS (this symbol + magic). dirFilter=0 (default) closes
// every direction, unchanged from before; dirFilter=1/-1 restricts to
// BUY/SELL only — used by the direction-wide profit target below.
//==================================================================
void CloseAllPositions(int dirFilter = 0)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      if(dirFilter != 0)
        {
         int posDir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
         if(posDir != dirFilter) continue;
        }

      if(!trade.PositionClose(ticket))
         PrintFormat("AjipSnD: Close %I64u failed retcode=%d", ticket, trade.ResultRetcode());
     }
  }

//==================================================================
// CLOSE ALL TRACKED POSITIONS, untracking each once it's actually gone.
// dirFilter=0 (default) is the original every-direction close-all every
// existing caller still uses unchanged; dirFilter=1/-1 scopes the whole
// operation to just that direction, leaving the other direction's
// positions (and g_entries rows) completely untouched.
//==================================================================
void CloseAllAndUntrack(string reason, int dirFilter = 0)
  {
   CloseAllPositions(dirFilter);

   // ---- Untrack ONLY what actually closed ----
   // A close can be rejected — market closed over a holiday, trade context
   // busy — and the position then survives the call. Untracking it anyway
   // would lose the link to a position that's still actually open; the next
   // tick finds the same trigger still true and retries.
   for(int i = ArraySize(g_entries) - 1; i >= 0; i--)
     {
      if(dirFilter != 0 && g_entries[i].dir != dirFilter) continue;   // wasn't in scope, wasn't touched — leave tracked

      if(PositionSelectByTicket(g_entries[i].ticket))
         continue;                      // still open — retry on the next tick

      RemoveEntry(i);
     }

   int remaining = 0;
   for(int i = 0; i < ArraySize(g_entries); i++)
      if(dirFilter == 0 || g_entries[i].dir == dirFilter) remaining++;
   if(remaining > 0)
      PrintFormat("AjipSnD: %s close incomplete — %d position(s) still open, retrying", reason, remaining);
  }

//==================================================================
// CHECK DIRECTION-WIDE UNREALIZED PROFIT TARGET (gated by news, same
// convention as the account-level profit targets below). Independent per
// direction and independent of the points-based per-position exit —
// this can fire and close a whole direction's basket regardless of
// whether any individual leg has partial-closed or armed TP->BE yet.
// Also cancels every resting pending order in that direction: leaving one
// alive would just reopen exposure on the same side right after the
// group closed for a win, likely at a bigger martingale lot than what
// just closed.
//==================================================================
void CheckDirectionUnrealizedTarget()
  {
   if(InpDirectionUnrealizedTarget <= 0) return;

   for(int d = 1; d >= -1; d -= 2)   // 1 = BUY, -1 = SELL
     {
      double floating = GetFloatingPnLByDirection(d);
      if(floating < InpDirectionUnrealizedTarget) continue;

      string reason = (d == 1) ? "BUY_DIRECTION_TARGET" : "SELL_DIRECTION_TARGET";
      PrintFormat("AjipSnD: %s DIRECTION TARGET HIT (%.2f >= %.2f) — closing all %s + cancelling its pending orders",
                  d == 1 ? "BUY" : "SELL", floating, InpDirectionUnrealizedTarget, d == 1 ? "BUY" : "SELL");
      WriteHandoffSignal(reason, floating);
      CloseAllAndUntrack(reason, d);
      CancelPendingOrdersForDirection(d);
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
      CloseAllAndUntrack("DAILY_TARGET");
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
      CloseAllAndUntrack("DAILY_MAX_LOSS");
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
      CloseAllAndUntrack("FINAL_TARGET");
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
      CloseAllAndUntrack("FINAL_MAX_LOSS");
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
