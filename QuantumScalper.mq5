//+------------------------------------------------------------------+
//|                                              QuantumScalper.mq5   |
//|                          XAUUSD Momentum Scalper with Averaging   |
//|                                                                    |
//|  Strategy: Momentum-based scalping on XAUUSD with position        |
//|  averaging. Detects short-term momentum shifts, enters trades,    |
//|  and adds positions if price moves against. Closes all positions  |
//|  when combined profit target is reached.                          |
//+------------------------------------------------------------------+
#property copyright "QuantumScalper"
#property version   "1.00"
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
input int      InpRSIBuyLevel      = 35;      // RSI Buy level (below = buy signal)
input int      InpRSISellLevel     = 65;      // RSI Sell level (above = sell signal)
input int      InpMomPeriod        = 5;       // Momentum Period (bars)
input double   InpMomThreshold     = 1.5;     // Momentum threshold (points)
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_M1; // Signal timeframe

input group "=== AVERAGING ==="
input int      InpMaxPositions     = 3;       // Max positions per direction
input double   InpAveragingStep    = 5.0;     // Pip distance to add position (points)
input double   InpAveragingMulti   = 1.0;     // Lot multiplier for averaging (1.0 = same lot)

input group "=== TAKE PROFIT ==="
input double   InpTPPoints         = 3.5;     // Take profit per position (points)
input double   InpGroupTPPoints    = 2.5;     // Group TP when averaging (points from avg price)
input bool     InpDynamicTP        = true;    // Use dynamic TP (momentum-based)
input double   InpMinTP            = 1.5;     // Minimum TP (points)
input double   InpMaxTP            = 15.0;    // Maximum TP (points)

input group "=== STOP LOSS ==="
input double   InpSLPoints         = 16.0;    // Stop loss per position (points)
input double   InpGroupSLPoints    = 20.0;    // Group SL when multiple positions (points)
input double   InpMaxDrawdownPct   = 5.0;     // Max drawdown % to close all

input group "=== SPREAD & SLIPPAGE ==="
input double   InpMaxSpread        = 5.0;     // Max allowed spread (points)
input int      InpSlippage         = 3;       // Max slippage (points)
input int      InpRetryCount       = 3;       // Order retry count on failure
input int      InpRetryDelay       = 500;     // Delay between retries (ms)

input group "=== TIMING ==="
input bool     InpUseTimeFilter    = false;   // Enable time filter
input int      InpStartHour        = 2;       // Start hour (server time)
input int      InpEndHour          = 21;      // End hour (server time)
input int      InpMinBarAge        = 3;       // Min seconds since bar open to trade

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

