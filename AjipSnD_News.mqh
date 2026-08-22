#ifndef AJIPSND_NEWS_MQH
#define AJIPSND_NEWS_MQH

//==================================================================
// NEWS BLACKOUT — blocks new entries AND profit-taking close actions
// (target-hitting close-alls) around high-impact economic calendar
// events matching this symbol's base/profit currency.
//
// Kill-switch max-loss branches (FinalMaxLoss, WeeklyMaxLoss) are
// DELIBERATELY never gated — those protect the account and are needed
// most exactly when volatility (news spike) is highest.
//
// Result cached for NEWS_CACHE_SECONDS to avoid recomputing every tick.
//==================================================================
bool InNewsBlackout()
  {
   if(!InpNewsFilterEnabled) return(false);

   const int       NEWS_CACHE_SECONDS = 15;
   static datetime lastCheck  = 0;
   static bool     cached     = false;
   static bool     wasBlocked = false;

   datetime now = TimeCurrent();
   if(lastCheck != 0 && now - lastCheck < NEWS_CACHE_SECONDS)
      return(cached);
   lastCheck = now;

   string baseCcy   = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_BASE);
   string profitCcy = SymbolInfoString(_Symbol, SYMBOL_CURRENCY_PROFIT);

   datetime from = now - InpNewsMinutesAfter  * 60;
   datetime to   = now + InpNewsMinutesBefore * 60;

   bool   blocked      = false;
   string blockedEvent = "";

   MqlCalendarValue values[];
   if(CalendarValueHistory(values, from, to, "", ""))
     {
      int n = ArraySize(values);
      for(int i = 0; i < n; i++)
        {
         MqlCalendarEvent evt;
         if(!CalendarEventById(values[i].event_id, evt)) continue;
         if(evt.importance < InpNewsMinImportance) continue;

         MqlCalendarCountry country;
         if(!CalendarCountryById(evt.country_id, country)) continue;
         if(country.currency != baseCcy && country.currency != profitCcy) continue;

         blocked      = true;
         blockedEvent = StringFormat("%s (%s) @ %s", evt.name, country.currency,
                                      TimeToString(values[i].time, TIME_DATE | TIME_MINUTES));
         break;
        }
     }

   if(InpEnableLog)
     {
      if(blocked && !wasBlocked)
         PrintFormat("AjipSnD: News blackout started — %s", blockedEvent);
      else if(!blocked && wasBlocked)
         Print("AjipSnD: News blackout ended.");
     }

   wasBlocked = blocked;
   cached     = blocked;
   return(cached);
  }

#endif // AJIPSND_NEWS_MQH
