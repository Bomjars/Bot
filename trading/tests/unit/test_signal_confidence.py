"""validation/signal_confidence.py: bucketed win-rate by signal strength. Uses the real
`TradeRecord` dataclass (backtest/simulated_broker.py) as the input type, since that's
what production code will actually pass in -- the module itself only depends on it
structurally (see `ClosedTrade` Protocol).
"""

from __future__ import annotations

from datetime import UTC, datetime

import pytest

from intraday_trading.backtest.simulated_broker import TradeRecord
from intraday_trading.broker.base import Side
from intraday_trading.validation.signal_confidence import (
    ConfidenceBucket,
    build_confidence_table,
)

T0 = datetime(2024, 1, 2, 10, 0, tzinfo=UTC)


def _trade(signal_strength: float | None, realized_pnl: float) -> TradeRecord:
    return TradeRecord(
        symbol="SPY",
        side=Side.BUY,
        qty=10,
        entry_price=100.0,
        exit_price=100.0 + realized_pnl / 10,
        entry_time=T0,
        exit_time=T0,
        exit_reason="stop",
        realized_pnl=realized_pnl,
        total_commission=0.0,
        signal_strength=signal_strength,
    )


def test_VAL_014_trades_are_sorted_into_the_bucket_their_strength_falls_into() -> None:
    trades = [
        _trade(0.05, realized_pnl=10.0),  # bucket [0, 0.1)
        _trade(0.2, realized_pnl=-5.0),  # bucket [0.1, 0.25)
        _trade(0.3, realized_pnl=10.0),  # bucket [0.25, 0.5)
        _trade(2.0, realized_pnl=10.0),  # bucket [1.0, inf)
    ]
    table = build_confidence_table(trades)

    assert table.buckets[0] == ConfidenceBucket(low=0.0, high=0.1, n=1, n_wins=1)
    assert table.buckets[1] == ConfidenceBucket(low=0.1, high=0.25, n=1, n_wins=0)
    assert table.buckets[2] == ConfidenceBucket(low=0.25, high=0.5, n=1, n_wins=1)
    assert table.buckets[3] == ConfidenceBucket(low=0.5, high=1.0, n=0, n_wins=0)
    assert table.buckets[4] == ConfidenceBucket(low=1.0, high=float("inf"), n=1, n_wins=1)


def test_a_bucket_edge_falls_into_the_higher_bucket() -> None:
    """`low <= strength < high`: exactly on an edge belongs to the bucket that edge
    opens, not the one it closes."""
    table = build_confidence_table([_trade(0.1, realized_pnl=1.0)])
    assert table.buckets[0].n == 0  # [0, 0.1)
    assert table.buckets[1].n == 1  # [0.1, 0.25)


def test_win_rate_is_the_fraction_of_winning_trades_in_the_bucket() -> None:
    trades = [_trade(0.05, 10.0), _trade(0.05, -3.0), _trade(0.05, -1.0), _trade(0.05, 4.0)]
    table = build_confidence_table(trades)
    assert table.buckets[0].n == 4
    assert table.buckets[0].win_rate == pytest.approx(0.5)


def test_VAL_014_win_rate_is_none_for_an_empty_bucket() -> None:
    table = build_confidence_table([])
    assert all(bucket.win_rate is None for bucket in table.buckets)


def test_a_zero_pnl_trade_is_not_counted_as_a_win() -> None:
    table = build_confidence_table([_trade(0.05, 0.0)])
    assert table.buckets[0].n == 1
    assert table.buckets[0].n_wins == 0


def test_trades_with_no_signal_strength_are_excluded() -> None:
    table = build_confidence_table([_trade(None, 10.0)])
    assert all(bucket.n == 0 for bucket in table.buckets)


def test_lookup_returns_the_matching_bucket() -> None:
    table = build_confidence_table([_trade(0.3, 5.0)])
    bucket = table.lookup(0.35)
    assert bucket is not None
    assert bucket.low == 0.25 and bucket.high == 0.5
    assert bucket.n == 1


def test_lookup_returns_none_for_a_negative_strength() -> None:
    table = build_confidence_table([])
    assert table.lookup(-0.1) is None


def test_custom_edges_are_respected() -> None:
    table = build_confidence_table([_trade(0.6, 1.0)], edges=(0.5,))
    assert len(table.buckets) == 2
    assert table.buckets[1].n == 1


def test_edges_must_not_be_empty() -> None:
    with pytest.raises(ValueError, match="at least one boundary"):
        build_confidence_table([], edges=())


def test_edges_must_be_strictly_increasing() -> None:
    with pytest.raises(ValueError, match="strictly increasing"):
        build_confidence_table([], edges=(0.5, 0.5))
    with pytest.raises(ValueError, match="strictly increasing"):
        build_confidence_table([], edges=(0.5, 0.2))