//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Validate symbol
   if(Symbol() != "XAUUSD" && Symbol() != "XAUUSDm" && Symbol() != "XAUUSD."
      && Symbol() != "XAUUSD!" && Symbol() != "XAUUSDc" && Symbol() != "Gold"
      && StringFind(Symbol(), "XAUUSD") < 0 && StringFind(Symbol(), "Gold") < 0)
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
   trade.SetTypeFilling(ORDER_FILLING_IOC);
   trade.SetMarginMode();

   //--- Try FOK if IOC fails
   if(!IsFillingTypeAllowed(Symbol(), ORDER_FILLING_IOC))
   {
      if(IsFillingTypeAllowed(Symbol(), ORDER_FILLING_FOK))
         trade.SetTypeFilling(ORDER_FILLING_FOK);
      else
         trade.SetTypeFilling(ORDER_FILLING_RETURN);
   }

   //--- Create indicators
   hRSI = iRSI(Symbol(), InpTimeframe, InpRSIPeriod, PRICE_CLOSE);
   hATR = iATR(Symbol(), InpTimeframe, 14);

   if(hRSI == INVALID_HANDLE || hATR == INVALID_HANDLE)
   {
      Alert("QuantumScalper: Failed to create indicators!");
      return INIT_FAILED;
   }

   //--- Initialize spread tracking
   currentSpread = 0;
   avgSpread = 0;
   spreadSamples = 0;
   lastTradeTime = 0;
   lastBarTime = 0;
   dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   totalTradesDay = 0;
   winsDay = 0;
   lossesDay = 0;

   Print("QuantumScalper initialized on ", Symbol(), " | Point=", pointValue, " | Digits=", digits);

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(hRSI != INVALID_HANDLE) IndicatorRelease(hRSI);
   if(hATR != INVALID_HANDLE) IndicatorRelease(hATR);
   Comment("");
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- Refresh symbol data
   symInfo.Refresh();
   symInfo.RefreshRates();

   //--- Track spread
   UpdateSpread();

   //--- Check for new day
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
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(dayStartBalance > 0 && equity < dayStartBalance * (1.0 - InpMaxDrawdownPct / 100.0))
   {
      CloseAllPositions("Max drawdown reached");
      return;
   }

   //--- Manage existing positions (check group TP/SL)
   ManagePositions();

   //--- Check if we can open new trades
   if(!CanTrade())
      return;

   //--- Check for entry signals on new bar
   datetime barTime = iTime(Symbol(), InpTimeframe, 0);
   if(barTime == lastBarTime)
      return;

   //--- Wait for bar to mature slightly to avoid false signals
   if(InpMinBarAge > 0)
   {
      if((int)(TimeCurrent() - barTime) < InpMinBarAge)
         return;
   }

   lastBarTime = barTime;

   //--- Get indicator values
   double rsi[], atr[];
   if(CopyBuffer(hRSI, 0, 1, 3, rsi) < 3) return;
   if(CopyBuffer(hATR, 0, 1, 1, atr) < 1) return;
   ArraySetAsSeries(rsi, true);
   ArraySetAsSeries(atr, true);

   //--- Get price data for momentum
   double close[];
   if(CopyClose(Symbol(), InpTimeframe, 0, InpMomPeriod + 2, close) < InpMomPeriod + 2) return;
   ArraySetAsSeries(close, true);

   double momentum = close[1] - close[InpMomPeriod];
   double absMomentum = MathAbs(momentum);

   //--- Count existing positions
   int buyCount = 0, sellCount = 0;
   double buyAvgPrice = 0, sellAvgPrice = 0;
   double buyTotalLots = 0, sellTotalLots = 0;
   CountPositions(buyCount, sellCount, buyAvgPrice, sellAvgPrice, buyTotalLots, sellTotalLots);

   double ask = symInfo.Ask();
   double bid = symInfo.Bid();
   double lot = CalculateLot();

   //--- BUY SIGNAL
   if(buyCount == 0 && sellCount == 0)
   {
      //--- Fresh entry: RSI oversold + upward momentum
      if(rsi[0] < InpRSIBuyLevel && momentum > InpMomThreshold * pointValue)
      {
         double tp = CalculateDynamicTP(atr[0], absMomentum);
         double sl = InpSLPoints;

         OpenTrade(ORDER_TYPE_BUY, lot, tp, sl, "Entry");
      }
      //--- Fresh entry: RSI overbought + downward momentum
      else if(rsi[0] > InpRSISellLevel && momentum < -InpMomThreshold * pointValue)
      {
         double tp = CalculateDynamicTP(atr[0], absMomentum);
         double sl = InpSLPoints;

         OpenTrade(ORDER_TYPE_SELL, lot, tp, sl, "Entry");
      }
   }
   //--- AVERAGING: Add to existing buy positions
   else if(buyCount > 0 && buyCount < InpMaxPositions && sellCount == 0)
   {
      double distFromAvg = buyAvgPrice - ask;
      if(distFromAvg >= InpAveragingStep)
      {
         double avgLot = NormalizeLot(lot * InpAveragingMulti);
         OpenTrade(ORDER_TYPE_BUY, avgLot, 0, 0, "Avg" + IntegerToString(buyCount + 1));
      }
   }
   //--- AVERAGING: Add to existing sell positions
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
      DrawDashboard(rsi[0], momentum, atr[0], buyCount, sellCount, lot);
}

