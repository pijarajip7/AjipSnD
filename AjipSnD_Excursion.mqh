//+------------------------------------------------------------------+
//|                                            AjipSnD_Excursion.mqh |
//|            First-touch grid logger — offline (SL x TP) evaluation |
//+------------------------------------------------------------------+
#property strict

//==================================================================
// WHY THIS EXISTS
//==================================================================
// Max-excursion data (MFE/MAE) can prove a level was reached but not WHEN, so
// it cannot say which of two levels came first. That is exactly the question a
// stop-and-target pair asks, and it left the run #4 analysis unable to decide
// whether a wider target helps: at a symmetric 2.0 ATR bracket the true win
// rate was bounded only to [32%, 61%], with breakeven at 50%.
//
// Stamping the FIRST-TOUCH TIME of a grid of levels removes the ambiguity.
// For any (SL, TP) pair on the grid the outcome is decided by comparing two
// stamps, so one backtest run yields the entire expectancy surface exactly —
// including target distances the EA never traded, which no amount of
// re-reading the trade log can recover.
//
// The tracker is deliberately DECOUPLED from order execution: it arms on a
// validated zone whether or not an order was placed, and keeps recording after
// any real position closed. That matters because the position cap and the exit
// policy both change which entries exist, and a surface computed only over
// filled trades would silently re-introduce the very coupling it is meant to
// remove. Blocking reasons are recorded per row so the traded subset can still
// be isolated offline.

#define EXC_LEVELS 13

// Level grid in LTF ATR, ascending. Dense where the current target sits
// (0.25-1.5) so the region under test is well resolved, sparse further out
// where a target is only plausible, not likely.
const double ExcLevelAtr[EXC_LEVELS] =
  {0.25, 0.50, 0.75, 1.00, 1.25, 1.50, 2.00, 2.50, 3.00, 4.00, 5.00, 6.00, 8.00};

struct ExcursionRecord
  {
   bool     triggered;      // limit level was touched; the excursion clock runs
   int      dir;            // 1=BUY, -1=SELL
   double   limitPrice;     // level the real-or-hypothetical limit order sits at
   datetime armTime;        // zone validated, limit armed
   datetime triggerTime;    // limit touched — t0 for every stamp below
   double   atrLtf;         // LTF ATR at arm — the unit the level grid is in
   double   atrHtf;         // HTF ATR at arm
   datetime ltfZoneTime;    // join key to the zone CSV and the trade CSV
   datetime htfZoneTime;    // HTF zone being retested
   double   slAnchor;       // structural SL price the EA would use (0 = n/a)
   bool     filled;         // a real order actually filled at this level
   bool     blockedGap;     // zone gap gate rejected the real order
   bool     blockedGate;    // aggregate entry gate rejected it
   bool     blockedCap;     // position/pending cap alone would have rejected it
   double   maxFavAtr;      // continuous supplement to the grid
   double   maxAdvAtr;
   int      favNext;        // lowest grid index not yet reached, favorable side
   int      advNext;        // ... adverse side
   int      favSec[EXC_LEVELS]; // seconds from trigger to first touch (-1 = never)
   int      advSec[EXC_LEVELS];
   int      sessionEndSec;  // seconds from trigger until InSession() first fails
  };

ExcursionRecord g_excursion[];

//==================================================================
// ARM — a validated LTF zone now has a limit level worth watching
//==================================================================
// Called before the entry gates, so blocked setups are still observed. The
// caller passes what it already computed rather than recomputing here, which
// keeps the observed level identical to the one the EA would have traded.
void ExcursionArm(int dir, double limitPrice, datetime ltfZoneTime,
                  datetime htfZoneTime, double slAnchor,
                  bool blockedGap, bool blockedGate, bool blockedCap)
  {
   if(!InpExcursionLog) return;

   double atrLtf = GetAtrValue(false);
   if(atrLtf <= 0) return;          // no unit for the grid — nothing to record

   int sz = ArraySize(g_excursion);
   ArrayResize(g_excursion, sz + 1);

   g_excursion[sz].triggered   = false;
   g_excursion[sz].dir         = dir;
   g_excursion[sz].limitPrice  = limitPrice;
   g_excursion[sz].armTime     = TimeCurrent();
   g_excursion[sz].triggerTime = 0;
   g_excursion[sz].atrLtf      = atrLtf;
   g_excursion[sz].atrHtf      = GetAtrValue(true);
   g_excursion[sz].ltfZoneTime = ltfZoneTime;
   g_excursion[sz].htfZoneTime = htfZoneTime;
   g_excursion[sz].slAnchor    = slAnchor;
   g_excursion[sz].filled      = false;
   g_excursion[sz].blockedGap  = blockedGap;
   g_excursion[sz].blockedGate = blockedGate;
   g_excursion[sz].blockedCap  = blockedCap;
   g_excursion[sz].maxFavAtr   = 0.0;
   g_excursion[sz].maxAdvAtr   = 0.0;
   g_excursion[sz].favNext     = 0;
   g_excursion[sz].advNext     = 0;
   g_excursion[sz].sessionEndSec = -1;

   for(int k = 0; k < EXC_LEVELS; k++)
     {
      g_excursion[sz].favSec[k] = -1;
      g_excursion[sz].advSec[k] = -1;
     }
  }

