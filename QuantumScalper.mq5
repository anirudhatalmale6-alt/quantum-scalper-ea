//+------------------------------------------------------------------+
//|                                              QuantumScalper.mq5   |
//|                          XAUUSD Momentum Scalper with Averaging   |
//|                                        v1.2 - Fixed Units Bug     |
//+------------------------------------------------------------------+
#property copyright "QuantumScalper"
#property version   "1.20"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//--- All price-based inputs are in DOLLARS (actual price movement)
//--- e.g., TP=3.5 means $3.50 move in XAUUSD price
input group "=== LOT SIZING ==="
input double   InpBaseLot          = 0.01;    // Base lot size
input double   InpBalancePerLot    = 400.0;   // Balance per base lot ($)
input bool     InpAutoLot          = true;    // Auto-scale lot with balance
input double   InpMaxLot           = 1.0;     // Maximum lot size

input group "=== ENTRY SIGNALS ==="
input int      InpRSIPeriod        = 7;       // RSI Period
input int      InpRSIBuyLevel      = 45;      // RSI Buy threshold (below = buy zone)
input int      InpRSISellLevel     = 55;      // RSI Sell threshold (above = sell zone)
input int      InpEMA_Fast         = 5;       // Fast EMA Period
input int      InpEMA_Slow         = 20;      // Slow EMA Period
input double   InpMomMinDollar     = 0.50;    // Min momentum to confirm ($)
input int      InpMomBars          = 3;       // Momentum lookback (bars)
input int      InpCooldownSec      = 30;      // Cooldown between new entries (seconds)
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_M1; // Signal timeframe

input group "=== AVERAGING ==="
input int      InpMaxPositions     = 3;       // Max positions per direction
input double   InpAveragingStep    = 5.0;     // $ distance to add position
input double   InpAveragingMulti   = 1.0;     // Lot multiplier for averaging

input group "=== TAKE PROFIT ==="
input double   InpTPDollar         = 3.5;     // Single position TP ($)
input double   InpGroupTPDollar    = 2.5;     // Group TP from avg entry ($)
input bool     InpDynamicTP        = true;    // Dynamic TP (volatility-based)
input double   InpMinTP            = 1.5;     // Minimum TP ($)
input double   InpMaxTP            = 15.0;    // Maximum TP ($)

input group "=== STOP LOSS ==="
input double   InpSLDollar         = 16.0;    // Single position SL ($)
input double   InpGroupSLDollar    = 20.0;    // Group SL from avg entry ($)
input double   InpMaxDrawdownPct   = 5.0;     // Max daily drawdown % to close all

input group "=== SPREAD & SLIPPAGE ==="
input double   InpMaxSpreadDollar  = 0.50;    // Max allowed spread ($)
input int      InpSlippage         = 30;      // Max slippage (broker points)
input int      InpRetryCount       = 3;       // Order retry count
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
int            hRSI, hATR, hEMA_Fast, hEMA_Slow;

//--- State
int            digits;
datetime       lastTradeTime;
datetime       lastBarTime;
double         dayStartBalance;
int            totalTradesDay, winsDay, lossesDay;
double         avgSpreadDollar;
int            spreadSamples;

//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- Validate symbol
   string sym = Symbol();
   StringToUpper(sym);
   if(StringFind(sym, "XAUUSD") < 0 && StringFind(sym, "GOLD") < 0)
   {
      Alert("QuantumScalper: Designed for XAUUSD only! Symbol: ", Symbol());
      return INIT_FAILED;
   }

   symInfo.Name(Symbol());
   symInfo.Refresh();
   digits = symInfo.Digits();

   //--- Setup trade
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetMarginMode();

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

   lastTradeTime = 0;
   lastBarTime = 0;
   dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   totalTradesDay = 0;
   winsDay = 0;
   lossesDay = 0;
   avgSpreadDollar = 0;
   spreadSamples = 0;

   Print("QuantumScalper v1.2 | ", Symbol(), " | Digits=", digits,
         " | Point=", DoubleToString(symInfo.Point(), digits));

   return INIT_SUCCEEDED;
}

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
//| Spread in dollars (actual price difference)                       |
//+------------------------------------------------------------------+
double GetSpreadDollar()
{
   return symInfo.Ask() - symInfo.Bid();
}

