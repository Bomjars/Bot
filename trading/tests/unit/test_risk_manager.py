from __future__ import annotations

import threading
from datetime import datetime
from pathlib import Path

from intraday_trading.broker.base import PositionInfo, Side
from intraday_trading.config import RiskLimits
from intraday_trading.risk.risk_manager import RiskManager
from intraday_trading.risk.signals import EntrySignal, ExitSignal, HaltType
from intraday_trading.session.calendar import EXCHANGE_TZ, ExchangeCalendar
from intraday_trading.session.clock import SessionClock
from intraday_trading.storage.order_log import OrderLog
from intraday_trading.storage.position_record_store import PositionRecordStore
from intraday_trading.storage.rejection_log import RejectionLog
from intraday_trading.storage.risk_state_store import RiskStateStore
from tests.unit.fakes import FakeBroker

MID_SESSION = datetime(2024, 1, 2, 12, 0, tzinfo=EXCHANGE_TZ)  # well inside 9:30-16:00 ET


def _clock(now: datetime = MID_SESSION) -> SessionClock:
    return SessionClock(
        calendar=ExchangeCalendar(),
        no_entry_first_minutes=15,
        no_entry_last_minutes=30,
        flatten_before_close_minutes=10,
        now_provider=lambda: now,
    )


def _manager(
    tmp_path: Path,
    broker: FakeBroker | None = None,
    limits: RiskLimits | None = None,
    now: datetime = MID_SESSION,
    leveraged_etfs: frozenset[str] = frozenset(),
    live_notional_cap_usd: float | None = None,
) -> tuple[RiskManager, FakeBroker]:
    broker = broker or FakeBroker()
    db = tmp_path / "risk.db"
    manager = RiskManager(
        broker=broker,
        limits=limits or RiskLimits(),
        clock=_clock(now),
        state_store=RiskStateStore(db),
        rejection_log=RejectionLog(db),
        leveraged_etf_symbols=leveraged_etfs,
        live_notional_cap_usd=live_notional_cap_usd,
    )
    manager.begin_session()
    return manager, broker


def _signal(**overrides: object) -> EntrySignal:
    defaults: dict[str, object] = dict(
        strategy="test",
        symbol="AAPL",
        side=Side.BUY,
        qty=10,
        entry_price=100.0,
        stop_price=99.0,  # $1 stop distance
        take_profit_price=None,
        current_price=100.0,
        avg_dollar_volume=10_000_000.0,
        spread_pct=0.001,
        signal_seq="seq-1",
    )
    defaults.update(overrides)
    return EntrySignal(**defaults)  # type: ignore[arg-type]


def test_RISK_002_accept_when_within_all_limits(tmp_path: Path) -> None:
    manager, broker = _manager(tmp_path)
    decision = manager.check_and_submit_entry(_signal())
    assert decision.accepted is True
    assert len(broker.submitted_orders) == 1


def test_RISK_001_reject_when_risk_per_trade_exceeded(tmp_path: Path) -> None:
    # qty=10, stop distance $1 -> risk $10 on $100k equity = 0.01% risk, fine normally;
    # crank qty up so risk exceeds the 1% default limit ($1,000).
    manager, broker = _manager(tmp_path)
    decision = manager.check_and_submit_entry(_signal(qty=2000))  # risk = $2000 > 1% of 100k
    assert decision.accepted is False
    assert decision.reason == "risk_per_trade_exceeded"
    assert broker.submitted_orders == []


def test_RISK_003_reject_when_max_open_positions_reached(tmp_path: Path) -> None:
    broker = FakeBroker(
        positions=[
            PositionInfo("MSFT", 5, Side.BUY, 100, 100, 0),
            PositionInfo("GOOG", 5, Side.BUY, 100, 100, 0),
            PositionInfo("TSLA", 5, Side.BUY, 100, 100, 0),
        ]
    )
    manager, _ = _manager(tmp_path, broker=broker, limits=RiskLimits(max_open_positions=3))
    decision = manager.check_and_submit_entry(_signal())
    assert decision.accepted is False
    assert decision.reason == "max_open_positions_reached"


