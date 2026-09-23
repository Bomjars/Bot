"""Wires real components together from `Settings` -- the only place in this codebase
that constructs a real broker (`AlpacaBroker.paper()`/`IBKRBroker.paper()`, each the
only way to get one in paper mode; see CLAUDE.md and the two adapters' own docstrings
on why there is deliberately no unconditional `.live()` path).

Market data (bars) always comes from Alpaca regardless of `broker_provider` -- the
`Broker` a strategy trades through and the `MarketDataFeed` it reads bars from are
independent Protocols in this codebase, and building an IBKR-native bar feed is a
separate, larger piece of work than routing orders through IBKR. This is a deliberate
scoping choice, not an oversight: it still needs Alpaca paper keys configured even when
`broker_provider="ibkr"`.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime

from intraday_trading.alerting.telegram import TelegramAlerter
from intraday_trading.broker.alpaca_broker import AlpacaBroker
from intraday_trading.broker.base import Broker
from intraday_trading.broker.ibkr_broker import IBKRBroker
from intraday_trading.config import Settings
from intraday_trading.data.client import AlpacaMarketDataClient
from intraday_trading.execution.alpaca_feed import AlpacaPollingFeed
from intraday_trading.execution.event_loop import PaperTradingLoop
from intraday_trading.execution.fill_recorder import record_fill
from intraday_trading.execution.reconnect import retry_with_backoff
from intraday_trading.risk.risk_manager import RiskManager
from intraday_trading.session.calendar import ExchangeCalendar
from intraday_trading.session.clock import SessionClock
from intraday_trading.state.reconciler import Reconciler
from intraday_trading.storage.error_log import ErrorLog
from intraday_trading.storage.fill_log import FillLog
from intraday_trading.storage.order_log import OrderLog
from intraday_trading.storage.position_record_store import PositionRecordStore
from intraday_trading.storage.rejection_log import RejectionLog
from intraday_trading.storage.risk_state_store import RiskStateStore
from intraday_trading.strategies.base import Strategy
from intraday_trading.strategies.spy_momentum import SpyMomentumConfig, SpyMomentumStrategy

BROKER_PROVIDERS = ("alpaca", "ibkr")


@dataclass
class PaperTradingComponents:
    broker: Broker
    risk_manager: RiskManager
    reconciler: Reconciler
    loop: PaperTradingLoop
    alerter: TelegramAlerter


def _build_broker_hooks(
    broker_provider: str, settings: Settings, order_log: OrderLog
) -> tuple[Broker, Callable[[], None] | None, Callable[[], None] | None]:
    """Returns the broker plus its two loop hooks (see event_loop.py's
    `connection_guard`/`fill_poller`) -- both None for Alpaca, whose REST calls are
    stateless and whose fills are already synchronous."""
    if broker_provider == "alpaca":
        return AlpacaBroker.paper(settings), None, None
    if broker_provider == "ibkr":
        ibkr_broker = IBKRBroker.paper(settings)
        fill_log = FillLog(settings.database_path)

        def connection_guard() -> None:
            if not ibkr_broker.is_connected():
                retry_with_backoff(ibkr_broker.reconnect, max_attempts=5, base_delay_seconds=2.0)

        def fill_poller() -> None:
            for event in ibkr_broker.poll_fills():
                record_fill(fill_log, order_log, event)

        return ibkr_broker, connection_guard, fill_poller
    raise ValueError(f"broker_provider must be one of {BROKER_PROVIDERS}, got {broker_provider!r}")


def build_paper_trading_components(
    settings: Settings, symbols: list[str], broker_provider: str = "alpaca"
) -> PaperTradingComponents:
    order_log = OrderLog(settings.database_path)
    broker, connection_guard, fill_poller = _build_broker_hooks(
        broker_provider, settings, order_log
    )
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
        order_log=order_log,
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
        connection_guard=connection_guard,
        fill_poller=fill_poller,
    )
    return PaperTradingComponents(
        broker=broker,
        risk_manager=risk_manager,
        reconciler=reconciler,
        loop=loop,
        alerter=alerter,
    )
