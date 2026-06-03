#property strict
#property version   "1.01"
#property description "Trade copier backtester. Replays a randomEA report trade tape through the full copier logic."

#include <Trade/Trade.mqh>

// Report-backed MT5 trade copier.
// This file intentionally keeps copier.mq5 logic intact and replaces only the
// sender snapshot reader with a replay reader backed by randomEA_trade_tape.csv.

#define COPIER_FILE_PREFIX "minimal_trade_copier_"
#define COPY_COMMENT_PREFIX "TC#"
#define STATS_DASHBOARD_OBJECT "MTC1_STATS_DASHBOARD"
#define PARTIAL_TP_LINE_PREFIX "MTC1_PARTIAL_TP_"

enum ENUM_COPY_MODE
{
   COPY_EXACT_SAME = 0,
   COPY_EXACT_OPPOSITE = 1
};

enum ENUM_COPIER_LOT_MODE
{
   COPIER_LOT_EXACT = 0,
   COPIER_LOT_FIXED_STARTING_BALANCE_RISK = 1,
   COPIER_LOT_CURRENT_BALANCE_RISK = 2
};

enum ENUM_COPIER_ENTRY_MODE
{
   COPIER_ENTRY_MARKET_ORDER = 0,
   COPIER_ENTRY_PENDING_ORDER = 1
};

enum ENUM_SENDER_EXIT_ACTION
{
   SENDER_EXIT_CLOSE_ALWAYS = 0,
   SENDER_EXIT_PROTECT_ALWAYS = 1,
   SENDER_EXIT_SMART_PROTECT_PROFIT_CLOSE_LOSS = 2
};

enum ENUM_SYMBOL_MODE
{
   SYMBOL_SINGLE_PAIR = 0,
   SYMBOL_MULTI_PAIR = 1
};

enum ENUM_TP_ADJUST_MODE
{
   TP_ADJUST_PRESERVE_COPIED_RR = 0,
   TP_ADJUST_TARGET_RISK_MONEY = 1
};

enum ENUM_SENDER_EXIT_REASON
{
   SENDER_EXIT_REASON_UNKNOWN = 0,
   SENDER_EXIT_REASON_SOURCE_TP = 1,
   SENDER_EXIT_REASON_SOURCE_SL = 2,
   SENDER_EXIT_REASON_RANDOM_OR_MANUAL = 3
};

enum ENUM_PROFIT_TRAIL_SL_MODE
{
   PROFIT_TRAIL_SL_TO_BREAKEVEN = 0,
   PROFIT_TRAIL_SL_REDUCE_ORIGINAL_LOSS = 1
};

enum ENUM_SENDER_EXIT_PROFIT_LOCK_BASIS
{
   SENDER_EXIT_LOCK_CURRENT_OPEN_PROFIT = 0,
   SENDER_EXIT_LOCK_FULL_TP_PROFIT = 1
};

input group "Report Replay"
input string TradeTapeFileName = "randomEA_trade_tape.csv";
input bool UseCommonFilesFolder = true;
input int EntryLatencySeconds = 0;
input long ReplaySourceLogin = 26052601;
input bool ClearReplayStateOnInit = true;
input bool SkipTradesOpenedBeforeReplayStart = true;

input group "Signal Settings"
input string CopierKey = "report_backtest";
input ENUM_COPY_MODE CopyMode = COPY_EXACT_OPPOSITE;
input ENUM_SYMBOL_MODE SymbolMode = SYMBOL_SINGLE_PAIR;
input string CustomSymbol = "";
input string SenderSymbol1 = "";
input string CopierSymbol1 = "";
input string SenderSymbol2 = "";
input string CopierSymbol2 = "";
input string SenderSymbol3 = "";
input string CopierSymbol3 = "";

input group "Entry Settings"
input ENUM_COPIER_ENTRY_MODE EntryMode = COPIER_ENTRY_MARKET_ORDER;
input bool CopyStopLossTakeProfit = true;
input bool AdjustTakeProfitToCopiedRR = true;
input ENUM_TP_ADJUST_MODE TakeProfitAdjustMode = TP_ADJUST_TARGET_RISK_MONEY;
input bool PreventReEntryAfterCopiedExit = true;
input bool EnforceOneTradePerSymbol = true;
input int MaxCopiedPositionsPerSymbol = 1;
input bool SkipSenderTradesSeenWhileSymbolBusy = true;

input group "Partial TP Booking"
input bool EnablePartialTpBooking = false;
input double PartialTpTriggerPercent = 20.0;
input double PartialTpClosePercent = 50.0;

input group "Profit Progress Trailing SL"
input bool EnableProfitProgressTrailingSL = false;
input double ProfitTrailTriggerPercent = 40.0;
input ENUM_PROFIT_TRAIL_SL_MODE ProfitTrailStopMode = PROFIT_TRAIL_SL_TO_BREAKEVEN;
input double ProfitTrailRemainingLossPercent = 0.0;

input group "Sender Exit Settings"
input ENUM_SENDER_EXIT_ACTION SenderExitAction = SENDER_EXIT_SMART_PROTECT_PROFIT_CLOSE_LOSS;
input double SenderExitProfitLockPercent = 0.0;
input ENUM_SENDER_EXIT_PROFIT_LOCK_BASIS SenderExitProfitLockBasis = SENDER_EXIT_LOCK_CURRENT_OPEN_PROFIT;
input bool UseClosestLegalStopWhenBreakevenTooClose = true;
input bool AggressiveCloseNearTpOnSenderExit = false;
input double AggressiveCloseSpreadMultiplier = 1.0;

input group "Bad Behaviour Sender Handling"
input bool BadBehaviourSenderExitDetection = false;
input double BadBehaviourTpExitProgressPercent = 50.0;
input double BadBehaviourSlExitProgressPercent = 40.0;

input group "Lot Sizing"
input double LotMultiplier = 1.0;
input ENUM_COPIER_LOT_MODE LotMode = COPIER_LOT_EXACT;
input double RiskStartingBalance = 10000.0;
input double RiskPerTradePercent = 1.0;
input double MaxFixedRiskLot = 1.0;
input bool LogRiskSizingDetails = true;

input group "Trade Execution"
input ulong MagicNumber = 26053001;
input int SlippagePoints = 30;
input int PollMilliseconds = 500;
input int TradeRetries = 5;
input int RetryDelayMilliseconds = 250;

input group "Display"
input bool ShowChartStatus = true;
input bool ShowStatsDashboard = true;

struct SourcePosition
{
   ulong ticket;
   string symbol;
   long type;
   double volume;
   double price_open;
   double sl;
   double tp;
};

struct SourceTapeTrade
{
   ulong ticket;
   datetime entry_time;
   datetime exit_time;
   string symbol;
   long type;
   double volume;
   double price_open;
   double sl;
   double tp;
   double exit_price;
   string exit_reason;
   double source_profit;
};

struct TradeStats
{
   string symbol;
   int trades;
   int wins;
   int losses;
   double net_profit;
   double gross_profit;
   double gross_loss;
};

struct CopiedPositionIdentity
{
   long identifier;
   ulong source_ticket;
   string symbol;
   long type;
};

CTrade trade;
SourcePosition sources[];
SourceTapeTrade tape_trades[];
SourcePosition last_seen_sources[];
SourcePosition remembered_source_stops[];
CopiedPositionIdentity remembered_copied_positions[];
ulong logged_missing_sltp_rr_adjust_sources[];
ulong logged_incomplete_sltp_rr_adjust_sources[];
ulong logged_no_reentry_sources[];
long source_login = 0;
datetime source_time = 0;
datetime last_successful_read = 0;
datetime replay_start_time = 0;
string last_action = "Waiting for sender signal";
string last_error = "";
int loaded_tape_trades = 0;

int OnInit()
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);

   source_login = ReplaySourceLogin;
   if(!LoadTradeTape())
      return INIT_FAILED;

   replay_start_time = TimeCurrent();

   if(ClearReplayStateOnInit)
      ClearReplayState();

   int timer_ms = PollMilliseconds;
   if(timer_ms < 100)
      timer_ms = 100;

   EventSetMillisecondTimer(timer_ms);
   SyncPositions();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   ObjectDelete(0, STATS_DASHBOARD_OBJECT);
   DeletePartialTpLines();
}

void OnTick()
{
   SyncPositions();
}

void OnTimer()
{
   SyncPositions();
}

void SyncPositions()
{
   if(!ReadSources())
   {
      last_error = "Cannot replay trade tape: " + TradeTapeFileName + " / error " + (string)GetLastError();
      UpdateDashboard();
      return;
   }

   RememberOriginalSourceStops();
   RememberActiveCopiedSourceLifecycles();
   CloseOrphanCopiedPositions();

   int total = ArraySize(sources);
   for(int i = 0; i < total; i++)
      SyncOneSource(sources[i]);

   ManageProfitProgressTrailingSL();
   ManagePartialTpBooking();
   RefreshPartialTpLines();

   UpdateDashboard();
   UpdateStatsDashboard();
   RememberLastSeenSources();
}

bool ReadSources()
{
   ArrayResize(sources, 0);

   datetime now = TimeCurrent();
   int total = ArraySize(tape_trades);
   for(int i = 0; i < total; i++)
   {
      SourceTapeTrade tape = tape_trades[i];
      if(SkipTradesOpenedBeforeReplayStart && replay_start_time > 0 && tape.entry_time < replay_start_time)
         continue;

      datetime effective_entry = tape.entry_time + MathMax(0, EntryLatencySeconds);
      if(now < effective_entry)
         continue;
      if(tape.exit_time > 0 && now >= tape.exit_time)
         continue;

      SourcePosition src;
      src.ticket = tape.ticket;
      src.symbol = tape.symbol;
      src.type = tape.type;
      src.volume = tape.volume;
      src.price_open = tape.price_open;
      src.sl = tape.sl;
      src.tp = tape.tp;

      int size = ArraySize(sources);
      ArrayResize(sources, size + 1);
      sources[size] = src;
   }

   source_login = ReplaySourceLogin;
   source_time = now;
   last_successful_read = TimeCurrent();
   last_error = "";
   return true;
}

bool LoadTradeTape()
{
   ArrayResize(tape_trades, 0);

   int flags = FILE_READ | FILE_CSV | FILE_ANSI | FILE_SHARE_READ | FILE_SHARE_WRITE;
   if(UseCommonFilesFolder)
      flags |= FILE_COMMON;

   int handle = FileOpen(TradeTapeFileName, flags, '\n');
   if(handle == INVALID_HANDLE)
   {
      last_error = "Cannot open trade tape " + TradeTapeFileName + " / error " + (string)GetLastError();
      Print(last_error);
      return false;
   }

   string first_header = "";
   if(!FileIsEnding(handle))
      first_header = CleanCsvCell(FileReadString(handle));

   if(StringFind(first_header, "source_ticket") != 0)
   {
      FileClose(handle);
      last_error = "Trade tape header is not recognized in " + TradeTapeFileName +
                   " | first line: [" + first_header + "]";
      Print(last_error);
      return false;
   }

   int skipped_rows = 0;
   string first_data_line = "";
   string first_skipped_line = "";

   while(!FileIsEnding(handle))
   {
      string line = FileReadString(handle);
      StringTrimLeft(line);
      StringTrimRight(line);
      if(line == "")
         break;

      if(first_data_line == "")
         first_data_line = line;

      string fields[];
      int field_count = StringSplit(line, ';', fields);
      if(field_count < 12)
      {
         skipped_rows++;
         if(first_skipped_line == "")
            first_skipped_line = "fields=" + (string)field_count + " line=[" + line + "]";
         continue;
      }

      SourceTapeTrade tape;
      tape.ticket = (ulong)StringToInteger(CleanCsvCell(fields[0]));
      tape.entry_time = StringToTime(CleanCsvCell(fields[1]));
      tape.exit_time = StringToTime(CleanCsvCell(fields[2]));
      tape.symbol = CleanCsvCell(fields[3]);
      tape.type = SourceTypeFromText(CleanCsvCell(fields[4]));
      tape.volume = StringToDouble(CleanCsvCell(fields[5]));
      tape.price_open = StringToDouble(CleanCsvCell(fields[6]));
      tape.sl = StringToDouble(CleanCsvCell(fields[7]));
      tape.tp = StringToDouble(CleanCsvCell(fields[8]));
      tape.exit_price = StringToDouble(CleanCsvCell(fields[9]));
      tape.exit_reason = CleanCsvCell(fields[10]);
      tape.source_profit = StringToDouble(CleanCsvCell(fields[11]));

      if(tape.ticket > 0 && tape.entry_time > 0 && tape.symbol != "" && tape.volume > 0.0)
      {
         int size = ArraySize(tape_trades);
         ArrayResize(tape_trades, size + 1);
         tape_trades[size] = tape;
      }
      else
      {
         skipped_rows++;
         if(first_skipped_line == "")
         {
            first_skipped_line = "parsed ticket=" + (string)tape.ticket +
                                 " entry=" + TimeToString(tape.entry_time, TIME_DATE | TIME_SECONDS) +
                                 " symbol=[" + tape.symbol + "] volume=" + DoubleToString(tape.volume, 8) +
                                 " line=[" + line + "]";
         }
      }
   }

   FileClose(handle);
   loaded_tape_trades = ArraySize(tape_trades);
   if(loaded_tape_trades <= 0)
   {
      last_error = "Trade tape loaded 0 rows from " + TradeTapeFileName +
                   " | header=[" + first_header + "]" +
                   " | first data=[" + first_data_line + "]" +
                   " | skipped=" + (string)skipped_rows +
                   " | first skipped=[" + first_skipped_line + "]";
      Print(last_error);
      return false;
   }

   last_action = "Loaded report trade tape: " + (string)loaded_tape_trades + " source trades";
   if(skipped_rows > 0)
      last_action += " (" + (string)skipped_rows + " skipped rows)";
   Print(last_action);
   return true;
}