//---- Mark that a real order filled at this level (join back from the fill) ----
void ExcursionMarkFilled(int dir, datetime ltfZoneTime)
  {
   if(!InpExcursionLog) return;
   for(int i = ArraySize(g_excursion) - 1; i >= 0; i--)
     {
      if(g_excursion[i].dir != dir) continue;
      if(g_excursion[i].ltfZoneTime != ltfZoneTime) continue;
      g_excursion[i].filled = true;
      return;
     }
  }

//==================================================================
// CSV — one row per opportunity
//==================================================================
void ExcursionCsvWrite(int i)
  {
   string filename = "AjipSnD_Excursion_" + _Symbol + "_"
                   + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + ".csv";
   bool exists = FileIsExist(filename, FILE_COMMON);

   int h = FileOpen(filename,
                    FILE_COMMON | FILE_WRITE | FILE_READ | FILE_CSV | FILE_ANSI,
                    ',', CP_UTF8);
   if(h == INVALID_HANDLE)
     {
      PrintFormat("AjipSnD: Cannot open excursion CSV %s", filename);
      return;
     }

   if(!exists)
      FileWrite(h,
                "arm_time", "trigger_time", "triggered", "dir", "limit_price",
                "atr_ltf", "atr_htf", "ltf_zone_time", "htf_zone_time",
                "sl_anchor_price", "sl_anchor_atr",
                "filled", "blocked_gap", "blocked_gate", "blocked_cap",
                "session_end_sec", "max_fav_atr", "max_adv_atr",
                "f025", "f050", "f075", "f100", "f125", "f150", "f200",
                "f250", "f300", "f400", "f500", "f600", "f800",
                "a025", "a050", "a075", "a100", "a125", "a150", "a200",
                "a250", "a300", "a400", "a500", "a600", "a800");
   else
      FileSeek(h, 0, SEEK_END);

   // Stop distance in ATR, so the structural anchor can be compared against the
   // grid without re-deriving it from prices offline.
   double slAtr = 0.0;
   if(g_excursion[i].slAnchor > 0.0 && g_excursion[i].atrLtf > 0)
     {
      double d = (g_excursion[i].dir == 1)
                 ? (g_excursion[i].limitPrice - g_excursion[i].slAnchor)
                 : (g_excursion[i].slAnchor - g_excursion[i].limitPrice);
      slAtr = d / g_excursion[i].atrLtf;
     }

   FileWrite(h,
             TimeToString(g_excursion[i].armTime, TIME_DATE | TIME_SECONDS),
             g_excursion[i].triggered
                ? TimeToString(g_excursion[i].triggerTime, TIME_DATE | TIME_SECONDS)
                : "",
             g_excursion[i].triggered ? "1" : "0",
             g_excursion[i].dir == 1 ? "BUY" : "SELL",
             DoubleToString(g_excursion[i].limitPrice, g_digits),
             DoubleToString(g_excursion[i].atrLtf, 3),
             DoubleToString(g_excursion[i].atrHtf, 3),
             TimeToString(g_excursion[i].ltfZoneTime, TIME_DATE | TIME_SECONDS),
             TimeToString(g_excursion[i].htfZoneTime, TIME_DATE | TIME_SECONDS),
             DoubleToString(g_excursion[i].slAnchor, g_digits),
             DoubleToString(slAtr, 3),
             g_excursion[i].filled      ? "1" : "0",
             g_excursion[i].blockedGap  ? "1" : "0",
             g_excursion[i].blockedGate ? "1" : "0",
             g_excursion[i].blockedCap  ? "1" : "0",
             IntegerToString(g_excursion[i].sessionEndSec),
             DoubleToString(g_excursion[i].maxFavAtr, 3),
             DoubleToString(g_excursion[i].maxAdvAtr, 3),
             IntegerToString(g_excursion[i].favSec[0]),
             IntegerToString(g_excursion[i].favSec[1]),
             IntegerToString(g_excursion[i].favSec[2]),
             IntegerToString(g_excursion[i].favSec[3]),
             IntegerToString(g_excursion[i].favSec[4]),
             IntegerToString(g_excursion[i].favSec[5]),
             IntegerToString(g_excursion[i].favSec[6]),
             IntegerToString(g_excursion[i].favSec[7]),
             IntegerToString(g_excursion[i].favSec[8]),
             IntegerToString(g_excursion[i].favSec[9]),
             IntegerToString(g_excursion[i].favSec[10]),
             IntegerToString(g_excursion[i].favSec[11]),
             IntegerToString(g_excursion[i].favSec[12]),
             IntegerToString(g_excursion[i].advSec[0]),
             IntegerToString(g_excursion[i].advSec[1]),
             IntegerToString(g_excursion[i].advSec[2]),
             IntegerToString(g_excursion[i].advSec[3]),
             IntegerToString(g_excursion[i].advSec[4]),
             IntegerToString(g_excursion[i].advSec[5]),
             IntegerToString(g_excursion[i].advSec[6]),
             IntegerToString(g_excursion[i].advSec[7]),
             IntegerToString(g_excursion[i].advSec[8]),
             IntegerToString(g_excursion[i].advSec[9]),
             IntegerToString(g_excursion[i].advSec[10]),
             IntegerToString(g_excursion[i].advSec[11]),
             IntegerToString(g_excursion[i].advSec[12]));

   FileClose(h);
  }

