"""Small display-formatting helpers shared across pages."""

from __future__ import annotations

from datetime import datetime


def money(value: float | None, currency: str = "$") -> str:
    if value is None:
        return "—"
    sign = "-" if value < 0 else ""
    return f"{sign}{currency}{abs(value):,.2f}"


def pct(value: float | None) -> str:
    if value is None:
        return "—"
    return f"{value:+.2%}"


def since(ts: str | None) -> str:
    if not ts:
        return "—"
    try:
        parsed = datetime.fromisoformat(ts)
    except ValueError:
        return ts
    return parsed.strftime("%Y-%m-%d %H:%M")