long SourceTypeFromText(string text)
{
   StringToLower(text);
   if(text == "buy")
      return POSITION_TYPE_BUY;
   return POSITION_TYPE_SELL;
}

string CleanCsvCell(string value)
{
   StringTrimLeft(value);
   StringTrimRight(value);

   while(StringLen(value) > 0)
   {
      ushort last = StringGetCharacter(value, StringLen(value) - 1);
      if(last != '\r' && last != '\n')
         break;
      value = StringSubstr(value, 0, StringLen(value) - 1);
      StringTrimRight(value);
   }

   if(StringLen(value) > 0 && StringGetCharacter(value, 0) == 0xFEFF)
      value = StringSubstr(value, 1);

   if(StringLen(value) >= 2 &&
      StringGetCharacter(value, 0) == '"' &&
      StringGetCharacter(value, StringLen(value) - 1) == '"')
   {
      value = StringSubstr(value, 1, StringLen(value) - 2);
   }

   return value;
}

void ClearReplayState()
{
   int total = ArraySize(tape_trades);
   for(int i = 0; i < total; i++)
   {
      GlobalVariableDel(SourceLifecycleGlobalName(tape_trades[i].ticket));
      GlobalVariableDel(SourceExitProtectedGlobalName(tape_trades[i].ticket));
      GlobalVariableDel(SourceSkippedGlobalName(tape_trades[i].ticket));
      GlobalVariableDel(SourcePartialTpBookedGlobalName(tape_trades[i].ticket));
      GlobalVariableDel(SourceProfitTrailGlobalName(tape_trades[i].ticket));
   }

   ArrayResize(logged_missing_sltp_rr_adjust_sources, 0);
   ArrayResize(logged_incomplete_sltp_rr_adjust_sources, 0);
   ArrayResize(remembered_copied_positions, 0);
}

void SyncOneSource(const SourcePosition &src)
{
   string target_symbol = TargetSymbol(src.symbol);
   if(target_symbol == "")
   {
      last_action = "Skipping source #" + (string)src.ticket + " because sender symbol " + src.symbol + " is not configured";
      return;
   }

   if(!SymbolSelect(target_symbol, true))
   {
      last_error = "Cannot select target symbol " + target_symbol + " for source #" + (string)src.ticket;
      return;
   }

   double copied_volume = 0.0;
   double pending_volume = 0.0;
   bool wrong_position_found = false;
   string wanted_comment = CopyComment(src.ticket);
   long target_type = TargetType(src.type);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOurCopiedPosition())
         continue;

      if(SourceTicketFromSelectedPosition() != src.ticket)
         continue;

      string symbol = PositionGetString(POSITION_SYMBOL);
      long type = PositionGetInteger(POSITION_TYPE);
      double volume = PositionGetDouble(POSITION_VOLUME);

      if(symbol != target_symbol || type != target_type)
      {
         wrong_position_found = true;
         last_action = "Closing mismatched copied trade for source #" + (string)src.ticket;
         ClosePosition(ticket);
      }
      else
      {
         copied_volume += volume;
         if(CopyStopLossTakeProfit && AdjustTakeProfitToCopiedRR)
            AdjustTakeProfitToCopiedRRMoney(src, target_symbol, target_type, wanted_comment);
      }
   }

   if(wrong_position_found)
      copied_volume = CurrentCopiedVolume(src.ticket, target_symbol, target_type);

   double step = SymbolInfoDouble(target_symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0)
      step = 0.01;

   if(IsPendingEntryMode())
      pending_volume = CurrentCopiedPendingVolume(src.ticket, target_symbol, PendingTypeForSource(src, target_symbol, target_type));
   else
      DeleteCopiedPendingOrdersForSource(src.ticket);

   double active_volume = copied_volume + pending_volume;

   if(EnforceOneTradePerSymbol && SkippedSourceAlreadyMarked(src.ticket) && active_volume <= step / 2.0)
   {
      last_action = "Skipping stale source #" + (string)src.ticket + " on " + target_symbol +
                    "; it appeared while another copied trade/order was still active. Waiting for a fresh sender ticket.";
      return;
   }

   string busy_details = "";
   if(EnforceOneTradePerSymbol &&
      active_volume <= step / 2.0 &&
      CopiedExposureLimitReachedForSymbol(target_symbol, src.ticket, busy_details))
   {
      bool already_marked_stale = SkippedSourceAlreadyMarked(src.ticket);
      if(SkipSenderTradesSeenWhileSymbolBusy)
         MarkSourceSkippedWhileSymbolBusy(src.ticket);

      last_action = "Symbol exposure limit: source #" + (string)src.ticket + " " + src.symbol +
                    " maps to " + target_symbol + " but " + busy_details +
                    ". Skipping this sender ticket as stale; copier will wait for a fresh trade after the symbol has capacity.";
      if(!already_marked_stale)
         Print(last_action);
      return;
   }

   if(IsPendingEntryMode())
      pending_volume = SyncPendingOrdersForSource(src, target_symbol, target_type);

   active_volume = copied_volume + pending_volume;

   if(active_volume > step / 2.0)
      MarkSourceLifecycleStarted(src.ticket);

   if(PreventReEntryAfterCopiedExit && active_volume <= step / 2.0 && SourceLifecycleAlreadyStarted(src.ticket))
   {
      last_action = "Source #" + (string)src.ticket + " was already copied and exited; no re-entry";
      if(MarkSourceLoggedOnce(logged_no_reentry_sources, src.ticket))
         Print(last_action);
      return;
   }

   double desired_volume = 0.0;
   if(IsRiskLotMode() && active_volume > 0.0)
      desired_volume = active_volume;
   else
      desired_volume = DesiredCopiedVolume(src, target_symbol, target_type, false);

   if(SourcePartialTpAlreadyBooked(src.ticket))
      desired_volume *= 1.0 - (PartialTpClosePercentClamped() / 100.0);

   if(desired_volume <= 0.0)
      return;

   if(copied_volume > desired_volume + (step / 2.0))
   {
      last_action = "Reducing copied volume for source #" + (string)src.ticket;
      ReduceCopiedVolume(src.ticket, target_symbol, target_type, copied_volume - desired_volume);
   }
   else if(active_volume > desired_volume + (step / 2.0) && pending_volume > 0.0)
   {
      last_action = "Reducing pending copied volume for source #" + (string)src.ticket;
      ReduceCopiedPendingVolume(src.ticket, target_symbol, PendingTypeForSource(src, target_symbol, target_type), active_volume - desired_volume);
   }
   else if(active_volume + (step / 2.0) < desired_volume)
   {
      if(IsPendingEntryMode())
      {
         last_action = "Placing pending copied order for source #" + (string)src.ticket;
         if(OpenCopiedPendingOrder(src, target_symbol, target_type, desired_volume - active_volume))
            MarkSourceLifecycleStarted(src.ticket);
      }
      else
      {
         last_action = "Opening copied trade for source #" + (string)src.ticket;
         if(OpenCopiedPosition(src, target_symbol, target_type, desired_volume - copied_volume))
            MarkSourceLifecycleStarted(src.ticket);
      }
   }
   else
   {
      last_action = "Synced source #" + (string)src.ticket + " -> " + target_symbol + " " + PositionTypeName(target_type);
   }
}

void CloseOrphanCopiedPositions()
{
   CloseOrphanCopiedPendingOrders();

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOurCopiedPosition())
         continue;

      ulong source_ticket = SourceTicketFromSelectedPosition();
      if(source_ticket > 0 && !SourceExists(source_ticket))
      {
         HandleCopiedPositionAfterSenderExit(ticket, source_ticket);
      }
   }
}

void HandleCopiedPositionAfterSenderExit(const ulong ticket, const ulong source_ticket)
{
   if(EnableProfitProgressTrailingSL)
   {
      last_action = "Closing copied trade because source #" + (string)source_ticket +
                    " exited; profit-progress trailing SL mode is active";
      ClosePosition(ticket);
      return;
   }

   if(SourceExitAlreadyProtected(source_ticket))
   {
      if(CopiedPositionIsProfitable(ticket))
         LockProfitAfterSenderExit(ticket);

      last_action = "Copied trade for source #" + (string)source_ticket + " is already in sender-exit protection";
      return;
   }

   if(AggressiveCloseNearTpOnSenderExit && TryAggressiveCloseNearTpAfterSenderExit(ticket, source_ticket))
      return;

   if(BadBehaviourSenderExitDetection && HandleCopiedPositionByDetectedSenderExit(ticket, source_ticket))
      return;

   if(SenderExitAction == SENDER_EXIT_CLOSE_ALWAYS)
   {
      last_action = "Closing copied trade because source #" + (string)source_ticket + " exited";
      ClosePosition(ticket);
      return;
   }

   if(SenderExitAction == SENDER_EXIT_PROTECT_ALWAYS)
   {
      last_action = "Protecting copied trade because source #" + (string)source_ticket + " exited";
      MarkSourceExitProtected(source_ticket);
      if(!LockProfitAfterSenderExit(ticket))
      {
         last_action = "Profit lock could not be modified yet for source #" + (string)source_ticket + "; leaving copied trade open";
      }
      return;
   }

   if(CopiedPositionIsProfitable(ticket))
   {
      last_action = "Sender source #" + (string)source_ticket + " exited while copied trade is profitable; applying protection";
      MarkSourceExitProtected(source_ticket);
      if(!LockProfitAfterSenderExit(ticket))
      {
         last_action = "Profit lock could not be modified yet for source #" + (string)source_ticket + "; leaving profitable copied trade open";
      }
      return;
   }

   last_action = "Closing copied trade because source #" + (string)source_ticket + " exited while copied trade is not profitable";
   ClosePosition(ticket);
}

bool HandleCopiedPositionByDetectedSenderExit(const ulong ticket, const ulong source_ticket)
{
   SourcePosition last_src;
   if(!FindLastSeenSource(source_ticket, last_src))
      return false;

   ENUM_SENDER_EXIT_REASON reason = DetectSourceExitReason(last_src);
   if(reason == SENDER_EXIT_REASON_UNKNOWN)
      return false;

   if(reason == SENDER_EXIT_REASON_SOURCE_TP)
   {
      last_action = "Closing copied trade because sender source #" + (string)source_ticket +
                    " appears to have exited at TP";
      Print(last_action);
      ClosePosition(ticket);
      return true;
   }

   if(reason == SENDER_EXIT_REASON_SOURCE_SL)
   {
      last_action = "Protecting copied trade because sender source #" + (string)source_ticket +
                    " appears to have exited at SL";
      Print(last_action);
      MarkSourceExitProtected(source_ticket);
      if(!LockProfitAfterSenderExit(ticket))
      {
         last_action = "Sender source #" + (string)source_ticket +
                       " appears to have hit SL, but breakeven/profit lock could not be placed yet";
      }
      return true;
   }

   if(reason == SENDER_EXIT_REASON_RANDOM_OR_MANUAL)
   {
      last_action = "Closing copied trade because sender source #" + (string)source_ticket +
                    " exited away from TP/SL, likely random/manual exit";
      Print(last_action);
      ClosePosition(ticket);
      return true;
   }

   return false;
}

bool CopiedPositionIsProfitable(const ulong ticket)
{
   if(!PositionSelectByTicket(ticket))
      return false;

   double floating_profit = PositionGetDouble(POSITION_PROFIT) +
                            PositionGetDouble(POSITION_SWAP);
   if(floating_profit > 0.0)
      return true;

   string symbol = PositionGetString(POSITION_SYMBOL);
   long type = PositionGetInteger(POSITION_TYPE);
   double entry = PositionGetDouble(POSITION_PRICE_OPEN);
   double current = (type == POSITION_TYPE_BUY ? SymbolInfoDouble(symbol, SYMBOL_BID) : SymbolInfoDouble(symbol, SYMBOL_ASK));

   if(entry <= 0.0 || current <= 0.0)
      return false;

   if(type == POSITION_TYPE_BUY)
      return current > entry;

   return current < entry;
}

