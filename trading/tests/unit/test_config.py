from __future__ import annotations

import pytest
from pydantic import ValidationError

from intraday_trading.config import RiskLimits, Settings


def test_SAFE_001_default_live_trading_is_false() -> None:
    settings = Settings()
    assert settings.live_trading is False


def test_SAFE_002_live_trading_true_without_confirmation_rejected() -> None:
    with pytest.raises(ValidationError):
        Settings(live_trading=True)

    with pytest.raises(ValidationError):
        Settings(live_trading=True, live_trading_confirmation="yes please")


def test_SAFE_003_live_trading_true_with_exact_confirmation_accepted() -> None:
    settings = Settings(live_trading=True, live_trading_confirmation="I UNDERSTAND THE RISK")
    assert settings.live_trading is True


def test_RISK_023_risk_limits_are_configurable_not_hardcoded() -> None:
    default = RiskLimits()
    overridden = RiskLimits(max_trades_per_day=3, max_open_positions=1)
    assert default.max_trades_per_day == 10
    assert overridden.max_trades_per_day == 3
    assert overridden.max_open_positions == 1


def test_flatten_before_close_cannot_exceed_no_entry_last_window() -> None:
    with pytest.raises(ValidationError):
        RiskLimits(flatten_before_close_minutes=45, no_entry_last_minutes=30)