def test_RISK_004_reject_when_position_pct_exceeded(tmp_path: Path) -> None:
    # qty*entry_price = 10*100 = $1,000 notional; cap position pct so that's too big,
    # while keeping risk-per-trade ($10 risk) comfortably within its own 1% limit.
    manager, _ = _manager(tmp_path, limits=RiskLimits(max_position_pct_of_equity=0.005))
    decision = manager.check_and_submit_entry(_signal())
    assert decision.accepted is False
    assert decision.reason == "position_pct_exceeded"


def test_RISK_005_reject_when_leverage_exceeded(tmp_path: Path) -> None:
    broker = FakeBroker(equity=1_000.0, positions=[PositionInfo("MSFT", 9, Side.BUY, 100, 100, 0)])
    # existing notional 900 + new notional 1000 = 1900 > equity*1.0 (1000). Position-pct
    # limit widened to 100% so that check passes and the leverage check is what fires.
    limits = RiskLimits(max_open_positions=5, max_position_pct_of_equity=1.0)
    manager, _ = _manager(tmp_path, broker=broker, limits=limits)
    decision = manager.check_and_submit_entry(_signal(qty=10, entry_price=100.0, stop_price=99.5))
    assert decision.accepted is False
    assert decision.reason == "leverage_exceeded"


def test_GOLIVE_006_reject_when_live_notional_cap_exceeded(tmp_path: Path) -> None:
    manager, broker = _manager(tmp_path, live_notional_cap_usd=500.0)
    # notional = 10 * 100.0 = 1000 > cap of 500, well within every other limit
    decision = manager.check_and_submit_entry(_signal())
    assert decision.accepted is False
    assert decision.reason == "live_notional_cap_exceeded"
    assert broker.submitted_orders == []


def test_live_notional_cap_usd_property_reflects_construction(tmp_path: Path) -> None:
    capped, _ = _manager(tmp_path, live_notional_cap_usd=500.0)
    assert capped.live_notional_cap_usd == 500.0

    uncapped, _ = _manager(tmp_path / "b", live_notional_cap_usd=None)
    assert uncapped.live_notional_cap_usd is None


def test_no_live_cap_rejection_when_cap_not_configured(tmp_path: Path) -> None:
    manager, _ = _manager(tmp_path, live_notional_cap_usd=None)
    decision = manager.check_and_submit_entry(_signal())
    assert decision.accepted is True


def test_accepted_when_within_live_notional_cap(tmp_path: Path) -> None:
    manager, _ = _manager(tmp_path, live_notional_cap_usd=5_000.0)
    decision = manager.check_and_submit_entry(_signal())
    assert decision.accepted is True


def test_RISK_006_reject_leveraged_etf(tmp_path: Path) -> None:
    manager, _ = _manager(tmp_path, leveraged_etfs=frozenset({"TQQQ"}))
    decision = manager.check_and_submit_entry(_signal(symbol="TQQQ"))
    assert decision.accepted is False
    assert decision.reason == "leveraged_etf_excluded"


def test_RISK_010_missing_stop_rejected(tmp_path: Path) -> None:
    manager, _ = _manager(tmp_path)
    decision = manager.check_and_submit_entry(_signal(stop_price=0))
    assert decision.accepted is False
    assert decision.reason == "missing_stop_loss"


def test_reject_when_stop_equals_entry(tmp_path: Path) -> None:
    manager, _ = _manager(tmp_path)
    decision = manager.check_and_submit_entry(_signal(entry_price=100.0, stop_price=100.0))
    assert decision.accepted is False
    assert decision.reason == "invalid_stop_distance"


def test_reject_when_qty_not_positive(tmp_path: Path) -> None:
    manager, _ = _manager(tmp_path)
    decision = manager.check_and_submit_entry(_signal(qty=0))
    assert decision.accepted is False
    assert decision.reason == "qty_not_positive"


