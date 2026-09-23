from __future__ import annotations

from pathlib import Path

import pytest

from intraday_trading.broker.base import Side
from intraday_trading.storage.fx_conversion_log import FxConversionLog


def test_log_and_recent_round_trip(tmp_path: Path) -> None:
    log = FxConversionLog(tmp_path / "fx.db")
    log.log(
        broker_order_id="7",
        pair="GBP.USD",
        side=Side.SELL,
        amount=1_000.0,
        rate=1.27,
        commission=2.0,
        commission_currency="USD",
    )

    rows = log.recent()

    assert len(rows) == 1
    assert rows[0]["pair"] == "GBP.USD"
    assert rows[0]["side"] == "sell"
    assert rows[0]["amount"] == pytest.approx(1_000.0)
    assert rows[0]["rate"] == pytest.approx(1.27)
    assert rows[0]["commission"] == pytest.approx(2.0)


def test_total_commission_sums_across_conversions(tmp_path: Path) -> None:
    log = FxConversionLog(tmp_path / "fx.db")
    assert log.total_commission() == 0.0
    log.log("1", "GBP.USD", Side.SELL, 1_000.0, 1.27, 2.0, "USD")
    log.log("2", "GBP.USD", Side.BUY, 500.0, 1.26, 2.0, "USD")
    assert log.total_commission() == pytest.approx(4.0)


def test_recent_respects_limit(tmp_path: Path) -> None:
    log = FxConversionLog(tmp_path / "fx.db")
    for i in range(5):
        log.log(str(i), "GBP.USD", Side.SELL, 100.0, 1.27, 2.0, "USD")
    assert len(log.recent(limit=3)) == 3
