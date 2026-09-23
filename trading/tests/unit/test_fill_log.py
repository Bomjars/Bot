from __future__ import annotations

from pathlib import Path

import pytest

from intraday_trading.broker.base import Side
from intraday_trading.storage.fill_log import FillLog


def test_log_and_recent_round_trip(tmp_path: Path) -> None:
    log = FillLog(tmp_path / "fills.db")
    log.log(
        client_order_id="itd-1",
        broker_order_id="42",
        symbol="AAPL",
        side=Side.BUY,
        qty=10,
        expected_price=100.0,
        actual_price=100.5,
        commission=1.5,
        commission_currency="USD",
    )

    rows = log.recent()

    assert len(rows) == 1
    assert rows[0]["symbol"] == "AAPL"
    assert rows[0]["expected_price"] == pytest.approx(100.0)
    assert rows[0]["actual_price"] == pytest.approx(100.5)
    assert rows[0]["commission"] == pytest.approx(1.5)


def test_slippage_for_a_buy_is_positive_when_filled_above_expected(tmp_path: Path) -> None:
    log = FillLog(tmp_path / "fills.db")
    log.log(
        client_order_id="itd-1",
        broker_order_id="42",
        symbol="AAPL",
        side=Side.BUY,
        qty=10,
        expected_price=100.0,
        actual_price=100.5,
        commission=0.0,
        commission_currency="USD",
    )

    assert log.recent()[0]["slippage"] == pytest.approx(0.5)


def test_slippage_for_a_buy_is_negative_when_filled_below_expected(tmp_path: Path) -> None:
    log = FillLog(tmp_path / "fills.db")
    log.log(
        client_order_id="itd-1",
        broker_order_id="42",
        symbol="AAPL",
        side=Side.BUY,
        qty=10,
        expected_price=100.0,
        actual_price=99.5,
        commission=0.0,
        commission_currency="USD",
    )

    assert log.recent()[0]["slippage"] == pytest.approx(-0.5)


def test_slippage_for_a_sell_is_positive_when_filled_below_expected(tmp_path: Path) -> None:
    log = FillLog(tmp_path / "fills.db")
    log.log(
        client_order_id="itd-1",
        broker_order_id="42",
        symbol="AAPL",
        side=Side.SELL,
        qty=10,
        expected_price=100.0,
        actual_price=99.5,
        commission=0.0,
        commission_currency="USD",
    )

    assert log.recent()[0]["slippage"] == pytest.approx(0.5)  # adverse for a sell too


def test_total_commission_sums_across_fills(tmp_path: Path) -> None:
    log = FillLog(tmp_path / "fills.db")
    assert log.total_commission() == 0.0
    log.log("a", "1", "AAPL", Side.BUY, 10, 100.0, 100.0, commission=1.0, commission_currency="USD")
    log.log("b", "2", "AAPL", Side.BUY, 10, 100.0, 100.0, commission=2.5, commission_currency="USD")
    assert log.total_commission() == pytest.approx(3.5)


def test_total_slippage_cost_weights_by_qty(tmp_path: Path) -> None:
    log = FillLog(tmp_path / "fills.db")
    # buy 10 @ 0.5 adverse slippage = $5 cost; buy 4 @ -0.25 (favorable) = -$1
    log.log("a", "1", "AAPL", Side.BUY, 10, 100.0, 100.5, commission=0.0, commission_currency="USD")
    log.log("b", "2", "AAPL", Side.BUY, 4, 100.0, 99.75, commission=0.0, commission_currency="USD")

    assert log.total_slippage_cost() == pytest.approx(4.0)


def test_currency_and_fx_cost_are_persisted(tmp_path: Path) -> None:
    log = FillLog(tmp_path / "fills.db")
    log.log(
        "a",
        "1",
        "AAPL",
        Side.BUY,
        10,
        100.0,
        100.0,
        commission=1.0,
        commission_currency="USD",
        currency="USD",
        fx_cost=2.5,
    )

    row = log.recent()[0]
    assert row["currency"] == "USD"
    assert row["fx_cost"] == pytest.approx(2.5)


def test_fx_cost_defaults_to_zero(tmp_path: Path) -> None:
    log = FillLog(tmp_path / "fills.db")
    log.log("a", "1", "AAPL", Side.BUY, 10, 100.0, 100.0, commission=1.0, commission_currency="USD")
    assert log.recent()[0]["fx_cost"] == 0.0


def test_total_fx_cost_sums_across_fills(tmp_path: Path) -> None:
    log = FillLog(tmp_path / "fills.db")
    assert log.total_fx_cost() == 0.0
    log.log("a", "1", "AAPL", Side.BUY, 10, 100.0, 100.0, 0.0, "USD", fx_cost=1.5)
    log.log("b", "2", "AAPL", Side.SELL, 10, 100.0, 100.0, 0.0, "USD", fx_cost=2.0)
    assert log.total_fx_cost() == pytest.approx(3.5)


def test_recent_respects_limit(tmp_path: Path) -> None:
    log = FillLog(tmp_path / "fills.db")
    for i in range(5):
        log.log(
            f"itd-{i}",
            str(i),
            "AAPL",
            Side.BUY,
            10,
            100.0,
            100.0,
            commission=0.0,
            commission_currency="USD",
        )
    assert len(log.recent(limit=3)) == 3
