from __future__ import annotations

import pytest

from intraday_trading.sizing.position_sizer import compute_target_size


def test_computes_whole_shares_rounded_down() -> None:
    # equity=100_000, risk 1% = $1,000; stop distance $3 -> 333.33 -> floor to 333
    shares = compute_target_size(
        equity=100_000.0, entry_price=50.0, stop_price=47.0, risk_per_trade_pct=0.01
    )
    assert shares == 333


def test_zero_stop_distance_raises() -> None:
    with pytest.raises(ValueError, match="differ"):
        compute_target_size(
            equity=100_000.0, entry_price=50.0, stop_price=50.0, risk_per_trade_pct=0.01
        )


def test_non_positive_entry_price_raises() -> None:
    with pytest.raises(ValueError, match="positive"):
        compute_target_size(
            equity=100_000.0, entry_price=0.0, stop_price=-1.0, risk_per_trade_pct=0.01
        )


def test_never_returns_negative() -> None:
    shares = compute_target_size(
        equity=100.0, entry_price=50.0, stop_price=0.01, risk_per_trade_pct=0.0000001
    )
    assert shares >= 0