bool TryAggressiveCloseNearTpAfterSenderExit(const ulong ticket, const ulong source_ticket)
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);

   if(!PositionSelectByTicket(ticket))
      return true;

   string symbol = PositionGetString(POSITION_SYMBOL);
   long type = PositionGetInteger(POSITION_TYPE);
   double entry = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl = PositionGetDouble(POSITION_SL);
   double tp = PositionGetDouble(POSITION_TP);
   double volume = PositionGetDouble(POSITION_VOLUME);
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);

   if(entry <= 0.0 || tp <= 0.0 || volume <= 0.0 || bid <= 0.0 || ask <= 0.0)
      return false;

   double spread = MathAbs(ask - bid) * MathMax(0.0, AggressiveCloseSpreadMultiplier);
   double raw_spread = MathAbs(ask - bid);
   double trigger_tp = tp;
   double current = bid;
   bool reached = false;

   if(type == POSITION_TYPE_BUY)
   {
      trigger_tp = tp - spread;
      current = bid;
      reached = (current >= trigger_tp);
      if(trigger_tp <= entry)
      {
         PrintFormat("Aggressive sender-exit TP skipped source #%I64u ticket #%I64u: adjusted BUY TP %.5f is not above entry %.5f",
                     source_ticket, ticket, trigger_tp, entry);
         return false;
      }
   }
   else
   {
      trigger_tp = tp + spread;
      current = ask;
      reached = (current <= trigger_tp);
      if(trigger_tp >= entry)
      {
         PrintFormat("Aggressive sender-exit TP skipped source #%I64u ticket #%I64u: adjusted SELL TP %.5f is not below entry %.5f",
                     source_ticket, ticket, trigger_tp, entry);
         return false;
      }
   }

   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double original_tp_profit = ProfitAtPrice(symbol, type, volume, entry, tp);
   double trigger_tp_profit = ProfitAtPrice(symbol, type, volume, entry, trigger_tp);

   if(reached)
   {
      last_action = "Aggressive sender-exit TP close: source #" + (string)source_ticket +
                    " exited and copied trade #" + (string)ticket +
                    " reached spread-adjusted TP " + DoubleToString(trigger_tp, digits) +
                    " (current " + DoubleToString(current, digits) +
                    ", original TP " + DoubleToString(tp, digits) +
                    ", spread " + DoubleToString(raw_spread, digits) +
                    " x" + DoubleToString(MathMax(0.0, AggressiveCloseSpreadMultiplier), 2) +
                    ", original TP profit $" + DoubleToString(original_tp_profit, 2) +
                    ", adjusted TP profit $" + DoubleToString(trigger_tp_profit, 2) + ")";
      Print(last_action);
      ClosePosition(ticket);
      return true;
   }

   double adjusted_tp = FitTakeProfitToBrokerLimits(symbol, type, trigger_tp);
   adjusted_tp = NormalizePrice(symbol, adjusted_tp);
   if(adjusted_tp <= 0.0)
      return false;

   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(point <= 0.0)
      point = 0.00001;

   bool improves_tp = false;
   if(type == POSITION_TYPE_BUY)
      improves_tp = (adjusted_tp < tp - point / 2.0 && adjusted_tp > entry);
   else
      improves_tp = (adjusted_tp > tp + point / 2.0 && adjusted_tp < entry);

   if(!improves_tp)
   {
      PrintFormat("Aggressive sender-exit TP no-change source #%I64u ticket #%I64u: current %.5f has not reached adjusted TP %.5f; existing TP %.5f is already equal/better | spread %.5f x%.2f | original TP profit $%.2f | adjusted TP profit $%.2f",
                  source_ticket,
                  ticket,
                  current,
                  adjusted_tp,
                  tp,
                  raw_spread,
                  MathMax(0.0, AggressiveCloseSpreadMultiplier),
                  original_tp_profit,
                  trigger_tp_profit);
      return false;
   }

   ResetLastError();
   double adjusted_tp_profit = ProfitAtPrice(symbol, type, volume, entry, adjusted_tp);
   if(trade.PositionModify(ticket, sl, adjusted_tp))
   {
      last_action = "Aggressive sender-exit TP armed: moved copied trade #" + (string)ticket +
                    " TP from " + DoubleToString(tp, digits) +
                    " to spread-adjusted " + DoubleToString(adjusted_tp, digits) +
                    " after source #" + (string)source_ticket +
                    " exited; spread " + DoubleToString(raw_spread, digits) +
                    " x" + DoubleToString(MathMax(0.0, AggressiveCloseSpreadMultiplier), 2) +
                    ", original TP profit $" + DoubleToString(original_tp_profit, 2) +
                    ", new TP profit $" + DoubleToString(adjusted_tp_profit, 2) +
                    "; normal sender-exit protection still applies";
      Print(last_action);
      return false;
   }

   RememberTradeError("Aggressive sender-exit TP modify failed ticket #" + (string)ticket);
   return false;
}

double ProfitAtPrice(const string symbol,
                     const long type,
                     const double volume,
                     const double entry,
                     const double exit_price)
{
   if(volume <= 0.0 || entry <= 0.0 || exit_price <= 0.0)
      return 0.0;

   ENUM_ORDER_TYPE order_type = (type == POSITION_TYPE_BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   double profit = 0.0;
   if(!OrderCalcProfit(order_type, symbol, volume, entry, exit_price, profit))
      return 0.0;

   return profit;
}

bool SourceExists(const ulong source_ticket)
{
   int total = ArraySize(sources);
   for(int i = 0; i < total; i++)
   {
      if(sources[i].ticket == source_ticket)
         return true;
   }
   return false;
}

void RememberLastSeenSources()
{
   int total = ArraySize(sources);
   ArrayResize(last_seen_sources, total);

   for(int i = 0; i < total; i++)
      last_seen_sources[i] = sources[i];
}

void RememberOriginalSourceStops()
{
   int total = ArraySize(sources);
   for(int i = 0; i < total; i++)
   {
      int index = FindRememberedSourceStopIndex(sources[i].ticket);
      if(index < 0)
      {
         int size = ArraySize(remembered_source_stops);
         ArrayResize(remembered_source_stops, size + 1);
         remembered_source_stops[size] = sources[i];
         continue;
      }

      if(remembered_source_stops[index].price_open <= 0.0 && sources[i].price_open > 0.0)
         remembered_source_stops[index].price_open = sources[i].price_open;
      if(remembered_source_stops[index].sl <= 0.0 && sources[i].sl > 0.0)
         remembered_source_stops[index].sl = sources[i].sl;
      if(remembered_source_stops[index].tp <= 0.0 && sources[i].tp > 0.0)
         remembered_source_stops[index].tp = sources[i].tp;
   }
}

int FindRememberedSourceStopIndex(const ulong source_ticket)
{
   int total = ArraySize(remembered_source_stops);
   for(int i = 0; i < total; i++)
   {
      if(remembered_source_stops[i].ticket == source_ticket)
         return i;
   }

   return -1;
}

bool ApplyRememberedSourceStops(SourcePosition &src)
{
   int index = FindRememberedSourceStopIndex(src.ticket);
   if(index < 0)
      return false;

   bool changed = false;
   if(src.price_open <= 0.0 && remembered_source_stops[index].price_open > 0.0)
   {
      src.price_open = remembered_source_stops[index].price_open;
      changed = true;
   }
   if(src.sl <= 0.0 && remembered_source_stops[index].sl > 0.0)
   {
      src.sl = remembered_source_stops[index].sl;
      changed = true;
   }
   if(src.tp <= 0.0 && remembered_source_stops[index].tp > 0.0)
   {
      src.tp = remembered_source_stops[index].tp;
      changed = true;
   }

   return changed;
}

bool MarkSourceLoggedOnce(ulong &logged_sources[], const ulong source_ticket)
{
   if(source_ticket == 0)
      return false;

   int total = ArraySize(logged_sources);
   for(int i = 0; i < total; i++)
   {
      if(logged_sources[i] == source_ticket)
         return false;
   }

   ArrayResize(logged_sources, total + 1);
   logged_sources[total] = source_ticket;
   return true;
}

bool FindLastSeenSource(const ulong source_ticket, SourcePosition &src)
{
   int total = ArraySize(last_seen_sources);
   for(int i = 0; i < total; i++)
   {
      if(last_seen_sources[i].ticket == source_ticket)
      {
         src = last_seen_sources[i];
         return true;
      }
   }

   return false;
}

ENUM_SENDER_EXIT_REASON DetectSourceExitReason(const SourcePosition &src)
{
   double current_price = SourceExitReferencePrice(src);
   if(current_price <= 0.0)
   {
      Print("Copier sender-exit detection | Source #" + (string)src.ticket +
            " disappeared, but current source price is unavailable");
      return SENDER_EXIT_REASON_UNKNOWN;
   }

   SourcePosition reference_src = src;
   bool used_remembered_stops = ApplyRememberedSourceStops(reference_src);
   double tp_progress = SourceTpProgressPercent(reference_src, current_price);
   double sl_progress = SourceSlProgressPercent(reference_src, current_price);
   double tp_threshold = MathMax(0.0, MathMin(100.0, BadBehaviourTpExitProgressPercent));
   double sl_threshold = MathMax(0.0, MathMin(100.0, BadBehaviourSlExitProgressPercent));
   string remembered_text = (used_remembered_stops ? "yes" : "no");

   PrintFormat("Copier sender-exit detection | Source #%I64u disappeared | LastType=%s | CurrentPrice=%.5f | Entry=%.5f | LastSL=%.5f | LastTP=%.5f | RememberedStops=%s | SLProgress=%.1f%%/%.1f%% | TPProgress=%.1f%%/%.1f%%",
               reference_src.ticket,
               PositionTypeName(reference_src.type),
               current_price,
               reference_src.price_open,
               reference_src.sl,
               reference_src.tp,
               remembered_text,
               sl_progress,
               sl_threshold,
               tp_progress,
               tp_threshold);

   if(tp_progress >= tp_threshold && tp_threshold > 0.0)
      return SENDER_EXIT_REASON_SOURCE_TP;

   if(sl_progress >= sl_threshold && sl_threshold > 0.0)
      return SENDER_EXIT_REASON_SOURCE_SL;

   return SENDER_EXIT_REASON_RANDOM_OR_MANUAL;
}

double SourceTpProgressPercent(const SourcePosition &src, const double current_price)
{
   if(src.price_open <= 0.0 || src.tp <= 0.0 || current_price <= 0.0)
      return 0.0;

   double full_distance = MathAbs(src.tp - src.price_open);
   if(full_distance <= 0.0)
      return 0.0;

   double moved = 0.0;
   if(src.type == POSITION_TYPE_BUY)
      moved = current_price - src.price_open;
   else
      moved = src.price_open - current_price;

   return MathMax(0.0, MathMin(100.0, (moved / full_distance) * 100.0));
}

double SourceSlProgressPercent(const SourcePosition &src, const double current_price)
{
   if(src.price_open <= 0.0 || src.sl <= 0.0 || current_price <= 0.0)
      return 0.0;

   double full_distance = MathAbs(src.price_open - src.sl);
   if(full_distance <= 0.0)
      return 0.0;

   double moved = 0.0;
   if(src.type == POSITION_TYPE_BUY)
      moved = src.price_open - current_price;
   else
      moved = current_price - src.price_open;

   return MathMax(0.0, MathMin(100.0, (moved / full_distance) * 100.0));
}

double SourceExitReferencePrice(const SourcePosition &src)
{
   string symbol = SourceExitReferenceSymbol(src);
   if(symbol == "")
      return 0.0;

   if(!SymbolSelect(symbol, true))
      return 0.0;

   if(src.type == POSITION_TYPE_BUY)
      return SymbolInfoDouble(symbol, SYMBOL_BID);

   return SymbolInfoDouble(symbol, SYMBOL_ASK);
}

string SourceExitReferenceSymbol(const SourcePosition &src)
{
   if(src.symbol != "" && SymbolInfoDouble(src.symbol, SYMBOL_POINT) > 0.0)
      return src.symbol;

   string target_symbol = TargetSymbol(src.symbol);
   if(target_symbol != "")
      return target_symbol;

   return src.symbol;
}

void RememberActiveCopiedSourceLifecycles()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOurCopiedPosition())
         continue;

      ulong source_ticket = SourceTicketFromSelectedPosition();
      if(source_ticket > 0)
         MarkSourceLifecycleStarted(source_ticket);
   }

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !IsOurCopiedOrder())
         continue;

      ulong source_ticket = SourceTicketFromComment(OrderGetString(ORDER_COMMENT));
      if(source_ticket > 0)
         MarkSourceLifecycleStarted(source_ticket);
   }
}

bool SourceLifecycleAlreadyStarted(const ulong source_ticket)
{
   return GlobalVariableCheck(SourceLifecycleGlobalName(source_ticket));
}

void MarkSourceLifecycleStarted(const ulong source_ticket)
{
   if(source_ticket == 0)
      return;

   GlobalVariableSet(SourceLifecycleGlobalName(source_ticket), (double)TimeCurrent());
}

bool SourceExitAlreadyProtected(const ulong source_ticket)
{
   return GlobalVariableCheck(SourceExitProtectedGlobalName(source_ticket));
}

void MarkSourceExitProtected(const ulong source_ticket)
{
   if(source_ticket == 0)
      return;

   GlobalVariableSet(SourceExitProtectedGlobalName(source_ticket), (double)TimeCurrent());
}

bool SkippedSourceAlreadyMarked(const ulong source_ticket)
{
   return GlobalVariableCheck(SourceSkippedGlobalName(source_ticket));
}

void MarkSourceSkippedWhileSymbolBusy(const ulong source_ticket)
{
   if(source_ticket == 0)
      return;

   if(!SkippedSourceAlreadyMarked(source_ticket))
      GlobalVariableSet(SourceSkippedGlobalName(source_ticket), (double)TimeCurrent());
}

bool SourcePartialTpAlreadyBooked(const ulong source_ticket)
{
   return GlobalVariableCheck(SourcePartialTpBookedGlobalName(source_ticket));
}

void MarkSourcePartialTpBooked(const ulong source_ticket)
{
   if(source_ticket == 0)
      return;

   GlobalVariableSet(SourcePartialTpBookedGlobalName(source_ticket), (double)TimeCurrent());
}

bool SourceProfitTrailAlreadyApplied(const ulong source_ticket)
{
   return GlobalVariableCheck(SourceProfitTrailGlobalName(source_ticket));
}

void MarkSourceProfitTrailApplied(const ulong source_ticket)
{
   if(source_ticket == 0)
      return;

   GlobalVariableSet(SourceProfitTrailGlobalName(source_ticket), (double)TimeCurrent());
}

