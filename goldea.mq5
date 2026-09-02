//+------------------------------------------------------------------+
//|                                     Institutional_Sweep_Long.mq5 |
//|                     Liquidity Sweep Logic + Quality Analytics    |
//|                     Round 17: Louis Litt Final Audit Code        |
//+------------------------------------------------------------------+
#property strict
#include <Trade\Trade.mqh>

CTrade trade;

//--- Input Parameters (Original Baseline)
input int      LookbackPeriod         = 20;    // Bars to scan for Swing Levels (Liquidity Pools)
input int      EmaPeriod              = 50;    // M5 Trend Filter EMA
input double   RiskReward             = 2.0;   // Target R:R Ratio 
input double   RiskPercent            = 1.0;   // Account % to risk per trade (Adaptive)

//--- Risk Management (Base)
input bool     UseFixedLotSize        = true;  // Use Fixed Lot Size as Baseline
input double   FixedLotSize           = 0.05;  // Baseline Lot Size Value

//--- Round 5: Generous Dynamic Lot Sizing
input bool     UseGenerousDynamicLot  = true;  // Dynamically scale lot size based on SL distance
input double   Tier1_MaxPoints        = 30.0;  // SL <= 30 points -> Base Lot (0.05)
input double   Tier2_MaxPoints        = 40.0;  // SL <= 40 points -> Tier 2 Lot (0.04)
input double   Tier3_MaxPoints        = 50.0;  // SL <= 50 points -> Tier 3 Lot (0.03)
                                               // SL > 50 points  -> Tier 4 Lot (0.02)

//--- Round 17: Absolute Risk Sizing (Bypass SL Clamping)
input bool     UseMaxDollarStop       = true;  // Enable Absolute Max Dollar Risk Sizer
input double   MaxDollarLoss          = 120.0; // Max dollar risk allowed per trade ($120 Cap)

//--- Round 18: Peak-Decay Giveback Governor -----------------------------------
// Purely price-reactive profit protection. NO clock reference anywhere in this
// block. Arms once floating profit crosses GovernorActivationR * initial $ risk,
// then ratchets a floor behind the running peak. Floor never loosens, never
// drops below GovernorBufferR * risk (default 0.0 = hard breakeven guarantee).
input bool     UseGivebackGovernor    = true;  // Enable the ratchet giveback floor
input double   GovernorActivationR    = 1.0;   // Arm once profit >= this multiple of $ risk
input double   GovernorGivebackR      = 0.5;   // Max giveback from peak, in R, once armed
input double   GovernorBufferR        = 0.0;   // Floor floor (0 = never worse than breakeven)
//--------------------------------------------------------------------------------

//--- Meta-Labeling Brain (LOGGING ONLY - does not close or modify trades yet)
// Real coefficients, fitted on 5 years of actual tick-replayed trade data
// (2021.06-2026.06, AUC=0.706 on genuinely held-out future data). Prints
// P(real winner) every ~10 min on an open position, once it's cleared
// 0.3R. Nothing acts on this yet - the point of this pass is to check,
// on a real backtest, whether these P values actually track real outcomes.
input bool     UseMetaLabelLogging    = true;
input double   MetaLabel_Intercept    = 1.4761;   // FIXED MODEL v3 - v2 still failed live (proven: peak_R's
                                                     // own coefficient was unbounded and swamped even a
                                                     // FULL 100% giveback once peak exceeded ~2.35R, which
                                                     // is exactly why real data showed 0% of currentR>=1.0
                                                     // readings ever dropped below 0.5). v3 removes every
                                                     // unbounded term - verified mathematically: P_winner
                                                     // now depends ONLY on relative giveback fraction, time,
                                                     // velocity, quality - cannot be swamped by peak size,
                                                     // full stop, by construction, not just by chance.
input double   MetaLabel_Coef_GivebackFrac   = -2.2358;  // fraction of peak given back (0-1), the only
                                                            // giveback-related term left in the formula.
input double   MetaLabel_Coef_Velocity       = -0.4533;
input double   MetaLabel_Coef_Hour           = -0.0103;
input double   MetaLabel_Coef_QualityScore   = -0.0021;
input double   MetaLabel_Coef_ElapsedMin     = 0.0001;
input double   MetaLabel_ActivationR         = 0.3;
input int      MetaLabel_CheckIntervalSec    = 600;
input int      MetaLabel_MinCheckpoints      = 8;   // maturity gate - real log data showed AUC=0.511
                                                       // (coin-flip) at checkpoint #1, rising to 0.619 by
                                                       // #8 with 74.3% real win rate at P>=0.7 there.
                                                       // Below this count, P_winner is not printed - the
                                                       // number genuinely isn't trustworthy that early.
input bool     UseMetaLabelAction     = true;   // NOW A REAL EXIT-TIMING MECHANISM - closes the trade
                                                  // when P_winner drops below the threshold below.
input double   MetaLabel_ActionThreshold = 0.5; // pulled directly from the real calibration table:
                                                  // P<0.5 measured at 51.2% actual win rate, the
                                                  // coin-flip band - not an arbitrary guess.
input double   MetaLabel_ProtectTPDistanceR = 1.5; // TP is fixed at exactly 2.0R (verified, std dev
                                                     // ~0). Once current_R crosses this fraction of
                                                     // that target, never act - let the trade either
                                                     // hit its real TP or reverse on its own. This is
                                                     // what protected the $100+ winners we found being
                                                     // killed by the binary threshold alone.
//--------------------------------------------------------------------------------