def test_RISK_011_max_trades_per_day(tmp_path: Path) -> None:
    manager, broker = _manager(tmp_path, limits=RiskLimits(max_trades_per_day=2))
    for i in range(2):
        decision = manager.check_and_submit_entry(_signal(signal_seq=f"seq-{i}"))
        assert decision.accepted is True
    decision = manager.check_and_submit_entry(_signal(signal_seq="seq-3"))
    assert decision.accepted is False
    assert decision.reason == "max_trades_per_day_reached"
    assert len(broker.submitted_orders) == 2


def test_RISK_012_no_entry_in_first_15_minutes(tmp_path: Path) -> None:
    manager, _ = _manager(tmp_path, now=datetime(2024, 1, 2, 9, 40, tzinfo=EXCHANGE_TZ))
    decision = manager.check_and_submit_entry(_signal())
    assert decision.accepted is False
    assert decision.reason == "outside_entry_window"


def test_RISK_017_price_below_minimum(tmp_path: Path) -> None:
    manager, _ = _manager(tmp_path, limits=RiskLimits(min_price_usd=5.0))
    decision = manager.check_and_submit_entry(
        _signal(current_price=2.0, entry_price=2.0, stop_price=1.9)
    )
    assert decision.accepted is False
    assert decision.reason == "price_below_minimum"


def test_RISK_018_avg_dollar_volume_below_minimum(tmp_path: Path) -> None:
    manager, _ = _manager(tmp_path, limits=RiskLimits(min_avg_dollar_volume_usd=1_000_000))
    decision = manager.check_and_submit_entry(_signal(avg_dollar_volume=100.0))
    assert decision.accepted is False
    assert decision.reason == "avg_dollar_volume_below_minimum"


def test_RISK_019_spread_too_wide(tmp_path: Path) -> None:
    manager, _ = _manager(tmp_path, limits=RiskLimits(max_spread_pct=0.001))
    decision = manager.check_and_submit_entry(_signal(spread_pct=0.02))
    assert decision.accepted is False
    assert decision.reason == "spread_too_wide"


def test_RISK_020_fail_closed_on_unexpected_broker_error(tmp_path: Path) -> None:
    broker = FakeBroker(raise_on_submit=RuntimeError("boom"))
    manager, _ = _manager(tmp_path, broker=broker)
    decision = manager.check_and_submit_entry(_signal())
    assert decision.accepted is False
    assert decision.reason is not None and decision.reason.startswith("internal_error:")


def test_RISK_022_rejection_is_persisted(tmp_path: Path) -> None:
    manager, _ = _manager(tmp_path)
    manager.check_and_submit_entry(_signal(stop_price=0))
    db = tmp_path / "risk.db"
    log = RejectionLog(db)
    assert log.count() == 1


def test_RISK_023_limits_are_config_driven(tmp_path: Path) -> None:
    strict_manager, _ = _manager(tmp_path, limits=RiskLimits(max_trades_per_day=1))
    decision_1 = strict_manager.check_and_submit_entry(_signal(signal_seq="a"))
    decision_2 = strict_manager.check_and_submit_entry(_signal(signal_seq="b"))
    assert decision_1.accepted is True
    assert decision_2.accepted is False


