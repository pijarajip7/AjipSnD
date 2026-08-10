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
void AddEntry(ulong ticket, int dir, double entryPrice)
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

   // First entry of batch
   if(!g_batchActive)
     {
      g_batchActive = true;
      g_batchFirstEntryTime = TimeCurrent();
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
// ACCUMULATE BATCH STATS — fold closed position into batch
//==================================================================
void AccumulateBatchStats(int idx)
  {
   if(idx < 0 || idx >= ArraySize(g_entries)) return;

   // Get realized PnL from history
   double realized = 0.0;
   if(HistorySelect(g_entries[idx].entryTime, TimeCurrent() + 1))
     {
      int ndeals = HistoryDealsTotal();
      for(int i = 0; i < ndeals; i++)
        {
         ulong dticket = HistoryDealGetTicket(i);
         if(dticket == 0) continue;
         long dmagic = HistoryDealGetInteger(dticket, DEAL_MAGIC);
         if(dmagic != InpMagicNumber) continue;
         
         // Get the position ID this deal belongs to
         ulong dposition = HistoryDealGetInteger(dticket, DEAL_POSITION_ID);
         if(dposition != g_entries[idx].ticket) continue;

         realized += HistoryDealGetDouble(dticket, DEAL_PROFIT)
                   + HistoryDealGetDouble(dticket, DEAL_SWAP)
                   + HistoryDealGetDouble(dticket, DEAL_COMMISSION);
        }
     }

   g_batchCount++;
   g_batchRealizedPnl += realized;
   g_batchMfeSum += g_entries[idx].mfe;
   g_batchMaeSum += g_entries[idx].mae;

   if(realized > 0)       g_batchWins++;
   else if(realized < 0)  g_batchLosses++;
   else                   g_batchBreakEven++;
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
         AccumulateBatchStats(i);
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
void CheckPartialClose()
  {
   if(InpPartialCloseProfit <= 0 || InpPartialClosePercent <= 0) return;

   for(int i = ArraySize(g_entries) - 1; i >= 0; i--)
     {
      if(g_entries[i].partialClosed) continue;

      if(!PositionSelectByTicket(g_entries[i].ticket))
        {
         AccumulateBatchStats(i);
         RemoveEntry(i);
         continue;
        }

      double posProfit = PositionGetDouble(POSITION_PROFIT);
      if(posProfit < InpPartialCloseProfit) continue;

      double posVolume = PositionGetDouble(POSITION_VOLUME);
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

      PrintFormat("AjipSnD: Partial close ticket=%I64u, closedVol=%.2f, profit=%.2f",
                  ticket, closeVol, posProfit);

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

   int handle = FileOpen(filename, FILE_COMMON | FILE_WRITE | FILE_READ | FILE_TXT, 0, CP_UTF8);
   if(handle == INVALID_HANDLE)
     {
      PrintFormat("AjipSnD: Cannot open batch CSV %s", filename);
      return;
     }

   // Write header if new file
   if(!exists)
     {
      FileSeek(handle, 0, SEEK_END);
      FileWrite(handle, "CloseTime,CloseReason,PositionCount,Wins,Losses,BreakEven,TotalRealizedPnL,SumMFE,SumMAE,FirstEntryTime,LastEntryTime");
     }
   else
     {
      FileSeek(handle, 0, SEEK_END);
     }

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
  }

//==================================================================
// CLOSE ALL AND FLUSH BATCH (atomic)
//==================================================================
void CloseAllAndFlushBatch(string reason)
  {
   CloseAllPositions();

   // Accumulate + remove entries that were actually closed
   for(int i = ArraySize(g_entries) - 1; i >= 0; i--)
     {
      if(!PositionSelectByTicket(g_entries[i].ticket))
        {
         AccumulateBatchStats(i);
         RemoveEntry(i);
        }
     }

   // Flush only if all tracked entries are gone
   if(ArraySize(g_entries) == 0)
     {
      FlushBatchCSV(reason);
      ResetBatchAccumulator();
      g_lastBatchEndTime = TimeCurrent();
     }
  }

//==================================================================
// CHECK BATCH CLOSE-ALL — TARGET only (gated by news)
//==================================================================
void CheckBatchTargetCloseAll()
  {
   if(InpBatchMaxProfit <= 0) return;
   double total = g_batchRealizedPnl + GetFloatingPnL();
   if(total >= InpBatchMaxProfit)
     {
      PrintFormat("AjipSnD: BATCH TARGET HIT (%.2f >= %.2f) — closing batch", total, InpBatchMaxProfit);
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

      // Sum total volume for this direction (skip already-protected positions)
      double totalVolume = 0.0;
      for(int i = 0; i < n; i++)
        {
         if(g_entries[i].dir != dir) continue;
         if(!PositionSelectByTicket(g_entries[i].ticket)) continue;
         // Skip if already has a protective SL (partialClosed + SL != 0 = safe)
         if(g_entries[i].partialClosed && PositionGetDouble(POSITION_SL) != 0.0) continue;
         totalVolume += PositionGetDouble(POSITION_VOLUME);
        }

      if(totalVolume <= 0.0) continue;

      // Same slPoints for ALL positions in this direction
      double slPoints = budget / (totalVolume * valuePerPointPerLot);
      if(slPoints <= 0.0) continue;

      for(int i = 0; i < n; i++)
        {
         if(g_entries[i].dir != dir) continue;
         if(!PositionSelectByTicket(g_entries[i].ticket)) continue;
         if(g_entries[i].partialClosed && PositionGetDouble(POSITION_SL) != 0.0) continue;

         double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
         if(entryPrice <= 0.0) continue;

         double newSl = (dir == 1)
                        ? NormalizeDouble(entryPrice - slPoints * g_point, g_digits)
                        : NormalizeDouble(entryPrice + slPoints * g_point, g_digits);

         double curSl = PositionGetDouble(POSITION_SL);
         // Skip if already within 0.5 point
         if(MathAbs(curSl - newSl) < g_point * 0.5) continue;

         double curTp = PositionGetDouble(POSITION_TP);

         if(trade.PositionModify(g_entries[i].ticket, newSl, curTp))
            PrintFormat("AjipSnD: Aggregate SL set ticket=%I64u SL=%.5f (budget=%.2f totalVol=%.2f)",
                        g_entries[i].ticket, newSl, budget, totalVolume);
         else
            PrintFormat("AjipSnD: Aggregate SL FAILED ticket=%I64u retcode=%d SL=%.5f",
                        g_entries[i].ticket, trade.ResultRetcode(), newSl);
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
