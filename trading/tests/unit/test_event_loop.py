from __future__ import annotations

from collections.abc import Callable
from datetime import UTC, datetime, timedelta
from pathlib import Path

from intraday_trading.broker.base import Side
from intraday_trading.config import RiskLimits
from intraday_trading.execution.event_loop import PaperTradingLoop
from intraday_trading.risk.risk_manager import RiskManager
from intraday_trading.risk.signals import EntrySignal, ExitSignal
from intraday_trading.session.calendar import EXCHANGE_TZ, ExchangeCalendar
from intraday_trading.session.clock import SessionClock, TimeBox
from intraday_trading.state.reconciler import Reconciler
from intraday_trading.storage.error_log import ErrorLog
from intraday_trading.storage.position_record_store import PositionRecordStore
from intraday_trading.storage.rejection_log import RejectionLog
from intraday_trading.storage.risk_state_store import RiskStateStore
from intraday_trading.strategies.base import Bar, StrategyContext
from tests.unit.fakes import FakeBroker

T0 = datetime(2024, 1, 2, 9, 50, tzinfo=EXCHANGE_TZ)  # past the default 15-min no-entry window


class FakeAlerter:
    def __init__(self) -> None:
        self.alerts: list[str] = []
        self.summaries: list[str] = []

    def alert(self, text: str) -> None:
        self.alerts.append(text)

    def daily_summary(self, text: str) -> None:
        self.summaries.append(text)


class FakeFeed:
    def __init__(self, responses: list[object]) -> None:
        # each element is either a dict[str, Bar] to return, or an Exception to raise
        self._responses = list(responses)

    def poll(self) -> dict[str, Bar]:
        if not self._responses:
            return {}
        response = self._responses.pop(0)
        if isinstance(response, Exception):
            raise response
        assert isinstance(response, dict)
        return response


class FakeStrategy:
    name = "fake"

    def __init__(
        self,
        signal_factory: Callable[[str, Bar], list[EntrySignal | ExitSignal]] | None = None,
    ) -> None:
        self.calls: list[tuple[str, Bar]] = []
        self._signal_factory = signal_factory

    def on_bar(
        self, symbol: str, bar: Bar, context: StrategyContext
    ) -> list[EntrySignal | ExitSignal]:
        self.calls.append((symbol, bar))
        if self._signal_factory is None:
            return []
        return self._signal_factory(symbol, bar)


def _bar(ts: datetime, price: float = 100.0) -> Bar:
    return Bar(ts=ts, open=price, high=price, low=price, close=price, volume=1000.0)


def _setup(
    tmp_path: Path,
    strategies: list[FakeStrategy] | None = None,
    feed_responses: list[object] | None = None,
    kill_file: Path | None = None,
    broker_clock_provider: Callable[[], datetime] | None = None,
    now_provider: Callable[[], datetime] | None = None,
    limits: RiskLimits | None = None,
    error_log: ErrorLog | None = None,
):
    db = tmp_path / "loop.db"
    time_box = TimeBox(T0)
    resolved_limits = limits or RiskLimits(min_avg_dollar_volume_usd=1.0, min_price_usd=0.01)
    clock = SessionClock(
        calendar=ExchangeCalendar(),
        no_entry_first_minutes=resolved_limits.no_entry_first_minutes,
        no_entry_last_minutes=resolved_limits.no_entry_last_minutes,
        flatten_before_close_minutes=resolved_limits.flatten_before_close_minutes,
        now_provider=time_box,
    )
    broker = FakeBroker()
    records = PositionRecordStore(db)
    risk_manager = RiskManager(
        broker=broker,
        limits=resolved_limits,
        clock=clock,
        state_store=RiskStateStore(db),
        rejection_log=RejectionLog(db),
        position_records=records,
    )
    alerter = FakeAlerter()
    reconciler = Reconciler(broker, records, risk_manager, alerter)
    feed = FakeFeed(feed_responses or [{}])
    loop = PaperTradingLoop(
        strategies=list(strategies or []),
        data_feed=feed,
        risk_manager=risk_manager,
        reconciler=reconciler,
        alerter=alerter,
        kill_switch_file=kill_file or (tmp_path / "KILL_SWITCH"),
        now_provider=now_provider or (lambda: time_box.value),
        broker_clock_provider=broker_clock_provider,
        sleep=lambda _seconds: None,
        error_log=error_log,
    )
    return loop, broker, risk_manager, alerter, time_box


