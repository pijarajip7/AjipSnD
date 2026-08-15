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

//---- Stop-entry ladder: the inversion under test ----------------------------
// The traded entry is a LIMIT at the zone's proximal edge, so it fills while
// price is moving INTO the zone — the fill is selected precisely for the moves
// that keep going. Run #4/#5 measured the cost of that: 91.6% of resting orders
// filled, 97.4% at the proximal edge, and the entry ran ~4pp below a driftless
// walk at every geometry, a leak of 100-200 points that spread cannot explain.
//
// A STOP at the SAME level inverts the selection: it fills only once price has
// come back UP through the edge (down through it, for supply). Same zone, same
// price, opposite direction of fill — which is the cleanest possible isolation
// of the fill mechanism, since nothing else about the setup changes.
//
// The offsets are how much proof is demanded before entering. 0.00 is the pure
// inversion; larger values buy stronger evidence with a worse price. Each is a
// separate record because the excursion origin moves with the entry, and an
// origin shift cannot be reconstructed from a different origin's stamps.
//
// The REJECT ladder below reuses this exact array, on purpose: STOP and REJECT
// are two different answers to "how much proof", tested at the SAME thresholds,
// so a comparison between them isolates the timing rule and nothing else.
#define EXC_STOP_OFFSETS 4
const double ExcStopOffsetAtr[EXC_STOP_OFFSETS] = {0.00, 0.25, 0.50, 1.00};

//---- Rejection-entry ladder: confirmation, not just level-crossing ----------
// STOP fires on the first TICK that crosses zoneEdge + offset, mid-bar, with no
// requirement on how price got there — a wick that stabs through and instantly
// reverses fires it exactly like a clean break would. That is a real gap: a
// trader waiting for a rejection candle would not take a fill that gets undone
// before the bar even closes.
//
// REJECT asks a different question at the same thresholds: did the LTF bar
// that just CLOSED settle beyond zoneEdge + offset? Priming is identical to
// STOP (price must have entered the zone first) and the offsets are the same
// four values, but the trigger only fires from a closed-bar check — see
// UpdateExcursionRejects(), called from UpdateLTF() — never from the tick loop.
// A single strong bar can prime and trigger together: if that bar's own wick
// entered the zone and its close already clears the threshold, that is exactly
// the pin-bar pattern a rejection trader is waiting for.
#define EXC_KIND_LIMIT  0
#define EXC_KIND_STOP   1
#define EXC_KIND_REJECT 2