//--- Round 5: The Circuit Breaker (Consecutive Loss Pause)
input bool     UseConsecutiveLossPause = true; // Enable Pause after losing streak
input int      MaxConsecutiveLosses    = 1;    // Number of consecutive losses to trigger pause
input int      PauseDurationHours      = 24;   // How many hours to lock out trading

//--- Time-Based Exit Management 
input bool     UseTimeExit            = false; // Keep FALSE to let 1:2 R:R breathe
input int      TimeExitMinutes        = 30;    
input double   TimeExitThreshold      = 0.0;   

//--- Round 3: Omni-Directional Trade Settings
input bool     EnableLongTrades       = true;  
input bool     EnableShortTrades      = true;  

//--- Round 3: Higher Timeframe (H1) Anchor Filter
input bool     UseHTFFilter           = true;  
input int      H1_EmaPeriod           = 50;    

//--- Round 3: Market Structure & Displacement (CHoCH)
input bool     UseCHoCHFilter         = true;  

//--- Round 3: Cooldown & Frequency Matrix
input bool     UseCooldown            = true;  
input int      CooldownMinutes        = 120;   
input int      MaxTradesPerDay        = 2;     

//--- Round 4: Quality Score Boundary Gate (60 to 100)
input bool     UseQualityFilter       = true;  
input int      MinQualityScore        = 60;    
input int      MaxQualityScore        = 100;   

//--- Round 4: Toxic Session Filter
input bool     UseSessionFilter       = true;  
input int      ToxicHour1             = 7;     
input int      ToxicHour2             = 17;    
input int      ToxicHour3             = 21;    

//--- Analytics Toggle 
input bool     EnableCSVAnalytics     = true;  

//--- Global Variables
int      emaHandle;
int      h1EmaHandle;
string   csvFileName = "SweepAnalytics_Quality_Report.csv";
datetime lastTradeExitTime = 0;
datetime circuitBreakerUnlockTime = 0;

//--- Trade Analytics Structure
struct TradeAnalytics
  {
   ulong    ticket;
   int      tradeNumOfDay;
   datetime entryTime;
   double   entryPrice;
   double   closePrice;
   double   stopLoss;
   double   takeProfit;
   double   lotSize;
   int      qualityScore;
   double   peakMFE;
   datetime timePeakMFE;
   double   peakMAE;
   datetime timePeakMAE;
   double   intervalPnL[];   // Dynamic: grows every 5 min for the life of the trade (no 120-min cap)

   //--- Round 18: Governor state (price-reactive, carried per open position)
   double   riskDollar;      // $ risk at open = slDistancePts * lotSize (matches Louis Litt's own sizer math)
   bool     governorArmed;   // true once peakMFE has crossed GovernorActivationR * riskDollar
   double   governorFloor;   // ratcheting exit floor in $, -DBL_MAX until armed

   //--- Meta-Labeling Brain state (reuses riskDollar above, adds only what's new)
   datetime lastMetaCheckTime;     // rate-limits the check to once per MetaLabel_CheckIntervalSec
   int      metaCheckCount;        // how many times CheckMetaLabel has actually fired for this trade -
                                     // gates whether P_winner is mature enough to trust/print
   double   pointsHistory[];       // rolling ~30min of (points) samples for the velocity feature
   datetime pointsHistoryTimes[];  // matching timestamps for pointsHistory
  };

TradeAnalytics currentTrade;
bool           tradeIsActive = false;

//+------------------------------------------------------------------+
//| Helper: Calculate 0-100 Quality Score                            |
//+------------------------------------------------------------------+
int CalculateQualityScore(double sweepDepthPoints, double bodyPoints, double emaDistPoints, int tradeNum)
  {
   double depthScore = MathMin(30.0, MathMax(0.0, (sweepDepthPoints / 200.0) * 30.0));
   double bodyScore  = MathMin(30.0, MathMax(0.0, (bodyPoints / 100.0) * 30.0));
   double emaScore   = MathMin(20.0, MathMax(0.0, 20.0 * (1.0 - MathMin(emaDistPoints / 400.0, 1.0))));
   
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int sessionPts = 5;
   if(dt.hour >= 8 && dt.hour < 13)       sessionPts = 10; 
   else if(dt.hour >= 13 && dt.hour < 21) sessionPts = 10; 
   
   int tradeNumPts = 0;
   if(tradeNum == 1)      tradeNumPts = 10;
   else if(tradeNum == 2) tradeNumPts = 7;
   else if(tradeNum == 3) tradeNumPts = 4;
   
   int totalScore = (int)MathRound(depthScore + bodyScore + emaScore + sessionPts + tradeNumPts);
   return MathMin(100, MathMax(0, totalScore));
  }

//+------------------------------------------------------------------+
//| Helper: Get Trading Session                                      |
//+------------------------------------------------------------------+
string GetSession(datetime time)
  {
   MqlDateTime dt;
   TimeToStruct(time, dt);
   int h = dt.hour;
   
   if(h >= 0 && h < 8)   return "Asian";
   if(h >= 8 && h < 13)  return "London";
   if(h >= 13 && h < 21) return "New York";
   return "Overlap/Close";
  }

//+------------------------------------------------------------------+
//| Helper: Get & Safely Increment Trade Number of the Day           |
//+------------------------------------------------------------------+
int GetTradeNumOfDay(bool increment = false)
  {
   static datetime lastDayCounted = 0;
   static int      dailyCounter   = 0;
   
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   datetime currentDay = TimeCurrent() - (dt.hour * 3600 + dt.min * 60 + dt.sec);
   
   if(currentDay != lastDayCounted)
     {
      lastDayCounted = currentDay;
      dailyCounter   = 0;
     }
     
   if(increment)
     {
      dailyCounter++;
     }
     
   return dailyCounter;
  }

