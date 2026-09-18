"""Session clock: answers "can we enter", "should we flatten", "is the market open"
entirely in exchange time. RiskManager (step 3) is the caller that turns these answers
into actual order rejections — this module only knows about time, not orders.

UK display time is a pure conversion at the edge (`to_display_timezone`); every decision
here happens in `America/New_York`.
"""

from __future__ import annotations

from collections.abc import Callable
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

from intraday_trading.session.calendar import EXCHANGE_TZ, ExchangeCalendar, TradingSession

DISPLAY_TZ = ZoneInfo("Europe/London")

NowProvider = Callable[[], datetime]


def _real_now() -> datetime:
    return datetime.now(tz=EXCHANGE_TZ)


class TimeBox:
    """A settable, callable "now" for `SessionClock`. Used by anything that drives
    simulated time forward externally rather than reading the real clock -- today, the
    backtester (`backtest/engine.py`), which advances it bar by bar."""

    def __init__(self, initial: datetime) -> None:
        self.value = initial

    def __call__(self) -> datetime:
        return self.value


class SessionClock:
    def __init__(
        self,
        calendar: ExchangeCalendar,
        no_entry_first_minutes: int,
        no_entry_last_minutes: int,
        flatten_before_close_minutes: int,
        now_provider: NowProvider = _real_now,
    ) -> None:
        self._calendar = calendar
        self.no_entry_first_minutes = no_entry_first_minutes
        self.no_entry_last_minutes = no_entry_last_minutes
        self.flatten_before_close_minutes = flatten_before_close_minutes
        self._now_provider = now_provider

    def now(self) -> datetime:
        return self._now_provider().astimezone(EXCHANGE_TZ)

    def todays_session(self) -> TradingSession | None:
        return self._calendar.session_for_date(self.now().date())

    def is_market_open(self) -> bool:
        session = self.todays_session()
        if session is None:
            return False
        now = self.now()
        return session.open <= now < session.close

    def can_enter(self) -> bool:
        """False before `no_entry_first_minutes` after the open, after
        `no_entry_last_minutes` before the close, or on a day with no session at all."""
        session = self.todays_session()
        if session is None:
            return False
        now = self.now()
        earliest = session.open + timedelta(minutes=self.no_entry_first_minutes)
        latest = session.close - timedelta(minutes=self.no_entry_last_minutes)
        return earliest <= now <= latest

    def should_flatten(self) -> bool:
        """True once we're within `flatten_before_close_minutes` of the close, or the
        session has already ended (belt-and-braces: a missed flatten should still read
        as "flatten now", not "no session, do nothing")."""
        session = self.todays_session()
        if session is None:
            return False
        now = self.now()
        flatten_at = session.close - timedelta(minutes=self.flatten_before_close_minutes)
        return now >= flatten_at

    @staticmethod
    def to_display_timezone(moment: datetime) -> datetime:
        return moment.astimezone(DISPLAY_TZ)