def test_startup_reconciles_and_begins_session(tmp_path: Path) -> None:
    loop, _, risk_manager, _, _ = _setup(tmp_path)
    loop.startup()
    assert risk_manager.halt_status().trading_day == T0.date()


def test_KILL_002_kill_file_present_trips_switch_and_skips_polling(tmp_path: Path) -> None:
    kill_file = tmp_path / "KILL_SWITCH"
    kill_file.write_text("")
    strategy = FakeStrategy()
    loop, broker, risk_manager, alerter, _ = _setup(
        tmp_path, strategies=[strategy], kill_file=kill_file
    )

    loop.run_once()

    assert risk_manager.is_halted() is True
    assert broker.cancel_all_called == 1
    assert broker.close_all_called == 1
    assert strategy.calls == []
    assert any("Kill switch" in a for a in alerter.alerts)


def test_EXEC_010_clock_drift_halts_and_skips_polling(tmp_path: Path) -> None:
    strategy = FakeStrategy()
    broker_time = T0.astimezone(UTC)
    loop, _, risk_manager, alerter, _ = _setup(
        tmp_path,
        strategies=[strategy],
        broker_clock_provider=lambda: broker_time,
        now_provider=lambda: broker_time + timedelta(seconds=30),
    )

    loop.run_once()

    assert risk_manager.is_halted() is True
    assert strategy.calls == []
    assert any("Clock drift" in a for a in alerter.alerts)


def test_no_drift_alert_when_clocks_agree(tmp_path: Path) -> None:
    broker_time = T0.astimezone(UTC)
    loop, _, risk_manager, alerter, _ = _setup(
        tmp_path,
        broker_clock_provider=lambda: broker_time,
        now_provider=lambda: broker_time,
    )

    loop.run_once()

    assert risk_manager.is_halted() is False
    assert alerter.alerts == []


def test_no_drift_check_when_no_broker_clock_provider(tmp_path: Path) -> None:
    loop, _, risk_manager, alerter, _ = _setup(tmp_path, broker_clock_provider=None)
    loop.run_once()
    assert risk_manager.is_halted() is False
    assert alerter.alerts == []


def test_ALERT_001_new_halt_from_loss_limits_triggers_an_alert(tmp_path: Path) -> None:
    limits = RiskLimits(
        daily_loss_limit_pct=0.02, min_avg_dollar_volume_usd=1.0, min_price_usd=0.01
    )
    loop, broker, risk_manager, alerter, _ = _setup(tmp_path, limits=limits)
    loop.startup()
    broker.equity = 97_000.0  # -3%, past the 2% daily limit

    loop.run_once()

    assert risk_manager.is_halted() is True
    assert any("Trading halted" in a for a in alerter.alerts)


def test_no_duplicate_alert_when_already_halted(tmp_path: Path) -> None:
    limits = RiskLimits(
        daily_loss_limit_pct=0.02, min_avg_dollar_volume_usd=1.0, min_price_usd=0.01
    )
    loop, broker, risk_manager, alerter, _ = _setup(tmp_path, limits=limits)
    loop.startup()
    broker.equity = 97_000.0
    loop.run_once()
    alert_count_after_first = len(alerter.alerts)

    loop.run_once()  # still halted, must not alert again

    assert len(alerter.alerts) == alert_count_after_first


def test_session_flatten_sends_daily_summary_once(tmp_path: Path) -> None:
    near_close = datetime(2024, 1, 2, 15, 51, tzinfo=EXCHANGE_TZ)
    # explicit flatten window wide enough to include near_close
    limits = RiskLimits(
        min_avg_dollar_volume_usd=1.0, min_price_usd=0.01, flatten_before_close_minutes=15
    )
    loop, broker, risk_manager, alerter, time_box = _setup(tmp_path, limits=limits)
    time_box.value = near_close
    loop.startup()

    loop.run_once()
    loop.run_once()  # same day again -- must not send a second summary

    assert broker.close_all_called >= 1
    assert len(alerter.summaries) == 1


def test_EXEC_005_feed_disconnect_exhausted_triggers_alert_and_skips_strategies(
    tmp_path: Path,
) -> None:
    strategy = FakeStrategy()
    loop, _, _, alerter, _ = _setup(
        tmp_path,
        strategies=[strategy],
        feed_responses=[ConnectionError("down")] * 5,
    )
    loop.startup()

    loop.run_once()

    assert strategy.calls == []
    assert any("disconnected" in a for a in alerter.alerts)


