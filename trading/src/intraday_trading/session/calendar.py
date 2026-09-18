"""NYSE trading calendar: sessions, holidays, half days.

Wraps `pandas_market_calendars` so the rest of the codebase never hardcodes 9:30/16:00 —
half days (e.g. the day after Thanksgiving) close early, and holidays have no session at
all. Everything here is exchange-time; timezone display conversion happens elsewhere
(`clock.py`'s `to_display_timezone`).
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime
from zoneinfo import ZoneInfo

import pandas_market_calendars as mcal

EXCHANGE_TZ = ZoneInfo("America/New_York")


@dataclass(frozen=True)
class TradingSession:
    open: datetime
    close: datetime

    @property
    def is_half_day(self) -> bool:
        """True if the session closes earlier than a normal 16:00 ET close."""
        normal_close = self.close.replace(hour=16, minute=0, second=0, microsecond=0)
        return self.close < normal_close


class ExchangeCalendar:
    def __init__(self, exchange: str = "NYSE") -> None:
        self._calendar = mcal.get_calendar(exchange)

    def session_for_date(self, day: date) -> TradingSession | None:
        """Return the session for `day`, or None if it's a holiday/weekend."""
        schedule = self._calendar.schedule(start_date=day, end_date=day)
        if schedule.empty:
            return None
        row = schedule.iloc[0]
        return TradingSession(
            open=row["market_open"].to_pydatetime().astimezone(EXCHANGE_TZ),
            close=row["market_close"].to_pydatetime().astimezone(EXCHANGE_TZ),
        )

    def is_trading_day(self, day: date) -> bool:
        return self.session_for_date(day) is not None