//+------------------------------------------------------------------+
void UpdateSpread()
{
   double sp = GetSpreadDollar();
   if(spreadSamples < 1000)
   {
      avgSpreadDollar = (avgSpreadDollar * spreadSamples + sp) / (spreadSamples + 1);
      spreadSamples++;
   }
   else
      avgSpreadDollar = avgSpreadDollar * 0.999 + sp * 0.001;
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

   //--- Drawdown protection
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(dayStartBalance > 0 && equity < dayStartBalance * (1.0 - InpMaxDrawdownPct / 100.0))
   {
      CloseAllPositions("Max drawdown");
      return;
   }

   //--- Manage positions on EVERY tick (TP/SL checks)
   ManagePositions();

   //--- Can we trade?
   if(!CanTrade())
      return;

   //--- Cooldown
   if(TimeCurrent() - lastTradeTime < InpCooldownSec)
      return;

   //--- New bar check for entries
   datetime barTime = iTime(Symbol(), InpTimeframe, 0);
   if(barTime == lastBarTime)
      return;
   lastBarTime = barTime;

   //--- Read indicators (bar index 1 = last completed bar)
   double rsi[3], atr[2], emaF[3], emaS[3];
   if(CopyBuffer(hRSI, 0, 1, 3, rsi) < 3) return;
   if(CopyBuffer(hATR, 0, 1, 2, atr) < 2) return;
   if(CopyBuffer(hEMA_Fast, 0, 1, 3, emaF) < 3) return;
   if(CopyBuffer(hEMA_Slow, 0, 1, 3, emaS) < 3) return;
   ArraySetAsSeries(rsi, true);
   ArraySetAsSeries(atr, true);
   ArraySetAsSeries(emaF, true);
   ArraySetAsSeries(emaS, true);

   //--- Momentum in dollars
   double close[];
   if(CopyClose(Symbol(), InpTimeframe, 1, InpMomBars + 1, close) < InpMomBars + 1) return;
   ArraySetAsSeries(close, true);
   double momDollar = close[0] - close[InpMomBars];

   //--- Trend & signals
   bool emaUp      = (emaF[0] > emaS[0]);
   bool emaDown    = (emaF[0] < emaS[0]);
   bool emaCrossUp = (emaF[0] > emaS[0] && emaF[1] <= emaS[1]);
   bool emaCrossDn = (emaF[0] < emaS[0] && emaF[1] >= emaS[1]);
   bool rsiLow     = (rsi[0] < InpRSIBuyLevel);
   bool rsiHigh    = (rsi[0] > InpRSISellLevel);
   bool rsiUp      = (rsi[0] > rsi[1]);
   bool rsiDn      = (rsi[0] < rsi[1]);
   bool momUp      = (momDollar >= InpMomMinDollar);
   bool momDown    = (momDollar <= -InpMomMinDollar);

   //--- Count positions
   int buyCount = 0, sellCount = 0;
   double buyAvg = 0, sellAvg = 0, buyLots = 0, sellLots = 0;
   CountPositions(buyCount, sellCount, buyAvg, sellAvg, buyLots, sellLots);

   double lot = CalculateLot();

   //--- FRESH ENTRY
   if(buyCount == 0 && sellCount == 0)
   {
      bool buySignal = false;
      bool sellSignal = false;

      // Method 1: EMA crossover + momentum
      if(emaCrossUp && momUp) buySignal = true;
      if(emaCrossDn && momDown) sellSignal = true;

      // Method 2: Trend + RSI zone + momentum
      if(emaUp && rsiLow && rsiUp && momUp) buySignal = true;
      if(emaDown && rsiHigh && rsiDn && momDown) sellSignal = true;

      // Method 3: Strong momentum burst in trend
      if(emaUp && momDollar >= InpMomMinDollar * 2.0 && rsi[0] < 60) buySignal = true;
      if(emaDown && momDollar <= -InpMomMinDollar * 2.0 && rsi[0] > 40) sellSignal = true;

      // Method 4: RSI reversal from extreme + any momentum
      if(rsi[0] < 30 && rsiUp && momDollar > 0) buySignal = true;
      if(rsi[0] > 70 && rsiDn && momDollar < 0) sellSignal = true;

      // Method 5: EMA trend + RSI direction aligned (most relaxed)
      if(emaUp && rsiUp && momUp && rsi[0] < 55) buySignal = true;
      if(emaDown && rsiDn && momDown && rsi[0] > 45) sellSignal = true;

      double tp = InpDynamicTP ? CalcDynamicTP(atr[0]) : InpTPDollar;

      if(buySignal && !sellSignal)
         OpenTrade(ORDER_TYPE_BUY, lot, tp, InpSLDollar, "Entry");
      else if(sellSignal && !buySignal)
         OpenTrade(ORDER_TYPE_SELL, lot, tp, InpSLDollar, "Entry");
   }
   //--- AVERAGING BUY
   else if(buyCount > 0 && buyCount < InpMaxPositions && sellCount == 0)
   {
      double dist = buyAvg - symInfo.Ask();
      if(dist >= InpAveragingStep)
         OpenTrade(ORDER_TYPE_BUY, NormalizeLot(lot * InpAveragingMulti), 0, 0,
                   "Avg" + IntegerToString(buyCount + 1));
   }
   //--- AVERAGING SELL
   else if(sellCount > 0 && sellCount < InpMaxPositions && buyCount == 0)
   {
      double dist = symInfo.Bid() - sellAvg;
      if(dist >= InpAveragingStep)
         OpenTrade(ORDER_TYPE_SELL, NormalizeLot(lot * InpAveragingMulti), 0, 0,
                   "Avg" + IntegerToString(sellCount + 1));
   }

   if(InpShowDashboard)
      DrawDashboard(rsi[0], momDollar, atr[0], emaF[0], emaS[0], buyCount, sellCount, lot);
}