string SourceLifecycleGlobalName(const ulong source_ticket)
{
   return "MTC1_" + (string)MagicNumber + "_" + ShortSafeKey(CopierKey, 12) + "_" + (string)source_login + "_" + (string)source_ticket;
}

string SourceExitProtectedGlobalName(const ulong source_ticket)
{
   return "MTC1_PROT_" + (string)MagicNumber + "_" + ShortSafeKey(CopierKey, 12) + "_" + (string)source_login + "_" + (string)source_ticket;
}

string SourceSkippedGlobalName(const ulong source_ticket)
{
   return "MTC1_SKIP_" + (string)MagicNumber + "_" + ShortSafeKey(CopierKey, 12) + "_" + (string)source_login + "_" + (string)source_ticket;
}

string SourcePartialTpBookedGlobalName(const ulong source_ticket)
{
   return "MTC1_PTP_" + (string)MagicNumber + "_" + ShortSafeKey(CopierKey, 12) + "_" + (string)source_login + "_" + (string)source_ticket;
}

string SourceProfitTrailGlobalName(const ulong source_ticket)
{
   return "MTC1_PTRAIL_" + (string)MagicNumber + "_" + ShortSafeKey(CopierKey, 12) + "_" + (string)source_login + "_" + (string)source_ticket;
}

string ShortSafeKey(const string value, const int max_length)
{
   string key = SafeKey(value);
   if(max_length > 0 && StringLen(key) > max_length)
      key = StringSubstr(key, 0, max_length);

   if(key == "")
      key = "default";

   return key;
}

double CurrentCopiedVolume(const ulong source_ticket, const string symbol, const long type)
{
   double volume = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOurCopiedPosition())
         continue;

      if(SourceTicketFromSelectedPosition() == source_ticket &&
         PositionGetString(POSITION_SYMBOL) == symbol &&
         PositionGetInteger(POSITION_TYPE) == type)
      {
         volume += PositionGetDouble(POSITION_VOLUME);
      }
   }

   return volume;
}

double CurrentCopiedPendingVolume(const ulong source_ticket, const string symbol, const ENUM_ORDER_TYPE type)
{
   double volume = 0.0;
   string wanted_comment = CopyComment(source_ticket);

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !IsOurCopiedOrder())
         continue;

      if(OrderGetString(ORDER_COMMENT) == wanted_comment &&
         OrderGetString(ORDER_SYMBOL) == symbol &&
         (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) == type)
      {
         volume += OrderGetDouble(ORDER_VOLUME_CURRENT);
      }
   }

   return volume;
}

bool CopiedExposureLimitReachedForSymbol(const string symbol, const ulong source_ticket, string &details)
{
   int max_positions = MaxCopiedPositionsAllowedPerSymbol();
   if(max_positions <= 0)
   {
      details = "";
      return false;
   }

   int exposure_count = CountOtherCopiedExposureForSymbol(symbol, source_ticket, details);
   if(exposure_count < max_positions)
   {
      details = "";
      return false;
   }

   details = (string)exposure_count + "/" + (string)max_positions + " copied position/order slot(s) are already used on " + symbol +
             (details == "" ? "" : "; " + details);
   return true;
}

int CountOtherCopiedExposureForSymbol(const string symbol, const ulong source_ticket, string &first_detail)
{
   int count = 0;
   first_detail = "";

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOurCopiedPosition())
         continue;

      if(PositionGetString(POSITION_SYMBOL) != symbol)
         continue;

      ulong other_source = SourceTicketFromSelectedPosition();
      if(other_source == source_ticket)
         continue;

      count++;
      if(first_detail == "")
         first_detail = "copied position #" + (string)ticket + " from source #" + (string)other_source;
   }

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !IsOurCopiedOrder())
         continue;

      if(OrderGetString(ORDER_SYMBOL) != symbol)
         continue;

      ulong other_source = SourceTicketFromComment(OrderGetString(ORDER_COMMENT));
      if(other_source == source_ticket)
         continue;

      count++;
      if(first_detail == "")
         first_detail = "copied pending order #" + (string)ticket + " from source #" + (string)other_source;
   }

   return count;
}

int MaxCopiedPositionsAllowedPerSymbol()
{
   if(MaxCopiedPositionsPerSymbol <= 0)
      return 0;

   return MaxCopiedPositionsPerSymbol;
}

void ReduceCopiedVolume(const ulong source_ticket, const string symbol, const long type, double volume_to_close)
{
   for(int i = PositionsTotal() - 1; i >= 0 && volume_to_close > 0.0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOurCopiedPosition())
         continue;

      if(SourceTicketFromSelectedPosition() != source_ticket ||
         PositionGetString(POSITION_SYMBOL) != symbol ||
         PositionGetInteger(POSITION_TYPE) != type)
      {
         continue;
      }

      double position_volume = PositionGetDouble(POSITION_VOLUME);
      double close_volume = MathMin(position_volume, volume_to_close);
      close_volume = NormalizeVolume(symbol, close_volume);

      if(close_volume > 0.0)
      {
         if(close_volume >= position_volume)
            ClosePosition(ticket);
         else
            ClosePartialPosition(ticket, close_volume);
      }

      volume_to_close -= close_volume;
   }
}

void ManagePartialTpBooking()
{
   if(!EnablePartialTpBooking)
      return;

   double trigger_percent = PartialTpTriggerPercentClamped();
   double close_percent = PartialTpClosePercentClamped();
   if(trigger_percent <= 0.0 || close_percent <= 0.0)
      return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOurCopiedPosition())
         continue;

      ulong source_ticket = SourceTicketFromSelectedPosition();
      if(source_ticket == 0 || SourcePartialTpAlreadyBooked(source_ticket))
         continue;

      TryBookPartialAtTpProgress(ticket, source_ticket, trigger_percent, close_percent);
   }
}

void RefreshPartialTpLines()
{
   DeletePartialTpLines();

   if(!EnablePartialTpBooking)
      return;

   double trigger_percent = PartialTpTriggerPercentClamped();
   double close_percent = PartialTpClosePercentClamped();
   if(trigger_percent <= 0.0 || close_percent <= 0.0)
      return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOurCopiedPosition())
         continue;

      string symbol = PositionGetString(POSITION_SYMBOL);
      if(symbol != _Symbol)
         continue;

      ulong source_ticket = SourceTicketFromSelectedPosition();
      if(source_ticket == 0 || SourcePartialTpAlreadyBooked(source_ticket))
         continue;

      double trigger_price = PartialTpTriggerPriceForPosition(symbol,
                                                              PositionGetInteger(POSITION_TYPE),
                                                              PositionGetDouble(POSITION_PRICE_OPEN),
                                                              PositionGetDouble(POSITION_TP),
                                                              trigger_percent);
      if(trigger_price <= 0.0)
         continue;

      DrawPartialTpLine(source_ticket, symbol, trigger_price, close_percent, trigger_percent);
   }
}

double PartialTpTriggerPriceForPosition(const string symbol,
                                        const long type,
                                        const double entry,
                                        const double tp,
                                        const double trigger_percent)
{
   if(entry <= 0.0 || tp <= 0.0)
      return 0.0;

   if(type == POSITION_TYPE_BUY && tp <= entry)
      return 0.0;
   if(type == POSITION_TYPE_SELL && tp >= entry)
      return 0.0;

   double price = entry + ((tp - entry) * (trigger_percent / 100.0));
   return NormalizePrice(symbol, price);
}

void DrawPartialTpLine(const ulong source_ticket,
                       const string symbol,
                       const double price,
                       const double close_percent,
                       const double trigger_percent)
{
   string name = PartialTpLineName(source_ticket);
   if(ObjectCreate(0, name, OBJ_HLINE, 0, 0, price))
   {
      ObjectSetInteger(0, name, OBJPROP_COLOR, clrDeepSkyBlue);
      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DASH);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, name, OBJPROP_BACK, false);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   }

   ObjectSetDouble(0, name, OBJPROP_PRICE, price);
   ObjectSetString(0, name, OBJPROP_TEXT,
                   "Partial TP " + DoubleToString(close_percent, 2) +
                   "% at " + DoubleToString(trigger_percent, 2) +
                   "% | source #" + (string)source_ticket +
                   " | " + symbol + " " +
                   DoubleToString(price, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)));
}

void DeletePartialTpLines()
{
   string own_prefix = PartialTpLineNamePrefix();
   for(int i = ObjectsTotal(0, -1, -1) - 1; i >= 0; i--)
   {
      string name = ObjectName(0, i, -1, -1);
      if(StringFind(name, own_prefix) == 0)
         ObjectDelete(0, name);
   }
}

string PartialTpLineNamePrefix()
{
   return PARTIAL_TP_LINE_PREFIX + (string)MagicNumber + "_" +
          ShortSafeKey(CopierKey, 12) + "_" +
          (string)source_login + "_";
}

string PartialTpLineName(const ulong source_ticket)
{
   return PartialTpLineNamePrefix() + (string)source_ticket;
}

bool TryBookPartialAtTpProgress(const ulong ticket,
                                const ulong source_ticket,
                                const double trigger_percent,
                                const double close_percent)
{
   if(!PositionSelectByTicket(ticket))
      return false;

   string symbol = PositionGetString(POSITION_SYMBOL);
   long type = PositionGetInteger(POSITION_TYPE);
   double entry = PositionGetDouble(POSITION_PRICE_OPEN);
   double tp = PositionGetDouble(POSITION_TP);
   double volume = PositionGetDouble(POSITION_VOLUME);
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

   if(entry <= 0.0 || tp <= 0.0 || volume <= 0.0)
      return false;

   double current = 0.0;
   double tp_distance = 0.0;
   double current_distance = 0.0;

   if(type == POSITION_TYPE_BUY)
   {
      if(tp <= entry)
         return false;

      current = SymbolInfoDouble(symbol, SYMBOL_BID);
      tp_distance = tp - entry;
      current_distance = current - entry;
   }
   else if(type == POSITION_TYPE_SELL)
   {
      if(tp >= entry)
         return false;

      current = SymbolInfoDouble(symbol, SYMBOL_ASK);
      tp_distance = entry - tp;
      current_distance = entry - current;
   }
   else
   {
      return false;
   }

   if(tp_distance <= 0.0)
      return false;

   double progress = (current_distance / tp_distance) * 100.0;
   if(progress + 0.000001 < trigger_percent)
      return false;

   double close_volume = NormalizePartialCloseVolume(symbol, volume, close_percent);
   double step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0)
      step = 0.01;

   if(close_volume <= 0.0)
   {
      last_action = "Partial TP booking skipped source #" + (string)source_ticket +
                    " because the requested close volume would not leave a valid remaining lot";
      return false;
   }

   bool ok = false;
   if(close_volume >= volume - (step / 2.0))
      ok = ClosePosition(ticket);
   else
      ok = ClosePartialPosition(ticket, close_volume);

   if(!ok)
      return false;

   MarkSourcePartialTpBooked(source_ticket);
   last_action = "Partial TP booking: source #" + (string)source_ticket +
                 " reached " + DoubleToString(progress, 2) + "% of entry-to-TP distance" +
                 " at " + DoubleToString(current, digits) +
                 "; closed " + DoubleToString(close_percent, 2) + "% volume";
   Print(last_action);
   return true;
}

void ManageProfitProgressTrailingSL()
{
   if(!EnableProfitProgressTrailingSL)
      return;

   double trigger_percent = ProfitTrailTriggerPercentClamped();
   if(trigger_percent <= 0.0)
      return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOurCopiedPosition())
         continue;

      ulong source_ticket = SourceTicketFromSelectedPosition();
      if(source_ticket == 0)
         continue;
      if(SourceProfitTrailAlreadyApplied(source_ticket))
         continue;

      TryTrailSlAtProfitProgress(ticket, source_ticket, trigger_percent);
   }
}

bool TryTrailSlAtProfitProgress(const ulong ticket,
                                const ulong source_ticket,
                                const double trigger_percent)
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);

   if(!PositionSelectByTicket(ticket))
      return false;

   string symbol = PositionGetString(POSITION_SYMBOL);
   long type = PositionGetInteger(POSITION_TYPE);
   double entry = PositionGetDouble(POSITION_PRICE_OPEN);
   double old_sl = PositionGetDouble(POSITION_SL);
   double tp = PositionGetDouble(POSITION_TP);
   double volume = PositionGetDouble(POSITION_VOLUME);
   double current = (type == POSITION_TYPE_BUY ? SymbolInfoDouble(symbol, SYMBOL_BID) : SymbolInfoDouble(symbol, SYMBOL_ASK));
   int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

   if(entry <= 0.0 || tp <= 0.0 || volume <= 0.0 || current <= 0.0)
      return false;

   double full_tp_profit = ProfitAtPrice(symbol, type, volume, entry, tp);
   double current_profit = ProfitAtPrice(symbol, type, volume, entry, current);
   if(full_tp_profit <= 0.0 || current_profit <= 0.0)
      return false;

   double progress = (current_profit / full_tp_profit) * 100.0;
   if(progress + 0.000001 < trigger_percent)
      return false;

   double desired_sl = ProfitTrailDesiredStop(symbol, type, volume, entry, old_sl);
   if(desired_sl <= 0.0)
      return false;

   double new_sl = FitStopToBrokerLimits(symbol, type, desired_sl);
   new_sl = NormalizePrice(symbol, new_sl);
   if(new_sl <= 0.0)
      return false;

   bool desired_requires_breakeven_side = ProfitTrailStopReachedDesiredSide(type, entry, desired_sl);
   if(desired_requires_breakeven_side &&
      !ProfitTrailStopReachedDesiredSide(type, entry, new_sl) &&
      !UseClosestLegalStopWhenBreakevenTooClose)
   {
      last_action = "Profit-progress trailing SL skipped copied trade #" + (string)ticket +
                    " because target SL is too close for broker stop limits";
      return false;
   }

   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(point <= 0.0)
      point = 0.00001;

   bool improves_sl = false;
   if(type == POSITION_TYPE_BUY)
      improves_sl = (old_sl <= 0.0 || new_sl > old_sl + point / 2.0);
   else
      improves_sl = (old_sl <= 0.0 || new_sl < old_sl - point / 2.0);

   if(!improves_sl)
      return true;

   ResetLastError();
   if(trade.PositionModify(ticket, new_sl, tp))
   {
      MarkSourceProfitTrailApplied(source_ticket);
      double risk_before = ProfitTrailRiskMoney(symbol, type, volume, entry, old_sl);
      double risk_after = ProfitTrailRiskMoney(symbol, type, volume, entry, new_sl);
      last_action = "Profit-progress trailing SL: source #" + (string)source_ticket +
                    " reached " + DoubleToString(progress, 2) + "% of TP profit" +
                    "; moved copied trade #" + (string)ticket +
                    " SL to " + DoubleToString(new_sl, digits) +
                    " (risk $" + DoubleToString(risk_before, 2) +
                    " -> $" + DoubleToString(risk_after, 2) + ")";
      if(desired_requires_breakeven_side && !ProfitTrailStopReachedDesiredSide(type, entry, new_sl))
      {
         last_action += " (closest legal stop; target " +
                        DoubleToString(NormalizePrice(symbol, desired_sl), digits) +
                        " is inside broker stop limits)";
      }
      last_error = "";
      Print(last_action);
      return true;
   }

   RememberTradeError("Profit-progress trailing SL modify failed ticket #" + (string)ticket);
   return false;
}

