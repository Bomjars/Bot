from __future__ import annotations

from datetime import UTC, datetime
from pathlib import Path

from intraday_trading.broker.base import OrderInfo, PositionInfo, Side
from intraday_trading.config import RiskLimits
from intraday_trading.risk.risk_manager import RiskManager
from intraday_trading.risk.signals import HaltType
from intraday_trading.session.calendar import ExchangeCalendar
from intraday_trading.session.clock import SessionClock
from intraday_trading.state.reconciler import Reconciler
from intraday_trading.storage.position_record_store import PositionRecordStore
from intraday_trading.storage.rejection_log import RejectionLog
from intraday_trading.storage.risk_state_store import RiskStateStore
from tests.unit.fakes import FakeBroker


class FakeAlerter:
    def __init__(self) -> None:
        self.alerts: list[str] = []
        self.summaries: list[str] = []

    def alert(self, text: str) -> None:
        self.alerts.append(text)

    def daily_summary(self, text: str) -> None:
        self.summaries.append(text)


def _setup(
    tmp_path: Path,
) -> tuple[Reconciler, FakeBroker, PositionRecordStore, RiskManager, FakeAlerter]:
    db = tmp_path / "recon.db"
    broker = FakeBroker()
    clock = SessionClock(ExchangeCalendar(), 0, 0, 0, now_provider=lambda: datetime.now(tz=UTC))
    risk_manager = RiskManager(
        broker=broker,
        limits=RiskLimits(),
        clock=clock,
        state_store=RiskStateStore(db),
        rejection_log=RejectionLog(db),
    )
    records = PositionRecordStore(db)
    alerter = FakeAlerter()
    reconciler = Reconciler(broker, records, risk_manager, alerter)
    return reconciler, broker, records, risk_manager, alerter


def test_no_action_when_position_has_a_record_and_an_open_order(tmp_path: Path) -> None:
    reconciler, broker, records, _, alerter = _setup(tmp_path)
    broker.positions = [PositionInfo("AAPL", 10, Side.BUY, 100.0, 101.0, 10.0)]
    broker.get_open_orders = lambda: [  # type: ignore[method-assign]
        OrderInfo("o1", "c1", "AAPL", Side.SELL, 10, "open")
    ]
    records.record_open("AAPL", 95.0, None, "c1", datetime.now(tz=UTC))

    result = reconciler.reconcile()

    assert result.stops_restored == []
    assert result.unrecognized_positions == []
    assert broker.submitted_orders == []
    assert alerter.alerts == []


def test_EXEC_007_missing_stop_is_restored_from_the_local_record(tmp_path: Path) -> None:
    reconciler, broker, records, _, alerter = _setup(tmp_path)
    broker.positions = [PositionInfo("AAPL", 10, Side.BUY, 100.0, 101.0, 10.0)]
    records.record_open("AAPL", 95.0, 110.0, "c1", datetime.now(tz=UTC))
    # broker.get_open_orders() defaults to [] -- no resting order at all

    result = reconciler.reconcile()

    assert result.stops_restored == ["AAPL"]
    assert len(broker.submitted_orders) == 1
    assert broker.submitted_orders[0].stop_loss_price == 95.0
    assert broker.submitted_orders[0].take_profit_price == 110.0
    assert any("restored" in a for a in alerter.alerts)


def test_EXEC_008_unrecognized_position_halts_and_alerts_without_restoring(tmp_path: Path) -> None:
    reconciler, broker, records, risk_manager, alerter = _setup(tmp_path)
    broker.positions = [PositionInfo("AAPL", 10, Side.BUY, 100.0, 101.0, 10.0)]
    # no record for AAPL at all

    result = reconciler.reconcile()

    assert result.unrecognized_positions == ["AAPL"]
    assert broker.submitted_orders == []  # never guesses a stop
    assert risk_manager.is_halted() is True
    assert risk_manager.halt_status().halt_type == HaltType.RECONCILIATION_MISMATCH
    assert any("no local record" in a for a in alerter.alerts)


def test_stale_record_is_cleared_when_position_already_closed(tmp_path: Path) -> None:
    reconciler, broker, records, _, _ = _setup(tmp_path)
    broker.positions = []  # nothing open at the broker
    records.record_open("AAPL", 95.0, None, "c1", datetime.now(tz=UTC))

    result = reconciler.reconcile()

    assert result.stale_records_cleared == ["AAPL"]
    assert records.get("AAPL") is None


def test_multiple_symbols_handled_independently(tmp_path: Path) -> None:
    reconciler, broker, records, risk_manager, _ = _setup(tmp_path)
    broker.positions = [
        PositionInfo("AAPL", 10, Side.BUY, 100.0, 101.0, 10.0),  # has record, missing stop
        PositionInfo("MSFT", 5, Side.BUY, 200.0, 201.0, 5.0),  # no record at all
    ]
    records.record_open("AAPL", 95.0, None, "c1", datetime.now(tz=UTC))
    records.record_open("TSLA", 200.0, None, "c2", datetime.now(tz=UTC))  # stale: no TSLA position

    result = reconciler.reconcile()

    assert result.stops_restored == ["AAPL"]
    assert result.unrecognized_positions == ["MSFT"]
    assert result.stale_records_cleared == ["TSLA"]
    assert risk_manager.is_halted() is True