//+------------------------------------------------------------------+
bool CanTrade()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return false;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED)) return false;

   //--- Spread check in DOLLARS
   if(GetSpreadDollar() > InpMaxSpreadDollar)
      return false;

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
void CountPositions(int &buyCount, int &sellCount,
                    double &buyAvg, double &sellAvg,
                    double &buyLots, double &sellLots)
{
   buyCount = 0; sellCount = 0;
   buyAvg = 0; sellAvg = 0;
   buyLots = 0; sellLots = 0;
   double buyWP = 0, sellWP = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Magic() != InpMagicNumber) continue;
      if(posInfo.Symbol() != Symbol()) continue;

      if(posInfo.PositionType() == POSITION_TYPE_BUY)
      {
         buyCount++;
         buyLots += posInfo.Volume();
         buyWP += posInfo.PriceOpen() * posInfo.Volume();
      }
      else
      {
         sellCount++;
         sellLots += posInfo.Volume();
         sellWP += posInfo.PriceOpen() * posInfo.Volume();
      }
   }

   if(buyLots > 0)  buyAvg = buyWP / buyLots;
   if(sellLots > 0) sellAvg = sellWP / sellLots;
}

//+------------------------------------------------------------------+
double CalcDynamicTP(double atrValue)
{
   double tp = InpTPDollar;

   if(atrValue > 10.0)       tp *= 1.3;
   else if(atrValue > 6.0)   tp *= 1.1;
   else if(atrValue < 2.0)   tp *= 0.8;

   return MathMax(InpMinTP, MathMin(InpMaxTP, tp));
}

//+------------------------------------------------------------------+
double CalculateLot()
{
   double lot = InpBaseLot;
   if(InpAutoLot)
   {
      double bal = AccountInfoDouble(ACCOUNT_BALANCE);
      lot = MathFloor(bal / InpBalancePerLot) * InpBaseLot;
      lot = MathMax(InpBaseLot, lot);
   }
   return NormalizeLot(lot);
}

//+------------------------------------------------------------------+
double NormalizeLot(double lot)
{
   double minL = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MIN);
   double maxL = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(Symbol(), SYMBOL_VOLUME_STEP);

   lot = MathMax(minL, lot);
   lot = MathMin(MathMin(maxL, InpMaxLot), lot);
   if(step > 0) lot = MathFloor(lot / step) * step;

   return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
//| Open trade - TP/SL in dollars (price difference)                  |
//+------------------------------------------------------------------+
bool OpenTrade(ENUM_ORDER_TYPE type, double lot, double tpDollar, double slDollar, string label)
{
   string comment = InpComment + "_" + label;

   for(int attempt = 0; attempt < InpRetryCount; attempt++)
   {
      symInfo.RefreshRates();
      double ask = symInfo.Ask();
      double bid = symInfo.Bid();
      double price = (type == ORDER_TYPE_BUY) ? ask : bid;

      if(GetSpreadDollar() > InpMaxSpreadDollar)
      {
         Print("Spread $", DoubleToString(GetSpreadDollar(), 2), " > max $", DoubleToString(InpMaxSpreadDollar, 2));
         return false;
      }

      double slPrice = 0, tpPrice = 0;

      if(slDollar > 0)
      {
         slPrice = (type == ORDER_TYPE_BUY) ?
            NormalizeDouble(price - slDollar, digits) :
            NormalizeDouble(price + slDollar, digits);
      }

      if(tpDollar > 0)
      {
         tpPrice = (type == ORDER_TYPE_BUY) ?
            NormalizeDouble(price + tpDollar, digits) :
            NormalizeDouble(price - tpDollar, digits);
      }

      bool result = (type == ORDER_TYPE_BUY) ?
         trade.Buy(lot, Symbol(), price, slPrice, tpPrice, comment) :
         trade.Sell(lot, Symbol(), price, slPrice, tpPrice, comment);

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

      Print("Attempt ", attempt + 1, " failed: ", trade.ResultRetcodeDescription());
      if(attempt < InpRetryCount - 1) Sleep(InpRetryDelay);
   }
   return false;
}