struct ExcursionRecord
  {
   bool     triggered;      // entry level was reached; the excursion clock runs
   int      dir;            // 1=BUY, -1=SELL
   double   limitPrice;     // level the hypothetical order sits at
   double   fillPrice;      // price actually paid at trigger = excursion origin
   int      kind;           // EXC_KIND_LIMIT / _STOP / _REJECT
   bool     primed;         // STOP/REJECT only: price entered the zone, now live
   double   offsetAtr;      // STOP/REJECT only: proof demanded beyond the edge
   double   zoneEdge;       // STOP/REJECT only: proximal edge entered first
   datetime primeTime;      // STOP/REJECT only: when price first entered the zone
   datetime armTime;        // zone validated, record created
   datetime triggerTime;    // entry level reached — t0 for every stamp below
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
void ExcursionArmOne(int dir, double entryPrice, datetime ltfZoneTime,
                     datetime htfZoneTime, double slAnchor,
                     bool blockedGap, bool blockedGate, bool blockedCap,
                     int kind, double offsetAtr, double zoneEdge,
                     double atrLtf)
  {
   int sz = ArraySize(g_excursion);
   ArrayResize(g_excursion, sz + 1);

   g_excursion[sz].triggered   = false;
   g_excursion[sz].dir         = dir;
   g_excursion[sz].limitPrice  = entryPrice;
   g_excursion[sz].fillPrice   = entryPrice;   // replaced by the real fill at trigger
   g_excursion[sz].kind        = kind;
   g_excursion[sz].primed      = (kind == EXC_KIND_LIMIT);  // a limit is live immediately
   g_excursion[sz].offsetAtr   = offsetAtr;
   g_excursion[sz].zoneEdge    = zoneEdge;
   g_excursion[sz].primeTime   = 0;
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

//---- Arm the whole family for one zone: the traded limit + the stop ladder ----
// Every variant observes the SAME zone over the SAME window, so the comparison
// between them is free of any population difference. That is the entire point:
// run #5 could rank geometries but not entry mechanisms, because only one
// mechanism was ever observed.
void ExcursionArm(int dir, double limitPrice, datetime ltfZoneTime,
                  datetime htfZoneTime, double slAnchor,
                  bool blockedGap, bool blockedGate, bool blockedCap)
  {
   if(!InpExcursionLog) return;

   double atrLtf = GetAtrValue(false);
   if(atrLtf <= 0) return;          // no unit for the grid — nothing to record

   // The traded entry: a limit resting at the zone's proximal edge.
   ExcursionArmOne(dir, limitPrice, ltfZoneTime, htfZoneTime, slAnchor,
                   blockedGap, blockedGate, blockedCap,
                   EXC_KIND_LIMIT, 0.0, limitPrice, atrLtf);

   // The inversion: a stop at the same edge, plus progressively more proof.
   if(InpStopEntryProbe)
      for(int k = 0; k < EXC_STOP_OFFSETS; k++)
        {
         double off   = ExcStopOffsetAtr[k] * atrLtf;
         double entry = (dir == 1) ? (limitPrice + off) : (limitPrice - off);
         ExcursionArmOne(dir, NormalizeDouble(entry, g_digits),
                         ltfZoneTime, htfZoneTime, slAnchor,
                         blockedGap, blockedGate, blockedCap,
                         EXC_KIND_STOP, ExcStopOffsetAtr[k], limitPrice, atrLtf);
        }

   // The confirmation: same edge, same offsets, but the trigger only fires
   // from a closed LTF bar (UpdateExcursionRejects), never from this tick loop.
   if(InpRejectEntryProbe)
      for(int k = 0; k < EXC_STOP_OFFSETS; k++)
        {
         double off   = ExcStopOffsetAtr[k] * atrLtf;
         double entry = (dir == 1) ? (limitPrice + off) : (limitPrice - off);
         ExcursionArmOne(dir, NormalizeDouble(entry, g_digits),
                         ltfZoneTime, htfZoneTime, slAnchor,
                         blockedGap, blockedGate, blockedCap,
                         EXC_KIND_REJECT, ExcStopOffsetAtr[k], limitPrice, atrLtf);
        }
  }

//---- Mark that a real order filled at this level (join back from the fill) ----
// Only the limit record can be filled — the EA still trades limits, and the
// STOP/REJECT ladders are observation. Matching on kind keeps the flag honest.
void ExcursionMarkFilled(int dir, datetime ltfZoneTime)
  {
   if(!InpExcursionLog) return;
   for(int i = ArraySize(g_excursion) - 1; i >= 0; i--)
     {
      if(g_excursion[i].kind != EXC_KIND_LIMIT) continue;
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
                "fill_price", "slip_pts", "entry_kind", "offset_atr", "primed", "prime_time",
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
                 ? (g_excursion[i].fillPrice - g_excursion[i].slAnchor)
                 : (g_excursion[i].slAnchor - g_excursion[i].fillPrice);
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
             DoubleToString(g_excursion[i].fillPrice, g_digits),
             DoubleToString(g_excursion[i].triggered
                            ? (g_excursion[i].dir == 1
                               ? (g_excursion[i].fillPrice - g_excursion[i].limitPrice)
                               : (g_excursion[i].limitPrice - g_excursion[i].fillPrice)) / g_point
                            : 0.0, 1),
             g_excursion[i].kind == EXC_KIND_STOP   ? "STOP"   :
             g_excursion[i].kind == EXC_KIND_REJECT ? "REJECT" : "LIMIT",
             DoubleToString(g_excursion[i].offsetAtr, 2),
             g_excursion[i].primed ? "1" : "0",
             g_excursion[i].primed
                ? TimeToString(g_excursion[i].primeTime, TIME_DATE | TIME_SECONDS)
                : "",
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
         // A stop entry is only live once price has actually entered the zone.
         // Without this priming step a BUY STOP sitting at or below the current
         // ask would fire on the arming tick and measure nothing — it would be
         // a market order wearing a stop order's name.
         if(!g_excursion[i].primed)
           {
            bool entered = (g_excursion[i].dir == 1)
                           ? (ask <= g_excursion[i].zoneEdge)
                           : (bid >= g_excursion[i].zoneEdge);
            if(entered)
              {
               g_excursion[i].primed    = true;
               g_excursion[i].primeTime = now;
              }
            else if((int)(now - g_excursion[i].armTime) >= armLimit)
              {
               ExcursionCsvWrite(i);        // zone never revisited
               ArrayRemove(g_excursion, i, 1);
              }
            continue;
           }

         // REJECT never fires from ticks — only UpdateExcursionRejects(), on a
         // closed LTF bar, decides it. This loop still primes it and still
         // expires it, but the "did price cross the level" test below is a
         // STOP-only question — for REJECT the level alone was never the bar.
         if(g_excursion[i].kind != EXC_KIND_REJECT)
           {
            // A BUY LIMIT fills when Ask falls to it; a BUY STOP when Ask rises
            // to it. Same level, opposite direction of fill — the experiment.
            bool hit;
            if(g_excursion[i].kind == EXC_KIND_STOP)
               hit = (g_excursion[i].dir == 1)
                     ? (ask >= g_excursion[i].limitPrice)
                     : (bid <= g_excursion[i].limitPrice);
            else
               hit = (g_excursion[i].dir == 1)
                     ? (ask <= g_excursion[i].limitPrice)
                     : (bid >= g_excursion[i].limitPrice);

            if(hit)
              {
               g_excursion[i].triggered   = true;
               g_excursion[i].triggerTime = now;

               // The origin must be what the trade would actually pay, not the
               // level it was written at. A limit fills at its level or better,
               // so the level is right. A stop fills at its level or WORSE —
               // price has already jumped through it — and booking the jump as
               // free profit flatters every stop entry. Run #6 measured that
               // flattery at ~43 points: negligible against a 4 ATR stop, a
               // fifth of a 0.25 ATR one — exactly where the ladder looked best.
               g_excursion[i].fillPrice = (g_excursion[i].kind == EXC_KIND_STOP)
                                          ? ((g_excursion[i].dir == 1) ? ask : bid)
                                          : g_excursion[i].limitPrice;
               continue;                   // start the clock on the next tick
              }
           }

         // STOP/REJECT's own window runs from priming, not from arming: the
         // wait for price to revisit the zone is not evidence about the entry.
         datetime since = (g_excursion[i].kind != EXC_KIND_LIMIT)
                          ? g_excursion[i].primeTime : g_excursion[i].armTime;
         if((int)(now - since) >= armLimit)
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
                   ? (px - g_excursion[i].fillPrice)
                   : (g_excursion[i].fillPrice - px);
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

//==================================================================
// REJECT TRIGGER — called once per closed LTF bar, from UpdateLTF()
//==================================================================
// The one check that cannot run on ticks: did the bar that just closed settle
// beyond the confirmation threshold? A wick that stabs through offsetAtr and
// snaps back before the bar closes must NOT trigger this — that is precisely
// the failure mode a rejection trader is trying to avoid, and precisely what
// distinguishes this from the STOP ladder at the same thresholds.
//
// Priming (price must have entered the zone) is handled by the ordinary tick
// loop in UpdateExcursions() and is shared with STOP, so a record can arrive
// here already primed from earlier in the same bar's formation — including
// the bar that primed it, which is the ordinary case for a clean pin bar.
void UpdateExcursionRejects(const MqlRates &bar)
  {
   if(!InpExcursionLog || !InpRejectEntryProbe) return;
   int n = ArraySize(g_excursion);
   if(n == 0) return;

   datetime now = TimeCurrent();

   for(int i = n - 1; i >= 0; i--)
     {
      if(g_excursion[i].kind != EXC_KIND_REJECT) continue;
      if(g_excursion[i].triggered) continue;
      if(!g_excursion[i].primed) continue;      // tick loop primes; not yet touched

      bool confirmed = (g_excursion[i].dir == 1)
                       ? (bar.close >= g_excursion[i].limitPrice)
                       : (bar.close <= g_excursion[i].limitPrice);
      if(!confirmed) continue;

      g_excursion[i].triggered   = true;
      g_excursion[i].triggerTime = now;
      g_excursion[i].fillPrice   = bar.close;
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
