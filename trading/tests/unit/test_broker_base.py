from __future__ import annotations

import pytest

from intraday_trading.broker.base import BracketOrderRequest, Side, make_client_order_id


def test_EXEC_002_client_order_id_is_deterministic() -> None:
    id_a = make_client_order_id("orb", "AAPL", "2024-01-02", "1")
    id_b = make_client_order_id("orb", "AAPL", "2024-01-02", "1")
    id_c = make_client_order_id("orb", "AAPL", "2024-01-02", "2")

    assert id_a == id_b
    assert id_a != id_c
    assert len(id_a) < 48


def test_RISK_010_bracket_order_requires_positive_stop() -> None:
    with pytest.raises(ValueError, match="stop_loss_price"):
        BracketOrderRequest(
            client_order_id="x",
            symbol="AAPL",
            side=Side.BUY,
            qty=10,
            stop_loss_price=0,
        )


def test_bracket_order_requires_positive_qty() -> None:
    with pytest.raises(ValueError, match="qty"):
        BracketOrderRequest(
            client_order_id="x",
            symbol="AAPL",
            side=Side.BUY,
            qty=0,
            stop_loss_price=10,
        )