def test_RISK_024_concurrent_entries_cannot_double_accept(tmp_path: Path) -> None:
    broker = FakeBroker()
    manager, _ = _manager(tmp_path, broker=broker, limits=RiskLimits(max_open_positions=1))

    # Simulate the broker gaining a position the instant an order is accepted, as a real
    # broker would (via reconciliation) -- without the lock, two threads could both read
    # "0 open positions" before either's submission registers.
    original_submit = broker.submit_bracket_order

    def submit_and_register_position(request):  # type: ignore[no-untyped-def]
        order = original_submit(request)
        broker.positions.append(
            PositionInfo(
                request.symbol, request.qty, request.side, request.stop_loss_price, 100.0, 0.0
            )
        )
        return order

    broker.submit_bracket_order = submit_and_register_position  # type: ignore[method-assign]

    results: list[bool] = []

    def attempt(seq: str) -> None:
        decision = manager.check_and_submit_entry(_signal(signal_seq=seq, symbol=f"SYM{seq}"))
        results.append(decision.accepted)

    threads = [threading.Thread(target=attempt, args=(str(i),)) for i in range(5)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    assert results.count(True) == 1


def test_KILL_001_trip_kill_switch_cancels_then_flattens_and_halts(tmp_path: Path) -> None:
    broker = FakeBroker(positions=[PositionInfo("AAPL", 10, Side.BUY, 100, 100, 0)])
    manager, _ = _manager(tmp_path, broker=broker)

    manager.trip_kill_switch("test kill")

    assert broker.cancel_all_called == 1
    assert broker.close_all_called == 1
    assert manager.is_halted() is True

    decision = manager.check_and_submit_entry(_signal())
    assert decision.accepted is False
    assert decision.reason is not None and decision.reason.startswith("halted:")


def test_re_enable_clears_halt(tmp_path: Path) -> None:
    manager, _ = _manager(tmp_path)
    manager.trip_kill_switch("test")
    assert manager.is_halted() is True
    manager.re_enable()
    assert manager.is_halted() is False


def test_check_loss_limits_is_idempotent_once_halted(tmp_path: Path) -> None:
    broker = FakeBroker(
        equity=100_000.0, positions=[PositionInfo("AAPL", 10, Side.BUY, 100, 100, 0)]
    )
    manager, _ = _manager(tmp_path, broker=broker, limits=RiskLimits(daily_loss_limit_pct=0.02))

    broker.equity = 97_000.0
    first = manager.check_loss_limits()
    assert first.halted is True
    assert broker.close_all_called == 1

    second = manager.check_loss_limits()
    assert second.halted is True
    assert broker.close_all_called == 1  # not flattened a second time


def test_check_session_flatten_does_nothing_mid_session(tmp_path: Path) -> None:
    broker = FakeBroker()
    manager, _ = _manager(tmp_path, broker=broker, now=MID_SESSION)
    assert manager.check_session_flatten() is False
    assert broker.close_all_called == 0


def test_RISK_014_session_flatten_does_not_halt(tmp_path: Path) -> None:
    near_close = datetime(2024, 1, 2, 15, 55, tzinfo=EXCHANGE_TZ)  # 5 min before 16:00 close
    broker = FakeBroker(positions=[PositionInfo("AAPL", 10, Side.BUY, 100, 100, 0)])
    manager, _ = _manager(tmp_path, broker=broker, now=near_close)

    flattened = manager.check_session_flatten()

    assert flattened is True
    assert broker.close_all_called == 1
    assert manager.is_halted() is False


def test_RISK_007_daily_loss_flattens_and_halts(tmp_path: Path) -> None:
    broker = FakeBroker(
        equity=100_000.0, positions=[PositionInfo("AAPL", 10, Side.BUY, 100, 100, 0)]
    )
    manager, _ = _manager(tmp_path, broker=broker, limits=RiskLimits(daily_loss_limit_pct=0.02))

    broker.equity = 97_000.0  # -3%, past the 2% daily limit
    state = manager.check_loss_limits()

    assert state.halted is True
    assert state.halt_type == HaltType.DAILY_LOSS
    assert broker.close_all_called == 1


def test_RISK_008_weekly_loss_halts_and_persists_across_restart(tmp_path: Path) -> None:
    # Wide daily limit so the daily check doesn't trip first -- this test is about the
    # weekly limit specifically.
    limits = RiskLimits(weekly_loss_limit_pct=0.05, daily_loss_limit_pct=0.5)
    broker = FakeBroker(equity=100_000.0)
    manager, _ = _manager(tmp_path, broker=broker, limits=limits)

    broker.equity = 94_000.0  # -6%, past the 5% weekly limit
    state = manager.check_loss_limits()
    assert state.halted is True
    assert state.halt_type == HaltType.WEEKLY_LOSS

    # "restart": brand-new RiskManager instance pointed at the same DB file must still be halted
    rebuilt = RiskManager(
        broker=broker,
        limits=limits,
        clock=_clock(),
        state_store=RiskStateStore(tmp_path / "risk.db"),
        rejection_log=RejectionLog(tmp_path / "risk.db"),
    )
    assert rebuilt.is_halted() is True


def test_RISK_009_drawdown_circuit_breaker(tmp_path: Path) -> None:
    broker = FakeBroker(equity=100_000.0)
    manager, _ = _manager(
        tmp_path,
        broker=broker,
        limits=RiskLimits(
            drawdown_circuit_breaker_pct=0.10,
            daily_loss_limit_pct=0.5,
            weekly_loss_limit_pct=0.5,
        ),
    )
    manager.check_loss_limits()  # establishes peak_equity = 100_000

    broker.equity = 150_000.0
    manager.check_loss_limits()  # new peak = 150_000

    broker.equity = 130_000.0  # drawdown from peak = 13.3% > 10%
    state = manager.check_loss_limits()

    assert state.halted is True
    assert state.halt_type == HaltType.DRAWDOWN


def test_begin_session_called_twice_same_day_is_a_no_op(tmp_path: Path) -> None:
    broker = FakeBroker(equity=100_000.0)
    manager, _ = _manager(tmp_path, broker=broker)
    state_before = manager.halt_status()
    manager.begin_session()  # same day as the begin_session() already run by _manager()
    state_after = manager.halt_status()
    assert state_before.trading_day == state_after.trading_day
    assert state_before.daily_starting_equity == state_after.daily_starting_equity


def test_check_loss_limits_before_any_begin_session_does_not_crash(tmp_path: Path) -> None:
    # No begin_session() call at all: daily/weekly baselines are None and peak_equity
    # starts None too. With equity=0.0 the freshly-set peak_equity (0.0) is falsy, so
    # every comparison branch is skipped and this must still return cleanly, unhalted.
    broker = FakeBroker(equity=0.0)
    db = tmp_path / "risk.db"
    manager = RiskManager(
        broker=broker,
        limits=RiskLimits(),
        clock=_clock(),
        state_store=RiskStateStore(db),
        rejection_log=RejectionLog(db),
    )
    state = manager.check_loss_limits()
    assert state.halted is False


def test_begin_session_auto_clears_daily_loss_halt_next_day(tmp_path: Path) -> None:
    broker = FakeBroker(equity=100_000.0)
    day1 = datetime(2024, 1, 2, 12, 0, tzinfo=EXCHANGE_TZ)
    manager, _ = _manager(
        tmp_path, broker=broker, now=day1, limits=RiskLimits(daily_loss_limit_pct=0.02)
    )
    broker.equity = 97_000.0
    manager.check_loss_limits()
    assert manager.is_halted() is True

    day2 = datetime(2024, 1, 3, 9, 45, tzinfo=EXCHANGE_TZ)
    manager2 = RiskManager(
        broker=broker,
        limits=RiskLimits(daily_loss_limit_pct=0.02),
        clock=_clock(day2),
        state_store=RiskStateStore(tmp_path / "risk.db"),
        rejection_log=RejectionLog(tmp_path / "risk.db"),
    )
    manager2.begin_session()
    assert manager2.is_halted() is False


def test_begin_session_does_not_auto_clear_weekly_loss_halt(tmp_path: Path) -> None:
    broker = FakeBroker(equity=100_000.0)
    day1 = datetime(2024, 1, 2, 12, 0, tzinfo=EXCHANGE_TZ)
    manager, _ = _manager(
        tmp_path,
        broker=broker,
        now=day1,
        limits=RiskLimits(weekly_loss_limit_pct=0.05, daily_loss_limit_pct=0.5),
    )
    broker.equity = 94_000.0
    manager.check_loss_limits()
    assert manager.is_halted() is True

    day2 = datetime(2024, 1, 3, 9, 45, tzinfo=EXCHANGE_TZ)
    manager2 = RiskManager(
        broker=broker,
        limits=RiskLimits(weekly_loss_limit_pct=0.05, daily_loss_limit_pct=0.5),
        clock=_clock(day2),
        state_store=RiskStateStore(tmp_path / "risk.db"),
        rejection_log=RejectionLog(tmp_path / "risk.db"),
    )
    manager2.begin_session()
    assert manager2.is_halted() is True


def test_position_recorded_locally_on_successful_entry(tmp_path: Path) -> None:
    db = tmp_path / "risk.db"
    broker = FakeBroker()
    records = PositionRecordStore(db)
    manager = RiskManager(
        broker=broker,
        limits=RiskLimits(),
        clock=_clock(),
        state_store=RiskStateStore(db),
        rejection_log=RejectionLog(db),
        position_records=records,
    )
    manager.begin_session()

    decision = manager.check_and_submit_entry(_signal())

    assert decision.accepted is True
    record = records.get("AAPL")
    assert record is not None
    assert record.stop_price == 99.0


def test_no_position_recorded_when_entry_is_rejected(tmp_path: Path) -> None:
    db = tmp_path / "risk.db"
    records = PositionRecordStore(db)
    manager = RiskManager(
        broker=FakeBroker(),
        limits=RiskLimits(),
        clock=_clock(),
        state_store=RiskStateStore(db),
        rejection_log=RejectionLog(db),
        position_records=records,
    )
    manager.begin_session()

    manager.check_and_submit_entry(_signal(stop_price=0))

    assert records.get("AAPL") is None


def test_EXEC_007_restore_missing_stop_places_a_stop_only_order(tmp_path: Path) -> None:
    manager, broker = _manager(tmp_path)

    order = manager.restore_missing_stop(
        "AAPL", Side.BUY, qty=10, stop_price=95.0, take_profit_price=None
    )

    assert order.status == "filled" or order.status == "accepted"
    assert broker.submitted_orders[-1].stop_loss_price == 95.0


def test_EXEC_008_halt_for_unrecognized_position_does_not_flatten(tmp_path: Path) -> None:
    manager, broker = _manager(tmp_path)

    manager.halt_for_unrecognized_position("found AAPL at broker with no local record")

    assert manager.is_halted() is True
    assert manager.halt_status().halt_type == HaltType.RECONCILIATION_MISMATCH
    assert broker.close_all_called == 0


def test_EXEC_010_halt_for_clock_drift_does_not_flatten(tmp_path: Path) -> None:
    manager, broker = _manager(tmp_path)

    manager.halt_for_clock_drift("local clock is 42s ahead of the broker's")

    assert manager.is_halted() is True
    assert manager.halt_status().halt_type == HaltType.CLOCK_DRIFT
    assert broker.close_all_called == 0


def test_order_logged_on_successful_entry(tmp_path: Path) -> None:
    db = tmp_path / "risk.db"
    broker = FakeBroker()
    order_log = OrderLog(db)
    manager = RiskManager(
        broker=broker,
        limits=RiskLimits(),
        clock=_clock(),
        state_store=RiskStateStore(db),
        rejection_log=RejectionLog(db),
        order_log=order_log,
    )
    manager.begin_session()

    decision = manager.check_and_submit_entry(_signal())

    assert decision.accepted is True
    assert order_log.count() == 1


def test_no_order_logged_when_entry_is_rejected(tmp_path: Path) -> None:
    db = tmp_path / "risk.db"
    order_log = OrderLog(db)
    manager = RiskManager(
        broker=FakeBroker(),
        limits=RiskLimits(),
        clock=_clock(),
        state_store=RiskStateStore(db),
        rejection_log=RejectionLog(db),
        order_log=order_log,
    )
    manager.begin_session()

    manager.check_and_submit_entry(_signal(stop_price=0))

    assert order_log.count() == 0


def test_flatten_one_closes_only_the_given_symbol(tmp_path: Path) -> None:
    broker = FakeBroker(
        positions=[
            PositionInfo("AAPL", 10, Side.BUY, 100, 100, 0),
            PositionInfo("MSFT", 5, Side.BUY, 200, 200, 0),
        ]
    )
    manager, _ = _manager(tmp_path, broker=broker)

    manager.flatten_one("AAPL")

    assert [p.symbol for p in broker.positions] == ["MSFT"]
    assert manager.is_halted() is False  # a single flatten is not an emergency


def test_pause_entries_halts_without_flattening(tmp_path: Path) -> None:
    broker = FakeBroker(positions=[PositionInfo("AAPL", 10, Side.BUY, 100, 100, 0)])
    manager, _ = _manager(tmp_path, broker=broker)

    manager.pause_entries("operator requested a pause")

    assert manager.is_halted() is True
    assert manager.halt_status().halt_type == HaltType.MANUAL_PAUSE
    assert broker.close_all_called == 0

    decision = manager.check_and_submit_entry(_signal())
    assert decision.accepted is False

    manager.re_enable()
    assert manager.is_halted() is False


def test_STRAT_002_check_and_submit_exit_closes_open_position(tmp_path: Path) -> None:
    broker = FakeBroker(positions=[PositionInfo("AAPL", 10, Side.BUY, 100, 100, 0)])
    manager, _ = _manager(tmp_path, broker=broker)

    decision = manager.check_and_submit_exit(
        ExitSignal(strategy="test", symbol="AAPL", reason="stop", signal_seq="exit-1")
    )

    assert decision.accepted is True
    assert decision.broker_order_id is not None
    assert broker.positions == []


def test_check_and_submit_exit_is_a_no_op_when_nothing_is_open(tmp_path: Path) -> None:
    manager, broker = _manager(tmp_path, broker=FakeBroker(positions=[]))

    decision = manager.check_and_submit_exit(
        ExitSignal(strategy="test", symbol="AAPL", reason="stop", signal_seq="exit-1")
    )

    assert decision.accepted is False
    assert decision.reason == "no_open_position"


def test_RISK_020_check_and_submit_exit_fails_closed_on_unexpected_error(tmp_path: Path) -> None:
    broker = FakeBroker(raise_on_close=RuntimeError("broker unreachable"))
    manager, _ = _manager(tmp_path, broker=broker)

    decision = manager.check_and_submit_exit(
        ExitSignal(strategy="test", symbol="AAPL", reason="stop", signal_seq="exit-1")
    )

    assert decision.accepted is False
    assert decision.reason is not None
    assert "broker unreachable" in decision.reason


def test_check_and_submit_exit_removes_the_position_record(tmp_path: Path) -> None:
    broker = FakeBroker(positions=[PositionInfo("AAPL", 10, Side.BUY, 100, 100, 0)])
    db = tmp_path / "risk.db"
    position_records = PositionRecordStore(db)
    position_records.record_open(
        symbol="AAPL",
        stop_price=95.0,
        take_profit_price=None,
        client_order_id="c1",
        opened_at=MID_SESSION,
    )
    manager = RiskManager(
        broker=broker,
        limits=RiskLimits(),
        clock=_clock(),
        state_store=RiskStateStore(db),
        rejection_log=RejectionLog(db),
        position_records=position_records,
    )
    manager.begin_session()

    manager.check_and_submit_exit(
        ExitSignal(strategy="test", symbol="AAPL", reason="stop", signal_seq="exit-1")
    )

    assert position_records.get("AAPL") is None


def test_get_account_passes_through_to_the_broker(tmp_path: Path) -> None:
    manager, broker = _manager(tmp_path, broker=FakeBroker(equity=42_000.0))
    assert manager.get_account().equity == 42_000.0


def test_get_positions_passes_through_to_the_broker(tmp_path: Path) -> None:
    broker = FakeBroker(positions=[PositionInfo("AAPL", 10, Side.BUY, 100, 100, 0)])
    manager, _ = _manager(tmp_path, broker=broker)
    assert [p.symbol for p in manager.get_positions()] == ["AAPL"]
