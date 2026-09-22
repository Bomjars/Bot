from __future__ import annotations

from datetime import UTC, datetime, timedelta

from intraday_trading.backtest.costs import CostModel
from intraday_trading.backtest.simulated_broker import SimulatedBroker
from intraday_trading.broker.base import BracketOrderRequest, Side
from intraday_trading.strategies.base import Bar

T0 = datetime(2024, 1, 2, 9, 30, tzinfo=UTC)


def _bar(ts: datetime, o: float, h: float, l: float, c: float, v: float = 1000.0) -> Bar:  # noqa: E741
    return Bar(ts=ts, open=o, high=h, low=l, close=c, volume=v)


def test_submit_bracket_order_opens_a_position_and_deducts_commission() -> None:
    broker = SimulatedBroker(starting_equity=100_000.0, cost_model=CostModel(commission_min=1.0))
    broker.process_bar("AAPL", _bar(T0, 100, 100, 100, 100))

    order = broker.submit_bracket_order(
        BracketOrderRequest("id1", "AAPL", Side.BUY, 10, stop_loss_price=95.0)
    )

    assert order.status == "filled"
    positions = broker.get_positions()
    assert len(positions) == 1
    assert positions[0].symbol == "AAPL"
    assert positions[0].qty == 10
    assert broker.get_account().equity < 100_000.0  # commission paid


def test_stop_loss_triggers_on_bar_low() -> None:
    broker = SimulatedBroker(starting_equity=100_000.0, cost_model=CostModel())
    t1 = T0
    t2 = T0 + timedelta(minutes=1)
    broker.process_bar("AAPL", _bar(t1, 100, 100, 100, 100))
    broker.submit_bracket_order(
        BracketOrderRequest("id1", "AAPL", Side.BUY, 10, stop_loss_price=98.0)
    )

    broker.process_bar("AAPL", _bar(t2, 100, 100.5, 97.0, 99.0))  # low pierces the stop

    assert broker.get_positions() == []
    assert len(broker.closed_trades) == 1
    assert broker.closed_trades[0].exit_reason == "stop_loss"
    assert broker.closed_trades[0].exit_price <= 98.0 + 1e-6


def test_take_profit_triggers_on_bar_high() -> None:
    broker = SimulatedBroker(starting_equity=100_000.0, cost_model=CostModel())
    t1, t2 = T0, T0 + timedelta(minutes=1)
    broker.process_bar("AAPL", _bar(t1, 100, 100, 100, 100))
    broker.submit_bracket_order(
        BracketOrderRequest(
            "id1", "AAPL", Side.BUY, 10, stop_loss_price=95.0, take_profit_price=110.0
        )
    )

    broker.process_bar("AAPL", _bar(t2, 100, 111.0, 99.0, 105.0))

    assert broker.get_positions() == []
    assert broker.closed_trades[0].exit_reason == "take_profit"


def test_stop_wins_when_both_stop_and_target_hit_same_bar() -> None:
    broker = SimulatedBroker(starting_equity=100_000.0, cost_model=CostModel())
    t1, t2 = T0, T0 + timedelta(minutes=1)
    broker.process_bar("AAPL", _bar(t1, 100, 100, 100, 100))
    broker.submit_bracket_order(
        BracketOrderRequest(
            "id1", "AAPL", Side.BUY, 10, stop_loss_price=95.0, take_profit_price=105.0
        )
    )

    broker.process_bar("AAPL", _bar(t2, 100, 106.0, 94.0, 100.0))  # wild bar hits both

    assert broker.closed_trades[0].exit_reason == "stop_loss"


def test_close_all_positions_flattens_everything() -> None:
    broker = SimulatedBroker(starting_equity=100_000.0, cost_model=CostModel())
    broker.process_bar("AAPL", _bar(T0, 100, 100, 100, 100))
    broker.process_bar("MSFT", _bar(T0, 200, 200, 200, 200))
    broker.submit_bracket_order(
        BracketOrderRequest("id1", "AAPL", Side.BUY, 10, stop_loss_price=95.0)
    )
    broker.submit_bracket_order(
        BracketOrderRequest("id2", "MSFT", Side.BUY, 5, stop_loss_price=190.0)
    )

    broker.close_all_positions()

    assert broker.get_positions() == []
    assert len(broker.closed_trades) == 2
    assert all(t.exit_reason == "flatten" for t in broker.closed_trades)


def test_short_position_pnl_direction() -> None:
    broker = SimulatedBroker(
        starting_equity=100_000.0, cost_model=CostModel(slippage_bps=0, spread_bps=0)
    )
    t1, t2 = T0, T0 + timedelta(minutes=1)
    broker.process_bar("AAPL", _bar(t1, 100, 100, 100, 100))
    broker.submit_bracket_order(
        BracketOrderRequest("id1", "AAPL", Side.SELL, 10, stop_loss_price=105.0)
    )
    broker.process_bar("AAPL", _bar(t2, 100, 96, 90, 92))  # price fell -> short profits

    broker.close_position("AAPL")

    assert broker.closed_trades[0].realized_pnl > 0