def test_EXEC_005_feed_recovers_after_transient_failures(tmp_path: Path) -> None:
    strategy = FakeStrategy()
    bar = _bar(T0)
    loop, _, _, alerter, _ = _setup(
        tmp_path,
        strategies=[strategy],
        feed_responses=[ConnectionError("blip"), ConnectionError("blip"), {"AAPL": bar}],
    )
    loop.startup()

    loop.run_once()

    assert strategy.calls == [("AAPL", bar)]
    assert alerter.alerts == []


def test_bars_are_fed_to_every_strategy_and_signals_reach_risk_manager(tmp_path: Path) -> None:
    bar = _bar(T0)

    def factory(symbol: str, b: Bar) -> list[EntrySignal]:
        return [
            EntrySignal(
                strategy="fake",
                symbol=symbol,
                side=Side.BUY,
                qty=1,
                entry_price=b.close,
                stop_price=b.close - 5,
                take_profit_price=None,
                current_price=b.close,
                avg_dollar_volume=10_000_000.0,
                spread_pct=0.001,
                signal_seq="s1",
            )
        ]

    strategy = FakeStrategy(signal_factory=factory)
    loop, broker, _, _, _ = _setup(tmp_path, strategies=[strategy], feed_responses=[{"AAPL": bar}])
    loop.startup()

    loop.run_once()

    assert strategy.calls == [("AAPL", bar)]
    assert len(broker.submitted_orders) == 1
    assert broker.submitted_orders[0].symbol == "AAPL"


def test_STRAT_002_exit_signals_reach_risk_manager_via_the_loop(tmp_path: Path) -> None:
    from intraday_trading.broker.base import PositionInfo

    bar = _bar(T0)

    def factory(symbol: str, b: Bar) -> list[EntrySignal | ExitSignal]:
        return [ExitSignal(strategy="fake", symbol=symbol, reason="stop", signal_seq="e1")]

    strategy = FakeStrategy(signal_factory=factory)
    loop, broker, _, _, _ = _setup(tmp_path, strategies=[strategy], feed_responses=[{"AAPL": bar}])
    broker.positions = [PositionInfo("AAPL", 1, Side.BUY, 100.0, 100.0, 0.0)]
    loop.startup()

    loop.run_once()

    assert broker.positions == []


def test_no_bars_means_no_strategy_calls(tmp_path: Path) -> None:
    strategy = FakeStrategy()
    loop, _, _, _, _ = _setup(tmp_path, strategies=[strategy], feed_responses=[{}])
    loop.startup()

    loop.run_once()

    assert strategy.calls == []


def test_ALERT_002_unhandled_error_in_iteration_is_caught_and_alerted(tmp_path: Path) -> None:
    class BrokenStrategy:
        name = "broken"

        def on_bar(self, symbol: str, bar: Bar, context: StrategyContext) -> list[EntrySignal]:
            raise RuntimeError("strategy bug")

    bar = _bar(T0)
    loop, _, _, alerter, _ = _setup(
        tmp_path,
        strategies=[BrokenStrategy()],
        feed_responses=[{"AAPL": bar}],  # type: ignore[list-item]
    )
    loop.startup()

    loop.run_once()  # must not raise

    assert any("Unhandled error" in a for a in alerter.alerts)


def test_unhandled_error_is_persisted_when_error_log_configured(tmp_path: Path) -> None:
    class BrokenStrategy:
        name = "broken"

        def on_bar(self, symbol: str, bar: Bar, context: StrategyContext) -> list[EntrySignal]:
            raise RuntimeError("strategy bug")

    error_log = ErrorLog(tmp_path / "loop.db")
    bar = _bar(T0)
    loop, _, _, _, _ = _setup(
        tmp_path,
        strategies=[BrokenStrategy()],  # type: ignore[list-item]
        feed_responses=[{"AAPL": bar}],
        error_log=error_log,
    )
    loop.startup()

    loop.run_once()

    assert error_log.count_last_days(1) == 1


def test_unhandled_error_not_persisted_when_no_error_log_configured(tmp_path: Path) -> None:
    class BrokenStrategy:
        name = "broken"

        def on_bar(self, symbol: str, bar: Bar, context: StrategyContext) -> list[EntrySignal]:
            raise RuntimeError("strategy bug")

    bar = _bar(T0)
    loop, _, _, alerter, _ = _setup(
        tmp_path,
        strategies=[BrokenStrategy()],  # type: ignore[list-item]
        feed_responses=[{"AAPL": bar}],
    )
    loop.startup()

    loop.run_once()  # must not raise even without an error_log configured

    assert any("Unhandled error" in a for a in alerter.alerts)
    assert ErrorLog(tmp_path / "loop.db").count_last_days(1) == 0