//+------------------------------------------------------------------+
//| Update spread tracking                                            |
//+------------------------------------------------------------------+
void UpdateSpread()
{
   currentSpread = symInfo.Spread() * pointValue;

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
   //--- Check if trading is enabled
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      return false;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
      return false;

   //--- Check spread
   double spreadInPoints = (symInfo.Ask() - symInfo.Bid()) / pointValue;
   if(spreadInPoints > InpMaxSpread)
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
//| Calculate dynamic TP based on volatility and momentum             |
//+------------------------------------------------------------------+
double CalculateDynamicTP(double atrValue, double momentum)
{
   if(!InpDynamicTP)
      return InpTPPoints;

   //--- Base TP from input
   double tp = InpTPPoints;

   //--- Scale TP with ATR (higher volatility = wider TP)
   double atrFactor = atrValue / pointValue;
   if(atrFactor > 10)
      tp = tp * 1.3;
   else if(atrFactor < 3)
      tp = tp * 0.8;

   //--- Scale with momentum strength
   double momPoints = momentum / pointValue;
   if(momPoints > 8)
      tp = tp * 1.5;
   else if(momPoints > 5)
      tp = tp * 1.2;

   //--- Clamp to min/max
   tp = MathMax(InpMinTP, MathMin(InpMaxTP, tp));

   return tp;
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
   double ask = symInfo.Ask();
   double bid = symInfo.Bid();
   double price = (type == ORDER_TYPE_BUY) ? ask : bid;

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

   string comment = InpComment + "_" + label;

   //--- Retry loop for execution
   for(int attempt = 0; attempt < InpRetryCount; attempt++)
   {
      //--- Refresh prices before each attempt
      symInfo.RefreshRates();
      ask = symInfo.Ask();
      bid = symInfo.Bid();
      price = (type == ORDER_TYPE_BUY) ? ask : bid;

      //--- Re-check spread
      double spreadNow = (ask - bid) / pointValue;
      if(spreadNow > InpMaxSpread)
      {
         Print("Spread too high (", DoubleToString(spreadNow, 1), " > ", DoubleToString(InpMaxSpread, 1), "), skipping...");
         return false;
      }

      //--- Recalculate SL/TP with fresh price
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
         Print("Trade opened: ", (type == ORDER_TYPE_BUY ? "BUY" : "SELL"),
               " ", DoubleToString(lot, 2), " @ ", DoubleToString(price, digits),
               " SL=", DoubleToString(slPrice, digits),
               " TP=", DoubleToString(tpPrice, digits),
               " [", label, "]");
         return true;
      }

      //--- Log failure
      Print("Order attempt ", attempt + 1, " failed: ", trade.ResultRetcodeDescription(),
            " (", trade.ResultRetcode(), ")");

      if(attempt < InpRetryCount - 1)
         Sleep(InpRetryDelay);
   }

   return false;
}

//+------------------------------------------------------------------+
//| Manage open positions - group TP/SL                               |
//+------------------------------------------------------------------+
void ManagePositions()
{
   int buyCount = 0, sellCount = 0;
   double buyAvgPrice = 0, sellAvgPrice = 0;
   double buyTotalLots = 0, sellTotalLots = 0;
   CountPositions(buyCount, sellCount, buyAvgPrice, sellAvgPrice, buyTotalLots, sellTotalLots);

   double ask = symInfo.Ask();
   double bid = symInfo.Bid();

   //--- Manage BUY group
   if(buyCount > 0)
   {
      double unrealizedPips = bid - buyAvgPrice;

      //--- Group TP
      double targetTP;
      if(buyCount > 1)
         targetTP = InpGroupTPPoints;
      else
         targetTP = InpTPPoints;

      //--- Dynamic TP adjustment
      if(InpDynamicTP && buyCount == 1)
      {
         double atr[];
         if(CopyBuffer(hATR, 0, 0, 1, atr) >= 1)
         {
            double close[];
            if(CopyClose(Symbol(), InpTimeframe, 0, InpMomPeriod + 2, close) >= InpMomPeriod + 2)
            {
               ArraySetAsSeries(close, true);
               ArraySetAsSeries(atr, true);
               double momentum = MathAbs(close[0] - close[InpMomPeriod]);
               targetTP = CalculateDynamicTP(atr[0], momentum);
            }
         }
      }

      if(unrealizedPips >= targetTP)
      {
         CloseAllDirection(POSITION_TYPE_BUY, "TP hit (" + DoubleToString(unrealizedPips, 1) + " pts)");
      }

      //--- Group SL
      double targetSL = (buyCount > 1) ? InpGroupSLPoints : InpSLPoints;
      if(unrealizedPips <= -targetSL)
      {
         CloseAllDirection(POSITION_TYPE_BUY, "SL hit (" + DoubleToString(unrealizedPips, 1) + " pts)");
      }
   }

   //--- Manage SELL group
   if(sellCount > 0)
   {
      double unrealizedPips = sellAvgPrice - ask;

      //--- Group TP
      double targetTP;
      if(sellCount > 1)
         targetTP = InpGroupTPPoints;
      else
         targetTP = InpTPPoints;

      //--- Dynamic TP adjustment
      if(InpDynamicTP && sellCount == 1)
      {
         double atr[];
         if(CopyBuffer(hATR, 0, 0, 1, atr) >= 1)
         {
            double close[];
            if(CopyClose(Symbol(), InpTimeframe, 0, InpMomPeriod + 2, close) >= InpMomPeriod + 2)
            {
               ArraySetAsSeries(close, true);
               ArraySetAsSeries(atr, true);
               double momentum = MathAbs(close[0] - close[InpMomPeriod]);
               targetTP = CalculateDynamicTP(atr[0], momentum);
            }
         }
      }

      if(unrealizedPips >= targetTP)
      {
         CloseAllDirection(POSITION_TYPE_SELL, "TP hit (" + DoubleToString(unrealizedPips, 1) + " pts)");
      }

      //--- Group SL
      double targetSL = (sellCount > 1) ? InpGroupSLPoints : InpSLPoints;
      if(unrealizedPips <= -targetSL)
      {
         CloseAllDirection(POSITION_TYPE_SELL, "SL hit (" + DoubleToString(unrealizedPips, 1) + " pts)");
      }
   }
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
         {
            break;
         }
         Print("Close attempt ", attempt + 1, " failed for ticket ", posInfo.Ticket());
         if(attempt < InpRetryCount - 1)
            Sleep(InpRetryDelay);
      }
   }

   if(totalProfit > 0) winsDay++;
   else lossesDay++;

   Print("Closed all ", (type == POSITION_TYPE_BUY ? "BUY" : "SELL"),
         " positions. Reason: ", reason, " | P/L: $", DoubleToString(totalProfit, 2));
}

