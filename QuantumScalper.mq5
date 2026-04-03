//+------------------------------------------------------------------+
//|                                              QuantumScalper.mq5   |
//|                          XAUUSD Momentum Scalper with Averaging   |
//|                                           v1.1 - Improved Entry   |
//+------------------------------------------------------------------+
#property copyright "QuantumScalper"
#property version   "1.10"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//--- Input Parameters
input group "=== LOT SIZING ==="
input double   InpBaseLot          = 0.01;    // Base lot size
input double   InpBalancePerLot    = 400.0;   // Balance per base lot ($)
input bool     InpAutoLot          = true;    // Auto-scale lot with balance
input double   InpMaxLot           = 1.0;     // Maximum lot size

input group "=== ENTRY SIGNALS ==="
input int      InpRSIPeriod        = 7;       // RSI Period
input int      InpRSIBuyLevel      = 45;      // RSI Buy level (below = buy zone)
input int      InpRSISellLevel     = 55;      // RSI Sell level (above = sell zone)
input int      InpEMA_Fast         = 5;       // Fast EMA Period
input int      InpEMA_Slow         = 20;      // Slow EMA Period
input int      InpMomBars          = 3;       // Momentum lookback (bars)
input double   InpMomMinPoints     = 1.0;     // Min momentum to confirm entry (points)
input int      InpCooldownSec      = 60;      // Cooldown between trades (seconds)
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_M1; // Signal timeframe

input group "=== AVERAGING ==="
input int      InpMaxPositions     = 3;       // Max positions per direction
input double   InpAveragingStep    = 5.0;     // Distance to add position (points)
input double   InpAveragingMulti   = 1.0;     // Lot multiplier for averaging

input group "=== TAKE PROFIT ==="
input double   InpTPPoints         = 3.5;     // Single position TP (points)
input double   InpGroupTPPoints    = 2.5;     // Group TP when averaging (points from avg)
input bool     InpDynamicTP        = true;    // Dynamic TP (volatility-based)
input double   InpMinTP            = 1.5;     // Minimum TP (points)
input double   InpMaxTP            = 15.0;    // Maximum TP (points)

input group "=== STOP LOSS ==="
input double   InpSLPoints         = 16.0;    // Single position SL (points)
input double   InpGroupSLPoints    = 20.0;    // Group SL when multiple positions (points)
input double   InpMaxDrawdownPct   = 5.0;     // Max daily drawdown % to close all

input group "=== SPREAD & SLIPPAGE ==="
input double   InpMaxSpread        = 5.0;     // Max allowed spread (points)
input int      InpSlippage         = 3;       // Max slippage (points)
input int      InpRetryCount       = 3;       // Order retry count on failure
input int      InpRetryDelay       = 500;     // Delay between retries (ms)

input group "=== TIMING ==="
input bool     InpUseTimeFilter    = false;   // Enable time filter
input int      InpStartHour        = 2;       // Start hour (server time)
input int      InpEndHour          = 21;      // End hour (server time)

input group "=== GENERAL ==="
input int      InpMagicNumber      = 777777;  // Magic number
input string   InpComment          = "QS";    // Order comment
input bool     InpShowDashboard    = true;    // Show dashboard on chart

//--- Global Objects
CTrade         trade;
CPositionInfo  posInfo;
CSymbolInfo    symInfo;

//--- Indicator handles
int            hRSI;
int            hATR;
int            hEMA_Fast;
int            hEMA_Slow;

//--- State variables
double         currentSpread;
double         avgSpread;
int            spreadSamples;
double         pointValue;
int            digits;
datetime       lastTradeTime;
datetime       lastBarTime;
double         dayStartBalance;
int            totalTradesDay;
int            winsDay;
int            lossesDay;
int            signalDirection;  // 1=buy, -1=sell, 0=none