double ProfitTrailDesiredStop(const string symbol,
                              const long type,
                              const double volume,
                              const double entry,
                              const double old_sl)
{
   if(ProfitTrailStopMode == PROFIT_TRAIL_SL_TO_BREAKEVEN)
      return entry;

   if(old_sl <= 0.0 || volume <= 0.0 || entry <= 0.0)
      return 0.0;

   double remaining_loss_percent = ProfitTrailRemainingLossPercentClamped();
   if(remaining_loss_percent <= 0.0)
      return entry;

   double original_risk = ProfitTrailRiskMoney(symbol, type, volume, entry, old_sl);
   if(original_risk <= 0.0)
      return 0.0;

   double target_loss = original_risk * (remaining_loss_percent / 100.0);
   return PriceForTargetLoss(symbol, type, volume, entry, target_loss);
}

double PriceForTargetLoss(const string symbol,
                          const long type,
                          const double volume,
                          const double entry,
                          const double target_loss)
{
   if(volume <= 0.0 || entry <= 0.0 || target_loss <= 0.0)
      return 0.0;

   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(point <= 0.0)
      point = 0.00001;

   ENUM_ORDER_TYPE order_type = (type == POSITION_TYPE_BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   double range = MathMax(point, entry * 0.001);
   double low = entry;
   double high = entry;
   double profit = 0.0;

   for(int i = 0; i < 60; i++)
   {
      if(type == POSITION_TYPE_BUY)
         low = entry - range;
      else
         high = entry + range;

      double test_price = (type == POSITION_TYPE_BUY ? low : high);
      if(test_price <= 0.0)
         return 0.0;

      if(!OrderCalcProfit(order_type, symbol, volume, entry, test_price, profit))
         return 0.0;

      if(MathAbs(profit) >= target_loss && profit < 0.0)
         break;

      range *= 2.0;
   }

   if(MathAbs(profit) < target_loss || profit >= 0.0)
      return 0.0;

   for(int i = 0; i < 80; i++)
   {
      double mid = (low + high) / 2.0;
      if(!OrderCalcProfit(order_type, symbol, volume, entry, mid, profit))
         return 0.0;

      if(type == POSITION_TYPE_BUY)
      {
         if(MathAbs(profit) < target_loss)
            high = mid;
         else
            low = mid;
      }
      else
      {
         if(MathAbs(profit) < target_loss)
            low = mid;
         else
            high = mid;
      }
   }

   return (low + high) / 2.0;
}

double ProfitTrailRiskMoney(const string symbol,
                            const long type,
                            const double volume,
                            const double entry,
                            const double sl)
{
   if(volume <= 0.0 || entry <= 0.0 || sl <= 0.0)
      return 0.0;

   double profit = ProfitAtPrice(symbol, type, volume, entry, sl);
   if(profit >= 0.0)
      return 0.0;

   return MathAbs(profit);
}

bool ProfitTrailStopReachedDesiredSide(const long type,
                                       const double entry,
                                       const double sl)
{
   if(type == POSITION_TYPE_BUY)
      return sl >= entry;

   return sl <= entry;
}

double ProfitTrailTriggerPercentClamped()
{
   return MathMax(0.0, MathMin(100.0, ProfitTrailTriggerPercent));
}

double ProfitTrailRemainingLossPercentClamped()
{
   return MathMax(0.0, MathMin(100.0, ProfitTrailRemainingLossPercent));
}

double PartialTpTriggerPercentClamped()
{
   return MathMax(0.0, MathMin(100.0, PartialTpTriggerPercent));
}

double PartialTpClosePercentClamped()
{
   return MathMax(0.0, MathMin(100.0, PartialTpClosePercent));
}

bool OpenCopiedPosition(const SourcePosition &src, const string symbol, const long type, double volume)
{
   if(IsRiskLotMode())
      volume = DesiredCopiedVolume(src, symbol, type, true);

   volume = NormalizeVolume(symbol, volume);
   if(volume <= 0.0)
      return false;

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   trade.SetTypeFillingBySymbol(symbol);

   double sl = 0.0;
   double tp = 0.0;
   if(CopyStopLossTakeProfit)
      StopsForCopiedTrade(src, type, sl, tp);

   string comment = CopyComment(src.ticket);
   bool ok = false;

   if(type == POSITION_TYPE_BUY)
      ok = SendBuyWithRetries(volume, symbol, sl, tp, comment);
   else
      ok = SendSellWithRetries(volume, symbol, sl, tp, comment);

   if(!ok)
   {
      if(IsRiskLotMode() && CopyStopLossTakeProfit)
      {
         last_action = "Risk-sized source #" + (string)src.ticket + " was not opened because copied SL/TP is invalid";
         Print(last_action);
         return false;
      }

      last_action = "Retrying source #" + (string)src.ticket + " without copied SL/TP";
      if(type == POSITION_TYPE_BUY)
         ok = SendBuyWithRetries(volume, symbol, 0.0, 0.0, comment);
      else
         ok = SendSellWithRetries(volume, symbol, 0.0, 0.0, comment);
   }

   if(ok && CopyStopLossTakeProfit && AdjustTakeProfitToCopiedRR)
      AdjustTakeProfitToCopiedRRMoney(src, symbol, type, comment);

   if(ok)
      MarkSourceLifecycleStarted(src.ticket);

   return ok;
}

bool AdjustTakeProfitToCopiedRRMoney(const SourcePosition &src,
                                     const string symbol,
                                     const long type,
                                     const string comment)
{
   ulong ticket = FindNewestCopiedPosition(comment, symbol, type);
   if(ticket == 0)
   {
      Sleep(100);
      ticket = FindNewestCopiedPosition(comment, symbol, type);
   }

   if(ticket == 0 || !PositionSelectByTicket(ticket))
      return false;

   double entry = PositionGetDouble(POSITION_PRICE_OPEN);
   double sl = PositionGetDouble(POSITION_SL);
   double old_tp = PositionGetDouble(POSITION_TP);
   double position_volume = PositionGetDouble(POSITION_VOLUME);
   if(entry <= 0.0 || sl <= 0.0 || position_volume <= 0.0)
      return false;

   ENUM_ORDER_TYPE order_type = (type == POSITION_TYPE_BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   double risk_money = 0.0;
   if(!OrderCalcProfit(order_type, symbol, position_volume, entry, sl, risk_money))
      return false;

   risk_money = MathAbs(risk_money);
   if(risk_money <= 0.0)
      return false;

   double target_profit = risk_money;
   double rr = 1.0;
   string adjust_description = "risk money";

   if(TakeProfitAdjustMode == TP_ADJUST_PRESERVE_COPIED_RR)
   {
      if(src.sl <= 0.0 || src.tp <= 0.0)
      {
         last_action = "Skipped copied RR TP adjust for " + comment +
                       " because sender SL/TP is missing";
         if(MarkSourceLoggedOnce(logged_missing_sltp_rr_adjust_sources, src.ticket))
            Print(last_action);
         return false;
      }

      double copied_sl = 0.0;
      double copied_tp = 0.0;
      StopsForCopiedTrade(src, type, copied_sl, copied_tp);
      if(copied_sl <= 0.0 || copied_tp <= 0.0)
      {
         last_action = "Skipped copied RR TP adjust for " + comment +
                       " because copied SL/TP mapping is incomplete";
         if(MarkSourceLoggedOnce(logged_incomplete_sltp_rr_adjust_sources, src.ticket))
            Print(last_action);
         return false;
      }

      double intended_risk_distance = MathAbs(copied_sl - src.price_open);
      double intended_reward_distance = MathAbs(copied_tp - src.price_open);
      if(intended_risk_distance <= 0.0 || intended_reward_distance <= 0.0)
         return false;

      rr = intended_reward_distance / intended_risk_distance;
      if(rr <= 0.0)
         return false;

      target_profit = risk_money * rr;
      adjust_description = "copied RR " + DoubleToString(rr, 2);
   }

   double new_tp = PriceForTargetProfit(symbol, type, position_volume, entry, target_profit);
   if(new_tp <= 0.0)
      return false;

   new_tp = FitTakeProfitToBrokerLimits(symbol, type, new_tp);
   new_tp = NormalizePrice(symbol, new_tp);
   if(new_tp <= 0.0)
      return false;

   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(point <= 0.0)
      point = 0.00001;

   if(old_tp > 0.0 && MathAbs(old_tp - new_tp) < point / 2.0)
      return true;

   ResetLastError();
   if(trade.PositionModify(ticket, sl, new_tp))
   {
      last_action = "Adjusted copied trade #" + (string)ticket + " TP to " +
                    DoubleToString(new_tp, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)) +
                    " for " + adjust_description +
                    " target $" + DoubleToString(target_profit, 2);
      last_error = "";
      Print(last_action);
      return true;
   }

   RememberTradeError("Copied RR TP adjust failed ticket #" + (string)ticket);
   return false;
}

ulong FindNewestCopiedPosition(const string comment, const string symbol, const long type)
{
   ulong newest_ticket = 0;
   long newest_time = 0;
   ulong wanted_source_ticket = SourceTicketFromComment(comment);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOurCopiedPosition())
         continue;

      if(SourceTicketFromSelectedPosition() != wanted_source_ticket ||
         PositionGetString(POSITION_SYMBOL) != symbol ||
         PositionGetInteger(POSITION_TYPE) != type)
      {
         continue;
      }

      long open_time = PositionGetInteger(POSITION_TIME_MSC);
      if(open_time >= newest_time)
      {
         newest_time = open_time;
         newest_ticket = ticket;
      }
   }

   return newest_ticket;
}

double PriceForTargetProfit(const string symbol,
                            const long type,
                            const double volume,
                            const double entry,
                            const double target_profit)
{
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(point <= 0.0)
      point = 0.00001;

   ENUM_ORDER_TYPE order_type = (type == POSITION_TYPE_BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   double range = MathMax(point, entry * 0.001);
   double low = entry;
   double high = entry;
   double profit = 0.0;

   for(int i = 0; i < 60; i++)
   {
      if(type == POSITION_TYPE_BUY)
         high = entry + range;
      else
         low = entry - range;

      double test_price = (type == POSITION_TYPE_BUY ? high : low);
      if(test_price <= 0.0)
         return 0.0;

      if(!OrderCalcProfit(order_type, symbol, volume, entry, test_price, profit))
         return 0.0;

      if(profit >= target_profit)
         break;

      range *= 2.0;
   }

   if(profit < target_profit)
      return 0.0;

   for(int i = 0; i < 80; i++)
   {
      double mid = (low + high) / 2.0;
      if(!OrderCalcProfit(order_type, symbol, volume, entry, mid, profit))
         return 0.0;

      if(type == POSITION_TYPE_BUY)
      {
         if(profit < target_profit)
            low = mid;
         else
            high = mid;
      }
      else
      {
         if(profit < target_profit)
            high = mid;
         else
            low = mid;
      }
   }

   return (low + high) / 2.0;
}

double SyncPendingOrdersForSource(const SourcePosition &src, const string symbol, const long target_type)
{
   double pending_volume = 0.0;
   string wanted_comment = CopyComment(src.ticket);
   ENUM_ORDER_TYPE wanted_type = PendingTypeForSource(src, symbol, target_type);
   double wanted_price = NormalizePrice(symbol, src.price_open);
   double wanted_sl = 0.0;
   double wanted_tp = 0.0;
   if(CopyStopLossTakeProfit)
      StopsForCopiedTrade(src, target_type, wanted_sl, wanted_tp);

   wanted_sl = NormalizePrice(symbol, wanted_sl);
   wanted_tp = NormalizePrice(symbol, wanted_tp);

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !IsOurCopiedOrder())
         continue;

      string comment = OrderGetString(ORDER_COMMENT);
      if(comment != wanted_comment)
         continue;

      string order_symbol = OrderGetString(ORDER_SYMBOL);
      ENUM_ORDER_TYPE order_type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);

      if(order_symbol != symbol || order_type != wanted_type)
      {
         DeletePendingOrder(ticket);
         continue;
      }

      pending_volume += OrderGetDouble(ORDER_VOLUME_CURRENT);
      ModifyPendingOrderIfNeeded(ticket, symbol, wanted_price, wanted_sl, wanted_tp);
   }

   return pending_volume;
}