//+------------------------------------------------------------------+
//| Close all positions (emergency)                                   |
//+------------------------------------------------------------------+
void CloseAllPositions(string reason)
{
   Print("EMERGENCY CLOSE: ", reason);
   CloseAllDirection(POSITION_TYPE_BUY, reason);
   CloseAllDirection(POSITION_TYPE_SELL, reason);
}

//+------------------------------------------------------------------+
//| Check if filling type is allowed                                  |
//+------------------------------------------------------------------+
bool IsFillingTypeAllowed(string symbol, ENUM_ORDER_TYPE_FILLING fillType)
{
   int filling = (int)SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
   return (filling & (int)fillType) == (int)fillType;
}

//+------------------------------------------------------------------+
//| Draw dashboard on chart                                           |
//+------------------------------------------------------------------+
void DrawDashboard(double rsi, double momentum, double atr,
                   int buyCount, int sellCount, double lot)
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double spreadPts = (symInfo.Ask() - symInfo.Bid()) / pointValue;
   double ddPct = (dayStartBalance > 0) ? ((dayStartBalance - equity) / dayStartBalance * 100) : 0;

   string dash = "";
   dash += "=== QuantumScalper v1.0 ===\n";
   dash += "Symbol: " + Symbol() + "\n";
   dash += "Balance: $" + DoubleToString(balance, 2) + " | Equity: $" + DoubleToString(equity, 2) + "\n";
   dash += "Lot: " + DoubleToString(lot, 2) + (InpAutoLot ? " (auto)" : " (fixed)") + "\n";
   dash += "Spread: " + DoubleToString(spreadPts, 1) + " pts (avg " + DoubleToString(avgSpread / pointValue, 1) + ")\n";
   dash += "RSI(" + IntegerToString(InpRSIPeriod) + "): " + DoubleToString(rsi, 1) + "\n";
   dash += "Momentum: " + DoubleToString(momentum / pointValue, 1) + " pts\n";
   dash += "ATR: " + DoubleToString(atr / pointValue, 1) + " pts\n";
   dash += "Positions: BUY=" + IntegerToString(buyCount) + " SELL=" + IntegerToString(sellCount) + "\n";
   dash += "Today: " + IntegerToString(totalTradesDay) + " trades | W:" + IntegerToString(winsDay) + " L:" + IntegerToString(lossesDay) + "\n";
   dash += "DD: " + DoubleToString(ddPct, 2) + "% (max " + DoubleToString(InpMaxDrawdownPct, 1) + "%)\n";

   if(spreadPts > InpMaxSpread)
      dash += ">>> SPREAD TOO HIGH - PAUSED <<<\n";

   Comment(dash);
}

//+------------------------------------------------------------------+
//| OnTrade - track closed positions                                  |
//+------------------------------------------------------------------+
void OnTrade()
{
   // Additional trade event handling can be added here
}
//+------------------------------------------------------------------+