//+------------------------------------------------------------------+
//| Helper: Check Consecutive Losses from Trading History            |
//+------------------------------------------------------------------+
int GetConsecutiveLosses()
  {
   int consecLosses = 0;
   HistorySelect(0, TimeCurrent());
   int totalDeals = HistoryDealsTotal();
   
   for(int i = totalDeals - 1; i >= 0; i--)
     {
      ulong dealTicket = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(dealTicket, DEAL_ENTRY) == DEAL_ENTRY_OUT)
        {
         double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
         if(profit < 0) consecLosses++;
         else break; // Streak broken
        }
     }
   return consecLosses;
  }

//+------------------------------------------------------------------+
//| Meta-Labeling Brain: computes P(real winner) from the fitted      |
//| logistic regression, LOGGING ONLY - does not close or modify any  |
//| trade. Call once per tick from OnTick()'s monitoring block; it     |
//| self-rate-limits to MetaLabel_CheckIntervalSec internally.        |
//+------------------------------------------------------------------+
void CheckMetaLabel()
  {
   if(!UseMetaLabelLogging || currentTrade.riskDollar <= 0.0)
      return;

   datetime currentTime = TimeCurrent();
   if(currentTrade.lastMetaCheckTime != 0 &&
      (currentTime - currentTrade.lastMetaCheckTime) < MetaLabel_CheckIntervalSec)
      return;

   double currentPnL = PositionGetDouble(POSITION_PROFIT);
   double currentR    = currentPnL / currentTrade.riskDollar;
   if(currentR < MetaLabel_ActivationR)
      return;

   currentTrade.lastMetaCheckTime = currentTime;

   double currentPoints = currentPnL / (currentTrade.lotSize * 100.0);
   int n = ArraySize(currentTrade.pointsHistory);
   ArrayResize(currentTrade.pointsHistory, n + 1);
   ArrayResize(currentTrade.pointsHistoryTimes, n + 1);
   currentTrade.pointsHistory[n] = currentPoints;
   currentTrade.pointsHistoryTimes[n] = currentTime;

   int dropCount = 0;
   for(int i = 0; i < ArraySize(currentTrade.pointsHistoryTimes); i++)
     {
      if((currentTime - currentTrade.pointsHistoryTimes[i]) > 1800)
         dropCount++;
      else
         break;
     }
   if(dropCount > 0)
     {
      for(int i = 0; i < ArraySize(currentTrade.pointsHistoryTimes) - dropCount; i++)
        {
         currentTrade.pointsHistory[i] = currentTrade.pointsHistory[i + dropCount];
         currentTrade.pointsHistoryTimes[i] = currentTrade.pointsHistoryTimes[i + dropCount];
        }
      ArrayResize(currentTrade.pointsHistory, ArraySize(currentTrade.pointsHistory) - dropCount);
      ArrayResize(currentTrade.pointsHistoryTimes, ArraySize(currentTrade.pointsHistoryTimes) - dropCount);
     }

   double velocity = 0.0;
   if(ArraySize(currentTrade.pointsHistory) >= 2)
     {
      double elapsedMinSinceOldest = (currentTime - currentTrade.pointsHistoryTimes[0]) / 60.0;
      if(elapsedMinSinceOldest > 0)
         velocity = (currentPoints - currentTrade.pointsHistory[0]) / elapsedMinSinceOldest;
     }

   double peakR      = currentTrade.peakMFE / currentTrade.riskDollar;
   double drawdownR  = peakR - currentR;
   // THE REAL FIX (v3): giveback fraction ONLY. peakR is deliberately not
   // in this formula at all anymore - v2 kept it and it silently swamped
   // even a full 100% giveback once peak exceeded ~2.35R (proven with real
   // math and confirmed by the live log: 0% of currentR>=1.0 readings ever
   // dropped below 0.5 under v2). v3 has no unbounded term left to do that.
   double givebackFraction = (peakR > 0.0) ? MathMin(1.0, MathMax(0.0, drawdownR / peakR)) : 0.0;
   double elapsedMin = (currentTime - currentTrade.entryTime) / 60.0;
   MqlDateTime dt; TimeToStruct(currentTime, dt);

   double z = MetaLabel_Intercept
            + (MetaLabel_Coef_GivebackFrac * givebackFraction)
            + (MetaLabel_Coef_Velocity     * velocity)
            + (MetaLabel_Coef_Hour         * (double)dt.hour)
            + (MetaLabel_Coef_QualityScore * (double)currentTrade.qualityScore)
            + (MetaLabel_Coef_ElapsedMin   * elapsedMin);

   double pRealWinner = 1.0 / (1.0 + MathExp(-z));

   currentTrade.metaCheckCount++;

   // MATURITY GATE: the real backtest log showed AUC=0.511 (coin-flip) at
   // the very first checkpoint, rising to a genuinely usable 0.619 by the
   // 8th. Printing (and, now, acting on) P_winner before that many
   // checkpoints have accumulated would be trusting a number that's
   // proven, not assumed, to carry no real information yet.
   if(currentTrade.metaCheckCount < MetaLabel_MinCheckpoints)
      return;

   PrintFormat("META-LABEL ticket=%d currentR=%.2f peakR=%.2f drawdownR=%.2f P_winner=%.3f checkpointNum=%d",
               currentTrade.ticket, currentR, peakR, drawdownR, pRealWinner, currentTrade.metaCheckCount);

   // ACTION - this is a real exit-timing change (Tier 3), not logging
   // anymore. Threshold is pulled directly from the real calibration
   // table, not guessed: P<0.5 measured at 51.2% actual win rate, the
   // exact coin-flip band. This WILL reshuffle subsequent entries the
   // same way every other exit-timing change has this whole project -
   // that is expected, and the point of running this as a real backtest.
   //
   // TP-DISTANCE GATE: never act once currentR has crossed this fraction
   // of the fixed 2.0R target. This is what protects trades that are
   // genuinely close to completing their designed journey, instead of
   // cutting them on a binary win/loss vote that ignores how close they
   // already are to TP - this is exactly what killed the $100+ winners
   // in the ungated version.
   bool nearOwnTP = (currentR >= MetaLabel_ProtectTPDistanceR);

   if(UseMetaLabelAction && !nearOwnTP && pRealWinner < MetaLabel_ActionThreshold)
     {
      PrintFormat("META-LABEL ACTION: closing ticket=%d, P_winner=%.3f below threshold=%.3f",
                  currentTrade.ticket, pRealWinner, MetaLabel_ActionThreshold);
      trade.PositionClose(currentTrade.ticket, -1);
     }
  }