bool OpenCopiedPendingOrder(const SourcePosition &src, const string symbol, const long target_type, double volume)
{
   if(IsRiskLotMode())
      volume = DesiredCopiedVolume(src, symbol, target_type, true);

   volume = NormalizeVolume(symbol, volume);
   if(volume <= 0.0)
      return false;

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);
   trade.SetTypeFillingBySymbol(symbol);

   double price = NormalizePrice(symbol, src.price_open);
   double sl = 0.0;
   double tp = 0.0;
   if(CopyStopLossTakeProfit)
      StopsForCopiedTrade(src, target_type, sl, tp);

   sl = NormalizePrice(symbol, sl);
   tp = NormalizePrice(symbol, tp);

   string comment = CopyComment(src.ticket);
   ENUM_ORDER_TYPE pending_type = PendingTypeForSource(src, symbol, target_type);

   if(!PendingPriceIsValid(pending_type, symbol, price))
   {
      last_action = PendingOrderTypeName(pending_type) + " price is not valid yet for " + comment;
      last_error = "Waiting for valid pending price: " + symbol + " " +
                   DoubleToString(price, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS));
      return false;
   }

   bool ok = SendPendingOrderWithRetries(pending_type, volume, symbol, price, sl, tp, comment);

   if(!ok && (sl > 0.0 || tp > 0.0))
   {
      if(IsRiskLotMode() && CopyStopLossTakeProfit)
      {
         last_action = "Risk-sized source #" + (string)src.ticket + " pending order was not placed because copied SL/TP is invalid";
         Print(last_action);
         return false;
      }

      last_action = "Retrying source #" + (string)src.ticket + " pending order without copied SL/TP";
      ok = SendPendingOrderWithRetries(pending_type, volume, symbol, price, 0.0, 0.0, comment);
   }

   if(ok)
      MarkSourceLifecycleStarted(src.ticket);

   return ok;
}

ENUM_ORDER_TYPE PendingTypeForSource(const SourcePosition &src, const string symbol, const long target_type)
{
   double entry = NormalizePrice(symbol, src.price_open);
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);

   if(target_type == POSITION_TYPE_BUY)
   {
      if(entry < ask)
         return ORDER_TYPE_BUY_LIMIT;
      return ORDER_TYPE_BUY_STOP;
   }

   if(entry > bid)
      return ORDER_TYPE_SELL_LIMIT;
   return ORDER_TYPE_SELL_STOP;
}

bool PendingPriceIsValid(const ENUM_ORDER_TYPE order_type, const string symbol, const double price)
{
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(point <= 0.0)
      point = 0.00001;

   int stops_level = (int)SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double min_distance = stops_level * point;
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);

   if(price <= 0.0 || ask <= 0.0 || bid <= 0.0)
      return false;

   if(order_type == ORDER_TYPE_BUY_LIMIT)
      return price < ask - min_distance;
   if(order_type == ORDER_TYPE_BUY_STOP)
      return price > ask + min_distance;
   if(order_type == ORDER_TYPE_SELL_LIMIT)
      return price > bid + min_distance;
   if(order_type == ORDER_TYPE_SELL_STOP)
      return price < bid - min_distance;

   return false;
}

bool SendPendingOrderWithRetries(const ENUM_ORDER_TYPE order_type,
                                 const double volume,
                                 const string symbol,
                                 const double price,
                                 const double sl,
                                 const double tp,
                                 const string comment)
{
   int retries = MathMax(1, TradeRetries);
   for(int attempt = 1; attempt <= retries; attempt++)
   {
      ResetLastError();
      bool ok = false;

      if(order_type == ORDER_TYPE_BUY_LIMIT)
         ok = trade.BuyLimit(volume, price, symbol, sl, tp, ORDER_TIME_GTC, 0, comment);
      else if(order_type == ORDER_TYPE_BUY_STOP)
         ok = trade.BuyStop(volume, price, symbol, sl, tp, ORDER_TIME_GTC, 0, comment);
      else if(order_type == ORDER_TYPE_SELL_LIMIT)
         ok = trade.SellLimit(volume, price, symbol, sl, tp, ORDER_TIME_GTC, 0, comment);
      else if(order_type == ORDER_TYPE_SELL_STOP)
         ok = trade.SellStop(volume, price, symbol, sl, tp, ORDER_TIME_GTC, 0, comment);

      if(ok)
      {
         last_action = "Placed " + PendingOrderTypeName(order_type) + " " + symbol + " " +
                       DoubleToString(volume, 2) + " at " + DoubleToString(price, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS)) +
                       " for " + comment;
         last_error = "";
         Print(last_action);
         return true;
      }

      RememberTradeError(PendingOrderTypeName(order_type) + " failed attempt " + (string)attempt + "/" + (string)retries + " " + symbol);
      Sleep(MathMax(0, RetryDelayMilliseconds));
   }

   return false;
}

void ModifyPendingOrderIfNeeded(const ulong ticket,
                                const string symbol,
                                const double price,
                                const double sl,
                                const double tp)
{
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(point <= 0.0)
      point = 0.00001;

   double old_price = OrderGetDouble(ORDER_PRICE_OPEN);
   double old_sl = OrderGetDouble(ORDER_SL);
   double old_tp = OrderGetDouble(ORDER_TP);
   ENUM_ORDER_TYPE order_type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);

   if(MathAbs(old_price - price) < point / 2.0 &&
      MathAbs(old_sl - sl) < point / 2.0 &&
      MathAbs(old_tp - tp) < point / 2.0)
   {
      return;
   }

   if(!PendingPriceIsValid(order_type, symbol, price))
      return;

   ResetLastError();
   if(!trade.OrderModify(ticket, price, sl, tp, ORDER_TIME_GTC, 0))
      RememberTradeError("Pending modify failed ticket #" + (string)ticket);
}

void ReduceCopiedPendingVolume(const ulong source_ticket,
                               const string symbol,
                               const ENUM_ORDER_TYPE type,
                               double volume_to_delete)
{
   string wanted_comment = CopyComment(source_ticket);

   for(int i = OrdersTotal() - 1; i >= 0 && volume_to_delete > 0.0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !IsOurCopiedOrder())
         continue;

      if(OrderGetString(ORDER_COMMENT) != wanted_comment ||
         OrderGetString(ORDER_SYMBOL) != symbol ||
         (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) != type)
      {
         continue;
      }

      double order_volume = OrderGetDouble(ORDER_VOLUME_CURRENT);
      if(DeletePendingOrder(ticket))
         volume_to_delete -= order_volume;
   }
}

void CloseOrphanCopiedPendingOrders()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !IsOurCopiedOrder())
         continue;

      string comment = OrderGetString(ORDER_COMMENT);
      ulong source_ticket = SourceTicketFromComment(comment);
      if(source_ticket > 0 && !SourceExists(source_ticket))
      {
         last_action = "Cancelling pending copied order because source #" + (string)source_ticket + " exited";
         DeletePendingOrder(ticket);
      }
   }
}

void DeleteCopiedPendingOrdersForSource(const ulong source_ticket)
{
   string wanted_comment = CopyComment(source_ticket);

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !IsOurCopiedOrder())
         continue;

      if(OrderGetString(ORDER_COMMENT) == wanted_comment)
         DeletePendingOrder(ticket);
   }
}

bool DeletePendingOrder(const ulong ticket)
{
   int retries = MathMax(1, TradeRetries);
   for(int attempt = 1; attempt <= retries; attempt++)
   {
      ResetLastError();
      if(!OrderSelect(ticket))
         return true;

      if(trade.OrderDelete(ticket))
      {
         last_action = "Deleted pending copied order #" + (string)ticket;
         last_error = "";
         Print(last_action);
         return true;
      }

      RememberTradeError("Pending delete failed attempt " + (string)attempt + "/" + (string)retries + " ticket #" + (string)ticket);
      Sleep(MathMax(0, RetryDelayMilliseconds));
   }

   return false;
}

bool LockProfitAfterSenderExit(const ulong ticket)
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);

   if(!PositionSelectByTicket(ticket))
      return true;

   string symbol = PositionGetString(POSITION_SYMBOL);
   long type = PositionGetInteger(POSITION_TYPE);
   double entry = PositionGetDouble(POSITION_PRICE_OPEN);
   double old_sl = PositionGetDouble(POSITION_SL);
   double tp = PositionGetDouble(POSITION_TP);
   double volume = PositionGetDouble(POSITION_VOLUME);
   double percent = MathMax(0.0, MathMin(100.0, SenderExitProfitLockPercent));
   double current = (type == POSITION_TYPE_BUY ? SymbolInfoDouble(symbol, SYMBOL_BID) : SymbolInfoDouble(symbol, SYMBOL_ASK));

   if(entry <= 0.0 || current <= 0.0 || volume <= 0.0)
      return false;

   bool profitable = (type == POSITION_TYPE_BUY ? current > entry : current < entry);
   if(!profitable)
   {
      last_action = "Sender exited but copied trade is not in profit yet; leaving trade open #" + (string)ticket;
      return false;
   }

   double new_sl = 0.0;
   double desired_sl = 0.0;
   string basis_text = "open profit";
   if(SenderExitProfitLockBasis == SENDER_EXIT_LOCK_FULL_TP_PROFIT && percent > 0.0)
   {
      if(tp <= 0.0)
      {
         last_action = "Sender exited but TP-profit lock basis needs a copied TP #" + (string)ticket;
         return false;
      }

      double full_tp_profit = ProfitAtPrice(symbol, type, volume, entry, tp);
      if(full_tp_profit <= 0.0)
      {
         last_action = "Sender exited but copied TP profit is not positive #" + (string)ticket;
         return false;
      }

      double target_profit = full_tp_profit * (percent / 100.0);
      desired_sl = PriceForTargetProfit(symbol, type, volume, entry, target_profit);
      basis_text = "full TP profit";
   }
   else
   {
      if(type == POSITION_TYPE_BUY)
         desired_sl = entry + ((current - entry) * (percent / 100.0));
      else
         desired_sl = entry - ((entry - current) * (percent / 100.0));
   }

   if(desired_sl <= 0.0)
      return false;

   new_sl = desired_sl;
   new_sl = FitStopToBrokerLimits(symbol, type, new_sl);
   new_sl = NormalizePrice(symbol, new_sl);

   if(new_sl <= 0.0)
      return false;

   if(type == POSITION_TYPE_BUY && new_sl < entry)
   {
      if(!UseClosestLegalStopWhenBreakevenTooClose)
      {
         last_action = "Sender exited but breakeven/profit lock is too close for broker stop limits #" + (string)ticket;
         return false;
      }
   }

   if(type == POSITION_TYPE_SELL && new_sl > entry)
   {
      if(!UseClosestLegalStopWhenBreakevenTooClose)
      {
         last_action = "Sender exited but breakeven/profit lock is too close for broker stop limits #" + (string)ticket;
         return false;
      }
   }

   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(point <= 0.0)
      point = 0.00001;

   bool improves_sl = false;
   if(type == POSITION_TYPE_BUY)
      improves_sl = (old_sl <= 0.0 || new_sl > old_sl + point / 2.0);
   else
      improves_sl = (old_sl <= 0.0 || new_sl < old_sl - point / 2.0);

   if(!improves_sl)
   {
      last_action = "Copied trade #" + (string)ticket + " already has equal or better locked SL";
      return true;
   }

   ResetLastError();
   if(trade.PositionModify(ticket, new_sl, tp))
   {
      int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
      last_action = "Moved copied trade #" + (string)ticket + " SL to " +
                    DoubleToString(new_sl, digits) +
                    " after sender exit; locked " +
                    DoubleToString(percent, 2) + "% of " + basis_text;
      if((type == POSITION_TYPE_BUY && new_sl < entry) || (type == POSITION_TYPE_SELL && new_sl > entry))
      {
         last_action += " (closest legal stop; target " +
                        DoubleToString(NormalizePrice(symbol, desired_sl), digits) +
                        " is inside broker stop limits)";
      }
      last_error = "";
      Print(last_action);
      return true;
   }

   RememberTradeError("Profit lock failed ticket #" + (string)ticket);
   return false;
}

double FitStopToBrokerLimits(const string symbol, const long position_type, double sl)
{
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(point <= 0.0)
      point = 0.00001;

   int stops_level = (int)SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double min_distance = stops_level * point;
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);

   if(position_type == POSITION_TYPE_BUY)
   {
      double max_sl = bid - min_distance;
      if(sl > max_sl)
         sl = max_sl;
   }
   else
   {
      double min_sl = ask + min_distance;
      if(sl < min_sl)
         sl = min_sl;
   }

   return sl;
}

double FitTakeProfitToBrokerLimits(const string symbol, const long position_type, double tp)
{
   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(point <= 0.0)
      point = 0.00001;

   int stops_level = (int)SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double min_distance = stops_level * point;
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);

   if(position_type == POSITION_TYPE_BUY)
   {
      double min_tp = bid + min_distance;
      if(tp < min_tp)
         tp = min_tp;
   }
   else
   {
      double max_tp = ask - min_distance;
      if(tp > max_tp)
         tp = max_tp;
   }

   return tp;
}

