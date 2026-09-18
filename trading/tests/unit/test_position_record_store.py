from __future__ import annotations

from datetime import UTC, datetime
from pathlib import Path

from intraday_trading.storage.position_record_store import PositionRecordStore


def test_record_open_and_get_round_trip(tmp_path: Path) -> None:
    store = PositionRecordStore(tmp_path / "positions.db")
    opened_at = datetime(2024, 1, 2, 9, 45, tzinfo=UTC)

    store.record_open(
        "AAPL", stop_price=95.0, take_profit_price=110.0, client_order_id="id1", opened_at=opened_at
    )

    record = store.get("AAPL")
    assert record is not None
    assert record.stop_price == 95.0
    assert record.take_profit_price == 110.0
    assert record.client_order_id == "id1"


def test_get_missing_symbol_returns_none(tmp_path: Path) -> None:
    store = PositionRecordStore(tmp_path / "positions.db")
    assert store.get("AAPL") is None


def test_record_open_upserts(tmp_path: Path) -> None:
    store = PositionRecordStore(tmp_path / "positions.db")
    now = datetime.now(tz=UTC)
    store.record_open("AAPL", 95.0, None, "id1", now)
    store.record_open("AAPL", 90.0, 120.0, "id2", now)

    record = store.get("AAPL")
    assert record is not None
    assert record.stop_price == 90.0
    assert record.take_profit_price == 120.0
    assert record.client_order_id == "id2"


def test_remove_deletes_the_record(tmp_path: Path) -> None:
    store = PositionRecordStore(tmp_path / "positions.db")
    store.record_open("AAPL", 95.0, None, "id1", datetime.now(tz=UTC))
    store.remove("AAPL")
    assert store.get("AAPL") is None


def test_all_returns_every_record(tmp_path: Path) -> None:
    store = PositionRecordStore(tmp_path / "positions.db")
    now = datetime.now(tz=UTC)
    store.record_open("AAPL", 95.0, None, "id1", now)
    store.record_open("MSFT", 190.0, None, "id2", now)

    symbols = {r.symbol for r in store.all()}
    assert symbols == {"AAPL", "MSFT"}