//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Validate symbol
   if(StringFind(Symbol(), "XAUUSD") < 0 && StringFind(Symbol(), "Gold") < 0
      && StringFind(Symbol(), "GOLD") < 0 && StringFind(Symbol(), "xauusd") < 0)
   {
      Alert("QuantumScalper: This EA is designed for XAUUSD only! Current symbol: ", Symbol());
      return INIT_FAILED;
   }

   //--- Initialize symbol info
   symInfo.Name(Symbol());
   symInfo.Refresh();
   pointValue = symInfo.Point();
   digits = symInfo.Digits();

   //--- Setup trade object
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetMarginMode();

   //--- Detect filling mode
   int filling = (int)SymbolInfoInteger(Symbol(), SYMBOL_FILLING_MODE);
   if((filling & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      trade.SetTypeFilling(ORDER_FILLING_IOC);
   else if((filling & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      trade.SetTypeFilling(ORDER_FILLING_FOK);
   else
      trade.SetTypeFilling(ORDER_FILLING_RETURN);

   //--- Create indicators
   hRSI      = iRSI(Symbol(), InpTimeframe, InpRSIPeriod, PRICE_CLOSE);
   hATR      = iATR(Symbol(), InpTimeframe, 14);
   hEMA_Fast = iMA(Symbol(), InpTimeframe, InpEMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
   hEMA_Slow = iMA(Symbol(), InpTimeframe, InpEMA_Slow, 0, MODE_EMA, PRICE_CLOSE);

   if(hRSI == INVALID_HANDLE || hATR == INVALID_HANDLE ||
      hEMA_Fast == INVALID_HANDLE || hEMA_Slow == INVALID_HANDLE)
   {
      Alert("QuantumScalper: Failed to create indicators!");
      return INIT_FAILED;
   }

   //--- Initialize state
   currentSpread = 0;
   avgSpread = 0;
   spreadSamples = 0;
   lastTradeTime = 0;
   lastBarTime = 0;
   dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   totalTradesDay = 0;
   winsDay = 0;
   lossesDay = 0;
   signalDirection = 0;

   Print("QuantumScalper v1.1 initialized | ", Symbol(), " | Point=", pointValue, " | Digits=", digits);

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(hRSI != INVALID_HANDLE)      IndicatorRelease(hRSI);
   if(hATR != INVALID_HANDLE)      IndicatorRelease(hATR);
   if(hEMA_Fast != INVALID_HANDLE) IndicatorRelease(hEMA_Fast);
   if(hEMA_Slow != INVALID_HANDLE) IndicatorRelease(hEMA_Slow);
   Comment("");
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   symInfo.Refresh();
   symInfo.RefreshRates();

   UpdateSpread();

   //--- New day reset
   MqlDateTime dt;
   TimeCurrent(dt);
   static int lastDay = -1;
   if(dt.day != lastDay)
   {
      lastDay = dt.day;
      dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      totalTradesDay = 0;
      winsDay = 0;
      lossesDay = 0;
   }

   //--- Check max drawdown
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(dayStartBalance > 0 && equity < dayStartBalance * (1.0 - InpMaxDrawdownPct / 100.0))
   {
      CloseAllPositions("Max drawdown reached");
      return;
   }

   //--- Manage existing positions
   ManagePositions();

   //--- Check if we can trade
   if(!CanTrade())
      return;

   //--- Cooldown check
   if(TimeCurrent() - lastTradeTime < InpCooldownSec)
      return;

   //--- Only check signals on new bar
   datetime barTime = iTime(Symbol(), InpTimeframe, 0);
   if(barTime == lastBarTime)
      return;
   lastBarTime = barTime;

   //--- Get indicator values (bar 1 = last completed bar)
   double rsi[3], atr[2], emaFast[3], emaSlow[3];
   if(CopyBuffer(hRSI, 0, 1, 3, rsi) < 3) return;
   if(CopyBuffer(hATR, 0, 1, 2, atr) < 2) return;
   if(CopyBuffer(hEMA_Fast, 0, 1, 3, emaFast) < 3) return;
   if(CopyBuffer(hEMA_Slow, 0, 1, 3, emaSlow) < 3) return;
   ArraySetAsSeries(rsi, true);
   ArraySetAsSeries(atr, true);
   ArraySetAsSeries(emaFast, true);
   ArraySetAsSeries(emaSlow, true);

   //--- Get price data for momentum
   double close[];
   if(CopyClose(Symbol(), InpTimeframe, 1, InpMomBars + 1, close) < InpMomBars + 1) return;
   ArraySetAsSeries(close, true);

   double momentum = (close[0] - close[InpMomBars]) / pointValue;
   double absMomentum = MathAbs(momentum);

   //--- Determine trend from EMA crossover
   bool emaUpTrend   = (emaFast[0] > emaSlow[0]);
   bool emaDownTrend = (emaFast[0] < emaSlow[0]);
   bool emaCrossUp   = (emaFast[0] > emaSlow[0] && emaFast[1] <= emaSlow[1]);
   bool emaCrossDown = (emaFast[0] < emaSlow[0] && emaFast[1] >= emaSlow[1]);

   //--- RSI conditions (relaxed)
   bool rsiBuyZone  = (rsi[0] < InpRSIBuyLevel);
   bool rsiSellZone = (rsi[0] > InpRSISellLevel);
   bool rsiRising   = (rsi[0] > rsi[1]);
   bool rsiFalling  = (rsi[0] < rsi[1]);

   //--- Momentum confirmation
   bool momUp   = (momentum >= InpMomMinPoints);
   bool momDown = (momentum <= -InpMomMinPoints);

   //--- Count existing positions
   int buyCount = 0, sellCount = 0;
   double buyAvgPrice = 0, sellAvgPrice = 0;
   double buyTotalLots = 0, sellTotalLots = 0;
   CountPositions(buyCount, sellCount, buyAvgPrice, sellAvgPrice, buyTotalLots, sellTotalLots);

   double ask = symInfo.Ask();
   double bid = symInfo.Bid();
   double lot = CalculateLot();

   //--- FRESH ENTRY (no positions open)
   if(buyCount == 0 && sellCount == 0)
   {
      //--- BUY CONDITIONS (any of these combos)
      bool buySignal = false;

      // Method 1: EMA crossover up + momentum confirms
      if(emaCrossUp && momUp)
         buySignal = true;

      // Method 2: RSI in buy zone + rising + EMA uptrend
      if(rsiBuyZone && rsiRising && emaUpTrend && momUp)
         buySignal = true;

      // Method 3: Strong momentum burst in uptrend
      if(emaUpTrend && momentum >= InpMomMinPoints * 2.0 && rsi[0] < 60)
         buySignal = true;

      //--- SELL CONDITIONS
      bool sellSignal = false;

      // Method 1: EMA crossover down + momentum confirms
      if(emaCrossDown && momDown)
         sellSignal = true;

      // Method 2: RSI in sell zone + falling + EMA downtrend
      if(rsiSellZone && rsiFalling && emaDownTrend && momDown)
         sellSignal = true;

      // Method 3: Strong momentum burst in downtrend
      if(emaDownTrend && momentum <= -InpMomMinPoints * 2.0 && rsi[0] > 40)
         sellSignal = true;

      if(buySignal && !sellSignal)
      {
         double tp = CalculateDynamicTP(atr[0], absMomentum * pointValue);
         OpenTrade(ORDER_TYPE_BUY, lot, tp, InpSLPoints, "Entry");
      }
      else if(sellSignal && !buySignal)
      {
         double tp = CalculateDynamicTP(atr[0], absMomentum * pointValue);
         OpenTrade(ORDER_TYPE_SELL, lot, tp, InpSLPoints, "Entry");
      }
   }
   //--- AVERAGING: Add to losing buy positions
   else if(buyCount > 0 && buyCount < InpMaxPositions && sellCount == 0)
   {
      double distFromAvg = buyAvgPrice - ask;
      if(distFromAvg >= InpAveragingStep)
      {
         double avgLot = NormalizeLot(lot * InpAveragingMulti);
         OpenTrade(ORDER_TYPE_BUY, avgLot, 0, 0, "Avg" + IntegerToString(buyCount + 1));
      }
   }
   //--- AVERAGING: Add to losing sell positions
   else if(sellCount > 0 && sellCount < InpMaxPositions && buyCount == 0)
   {
      double distFromAvg = bid - sellAvgPrice;
      if(distFromAvg >= InpAveragingStep)
      {
         double avgLot = NormalizeLot(lot * InpAveragingMulti);
         OpenTrade(ORDER_TYPE_SELL, avgLot, 0, 0, "Avg" + IntegerToString(sellCount + 1));
      }
   }

   //--- Dashboard
   if(InpShowDashboard)
      DrawDashboard(rsi[0], momentum, atr[0], emaFast[0], emaSlow[0], buyCount, sellCount, lot);
}

//+------------------------------------------------------------------+
//| Update spread tracking                                            |
//+------------------------------------------------------------------+
void UpdateSpread()
{
   currentSpread = (symInfo.Ask() - symInfo.Bid()) / pointValue;

   if(spreadSamples < 1000)
   {
      avgSpread = (avgSpread * spreadSamples + currentSpread) / (spreadSamples + 1);
      spreadSamples++;
   }
   else
   {
      avgSpread = avgSpread * 0.999 + currentSpread * 0.001;
   }
}

//+------------------------------------------------------------------+
//| Check if trading is allowed                                       |
//+------------------------------------------------------------------+
bool CanTrade()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      return false;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
      return false;

   //--- Check spread
   double spreadPts = (symInfo.Ask() - symInfo.Bid()) / pointValue;
   if(spreadPts > InpMaxSpread)
      return false;

   //--- Time filter
   if(InpUseTimeFilter)
   {
      MqlDateTime dt;
      TimeCurrent(dt);
      if(dt.hour < InpStartHour || dt.hour >= InpEndHour)
         return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| Count open positions for this EA                                  |
//+------------------------------------------------------------------+
void CountPositions(int &buyCount, int &sellCount,
                    double &buyAvgPrice, double &sellAvgPrice,
                    double &buyTotalLots, double &sellTotalLots)
{
   buyCount = 0;
   sellCount = 0;
   buyAvgPrice = 0;
   sellAvgPrice = 0;
   buyTotalLots = 0;
   sellTotalLots = 0;

   double buyWeightedPrice = 0;
   double sellWeightedPrice = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i))
         continue;
      if(posInfo.Magic() != InpMagicNumber)
         continue;
      if(posInfo.Symbol() != Symbol())
         continue;

      if(posInfo.PositionType() == POSITION_TYPE_BUY)
      {
         buyCount++;
         buyTotalLots += posInfo.Volume();
         buyWeightedPrice += posInfo.PriceOpen() * posInfo.Volume();
      }
      else if(posInfo.PositionType() == POSITION_TYPE_SELL)
      {
         sellCount++;
         sellTotalLots += posInfo.Volume();
         sellWeightedPrice += posInfo.PriceOpen() * posInfo.Volume();
      }
   }

   if(buyTotalLots > 0) buyAvgPrice = buyWeightedPrice / buyTotalLots;
   if(sellTotalLots > 0) sellAvgPrice = sellWeightedPrice / sellTotalLots;
}

//+------------------------------------------------------------------+
//| Calculate dynamic TP based on volatility                          |
//+------------------------------------------------------------------+
double CalculateDynamicTP(double atrValue, double momentum)
{
   if(!InpDynamicTP)
      return InpTPPoints;

   double tp = InpTPPoints;

   //--- Scale with ATR
   double atrPts = atrValue / pointValue;
   if(atrPts > 10)
      tp = tp * 1.3;
   else if(atrPts > 6)
      tp = tp * 1.1;
   else if(atrPts < 3)
      tp = tp * 0.8;

   //--- Scale with momentum strength
   double momPts = momentum / pointValue;
   if(momPts > 8)
      tp = tp * 1.5;
   else if(momPts > 5)
      tp = tp * 1.2;

   return MathMax(InpMinTP, MathMin(InpMaxTP, tp));
}

//+------------------------------------------------------------------+
//| Calculate lot size                                                |
//+------------------------------------------------------------------+
double CalculateLot()
{
   double lot = InpBaseLot;

   if(InpAutoLot)
   {
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      lot = MathFloor(balance / InpBalancePerLot) * InpBaseLot;
      lot = MathMax(InpBaseLot, lot);
   }

   return NormalizeLot(lot);
}

//+------------------------------------------------------------------+
//| Normalize lot to broker requirements                              |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
{
   double minLot = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);

   lot = MathMax(minLot, lot);
   lot = MathMin(MathMin(maxLot, InpMaxLot), lot);

   if(stepLot > 0)
      lot = MathFloor(lot / stepLot) * stepLot;

   return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
//| Open a trade with retry logic                                     |
//+------------------------------------------------------------------+
bool OpenTrade(ENUM_ORDER_TYPE type, double lot, double tpPoints, double slPoints, string label)
{
   string comment = InpComment + "_" + label;

   for(int attempt = 0; attempt < InpRetryCount; attempt++)
   {
      symInfo.RefreshRates();
      double ask = symInfo.Ask();
      double bid = symInfo.Bid();
      double price = (type == ORDER_TYPE_BUY) ? ask : bid;

      //--- Re-check spread
      double spreadNow = (ask - bid) / pointValue;
      if(spreadNow > InpMaxSpread)
      {
         Print("Spread too high: ", DoubleToString(spreadNow, 1), " > ", DoubleToString(InpMaxSpread, 1));
         return false;
      }

      //--- Calculate SL/TP prices
      double slPrice = 0, tpPrice = 0;

      if(slPoints > 0)
      {
         if(type == ORDER_TYPE_BUY)
            slPrice = NormalizeDouble(price - slPoints, digits);
         else
            slPrice = NormalizeDouble(price + slPoints, digits);
      }

      if(tpPoints > 0)
      {
         if(type == ORDER_TYPE_BUY)
            tpPrice = NormalizeDouble(price + tpPoints, digits);
         else
            tpPrice = NormalizeDouble(price - tpPoints, digits);
      }

      bool result = false;
      if(type == ORDER_TYPE_BUY)
         result = trade.Buy(lot, Symbol(), price, slPrice, tpPrice, comment);
      else
         result = trade.Sell(lot, Symbol(), price, slPrice, tpPrice, comment);

      if(result && trade.ResultRetcode() == TRADE_RETCODE_DONE)
      {
         lastTradeTime = TimeCurrent();
         totalTradesDay++;
         Print(label, ": ", (type == ORDER_TYPE_BUY ? "BUY" : "SELL"),
               " ", DoubleToString(lot, 2), " @ ", DoubleToString(price, digits),
               " SL=", DoubleToString(slPrice, digits),
               " TP=", DoubleToString(tpPrice, digits));
         return true;
      }

      Print("Order attempt ", attempt + 1, " failed: ", trade.ResultRetcodeDescription());

      if(attempt < InpRetryCount - 1)
         Sleep(InpRetryDelay);
   }

   return false;
}

//+------------------------------------------------------------------+
//| Manage open positions - group TP/SL on every tick                 |
//+------------------------------------------------------------------+
void ManagePositions()
{
   int buyCount = 0, sellCount = 0;
   double buyAvgPrice = 0, sellAvgPrice = 0;
   double buyTotalLots = 0, sellTotalLots = 0;
   CountPositions(buyCount, sellCount, buyAvgPrice, sellAvgPrice, buyTotalLots, sellTotalLots);

   double ask = symInfo.Ask();
   double bid = symInfo.Bid();

   //--- Manage BUY positions
   if(buyCount > 0)
   {
      double unrealizedPts = bid - buyAvgPrice;
      double targetTP = (buyCount > 1) ? InpGroupTPPoints : GetCurrentTP(POSITION_TYPE_BUY);
      double targetSL = (buyCount > 1) ? InpGroupSLPoints : InpSLPoints;

      if(unrealizedPts >= targetTP)
         CloseAllDirection(POSITION_TYPE_BUY, "TP +" + DoubleToString(unrealizedPts, 1) + " pts");
      else if(unrealizedPts <= -targetSL)
         CloseAllDirection(POSITION_TYPE_BUY, "SL " + DoubleToString(unrealizedPts, 1) + " pts");
   }

   //--- Manage SELL positions
   if(sellCount > 0)
   {
      double unrealizedPts = sellAvgPrice - ask;
      double targetTP = (sellCount > 1) ? InpGroupTPPoints : GetCurrentTP(POSITION_TYPE_SELL);
      double targetSL = (sellCount > 1) ? InpGroupSLPoints : InpSLPoints;

      if(unrealizedPts >= targetTP)
         CloseAllDirection(POSITION_TYPE_SELL, "TP +" + DoubleToString(unrealizedPts, 1) + " pts");
      else if(unrealizedPts <= -targetSL)
         CloseAllDirection(POSITION_TYPE_SELL, "SL " + DoubleToString(unrealizedPts, 1) + " pts");
   }
}

//+------------------------------------------------------------------+
//| Get dynamic TP for current market conditions                      |
//+------------------------------------------------------------------+
double GetCurrentTP(ENUM_POSITION_TYPE type)
{
   if(!InpDynamicTP)
      return InpTPPoints;

   double atr[];
   if(CopyBuffer(hATR, 0, 0, 1, atr) < 1)
      return InpTPPoints;

   double close[];
   if(CopyClose(Symbol(), InpTimeframe, 0, InpMomBars + 1, close) < InpMomBars + 1)
      return InpTPPoints;
   ArraySetAsSeries(close, true);

   double momentum = MathAbs(close[0] - close[InpMomBars]);
   return CalculateDynamicTP(atr[0], momentum);
}

//+------------------------------------------------------------------+
//| Close all positions in one direction                              |
//+------------------------------------------------------------------+
void CloseAllDirection(ENUM_POSITION_TYPE type, string reason)
{
   double totalProfit = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i))
         continue;
      if(posInfo.Magic() != InpMagicNumber)
         continue;
      if(posInfo.Symbol() != Symbol())
         continue;
      if(posInfo.PositionType() != type)
         continue;

      totalProfit += posInfo.Profit() + posInfo.Swap() + posInfo.Commission();

      for(int attempt = 0; attempt < InpRetryCount; attempt++)
      {
         if(trade.PositionClose(posInfo.Ticket()))
            break;
         Print("Close retry ", attempt + 1, " ticket ", posInfo.Ticket());
         if(attempt < InpRetryCount - 1)
            Sleep(InpRetryDelay);
      }
   }

   if(totalProfit > 0) winsDay++;
   else lossesDay++;

   Print("CLOSED ", (type == POSITION_TYPE_BUY ? "BUY" : "SELL"),
         " | ", reason, " | P/L: $", DoubleToString(totalProfit, 2));
}