void StopsForCopiedTrade(const SourcePosition &src, const long target_type, double &sl, double &tp)
{
   sl = 0.0;
   tp = 0.0;

   if(CopyMode == COPY_EXACT_SAME)
   {
      sl = src.sl;
      tp = src.tp;
      return;
   }

   if(target_type == POSITION_TYPE_BUY)
   {
      sl = src.tp;
      tp = src.sl;
   }
   else
   {
      sl = src.tp;
      tp = src.sl;
   }
}

double DesiredCopiedVolume(const SourcePosition &src, const string target_symbol, const long target_type, const bool log_details)
{
   double exact_volume = NormalizeVolume(target_symbol, src.volume * LotMultiplier);
   if(LotMode == COPIER_LOT_EXACT)
      return exact_volume;

   double sl = 0.0;
   double tp = 0.0;
   StopsForCopiedTrade(src, target_type, sl, tp);

   double risk_volume = CalculateFixedRiskVolume(src, target_symbol, target_type, sl, log_details);
   if(risk_volume > 0.0)
      return risk_volume;

   last_error = "Risk lot mode skipped source #" + (string)src.ticket + " because copied SL distance is invalid";
   if(log_details)
      Print(last_error);
   return 0.0;
}

double CalculateFixedRiskVolume(const SourcePosition &src, const string symbol, const long target_type, const double sl, const bool log_details)
{
   double risk_base = RiskSizingBalanceBase();
   double risk_amount = risk_base * (RiskPerTradePercent / 100.0);
   double entry_price = RiskSizingEntryPrice(src, symbol, target_type);
   if(risk_amount <= 0.0 || entry_price <= 0.0 || sl <= 0.0)
      return 0.0;

   if(MathAbs(entry_price - sl) < SymbolInfoDouble(symbol, SYMBOL_POINT))
      return 0.0;

   ENUM_ORDER_TYPE order_type = (target_type == POSITION_TYPE_BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   double loss_per_lot = 0.0;
   if(!OrderCalcProfit(order_type, symbol, 1.0, entry_price, sl, loss_per_lot))
      return 0.0;

   loss_per_lot = MathAbs(loss_per_lot);
   if(loss_per_lot <= 0.0)
      return 0.0;

   double raw_volume = risk_amount / loss_per_lot;
   double normalized_volume = NormalizeVolume(symbol, raw_volume);
   if(MaxFixedRiskLot > 0.0 && normalized_volume > MaxFixedRiskLot)
   {
      if(log_details && LogRiskSizingDetails)
      {
         PrintFormat("Risk Sizing: Source #%I64u skipped because calculated lot %.2f exceeds MaxFixedRiskLot %.2f",
                     src.ticket, normalized_volume, MaxFixedRiskLot);
      }
      last_error = "Risk lot skipped source #" + (string)src.ticket + " because calculated lot exceeds max cap";
      return 0.0;
   }

   double expected_risk = loss_per_lot * normalized_volume;

   if(log_details && LogRiskSizingDetails)
   {
      PrintFormat("Risk Sizing: Source #%I64u | Symbol=%s | Direction=%s | RiskBaseMode=%s | RiskBase=%.2f | RiskPercent=%.2f%% | RiskMoney=%.2f",
                  src.ticket, symbol, PositionTypeName(target_type), EnumToString(LotMode), risk_base, RiskPerTradePercent, risk_amount);
      PrintFormat("Risk Sizing: Entry=%.5f | SL=%.5f | Distance=%.1f points | LossPer1Lot=%.2f | RawLot=%.8f | NormalizedLot=%.2f | ExpectedRisk=%.2f",
                  entry_price, sl, MathAbs(entry_price - sl) / SymbolInfoDouble(symbol, SYMBOL_POINT),
                  loss_per_lot, raw_volume, normalized_volume, expected_risk);
      PrintFormat("Risk Sizing: SenderEntry=%.5f | SenderSL=%.5f | SenderTP=%.5f | CopySLTP=%s | Note: broker min/max/step can change final risk.",
                  src.price_open, src.sl, src.tp, CopyStopLossTakeProfit ? "ON" : "OFF");
   }

   return normalized_volume;
}

double RiskSizingBalanceBase()
{
   if(LotMode == COPIER_LOT_CURRENT_BALANCE_RISK)
      return AccountInfoDouble(ACCOUNT_BALANCE);

   return RiskStartingBalance;
}

double RiskSizingEntryPrice(const SourcePosition &src, const string symbol, const long target_type)
{
   if(IsPendingEntryMode())
      return NormalizePrice(symbol, src.price_open);

   if(target_type == POSITION_TYPE_BUY)
      return SymbolInfoDouble(symbol, SYMBOL_ASK);

   return SymbolInfoDouble(symbol, SYMBOL_BID);
}

bool ClosePosition(const ulong ticket)
{
   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePoints);

   int retries = MathMax(1, TradeRetries);
   for(int attempt = 1; attempt <= retries; attempt++)
   {
      ResetLastError();
      if(!PositionSelectByTicket(ticket))
      {
         last_action = "Position already closed: #" + (string)ticket;
         return true;
      }

      string symbol = PositionGetString(POSITION_SYMBOL);
      double volume = PositionGetDouble(POSITION_VOLUME);
      bool ok = trade.PositionClose(ticket, SlippagePoints);
      if(ok)
      {
         last_action = "Closed copied trade #" + (string)ticket + " " + symbol + " " + DoubleToString(volume, 2);
         last_error = "";
         Print(last_action);
         return true;
      }

      RememberTradeError("Close failed attempt " + (string)attempt + "/" + (string)retries + " ticket #" + (string)ticket);
      Sleep(MathMax(0, RetryDelayMilliseconds));
   }

   return false;
}

bool ClosePartialPosition(const ulong ticket, const double volume)
{
   int retries = MathMax(1, TradeRetries);
   for(int attempt = 1; attempt <= retries; attempt++)
   {
      ResetLastError();
      if(!PositionSelectByTicket(ticket))
         return true;

      bool ok = trade.PositionClosePartial(ticket, volume, SlippagePoints);
      if(ok)
      {
         last_action = "Partially closed copied trade #" + (string)ticket + " volume " + DoubleToString(volume, 2);
         last_error = "";
         Print(last_action);
         return true;
      }

      RememberTradeError("Partial close failed attempt " + (string)attempt + "/" + (string)retries + " ticket #" + (string)ticket);
      Sleep(MathMax(0, RetryDelayMilliseconds));
   }

   return false;
}

bool SendBuyWithRetries(const double volume, const string symbol, const double sl, const double tp, const string comment)
{
   int retries = MathMax(1, TradeRetries);
   for(int attempt = 1; attempt <= retries; attempt++)
   {
      ResetLastError();
      if(trade.Buy(volume, symbol, 0.0, sl, tp, comment))
      {
         last_action = "Opened BUY " + symbol + " " + DoubleToString(volume, 2) + " for " + comment;
         last_error = "";
         Print(last_action);
         return true;
      }

      RememberTradeError("Buy failed attempt " + (string)attempt + "/" + (string)retries + " " + symbol + " " + DoubleToString(volume, 2));
      Sleep(MathMax(0, RetryDelayMilliseconds));
   }

   return false;
}

bool SendSellWithRetries(const double volume, const string symbol, const double sl, const double tp, const string comment)
{
   int retries = MathMax(1, TradeRetries);
   for(int attempt = 1; attempt <= retries; attempt++)
   {
      ResetLastError();
      if(trade.Sell(volume, symbol, 0.0, sl, tp, comment))
      {
         last_action = "Opened SELL " + symbol + " " + DoubleToString(volume, 2) + " for " + comment;
         last_error = "";
         Print(last_action);
         return true;
      }

      RememberTradeError("Sell failed attempt " + (string)attempt + "/" + (string)retries + " " + symbol + " " + DoubleToString(volume, 2));
      Sleep(MathMax(0, RetryDelayMilliseconds));
   }

   return false;
}

void RememberTradeError(const string prefix)
{
   last_error = prefix +
                " | retcode " + (string)trade.ResultRetcode() +
                " " + trade.ResultRetcodeDescription() +
                " | terminal error " + (string)GetLastError();
   Print(last_error);
}

bool IsOurCopiedPosition()
{
   if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)
      return false;

   return SourceTicketFromSelectedPosition() > 0;
}

ulong SourceTicketFromSelectedPosition()
{
   ulong source_ticket = SourceTicketFromComment(PositionGetString(POSITION_COMMENT));
   if(source_ticket > 0)
   {
      RememberSelectedCopiedPositionIdentity(source_ticket);
      return source_ticket;
   }

   return RememberedSourceTicketForSelectedPosition();
}

void RememberSelectedCopiedPositionIdentity(const ulong source_ticket)
{
   if(source_ticket == 0)
      return;

   long identifier = SelectedPositionIdentifier();
   if(identifier <= 0)
      return;

   int total = ArraySize(remembered_copied_positions);
   for(int i = 0; i < total; i++)
   {
      if(remembered_copied_positions[i].identifier == identifier)
      {
         remembered_copied_positions[i].source_ticket = source_ticket;
         remembered_copied_positions[i].symbol = PositionGetString(POSITION_SYMBOL);
         remembered_copied_positions[i].type = PositionGetInteger(POSITION_TYPE);
         GlobalVariableSet(PositionIdentityGlobalName(identifier), (double)source_ticket);
         return;
      }
   }

   ArrayResize(remembered_copied_positions, total + 1);
   remembered_copied_positions[total].identifier = identifier;
   remembered_copied_positions[total].source_ticket = source_ticket;
   remembered_copied_positions[total].symbol = PositionGetString(POSITION_SYMBOL);
   remembered_copied_positions[total].type = PositionGetInteger(POSITION_TYPE);
   GlobalVariableSet(PositionIdentityGlobalName(identifier), (double)source_ticket);
}

ulong RememberedSourceTicketForSelectedPosition()
{
   long identifier = SelectedPositionIdentifier();
   if(identifier <= 0)
      return 0;

   int total = ArraySize(remembered_copied_positions);
   for(int i = 0; i < total; i++)
   {
      if(remembered_copied_positions[i].identifier == identifier)
         return remembered_copied_positions[i].source_ticket;
   }

   string global_name = PositionIdentityGlobalName(identifier);
   if(GlobalVariableCheck(global_name))
      return (ulong)GlobalVariableGet(global_name);

   return 0;
}

long SelectedPositionIdentifier()
{
   long identifier = PositionGetInteger(POSITION_IDENTIFIER);
   if(identifier <= 0)
      identifier = PositionGetInteger(POSITION_TICKET);

   return identifier;
}

string PositionIdentityGlobalName(const long identifier)
{
   return "MTC1_POS_" + (string)MagicNumber + "_" +
          ShortSafeKey(CopierKey, 12) + "_" +
          (string)source_login + "_" +
          (string)identifier;
}

bool IsOurCopiedOrder()
{
   if((ulong)OrderGetInteger(ORDER_MAGIC) != MagicNumber)
      return false;

   string comment = OrderGetString(ORDER_COMMENT);
   return StringFind(comment, COPY_COMMENT_PREFIX) == 0;
}

string TargetSymbol(const string source_symbol)
{
   if(SymbolMode == SYMBOL_MULTI_PAIR)
      return MultiPairTargetSymbol(source_symbol);

   string custom = Trim(CustomSymbol);
   if(custom != "")
      return custom;

   return source_symbol;
}

string MultiPairTargetSymbol(const string source_symbol)
{
   string sender1 = Trim(SenderSymbol1);
   string copier1 = Trim(CopierSymbol1);
   if(sender1 != "" && copier1 != "" && source_symbol == sender1)
      return copier1;

   string sender2 = Trim(SenderSymbol2);
   string copier2 = Trim(CopierSymbol2);
   if(sender2 != "" && copier2 != "" && source_symbol == sender2)
      return copier2;

   string sender3 = Trim(SenderSymbol3);
   string copier3 = Trim(CopierSymbol3);
   if(sender3 != "" && copier3 != "" && source_symbol == sender3)
      return copier3;

   return "";
}

string CopierFileName()
{
   string key = SafeKey(CopierKey);
   if(key == "")
      key = "default";

   return COPIER_FILE_PREFIX + key + ".csv";
}

string SafeKey(string value)
{
   StringTrimLeft(value);
   StringTrimRight(value);

   string clean = "";
   int length = StringLen(value);
   for(int i = 0; i < length; i++)
   {
      ushort ch = StringGetCharacter(value, i);
      bool allowed = (ch >= '0' && ch <= '9') ||
                     (ch >= 'A' && ch <= 'Z') ||
                     (ch >= 'a' && ch <= 'z') ||
                     ch == '_' ||
                     ch == '-';

      if(allowed)
         clean += ShortToString(ch);
   }

   return clean;
}

long TargetType(const long source_type)
{
   if(CopyMode == COPY_EXACT_SAME)
      return source_type;

   if(source_type == POSITION_TYPE_BUY)
      return POSITION_TYPE_SELL;

   return POSITION_TYPE_BUY;
}

bool IsPendingEntryMode()
{
   return EntryMode == COPIER_ENTRY_PENDING_ORDER;
}

bool IsRiskLotMode()
{
   return LotMode == COPIER_LOT_FIXED_STARTING_BALANCE_RISK ||
          LotMode == COPIER_LOT_CURRENT_BALANCE_RISK;
}