//+------------------------------------------------------------------+
//| Manage positions - all comparisons in dollars                     |
//+------------------------------------------------------------------+
void ManagePositions()
{
   int buyCount = 0, sellCount = 0;
   double buyAvg = 0, sellAvg = 0, buyLots = 0, sellLots = 0;
   CountPositions(buyCount, sellCount, buyAvg, sellAvg, buyLots, sellLots);

   //--- BUY positions
   if(buyCount > 0)
   {
      double pnlDollar = symInfo.Bid() - buyAvg;
      double tp = (buyCount > 1) ? InpGroupTPDollar : GetLiveTP();
      double sl = (buyCount > 1) ? InpGroupSLDollar : InpSLDollar;

      if(pnlDollar >= tp)
         CloseAllDirection(POSITION_TYPE_BUY, "TP +$" + DoubleToString(pnlDollar, 2));
      else if(pnlDollar <= -sl)
         CloseAllDirection(POSITION_TYPE_BUY, "SL -$" + DoubleToString(MathAbs(pnlDollar), 2));
   }

   //--- SELL positions
   if(sellCount > 0)
   {
      double pnlDollar = sellAvg - symInfo.Ask();
      double tp = (sellCount > 1) ? InpGroupTPDollar : GetLiveTP();
      double sl = (sellCount > 1) ? InpGroupSLDollar : InpSLDollar;

      if(pnlDollar >= tp)
         CloseAllDirection(POSITION_TYPE_SELL, "TP +$" + DoubleToString(pnlDollar, 2));
      else if(pnlDollar <= -sl)
         CloseAllDirection(POSITION_TYPE_SELL, "SL -$" + DoubleToString(MathAbs(pnlDollar), 2));
   }
}

//+------------------------------------------------------------------+
double GetLiveTP()
{
   if(!InpDynamicTP) return InpTPDollar;

   double atr[];
   if(CopyBuffer(hATR, 0, 0, 1, atr) < 1) return InpTPDollar;
   return CalcDynamicTP(atr[0]);
}

//+------------------------------------------------------------------+
void CloseAllDirection(ENUM_POSITION_TYPE type, string reason)
{
   double totalProfit = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Magic() != InpMagicNumber) continue;
      if(posInfo.Symbol() != Symbol()) continue;
      if(posInfo.PositionType() != type) continue;

      totalProfit += posInfo.Profit() + posInfo.Swap() + posInfo.Commission();

      for(int a = 0; a < InpRetryCount; a++)
      {
         if(trade.PositionClose(posInfo.Ticket())) break;
         if(a < InpRetryCount - 1) Sleep(InpRetryDelay);
      }
   }

   if(totalProfit > 0) winsDay++;
   else lossesDay++;

   Print("CLOSED ", (type == POSITION_TYPE_BUY ? "BUY" : "SELL"),
         " | ", reason, " | P/L: $", DoubleToString(totalProfit, 2));
}

//+------------------------------------------------------------------+
void CloseAllPositions(string reason)
{
   Print("EMERGENCY: ", reason);
   CloseAllDirection(POSITION_TYPE_BUY, reason);
   CloseAllDirection(POSITION_TYPE_SELL, reason);
}

//+------------------------------------------------------------------+
void DrawDashboard(double rsi, double mom, double atr,
                   double ef, double es, int bc, int sc, double lot)
{
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   double sp  = GetSpreadDollar();
   double dd  = (dayStartBalance > 0) ? ((dayStartBalance - eq) / dayStartBalance * 100) : 0;

   string trend = (ef > es) ? "UP" : (ef < es) ? "DOWN" : "FLAT";

   string d = "";
   d += "=== QuantumScalper v1.2 ===\n";
   d += "Bal: $" + DoubleToString(bal, 2) + " | Eq: $" + DoubleToString(eq, 2) + "\n";
   d += "Lot: " + DoubleToString(lot, 2) + (InpAutoLot ? " (auto)" : "") + "\n";
   d += "Spread: $" + DoubleToString(sp, 2) + " (avg $" + DoubleToString(avgSpreadDollar, 2) + ")" +
        (sp > InpMaxSpreadDollar ? " >>> HIGH <<<" : "") + "\n";
   d += "Trend: " + trend + " | RSI: " + DoubleToString(rsi, 1) + "\n";
   d += "Mom: $" + DoubleToString(mom, 2) + " | ATR: $" + DoubleToString(atr, 2) + "\n";
   d += "Pos: BUY=" + IntegerToString(bc) + " SELL=" + IntegerToString(sc) + "\n";
   d += "Day: " + IntegerToString(totalTradesDay) + " trades W:" + IntegerToString(winsDay) + " L:" + IntegerToString(lossesDay) + "\n";
   d += "DD: " + DoubleToString(dd, 2) + "% / " + DoubleToString(InpMaxDrawdownPct, 1) + "%\n";

   Comment(d);
}

//+------------------------------------------------------------------+
void OnTrade() { }
//+------------------------------------------------------------------+