//+------------------------------------------------------------------+
//| Close all positions (emergency)                                   |
//+------------------------------------------------------------------+
void CloseAllPositions(string reason)
{
   Print("EMERGENCY: ", reason);
   CloseAllDirection(POSITION_TYPE_BUY, reason);
   CloseAllDirection(POSITION_TYPE_SELL, reason);
}

//+------------------------------------------------------------------+
//| Draw dashboard                                                    |
//+------------------------------------------------------------------+
void DrawDashboard(double rsi, double momentum, double atr,
                   double emaF, double emaS,
                   int buyCount, int sellCount, double lot)
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double spreadPts = (symInfo.Ask() - symInfo.Bid()) / pointValue;
   double ddPct = (dayStartBalance > 0) ? ((dayStartBalance - equity) / dayStartBalance * 100) : 0;

   string trend = (emaF > emaS) ? "UP" : (emaF < emaS) ? "DOWN" : "FLAT";

   string dash = "";
   dash += "=== QuantumScalper v1.1 ===\n";
   dash += "Balance: $" + DoubleToString(balance, 2) + " | Equity: $" + DoubleToString(equity, 2) + "\n";
   dash += "Lot: " + DoubleToString(lot, 2) + (InpAutoLot ? " (auto)" : " (fixed)") + "\n";
   dash += "Spread: " + DoubleToString(spreadPts, 1) + " pts (avg " + DoubleToString(avgSpread, 1) + ")\n";
   dash += "Trend: " + trend + " | RSI: " + DoubleToString(rsi, 1) + "\n";
   dash += "Momentum: " + DoubleToString(momentum, 1) + " pts\n";
   dash += "ATR: " + DoubleToString(atr / pointValue, 1) + " pts\n";
   dash += "Positions: BUY=" + IntegerToString(buyCount) + " SELL=" + IntegerToString(sellCount) + "\n";
   dash += "Today: " + IntegerToString(totalTradesDay) + " trades | W:" + IntegerToString(winsDay) + " L:" + IntegerToString(lossesDay) + "\n";
   dash += "DD: " + DoubleToString(ddPct, 2) + "% (max " + DoubleToString(InpMaxDrawdownPct, 1) + "%)\n";

   if(spreadPts > InpMaxSpread)
      dash += ">>> SPREAD TOO HIGH - PAUSED <<<\n";

   Comment(dash);
}

//+------------------------------------------------------------------+
//| OnTrade event handler                                             |
//+------------------------------------------------------------------+
void OnTrade()
{
}
//+------------------------------------------------------------------+
