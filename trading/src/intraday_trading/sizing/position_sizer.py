"""Volatility-based position sizing: how many whole shares to risk `risk_per_trade_pct`
of equity on this trade, given an ATR-derived stop distance.

This is a pure function, deliberately independent of RiskManager: strategies (steps 6-7)
use it to propose a size. RiskManager then independently *validates* that proposal
against the same limits (and every other hard limit) and rejects it if it doesn't comply
— it does not trust or silently resize whatever a strategy proposes. See risk/risk_manager.py.
"""

from __future__ import annotations

import math


def compute_target_size(
    equity: float,
    entry_price: float,
    stop_price: float,
    risk_per_trade_pct: float,
) -> int:
    """Whole shares such that (entry - stop) * shares ≈ equity * risk_per_trade_pct,
    rounded down so the actual risk never exceeds the target."""
    stop_distance = abs(entry_price - stop_price)
    if stop_distance <= 0:
        raise ValueError("entry_price and stop_price must differ")
    if entry_price <= 0:
        raise ValueError("entry_price must be positive")

    risk_amount = equity * risk_per_trade_pct
    shares = math.floor(risk_amount / stop_distance)
    return max(shares, 0)
