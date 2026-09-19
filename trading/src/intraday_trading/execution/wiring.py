"""Wires real components together from `Settings` -- the only place in this codebase
that constructs a real `AlpacaBroker` (via `AlpacaBroker.paper()`, which is itself the
only way to get one; see CLAUDE.md and broker/alpaca_broker.py's docstring on why there
is deliberately no `.live()` path yet).
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime

from intraday_trading.alerting.telegram import TelegramAlerter
from intraday_trading.broker.alpaca_broker import AlpacaBroker
from intraday_trading.config import Settings
from intraday_trading.data.client import AlpacaMarketDataClient
from intraday_trading.execution.alpaca_feed import AlpacaPollingFeed
from intraday_trading.execution.event_loop import PaperTradingLoop
from intraday_trading.risk.risk_manager import RiskManager
from intraday_trading.session.calendar import ExchangeCalendar
from intraday_trading.session.clock import SessionClock
from intraday_trading.state.reconciler import Reconciler
from intraday_trading.storage.error_log import ErrorLog
from intraday_trading.storage.order_log import OrderLog
from intraday_trading.storage.position_record_store import PositionRecordStore
from intraday_trading.storage.rejection_log import RejectionLog
from intraday_trading.storage.risk_state_store import RiskStateStore
from intraday_trading.strategies.base import Strategy
from intraday_trading.strategies.spy_momentum import SpyMomentumConfig, SpyMomentumStrategy


@dataclass
class PaperTradingComponents:
    broker: AlpacaBroker
    risk_manager: RiskManager
    reconciler: Reconciler
    loop: PaperTradingLoop
    alerter: TelegramAlerter


def build_paper_trading_components(
    settings: Settings, symbols: list[str]
) -> PaperTradingComponents:
    broker = AlpacaBroker.paper(settings)
    data_client = AlpacaMarketDataClient.from_settings(settings)
    feed = AlpacaPollingFeed(data_client, symbols, settings.alpaca_data_feed)

    clock = SessionClock(
        calendar=ExchangeCalendar(),
        no_entry_first_minutes=settings.risk.no_entry_first_minutes,
        no_entry_last_minutes=settings.risk.no_entry_last_minutes,
        flatten_before_close_minutes=settings.risk.flatten_before_close_minutes,
    )
    position_records = PositionRecordStore(settings.database_path)
    # GOLIVE-006: only ever set when live_trading is actually on (which itself needs
    # the SAFE-002/003 confirmation string) -- always None in paper, so this can never
    # accidentally cap a paper order.
    live_notional_cap_usd = (
        settings.live_equity_cap_gbp * settings.approx_gbp_usd_rate
        if settings.live_trading
        else None
    )
    risk_manager = RiskManager(
        broker=broker,
        limits=settings.risk,
        clock=clock,
        state_store=RiskStateStore(settings.database_path),
        rejection_log=RejectionLog(settings.database_path),
        position_records=position_records,
        order_log=OrderLog(settings.database_path),
        live_notional_cap_usd=live_notional_cap_usd,
    )
    alerter = TelegramAlerter(settings.telegram_bot_token, settings.telegram_chat_id)
    reconciler = Reconciler(broker, position_records, risk_manager, alerter)

    # Only ever the default (house_risk) config -- paper_faithful is for backtest
    # replication only (docs/STRATEGY_SPEC_SPY.md §7) and is never wired up here. Step 7's
    # ORB strategy has no spec yet, so it isn't attached even when its symbols are polled.
    strategies: list[Strategy] = []
    if "SPY" in {s.upper() for s in symbols}:
        strategies.append(SpyMomentumStrategy(symbol="SPY", config=SpyMomentumConfig()))

    loop = PaperTradingLoop(
        strategies=strategies,
        data_feed=feed,
        risk_manager=risk_manager,
        reconciler=reconciler,
        alerter=alerter,
        kill_switch_file=settings.kill_switch_file,
        now_provider=lambda: datetime.now(tz=UTC),
        broker_clock_provider=lambda: broker.get_clock().timestamp,
        error_log=ErrorLog(settings.database_path),
    )
    return PaperTradingComponents(
        broker=broker,
        risk_manager=risk_manager,
        reconciler=reconciler,
        loop=loop,
        alerter=alerter,
    )
