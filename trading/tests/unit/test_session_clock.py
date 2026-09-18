from __future__ import annotations

from datetime import date, datetime
from zoneinfo import ZoneInfo

from intraday_trading.session.calendar import EXCHANGE_TZ, ExchangeCalendar
from intraday_trading.session.clock import DISPLAY_TZ, SessionClock

NORMAL_DAY = date(2024, 1, 2)  # 9:30-16:00 ET, no holiday/half day
HALF_DAY = date(2024, 11, 29)  # 9:30-13:00 ET


def _clock(
    now: datetime,
    no_entry_first: int = 15,
    no_entry_last: int = 30,
    flatten: int = 10,
) -> SessionClock:
    return SessionClock(
        calendar=ExchangeCalendar(),
        no_entry_first_minutes=no_entry_first,
        no_entry_last_minutes=no_entry_last,
        flatten_before_close_minutes=flatten,
        now_provider=lambda: now,
    )


def _et(hour: int, minute: int, day: date = NORMAL_DAY) -> datetime:
    return datetime(day.year, day.month, day.day, hour, minute, tzinfo=EXCHANGE_TZ)


def test_SESSION_001_before_open_market_closed_and_cannot_enter() -> None:
    clock = _clock(_et(9, 0))
    assert clock.is_market_open() is False
    assert clock.can_enter() is False


def test_RISK_012_no_entry_in_first_15_minutes() -> None:
    clock = _clock(_et(9, 40))  # 10 min after 9:30 open
    assert clock.is_market_open() is True
    assert clock.can_enter() is False


def test_can_enter_once_past_no_entry_first_window() -> None:
    clock = _clock(_et(9, 46))  # 16 min after open
    assert clock.can_enter() is True


def test_RISK_013_no_entry_in_last_30_minutes() -> None:
    clock = _clock(_et(15, 35))  # 25 min before 16:00 close
    assert clock.can_enter() is False


def test_RISK_014_should_flatten_within_10_minutes_of_close() -> None:
    clock = _clock(_et(15, 51))  # 9 min before close
    assert clock.should_flatten() is True
    clock_earlier = _clock(_et(15, 30))
    assert clock_earlier.should_flatten() is False


def test_SESSION_004_holiday_reports_no_session_and_blocks_everything() -> None:
    clock = _clock(datetime(2024, 11, 28, 10, 0, tzinfo=EXCHANGE_TZ))
    assert clock.todays_session() is None
    assert clock.is_market_open() is False
    assert clock.can_enter() is False
    assert clock.should_flatten() is False


def test_SESSION_003_windows_shift_on_half_day() -> None:
    clock = _clock(_et(12, 45, day=HALF_DAY))  # 15 min before 13:00 half-day close
    assert clock.can_enter() is False  # inside the last-30-min window of the EARLY close
    flatten_clock = _clock(_et(12, 51, day=HALF_DAY))
    assert flatten_clock.should_flatten() is True


def test_SESSION_002_display_timezone_conversion_across_dst() -> None:
    winter_et = datetime(2024, 1, 2, 9, 30, tzinfo=EXCHANGE_TZ)
    summer_et = datetime(2024, 7, 2, 9, 30, tzinfo=EXCHANGE_TZ)

    winter_uk = SessionClock.to_display_timezone(winter_et)
    summer_uk = SessionClock.to_display_timezone(summer_et)

    assert winter_uk.tzinfo is not None
    assert winter_uk.utcoffset() == ZoneInfo("Europe/London").utcoffset(winter_et)
    # ET is UTC-5 in winter, UK is UTC+0 (5h ahead); in summer ET is UTC-4, UK is UTC+1
    # (also 5h ahead) -- the local-clock gap stays 5h since both regions observe DST.
    assert (winter_uk.hour, winter_uk.minute) == (14, 30)
    assert (summer_uk.hour, summer_uk.minute) == (14, 30)
    assert winter_uk.tzinfo == DISPLAY_TZ or str(winter_uk.tzinfo) == str(DISPLAY_TZ)
