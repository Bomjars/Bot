from __future__ import annotations

import os

import pytest


@pytest.fixture(autouse=True)
def _no_live_trading_env(monkeypatch: pytest.MonkeyPatch) -> None:
    """Belt-and-braces: no test can accidentally run with LIVE_TRADING=true, even if a
    developer's shell has it set."""
    monkeypatch.setenv("LIVE_TRADING", "false")
    monkeypatch.delenv("LIVE_TRADING_CONFIRMATION", raising=False)
    monkeypatch.setenv("ALPACA_API_KEY", os.environ.get("ALPACA_API_KEY", "test-key"))
    monkeypatch.setenv("ALPACA_SECRET_KEY", os.environ.get("ALPACA_SECRET_KEY", "test-secret"))
