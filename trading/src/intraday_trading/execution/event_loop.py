"""The paper/live trading event loop: data feed -> strategies -> RiskManager -> broker.
Drives the exact same `Strategy` and `RiskManager` classes the backtester drives
(BT-001) -- the only thing that differs is where bars come from.

Known, documented simplifications for this step:
- The data feed is polled (a `MarketDataFeed.poll()` call each iteration), not a
  websocket stream. For 1-minute-bar intraday strategies this is materially simpler and
  just as timely; true streaming is a future enhancement, not a requirement this system
  needs to meet.
- EXEC-009 (rate-limit backoff) is applied to the data feed poll, not to RiskManager's
  own broker calls during order submission -- a 429 there is already handled safely by
  RiskManager's existing fail-closed behaviour (RISK-020): it becomes a rejected order
  this cycle rather than a retry loop, which is correct but not optimal. Documented here
  rather than silently assumed.
- The daily summary "send once per day" guarantee is in-memory per running process, not
  persisted -- a restart in the last moments of a trading day could in theory resend it.
"""

from __future__ import annotations

from collections import defaultdict
from collections.abc import Callable
from datetime import date, datetime
from pathlib import Path
from typing import Protocol

import structlog

from intraday_trading.alerting.base import Alerter
from intraday_trading.execution.clock_drift import exceeds_threshold
from intraday_trading.execution.reconnect import RetriesExhausted, retry_with_backoff
from intraday_trading.killswitch.kill_switch import is_kill_file_present, trip
from intraday_trading.risk.risk_manager import RiskManager
from intraday_trading.risk.signals import EntrySignal
from intraday_trading.state.reconciler import Reconciler, ReconciliationResult
from intraday_trading.storage.error_log import ErrorLog
from intraday_trading.strategies.base import Bar, Strategy, StrategyContext

logger = structlog.get_logger(__name__)


class MarketDataFeed(Protocol):
    def poll(self) -> dict[str, Bar]:
        """Return any new bars since the last call, keyed by symbol. Empty dict if
        nothing new. May raise on a transient failure -- the loop retries with backoff."""
        ...  # pragma: no cover -- Protocol stub, never executed


class PaperTradingLoop:
    def __init__(
        self,
        strategies: list[Strategy],
        data_feed: MarketDataFeed,
        risk_manager: RiskManager,
        reconciler: Reconciler,
        alerter: Alerter,
        kill_switch_file: Path,
        clock_drift_threshold_seconds: float = 5.0,
        now_provider: Callable[[], datetime] = datetime.now,
        broker_clock_provider: Callable[[], datetime] | None = None,
        max_poll_attempts: int = 5,
        poll_retry_base_delay_seconds: float = 1.0,
        sleep: Callable[[float], None] = lambda _seconds: None,
        error_log: ErrorLog | None = None,
        connection_guard: Callable[[], None] | None = None,
        fill_poller: Callable[[], None] | None = None,
    ) -> None:
        self._strategies = strategies
        self._data_feed = data_feed
        self._risk_manager = risk_manager
        self._reconciler = reconciler
        self._alerter = alerter
        self._kill_switch_file = kill_switch_file
        self._clock_drift_threshold_seconds = clock_drift_threshold_seconds
        self._now_provider = now_provider
        self._broker_clock_provider = broker_clock_provider
        self._max_poll_attempts = max_poll_attempts
        self._poll_retry_base_delay_seconds = poll_retry_base_delay_seconds
        self._sleep = sleep
        self._error_log = error_log
        self._connection_guard = connection_guard
        """Broker-specific "am I still connected, and if not, reconnect (with
        backoff)" check -- e.g. IBKR's persistent socket connection needs this; Alpaca's
        stateless REST calls don't, so wiring only ever sets this for IBKR. Raising
        (e.g. retries exhausted) propagates into `run_once()`'s own catch-all, which
        logs/alerts and skips the rest of this tick -- "no new orders" falls out of that
        for free, rather than needing its own special case here."""
        self._fill_poller = fill_poller
        """Broker-specific "drain any newly-completed fills into storage" step -- e.g.
        IBKRBroker.poll_fills() plus execution/fill_recorder.py's record_fill(), wrapped
        into a single closure by wiring.py so this module never needs to import an
        IBKR-specific type. None for Alpaca, whose REST fills are already synchronous."""
        self._history: dict[str, list[Bar]] = defaultdict(list)
        self._last_summary_date: date | None = None

    def startup(self) -> ReconciliationResult:
        result = self._reconciler.reconcile()
        self._risk_manager.begin_session()
        return result

    def run_once(self) -> None:
        try:
            self._run_once_unsafe()
        except Exception as exc:
            logger.exception("paper_trading_loop_iteration_failed")
            if self._error_log is not None:
                self._error_log.log(f"{type(exc).__name__}: {exc}")
            self._alerter.alert("Unhandled error in the paper-trading loop -- see logs.")

    def _run_once_unsafe(self) -> None:
        if self._connection_guard is not None:
            self._connection_guard()

        if self._fill_poller is not None:
            self._fill_poller()

        if is_kill_file_present(self._kill_switch_file):
            trip(self._risk_manager, "kill switch file detected")
            self._alerter.alert(
                "Kill switch file detected -- all orders cancelled, positions flattened."
            )
            return

        self._risk_manager.begin_session()

        if self._broker_clock_provider is not None and exceeds_threshold(
            self._now_provider(), self._broker_clock_provider(), self._clock_drift_threshold_seconds
        ):
            self._risk_manager.halt_for_clock_drift(
                f"local/broker clock drift exceeds {self._clock_drift_threshold_seconds}s"
            )
            self._alerter.alert("Clock drift detected -- entries halted.")
            return

        was_halted = self._risk_manager.is_halted()
        self._risk_manager.check_loss_limits()
        if self._risk_manager.is_halted() and not was_halted:
            self._alerter.alert(f"Trading halted: {self._risk_manager.halt_status().halt_reason}")

        if self._risk_manager.check_session_flatten():
            self._maybe_send_daily_summary()
            return

        try:
            new_bars = retry_with_backoff(
                self._data_feed.poll,
                max_attempts=self._max_poll_attempts,
                base_delay_seconds=self._poll_retry_base_delay_seconds,
                sleep=self._sleep,
            )
        except RetriesExhausted as exc:
            self._alerter.alert(f"Market data feed disconnected after retries: {exc}")
            return

        for symbol, bar in sorted(new_bars.items()):
            self._history[symbol].append(bar)
            context = StrategyContext(
                current_time=bar.ts,
                history_by_symbol=self._history,
                equity=self._risk_manager.get_account().equity,
                open_positions={p.symbol: p for p in self._risk_manager.get_positions()},
            )
            for strategy in self._strategies:
                for signal in strategy.on_bar(symbol, bar, context):
                    if isinstance(signal, EntrySignal):
                        self._risk_manager.check_and_submit_entry(signal)
                    else:
                        self._risk_manager.check_and_submit_exit(signal)

    def _maybe_send_daily_summary(self) -> None:
        today = self._now_provider().date()
        if self._last_summary_date == today:
            return
        account = self._risk_manager.halt_status()
        self._alerter.daily_summary(
            f"Session closed for {today}. Trades today: {account.trades_today}."
        )
        self._last_summary_date = today
