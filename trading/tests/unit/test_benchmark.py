from __future__ import annotations

import pytest

from intraday_trading.reporting.benchmark import compute_benchmark_comparison, format_daily_report


def test_bot_pnl_and_return_from_equity_change() -> None:
    comparison = compute_benchmark_comparison(
        starting_equity=100_000.0,
        current_equity=101_000.0,
        benchmark_start_price=500.0,
        benchmark_current_price=500.0,
    )
    assert comparison.bot_pnl == pytest.approx(1_000.0)
    assert comparison.bot_return_pct == pytest.approx(0.01)


def test_benchmark_pnl_is_starting_equity_scaled_by_price_return() -> None:
    # SPY up 2% over the window -> $100k starting capital would be worth $2k more.
    comparison = compute_benchmark_comparison(
        starting_equity=100_000.0,
        current_equity=100_000.0,
        benchmark_start_price=500.0,
        benchmark_current_price=510.0,
    )
    assert comparison.benchmark_return_pct == pytest.approx(0.02)
    assert comparison.benchmark_pnl == pytest.approx(2_000.0)


def test_outperformance_is_positive_when_bot_beats_the_benchmark() -> None:
    comparison = compute_benchmark_comparison(
        starting_equity=100_000.0,
        current_equity=103_000.0,  # bot: +3%
        benchmark_start_price=500.0,
        benchmark_current_price=505.0,  # benchmark: +1%
    )
    assert comparison.outperformance_pct == pytest.approx(0.02)


def test_outperformance_is_negative_when_bot_lags_the_benchmark() -> None:
    comparison = compute_benchmark_comparison(
        starting_equity=100_000.0,
        current_equity=100_500.0,  # bot: +0.5%
        benchmark_start_price=500.0,
        benchmark_current_price=510.0,  # benchmark: +2%
    )
    assert comparison.outperformance_pct == pytest.approx(-0.015)


def test_a_falling_benchmark_produces_a_negative_benchmark_pnl() -> None:
    comparison = compute_benchmark_comparison(
        starting_equity=100_000.0,
        current_equity=100_000.0,
        benchmark_start_price=500.0,
        benchmark_current_price=490.0,
    )
    assert comparison.benchmark_pnl == pytest.approx(-2_000.0)
    assert comparison.benchmark_return_pct == pytest.approx(-0.02)


def test_rejects_a_non_positive_starting_equity() -> None:
    with pytest.raises(ValueError, match="starting_equity"):
        compute_benchmark_comparison(
            starting_equity=0.0,
            current_equity=100.0,
            benchmark_start_price=500.0,
            benchmark_current_price=500.0,
        )


def test_rejects_a_non_positive_benchmark_start_price() -> None:
    with pytest.raises(ValueError, match="benchmark_start_price"):
        compute_benchmark_comparison(
            starting_equity=100_000.0,
            current_equity=100_000.0,
            benchmark_start_price=0.0,
            benchmark_current_price=500.0,
        )


def test_format_daily_report_reads_as_beat_when_bot_outperforms() -> None:
    comparison = compute_benchmark_comparison(100_000.0, 103_000.0, 500.0, 505.0)
    text = format_daily_report("SPY", comparison)
    assert "beat" in text
    assert "SPY" in text


def test_format_daily_report_reads_as_lagged_when_bot_underperforms() -> None:
    comparison = compute_benchmark_comparison(100_000.0, 100_500.0, 500.0, 510.0)
    text = format_daily_report("SPY", comparison)
    assert "lagged" in text