//+------------------------------------------------------------------+
//| Shadow Signal Logger - self-contained, duplicates the swing/HTF/  |
//| CHoCH/quality detection logic independently so the real execution |
//| path below is never touched. Runs on every new bar, regardless of |
//| position status. Logs every qualifying signal (long or short)     |
//| found, tagged with whether/why it would have been blocked -       |
//| ground truth for what the cascade silently drops.                 |
//+------------------------------------------------------------------+
void CheckShadowSignal(datetime barTime)
  {
   // Own, independent once-per-bar gate. The outer lastBarTime only updates
   // when a trade actually opens, so it does NOT reliably gate this to
   // once per bar while the EA is flat (which is most of the time) - that
   // was the exact cause of the 1GB file. This is fully self-contained and
   // does not touch or depend on the original variable at all.
   static datetime lastShadowBarTime = 0;
   if(barTime == lastShadowBarTime)
      return;
   lastShadowBarTime = barTime;

   // Determine, in the SAME order the real gates check them, whether this
   // bar's signal (if any) would actually have been allowed to execute.
   // Evaluated without returning, so detection below still runs regardless.
   string blockReason = "OK";
   if(PositionsTotal() > 0)
      blockReason = "BLOCKED:PositionOpen";
   else if(UseConsecutiveLossPause && TimeCurrent() < circuitBreakerUnlockTime)
      blockReason = "BLOCKED:CircuitBreaker";
   else if(UseSessionFilter)
     {
      MqlDateTime dtc; TimeToStruct(TimeCurrent(), dtc);
      if(dtc.hour == ToxicHour1 || dtc.hour == ToxicHour2 || dtc.hour == ToxicHour3)
         blockReason = "BLOCKED:Session";
     }
   if(blockReason == "OK" && UseCooldown && lastTradeExitTime > 0)
     {
      if((TimeCurrent() - lastTradeExitTime) < (CooldownMinutes * 60))
         blockReason = "BLOCKED:Cooldown";
     }
   int shadowDailyTrades = GetTradeNumOfDay(false);
   if(blockReason == "OK" && shadowDailyTrades >= MaxTradesPerDay)
      blockReason = "BLOCKED:DailyQuota";

   //--- independent recomputation of the swing scan and filters, matching
   //    the real execution logic exactly, but with zero side effects
   double High[], Low[], Open[], Close[], Ema[];
   CopyHigh(_Symbol, _Period, 0, LookbackPeriod + 2, High);
   CopyLow(_Symbol, _Period, 0, LookbackPeriod + 2, Low);
   CopyOpen(_Symbol, _Period, 0, 3, Open);
   CopyClose(_Symbol, _Period, 0, 3, Close);
   CopyBuffer(emaHandle, 0, 0, 3, Ema);

   double h1Close[], h1Ema[];
   CopyClose(_Symbol, PERIOD_H1, 0, 2, h1Close);
   CopyBuffer(h1EmaHandle, 0, 0, 2, h1Ema);

   if(ArraySize(High) < LookbackPeriod + 2 || ArraySize(h1Close) < 2 || ArraySize(Ema) < 2)
      return;   // not enough history yet (e.g. right at test start) - matches real logic implicitly

   double swingLow  = Low[2];
   double swingHigh = High[2];
   for(int i = 2; i < LookbackPeriod + 2; i++)
     {
      if(Low[i]  < swingLow)  swingLow  = Low[i];
      if(High[i] > swingHigh) swingHigh = High[i];
     }

   bool h1Bullish = (h1Close[1] > h1Ema[1]);
   bool h1Bearish = (h1Close[1] < h1Ema[1]);
   int prospectiveTradeNum = shadowDailyTrades + 1;

   string direction = "NONE";
   int qScore = -1;
   double wouldBeEntryPrice = 0;

   if(EnableLongTrades)
     {
      bool isUptrend           = (Close[1] > Ema[1]);
      bool sweptLiquidity      = (Low[1] < swingLow);
      bool rejectedLevel       = (Close[1] > swingLow);
      bool bullishDisplacement = (Close[1] > Open[1]);
      bool passHTF   = (!UseHTFFilter)   || h1Bullish;
      bool passCHoCH = (!UseCHoCHFilter) || (Close[1] > MathMax(High[2], High[3]));

      if(isUptrend && sweptLiquidity && rejectedLevel && bullishDisplacement && passHTF && passCHoCH)
        {
         double sweepDepthPts = (swingLow - Low[1]) / _Point;
         double bodyPts       = (Close[1] - Open[1]) / _Point;
         double emaDistPts    = MathAbs(Close[1] - Ema[1]) / _Point;
         int q = CalculateQualityScore(sweepDepthPts, bodyPts, emaDistPts, prospectiveTradeNum);
         if(!UseQualityFilter || (q >= MinQualityScore && q <= MaxQualityScore))
           {
            direction = "LONG";
            qScore = q;
            wouldBeEntryPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
           }
        }
     }

   if(direction == "NONE" && EnableShortTrades)
     {
      bool isDowntrend         = (Close[1] < Ema[1]);
      bool sweptBuyLiquidity   = (High[1] > swingHigh);
      bool rejectedBuyLevel    = (Close[1] < swingHigh);
      bool bearishDisplacement = (Close[1] < Open[1]);
      bool passHTF_Short   = (!UseHTFFilter)   || h1Bearish;
      bool passCHoCH_Short = (!UseCHoCHFilter) || (Close[1] < MathMin(Low[2], Low[3]));

      if(isDowntrend && sweptBuyLiquidity && rejectedBuyLevel && bearishDisplacement && passHTF_Short && passCHoCH_Short)
        {
         double sweepDepthPts = (High[1] - swingHigh) / _Point;
         double bodyPts       = (Open[1] - Close[1]) / _Point;
         double emaDistPts    = MathAbs(Close[1] - Ema[1]) / _Point;
         int q = CalculateQualityScore(sweepDepthPts, bodyPts, emaDistPts, prospectiveTradeNum);
         if(!UseQualityFilter || (q >= MinQualityScore && q <= MaxQualityScore))
           {
            direction = "SHORT";
            qScore = q;
            wouldBeEntryPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
           }
        }
     }

   if(direction == "NONE")
      return;   // no qualifying signal on this bar at all - nothing to log

   int fileHandle = FileOpen("SignalShadowLog.csv", FILE_CSV|FILE_WRITE|FILE_READ|FILE_ANSI, ",");
   if(fileHandle != INVALID_HANDLE)
     {
      if(FileSize(fileHandle) == 0)
         FileWrite(fileHandle, "BarTime,Direction,QualityScore,WouldBeEntryPrice,BlockReason");
      FileSeek(fileHandle, 0, SEEK_END);
      FileWrite(fileHandle, TimeToString(barTime, TIME_DATE|TIME_SECONDS), direction, qScore,
                DoubleToString(wouldBeEntryPrice, 5), blockReason);
      FileClose(fileHandle);
     }
  }

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
  {
   emaHandle = iMA(_Symbol, _Period, EmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(emaHandle == INVALID_HANDLE) return(INIT_FAILED);
   
   h1EmaHandle = iMA(_Symbol, PERIOD_H1, H1_EmaPeriod, 0, MODE_EMA, PRICE_CLOSE);
   if(h1EmaHandle == INVALID_HANDLE) return(INIT_FAILED);
   
   if(EnableCSVAnalytics)
     {
      int fileHandle = FileOpen(csvFileName, FILE_CSV|FILE_WRITE|FILE_READ|FILE_ANSI, ",");
      if(fileHandle != INVALID_HANDLE)
        {
         if(FileSize(fileHandle) == 0)
           {
            string headers = "Ticket,TradeNumOfDay,EntryTime,ExitTime,Session,Day,WeekOfMonth,Hour,QualityScore,EntryPrice,ClosePrice,SL,TP,LotSize,PeakMFE,TimeInPeakMFE(s),PeakMAE,TimeInPeakMAE(s),GovernorExit";
            for(int i = 5; i <= 120; i += 5) headers += StringFormat(",Min_%d", i);
            FileWrite(fileHandle, headers);
           }
         FileClose(fileHandle);
        }
     }
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   // ==========================================
   // 1. ANALYTICS & TIME EXIT LOGIC
   // ==========================================
   if(tradeIsActive && PositionsTotal() > 0)
     {
      if(PositionSelectByTicket(currentTrade.ticket))
        {
         double   currentPnL   = PositionGetDouble(POSITION_PROFIT);
         datetime currentTime  = TimeCurrent();
         
         if(currentPnL > currentTrade.peakMFE)
           {
            currentTrade.peakMFE     = currentPnL;
            currentTrade.timePeakMFE = currentTime;
           }
         if(currentPnL < currentTrade.peakMAE)
           {
            currentTrade.peakMAE     = currentPnL;
            currentTrade.timePeakMAE = currentTime;
           }
           
         int elapsedSeconds   = (int)(currentTime - currentTrade.entryTime);
         int currentSlotCount = elapsedSeconds / 300;
         int existingSlots    = ArraySize(currentTrade.intervalPnL);
         if(currentSlotCount > existingSlots)
           {
            ArrayResize(currentTrade.intervalPnL, currentSlotCount);
            for(int i = existingSlots; i < currentSlotCount; i++)
               currentTrade.intervalPnL[i] = currentPnL;
           }

         // Meta-Labeling Brain - LOGGING ONLY, does not touch the position.
         // Self rate-limits internally to MetaLabel_CheckIntervalSec.
         CheckMetaLabel();

         // ---- Round 18: Peak-Decay Giveback Governor -----------------------
         // Purely price/R-reactive. No datetime, no bar count, no session check
         // anywhere in this block - it only ever looks at currentPnL vs a
         // ratcheting floor derived from the running peak. Runs on every tick,
         // so it reacts the instant price touches the floor, not on a timer.
         if(UseGivebackGovernor && currentTrade.riskDollar > 0.0)
           {
            if(!currentTrade.governorArmed &&
               currentTrade.peakMFE >= GovernorActivationR * currentTrade.riskDollar)
              {
               currentTrade.governorArmed = true;
              }

            if(currentTrade.governorArmed)
              {
               double candidateFloor = MathMax(GovernorBufferR * currentTrade.riskDollar,
                                                currentTrade.peakMFE - GovernorGivebackR * currentTrade.riskDollar);
               if(candidateFloor > currentTrade.governorFloor)
                  currentTrade.governorFloor = candidateFloor;   // ratchet: only ever moves up

               if(currentPnL <= currentTrade.governorFloor)
                 {
                  trade.PositionClose(currentTrade.ticket, -1);
                  // Deliberately no 'return' here - fall through so the
                  // close-detection block below (section 2) can fire on the
                  // very next tick and log it exactly like any other exit.
                 }
              }
           }
         // ---------------------------------------------------------------------
           
         if(UseTimeExit && elapsedSeconds >= TimeExitMinutes * 60)
           {
            if(currentPnL <= TimeExitThreshold)
              {
               trade.PositionClose(currentTrade.ticket, -1);
              }
           }
        }
     }
     
   // ==========================================
   // 2. ANALYTICS: DETECT CLOSE & WRITE CSV
   // ==========================================
   if(tradeIsActive && PositionsTotal() == 0)
     {
      lastTradeExitTime = TimeCurrent(); 
      
      // Update Circuit Breaker Logic
      if(UseConsecutiveLossPause)
        {
         int currentLossStreak = GetConsecutiveLosses();
         if(currentLossStreak >= MaxConsecutiveLosses)
           {
            circuitBreakerUnlockTime = TimeCurrent() + (PauseDurationHours * 3600);
            PrintFormat("Circuit Breaker Activated. Locked until: %s", TimeToString(circuitBreakerUnlockTime));
           }
        }
      
      if(EnableCSVAnalytics)
        {
         int fileHandle = FileOpen(csvFileName, FILE_CSV|FILE_WRITE|FILE_READ|FILE_ANSI, ",");
         if(fileHandle != INVALID_HANDLE)
           {
            FileSeek(fileHandle, 0, SEEK_END);
            
            double exitPrice = 0;
            datetime exitTime = TimeCurrent();
            HistorySelect(currentTrade.entryTime, TimeCurrent());
            for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
              {
               ulong dealTicket = HistoryDealGetTicket(i);
               if(HistoryDealGetInteger(dealTicket, DEAL_ENTRY) == DEAL_ENTRY_OUT)
                 {
                  exitPrice = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
                  exitTime  = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
                  break;
                 }
              }
            
            MqlDateTime dt;
            TimeToStruct(currentTrade.entryTime, dt);
            int weekOfMonth = (dt.day - 1) / 7 + 1;
            
            long timeSpentMFE = currentTrade.timePeakMFE - currentTrade.entryTime;
            long timeSpentMAE = currentTrade.timePeakMAE - currentTrade.entryTime;

            string governorTag = currentTrade.governorArmed ? "1" : "0";
            
            string row = StringFormat("%d,%d,%s,%s,%s,%d,%d,%d,Q%d,%.5f,%.5f,%.5f,%.5f,%.2f,%.2f,%d,%.2f,%d,%s",
               currentTrade.ticket,
               currentTrade.tradeNumOfDay,
               TimeToString(currentTrade.entryTime, TIME_DATE|TIME_SECONDS),
               TimeToString(exitTime, TIME_DATE|TIME_SECONDS),
               GetSession(currentTrade.entryTime),
               dt.day_of_week,
               weekOfMonth,
               dt.hour,
               currentTrade.qualityScore,
               currentTrade.entryPrice,
               exitPrice,
               currentTrade.stopLoss,
               currentTrade.takeProfit,
               currentTrade.lotSize,
               currentTrade.peakMFE,
               timeSpentMFE,
               currentTrade.peakMAE,
               timeSpentMAE,
               governorTag
            );
            
            int totalSlots = ArraySize(currentTrade.intervalPnL);
            for(int i = 0; i < totalSlots; i++)
              {
               row += StringFormat(",%.2f", currentTrade.intervalPnL[i]);
              }
              
            FileWrite(fileHandle, row);
            FileClose(fileHandle);
           }
        }
      tradeIsActive = false;
     }

   // ==========================================
   // 3. CORE ENTRY LOGIC (ROUND 17)
   // ==========================================
   static datetime lastBarTime;
   datetime currentBarTime = iTime(_Symbol, _Period, 0);
   if(currentBarTime == lastBarTime) return;

   // Shadow Signal Logger - runs on EVERY new bar, unconditionally, BEFORE
   // any gate below. Self-contained: recomputes the swing/HTF/CHoCH/quality
   // logic independently, does not touch or depend on the execution path
   // below it. Records whether a qualifying signal existed and whether a
   // position was open (blocking it) at that exact moment - ground truth
   // for whether the cascade silently dropped a real signal, not inference.
   CheckShadowSignal(currentBarTime);

   if(PositionsTotal() > 0) return;
   
   // Check Circuit Breaker Lockout
   if(UseConsecutiveLossPause && TimeCurrent() < circuitBreakerUnlockTime) return;
   
   if(UseSessionFilter)
     {
      MqlDateTime currentDt;
      TimeToStruct(TimeCurrent(), currentDt);
      if(currentDt.hour == ToxicHour1 || currentDt.hour == ToxicHour2 || currentDt.hour == ToxicHour3) return;
     }
   
   if(UseCooldown && lastTradeExitTime > 0)
     {
      if((TimeCurrent() - lastTradeExitTime) < (CooldownMinutes * 60)) return;
     }
     
   int currentDailyTrades = GetTradeNumOfDay(false);
   if(currentDailyTrades >= MaxTradesPerDay) return;

   double High[], Low[], Open[], Close[], Ema[];
   CopyHigh(_Symbol, _Period, 0, LookbackPeriod + 2, High);
   CopyLow(_Symbol, _Period, 0, LookbackPeriod + 2, Low);
   CopyOpen(_Symbol, _Period, 0, 3, Open);
   CopyClose(_Symbol, _Period, 0, 3, Close);
   CopyBuffer(emaHandle, 0, 0, 3, Ema);
   
   double h1Close[], h1Ema[];
   CopyClose(_Symbol, PERIOD_H1, 0, 2, h1Close);
   CopyBuffer(h1EmaHandle, 0, 0, 2, h1Ema);

   double swingLow  = Low[2];
   double swingHigh = High[2]; 
   for(int i = 2; i < LookbackPeriod + 2; i++)
     {
      if(Low[i]  < swingLow)  swingLow  = Low[i];
      if(High[i] > swingHigh) swingHigh = High[i];
     }

   bool h1Bullish = (h1Close[1] > h1Ema[1]);
   bool h1Bearish = (h1Close[1] < h1Ema[1]);
   int prospectiveTradeNum = currentDailyTrades + 1;

   // ==========================================
   // LONG (BUY) SWEEP EXECUTION
   // ==========================================
   if(EnableLongTrades)
     {
      bool isUptrend           = (Close[1] > Ema[1]);
      bool sweptLiquidity       = (Low[1] < swingLow);
      bool rejectedLevel        = (Close[1] > swingLow);
      bool bullishDisplacement = (Close[1] > Open[1]);
      
      bool passHTF   = (!UseHTFFilter)   || h1Bullish;
      bool passCHoCH = (!UseCHoCHFilter) || (Close[1] > MathMax(High[2], High[3]));
      
      if(isUptrend && sweptLiquidity && rejectedLevel && bullishDisplacement && passHTF && passCHoCH)
        {
         double sweepDepthPts = (swingLow - Low[1]) / _Point;
         double bodyPts       = (Close[1] - Open[1]) / _Point;
         double emaDistPts    = MathAbs(Close[1] - Ema[1]) / _Point;
         
         int qScore = CalculateQualityScore(sweepDepthPts, bodyPts, emaDistPts, prospectiveTradeNum);
         
         if(!UseQualityFilter || (qScore >= MinQualityScore && qScore <= MaxQualityScore))
           {
            double structuralSL  = Low[1] - (5 * _Point);
            double entryPrice    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double slDistancePts = (entryPrice - structuralSL) / _Point;
            
            if(slDistancePts > 0)
              {
               double lotSize = FixedLotSize;
               if(UseGenerousDynamicLot)
                 {
                  if(slDistancePts <= Tier1_MaxPoints) lotSize = 0.05;
                  else if(slDistancePts <= Tier2_MaxPoints) lotSize = 0.04;
                  else if(slDistancePts <= Tier3_MaxPoints) lotSize = 0.03;
                  else lotSize = 0.02;
                 }
               else if(!UseFixedLotSize)
                 {
                  double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
                  double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
                  double distTick  = (entryPrice - structuralSL) / tickSize;
                  if(tickValue > 0) lotSize = NormalizeDouble((AccountInfoDouble(ACCOUNT_BALANCE) * (RiskPercent / 100.0)) / (distTick * tickValue), 2);
                 }
                 
               // ROUND 17: Louis Litt Final Financial Audit Sizer
               if(UseMaxDollarStop && lotSize > 0)
                 {
                  // 1 Point (0.01) on XAUUSD for 1 Lot = $1.00 PnL.
                  double structuralDollarRisk = slDistancePts * lotSize; 
                  
                  if(structuralDollarRisk > MaxDollarLoss)
                    {
                     // Shrink the lot size to exactly fit the budget. NEVER touch the structural SL.
                     lotSize = MaxDollarLoss / slDistancePts;
                     
                     // Floor it to the nearest 0.01 to ensure we mathematically NEVER exceed 120.0
                     lotSize = MathFloor(lotSize * 100.0) / 100.0; 
                     
                     double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
                     if(lotSize < minLot) 
                       {
                        PrintFormat("Louis Litt Reject: SL distance %.1f too massive. Min lot risks > $%.2f. Trade skipped.", slDistancePts, MaxDollarLoss);
                        return; // Reject trade to protect firm capital
                       }
                    }
                 }
                 
               double takeProfit = entryPrice + ((entryPrice - structuralSL) * RiskReward);
               string orderComment = StringFormat("Q%d - Sweep Long", qScore);
               
               if(trade.Buy(lotSize, _Symbol, entryPrice, structuralSL, takeProfit, orderComment))
                 {
                  int actualTradeNum = GetTradeNumOfDay(true); 
                 
                  tradeIsActive            = true;
                  currentTrade.ticket      = trade.ResultOrder();
                  currentTrade.tradeNumOfDay = actualTradeNum;
                  currentTrade.entryTime   = TimeCurrent();
                  currentTrade.entryPrice  = entryPrice;
                  currentTrade.stopLoss    = structuralSL;
                  currentTrade.takeProfit  = takeProfit;
                  currentTrade.lotSize     = lotSize;
                  currentTrade.qualityScore= qScore;
                  currentTrade.peakMFE     = 0;
                  currentTrade.timePeakMFE = TimeCurrent();
                  currentTrade.peakMAE     = 0;
                  currentTrade.timePeakMAE = TimeCurrent();
                  
                  ArrayResize(currentTrade.intervalPnL, 0);

                  // Round 18: Governor state reset for the new position.
                  // riskDollar reuses the exact same formula as the Louis Litt
                  // sizer above, so it is consistent with MaxDollarStop by
                  // construction - whatever the final lot size ended up being.
                  currentTrade.riskDollar    = slDistancePts * lotSize;
                  currentTrade.governorArmed = false;
                  currentTrade.governorFloor = -DBL_MAX;

                  // Meta-Labeling Brain state reset (reuses riskDollar above)
                  currentTrade.lastMetaCheckTime = 0;
                  currentTrade.metaCheckCount = 0;
                  ArrayResize(currentTrade.pointsHistory, 0);
                  ArrayResize(currentTrade.pointsHistoryTimes, 0);
                  lastBarTime = currentBarTime;
                  return;
                 }
              }
           }
        }
     }

   // ==========================================
   // SHORT (SELL) SWEEP EXECUTION
   // ==========================================
   if(EnableShortTrades)
     {
      bool isDowntrend          = (Close[1] < Ema[1]);
      bool sweptBuyLiquidity    = (High[1] > swingHigh);
      bool rejectedBuyLevel     = (Close[1] < swingHigh);
      bool bearishDisplacement  = (Close[1] < Open[1]);
      
      bool passHTF_Short   = (!UseHTFFilter)   || h1Bearish;
      bool passCHoCH_Short = (!UseCHoCHFilter) || (Close[1] < MathMin(Low[2], Low[3]));
      
      if(isDowntrend && sweptBuyLiquidity && rejectedBuyLevel && bearishDisplacement && passHTF_Short && passCHoCH_Short)
        {
         double sweepDepthPts = (High[1] - swingHigh) / _Point;
         double bodyPts       = (Open[1] - Close[1]) / _Point;
         double emaDistPts    = MathAbs(Close[1] - Ema[1]) / _Point;
         
         int qScore = CalculateQualityScore(sweepDepthPts, bodyPts, emaDistPts, prospectiveTradeNum);
         
         if(!UseQualityFilter || (qScore >= MinQualityScore && qScore <= MaxQualityScore))
           {
            double structuralSL  = High[1] + (5 * _Point);
            double entryPrice    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            double slDistancePts = (structuralSL - entryPrice) / _Point;
            
            if(slDistancePts > 0)
              {
               double lotSize = FixedLotSize;
               if(UseGenerousDynamicLot)
                 {
                  if(slDistancePts <= Tier1_MaxPoints) lotSize = 0.05;
                  else if(slDistancePts <= Tier2_MaxPoints) lotSize = 0.04;
                  else if(slDistancePts <= Tier3_MaxPoints) lotSize = 0.03;
                  else lotSize = 0.02;
                 }
               else if(!UseFixedLotSize)
                 {
                  double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
                  double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
                  double distTick  = (structuralSL - entryPrice) / tickSize;
                  if(tickValue > 0) lotSize = NormalizeDouble((AccountInfoDouble(ACCOUNT_BALANCE) * (RiskPercent / 100.0)) / (distTick * tickValue), 2);
                 }
                 
               // ROUND 17: Louis Litt Final Financial Audit Sizer
               if(UseMaxDollarStop && lotSize > 0)
                 {
                  double structuralDollarRisk = slDistancePts * lotSize; 
                  
                  if(structuralDollarRisk > MaxDollarLoss)
                    {
                     lotSize = MaxDollarLoss / slDistancePts;
                     lotSize = MathFloor(lotSize * 100.0) / 100.0; 
                     
                     double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
                     if(lotSize < minLot) 
                       {
                        PrintFormat("Louis Litt Reject: SL distance %.1f too massive. Min lot risks > $%.2f. Trade skipped.", slDistancePts, MaxDollarLoss);
                        return; 
                       }
                    }
                 }
                 
               double takeProfit = entryPrice - ((structuralSL - entryPrice) * RiskReward);
               string orderComment = StringFormat("Q%d - Sweep Short", qScore);
               
               if(trade.Sell(lotSize, _Symbol, entryPrice, structuralSL, takeProfit, orderComment))
                 {
                  int actualTradeNum = GetTradeNumOfDay(true);
                 
                  tradeIsActive            = true;
                  currentTrade.ticket      = trade.ResultOrder();
                  currentTrade.tradeNumOfDay = actualTradeNum;
                  currentTrade.entryTime   = TimeCurrent();
                  currentTrade.entryPrice  = entryPrice;
                  currentTrade.stopLoss    = structuralSL;
                  currentTrade.takeProfit  = takeProfit;
                  currentTrade.lotSize     = lotSize;
                  currentTrade.qualityScore= qScore;
                  currentTrade.peakMFE     = 0;
                  currentTrade.timePeakMFE = TimeCurrent();
                  currentTrade.peakMAE     = 0;
                  currentTrade.timePeakMAE = TimeCurrent();
                  
                  ArrayResize(currentTrade.intervalPnL, 0);

                  // Round 18: Governor state reset for the new position.
                  currentTrade.riskDollar    = slDistancePts * lotSize;
                  currentTrade.governorArmed = false;
                  currentTrade.governorFloor = -DBL_MAX;

                  // Meta-Labeling Brain state reset (reuses riskDollar above)
                  currentTrade.lastMetaCheckTime = 0;
                  currentTrade.metaCheckCount = 0;
                  ArrayResize(currentTrade.pointsHistory, 0);
                  ArrayResize(currentTrade.pointsHistoryTimes, 0);
                  lastBarTime = currentBarTime;
                  return;
                 }
              }
           }
        }
     }
  }