//==================================================================
// UPDATE — called every tick
//==================================================================
// Trigger and excursion are read off the side of the book the corresponding
// order would actually act on: a BUY LIMIT fills on Ask, and its stop and
// target both trigger on Bid. Measuring the grid on that same side is what
// makes an offline (SL x TP) resolution match a real fill rather than
// approximate it.
void UpdateExcursions()
  {
   if(!InpExcursionLog) return;
   int n = ArraySize(g_excursion);
   if(n == 0) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid <= 0 || ask <= 0) return;

   datetime now       = TimeCurrent();
   int      armLimit  = InpExcursionArmBars * 60;
   int      horizon   = InpExcursionBars * 60;
   bool     inSession = InSession();

   for(int i = n - 1; i >= 0; i--)
     {
      if(!g_excursion[i].triggered)
        {
         // A BUY LIMIT fills when Ask falls to it; a SELL LIMIT when Bid rises.
         bool hit = (g_excursion[i].dir == 1)
                    ? (ask <= g_excursion[i].limitPrice)
                    : (bid >= g_excursion[i].limitPrice);
         if(hit)
           {
            g_excursion[i].triggered   = true;
            g_excursion[i].triggerTime = now;
            continue;                      // start the clock on the next tick
           }
         if((int)(now - g_excursion[i].armTime) >= armLimit)
           {
            ExcursionCsvWrite(i);           // never filled — the row records that
            ArrayRemove(g_excursion, i, 1);
           }
         continue;
        }

      int elapsed = (int)(now - g_excursion[i].triggerTime);

      if(!inSession && g_excursion[i].sessionEndSec < 0)
         g_excursion[i].sessionEndSec = elapsed;

      double px  = (g_excursion[i].dir == 1) ? bid : ask;
      double fav = (g_excursion[i].dir == 1)
                   ? (px - g_excursion[i].limitPrice)
                   : (g_excursion[i].limitPrice - px);
      double favAtr = fav / g_excursion[i].atrLtf;
      double advAtr = -favAtr;             // one price, so exactly one side is positive

      if(favAtr > g_excursion[i].maxFavAtr) g_excursion[i].maxFavAtr = favAtr;
      if(advAtr > g_excursion[i].maxAdvAtr) g_excursion[i].maxAdvAtr = advAtr;

      while(g_excursion[i].favNext < EXC_LEVELS
            && favAtr >= ExcLevelAtr[g_excursion[i].favNext])
        {
         g_excursion[i].favSec[g_excursion[i].favNext] = elapsed;
         g_excursion[i].favNext++;
        }
      while(g_excursion[i].advNext < EXC_LEVELS
            && advAtr >= ExcLevelAtr[g_excursion[i].advNext])
        {
         g_excursion[i].advSec[g_excursion[i].advNext] = elapsed;
         g_excursion[i].advNext++;
        }

      if(elapsed >= horizon)
        {
         ExcursionCsvWrite(i);
         ArrayRemove(g_excursion, i, 1);
        }
     }
  }

//---- Flush whatever is still open on deinit, so the tail is not lost ----
void FlushExcursions()
  {
   if(!InpExcursionLog) return;
   for(int i = ArraySize(g_excursion) - 1; i >= 0; i--)
      ExcursionCsvWrite(i);
   ArrayResize(g_excursion, 0);
  }
//+------------------------------------------------------------------+