double NormalizeVolume(const string symbol, double volume)
{
   double min_volume = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double max_volume = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   if(step <= 0.0)
      step = 0.01;
   if(min_volume <= 0.0)
      min_volume = step;
   if(max_volume <= 0.0)
      max_volume = volume;

   volume = MathMax(min_volume, MathMin(max_volume, volume));
   volume = MathFloor((volume / step) + 0.0000001) * step;

   int digits = VolumeDigits(step);
   return NormalizeDouble(volume, digits);
}

double NormalizePartialCloseVolume(const string symbol, const double position_volume, const double close_percent)
{
   double min_volume = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   double step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   if(step <= 0.0)
      step = 0.01;
   if(min_volume <= 0.0)
      min_volume = step;

   int digits = VolumeDigits(step);
   double total_volume = NormalizeDouble(position_volume, digits);
   double requested_volume = total_volume * (MathMax(0.0, MathMin(100.0, close_percent)) / 100.0);

   if(total_volume <= 0.0 || requested_volume <= 0.0)
      return 0.0;

   if(close_percent >= 100.0)
      return total_volume;

   double close_volume = MathFloor((requested_volume / step) + 0.0000001) * step;
   close_volume = NormalizeDouble(close_volume, digits);

   while(close_volume > 0.0 && total_volume - close_volume < min_volume - (step / 2.0))
      close_volume = NormalizeDouble(close_volume - step, digits);

   if(close_volume < min_volume)
      return 0.0;

   return close_volume;
}

int VolumeDigits(const double step)
{
   int digits = 0;
   double value = step;

   while(digits < 8 && MathAbs(value - MathRound(value)) > 0.00000001)
   {
      value *= 10.0;
      digits++;
   }

   return digits;
}

double NormalizePrice(const string symbol, const double price)
{
   if(price <= 0.0)
      return 0.0;

   return NormalizeDouble(price, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS));
}

string CopyComment(const ulong source_ticket)
{
   return COPY_COMMENT_PREFIX + (string)source_ticket;
}

ulong SourceTicketFromComment(const string comment)
{
   if(StringFind(comment, COPY_COMMENT_PREFIX) != 0)
      return 0;

   return (ulong)StringToInteger(StringSubstr(comment, StringLen(COPY_COMMENT_PREFIX)));
}

string Trim(string value)
{
   StringTrimLeft(value);
   StringTrimRight(value);
   return value;
}

void UpdateStatsDashboard()
{
   if(!ShowStatsDashboard)
   {
      ObjectDelete(0, STATS_DASHBOARD_OBJECT);
      return;
   }

   TradeStats stats[];

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOurCopiedPosition())
         continue;

      string symbol = PositionGetString(POSITION_SYMBOL);
      int index = FindTradeStatsIndex(stats, symbol);
      if(index < 0)
      {
         int size = ArraySize(stats);
         ArrayResize(stats, size + 1);
         index = size;
         stats[index].symbol = symbol;
         stats[index].trades = 0;
         stats[index].wins = 0;
         stats[index].losses = 0;
         stats[index].net_profit = 0.0;
         stats[index].gross_profit = 0.0;
         stats[index].gross_loss = 0.0;
      }

      double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      stats[index].trades++;
      stats[index].net_profit += profit;
      if(profit >= 0.0)
      {
         stats[index].wins++;
         stats[index].gross_profit += profit;
      }
      else
      {
         stats[index].losses++;
         stats[index].gross_loss += profit;
      }
   }

   string text = "Copied Open Stats\n";
   int total = ArraySize(stats);
   if(total <= 0)
   {
      text += "No copied open trades";
   }
   else
   {
      for(int i = 0; i < total; i++)
      {
         text += stats[i].symbol + ": " +
                 (string)stats[i].trades +
                 " open, P/L " +
                 DoubleToString(stats[i].net_profit, 2) + "\n";
      }
   }

   if(ObjectFind(0, STATS_DASHBOARD_OBJECT) < 0)
   {
      ObjectCreate(0, STATS_DASHBOARD_OBJECT, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, STATS_DASHBOARD_OBJECT, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
      ObjectSetInteger(0, STATS_DASHBOARD_OBJECT, OBJPROP_XDISTANCE, 20);
      ObjectSetInteger(0, STATS_DASHBOARD_OBJECT, OBJPROP_YDISTANCE, 20);
      ObjectSetInteger(0, STATS_DASHBOARD_OBJECT, OBJPROP_FONTSIZE, 10);
      ObjectSetInteger(0, STATS_DASHBOARD_OBJECT, OBJPROP_COLOR, clrWhite);
   }

   ObjectSetString(0, STATS_DASHBOARD_OBJECT, OBJPROP_TEXT, text);
}

int FindTradeStatsIndex(const TradeStats &stats[], const string symbol)
{
   int total = ArraySize(stats);
   for(int i = 0; i < total; i++)
   {
      if(stats[i].symbol == symbol)
         return i;
   }

   return -1;
}

void UpdateDashboard()
{
   if(!ShowChartStatus)
      return;

   string mode = "Exact same";
   if(CopyMode == COPY_EXACT_OPPOSITE)
      mode = "Exact opposite";

   int signal_age = 0;
   if(source_time > 0)
      signal_age = (int)(TimeCurrent() - source_time);

    string text =
       "Minimal Trade Copier\n" +
       "Status: working\n" +
       "Key: " + SafeKey(CopierKey) + "\n" +
       "Mode: " + mode + "\n" +
       "Entry: " + EntryModeStatusLine() + "\n" +
       "Partial TP booking: " + PartialTpBookingStatusLine() + "\n" +
       "Profit trailing SL: " + ProfitProgressTrailingStatusLine() + "\n" +
       "Sender exit: " + SenderExitActionStatusLine() + "\n" +
       "Replay carry-in trades: " + ReplayCarryInStatusLine() + "\n" +
       "Aggressive sender-exit TP: " + AggressiveSenderExitTpStatusLine() + "\n" +
       "Bad behaviour exits: " + BadBehaviourSenderHandlingStatusLine() + "\n" +
       LotSizingStatusLine() +
       "Copy SL/TP: " + (CopyStopLossTakeProfit ? "yes" : "no") + "\n" +
       "TP RR adjust: " + (AdjustTakeProfitToCopiedRR ? "yes" : "no") + "\n" +
       "Symbol exposure limit: " + OneTradePerSymbolStatusLine() + "\n" +
       "Symbol mapping: " + SymbolMappingStatusLine() + "\n" +
       "Sender account: " + (string)source_login + "\n" +
       "Sender open trades: " + (string)ArraySize(sources) + "\n" +
      "Copied trades managed here: " + (string)CountOurCopiedPositions() + "\n" +
      "Copied pending orders here: " + (string)CountOurCopiedOrders() + "\n" +
      "Sender signal age: " + (string)signal_age + " sec\n" +
      "Last action: " + last_action + "\n";

   if(last_error != "")
      text += "Last error: " + last_error + "\n";

    Comment(text);
}

string EntryModeStatusLine()
{
   if(IsPendingEntryMode())
      return "pending order at sender entry";

   return "market order immediately";
}

string ReplayCarryInStatusLine()
{
   if(SkipTradesOpenedBeforeReplayStart)
      return "skip source trades opened before " + TimeToString(replay_start_time, TIME_DATE | TIME_SECONDS);

   return "copy active source trades already open at replay start";
}

string PartialTpBookingStatusLine()
{
   if(!EnablePartialTpBooking)
      return "off";

   return "close " + DoubleToString(PartialTpClosePercentClamped(), 2) +
          "% at " + DoubleToString(PartialTpTriggerPercentClamped(), 2) +
          "% of entry-to-TP distance";
}

string ProfitProgressTrailingStatusLine()
{
   if(!EnableProfitProgressTrailingSL)
      return "off";

   string stop_text = "move SL to breakeven";
   if(ProfitTrailStopMode == PROFIT_TRAIL_SL_REDUCE_ORIGINAL_LOSS)
   {
      double remaining_loss_percent = ProfitTrailRemainingLossPercentClamped();
      if(remaining_loss_percent <= 0.0)
         stop_text = "move SL to breakeven";
      else
         stop_text = "leave " + DoubleToString(remaining_loss_percent, 2) + "% original SL risk";
   }

   return "at " + DoubleToString(ProfitTrailTriggerPercentClamped(), 2) +
          "% of TP profit, " + stop_text +
          "; sender exit closes trade";
}

string ProfitLockStatusLine()
{
   double percent = MathMax(0.0, MathMin(100.0, SenderExitProfitLockPercent));
   if(percent <= 0.0)
      return "move SL to breakeven";

   string basis = "open profit";
   if(SenderExitProfitLockBasis == SENDER_EXIT_LOCK_FULL_TP_PROFIT)
      basis = "full TP profit";

   return "lock " + DoubleToString(percent, 2) + "% " + basis;
}

string SenderExitActionStatusLine()
{
   if(EnableProfitProgressTrailingSL)
      return "close copied trade (profit trailing SL mode)";

   if(SenderExitAction == SENDER_EXIT_CLOSE_ALWAYS)
      return "close copied trade";

   if(SenderExitAction == SENDER_EXIT_PROTECT_ALWAYS)
      return ProfitLockStatusLine();

   return "smart: protect profit, close loss";
}

string AggressiveSenderExitTpStatusLine()
{
   if(!AggressiveCloseNearTpOnSenderExit)
      return "off";

   return "on, spread x" + DoubleToString(MathMax(0.0, AggressiveCloseSpreadMultiplier), 2);
}

string BadBehaviourSenderHandlingStatusLine()
{
   if(!BadBehaviourSenderExitDetection)
      return "off";

   return "on, TP progress " + DoubleToString(MathMax(0.0, MathMin(100.0, BadBehaviourTpExitProgressPercent)), 1) +
          "% / SL progress " + DoubleToString(MathMax(0.0, MathMin(100.0, BadBehaviourSlExitProgressPercent)), 1) + "%";
}

string OneTradePerSymbolStatusLine()
{
   if(!EnforceOneTradePerSymbol)
      return "off";

   int max_positions = MaxCopiedPositionsAllowedPerSymbol();
   string max_text = (max_positions <= 0 ? "unlimited" : (string)max_positions);
   string text = "on, max " + max_text + " copied position/order slot(s) per symbol";
   if(SkipSenderTradesSeenWhileSymbolBusy)
      text += ", skip stale busy-ticket signals";
   else
      text += ", wait while busy";

   int skipped = CountSkippedSourcesInCurrentSignal();
   if(skipped > 0)
      text += " (" + (string)skipped + " current skipped)";

   return text;
}

string SymbolMappingStatusLine()
{
   if(SymbolMode == SYMBOL_MULTI_PAIR)
   {
      string text = "";

      if(Trim(SenderSymbol1) != "" && Trim(CopierSymbol1) != "")
         text += Trim(SenderSymbol1) + "->" + Trim(CopierSymbol1);

      if(Trim(SenderSymbol2) != "" && Trim(CopierSymbol2) != "")
      {
         if(text != "")
            text += "; ";
         text += Trim(SenderSymbol2) + "->" + Trim(CopierSymbol2);
      }

      if(Trim(SenderSymbol3) != "" && Trim(CopierSymbol3) != "")
      {
         if(text != "")
            text += "; ";
         text += Trim(SenderSymbol3) + "->" + Trim(CopierSymbol3);
      }

      if(text == "")
         return "multi-pair: no pairs configured";

      return "multi-pair: " + text;
   }

   string custom = Trim(CustomSymbol);
   if(custom != "")
      return "single-pair: all signals -> " + custom;

   return "single-pair: same as sender";
}

string LotSizingStatusLine()
{
   if(LotMode == COPIER_LOT_FIXED_STARTING_BALANCE_RISK)
   {
      double risk_amount = RiskStartingBalance * (RiskPerTradePercent / 100.0);
      return "Lot sizing: fixed risk " + DoubleToString(RiskPerTradePercent, 2) +
             "% of " + DoubleToString(RiskStartingBalance, 2) +
             " = " + DoubleToString(risk_amount, 2) + "\n";
   }

   if(LotMode == COPIER_LOT_CURRENT_BALANCE_RISK)
   {
      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      double risk_amount = balance * (RiskPerTradePercent / 100.0);
      return "Lot sizing: current balance risk " + DoubleToString(RiskPerTradePercent, 2) +
             "% of " + DoubleToString(balance, 2) +
             " = " + DoubleToString(risk_amount, 2) + "\n";
   }

   return "Lot multiplier: " + DoubleToString(LotMultiplier, 2) + "\n";
}

int CountSkippedSourcesInCurrentSignal()
{
   int count = 0;
   int total = ArraySize(sources);
   for(int i = 0; i < total; i++)
   {
      if(SkippedSourceAlreadyMarked(sources[i].ticket))
         count++;
   }

   return count;
}

int CountOurCopiedPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket != 0 && IsOurCopiedPosition())
         count++;
   }
   return count;
}

int CountOurCopiedOrders()
{
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket != 0 && IsOurCopiedOrder())
         count++;
   }
   return count;
}

string PositionTypeName(const long type)
{
   if(type == POSITION_TYPE_BUY)
      return "BUY";
   return "SELL";
}

string PendingOrderTypeName(const ENUM_ORDER_TYPE type)
{
   if(type == ORDER_TYPE_BUY_LIMIT)
      return "BUY LIMIT";
   if(type == ORDER_TYPE_BUY_STOP)
      return "BUY STOP";
   if(type == ORDER_TYPE_SELL_LIMIT)
      return "SELL LIMIT";
   if(type == ORDER_TYPE_SELL_STOP)
      return "SELL STOP";

   return "PENDING";
}
