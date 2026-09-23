from __future__ import annotations

from datetime import date, timedelta

import pandas_market_calendars as mcal
import pytest

from intraday_trading.session.calendar import ExchangeCalendar


def test_SESSION_004_holiday_has_no_session() -> None:
    calendar = ExchangeCalendar()
    assert calendar.session_for_date(date(2024, 11, 28)) is None  # Thanksgiving
    assert calendar.is_trading_day(date(2024, 11, 28)) is False


def test_SESSION_003_half_day_closes_early() -> None:
    calendar = ExchangeCalendar()
    session = calendar.session_for_date(date(2024, 11, 29))  # day after Thanksgiving
    assert session is not None
    assert session.is_half_day is True
    assert session.close.hour == 13
    assert session.close.minute == 0


def test_normal_day_session_is_930_to_1600_eastern() -> None:
    calendar = ExchangeCalendar()
    session = calendar.session_for_date(date(2024, 1, 2))
    assert session is not None
    assert session.is_half_day is False
    assert (session.open.hour, session.open.minute) == (9, 30)
    assert (session.close.hour, session.close.minute) == (16, 0)


def test_weekend_has_no_session() -> None:
    calendar = ExchangeCalendar()
    assert calendar.session_for_date(date(2024, 1, 6)) is None  # Saturday


def test_session_lookups_are_cached(monkeypatch: pytest.MonkeyPatch) -> None:
    calendar = ExchangeCalendar()
    first = calendar.session_for_date(date(2024, 1, 2))

    def _fail(**kwargs: object) -> None:
        raise AssertionError("schedule rebuilt for an already-loaded year")

    monkeypatch.setattr(calendar._calendar, "schedule", _fail)

    assert calendar.session_for_date(date(2024, 1, 2)) is first
    assert calendar.session_for_date(date(2024, 11, 28)) is None  # same year, cached
    assert calendar.session_for_date(date(2024, 6, 15)) is None  # a Saturday


def test_year_block_load_matches_single_day_schedules() -> None:
    """The year-at-a-time cache must give exactly what a one-day schedule call does,
    including holidays and half days (Jul 3/4, Thanksgiving, Christmas Eve/Day)."""
    calendar = ExchangeCalendar()
    raw = mcal.get_calendar("NYSE")
    days = [date(2024, 7, 1) + timedelta(days=i) for i in range(10)]
    days += [date(2024, 11, 25) + timedelta(days=i) for i in range(37)]  # into 2025
    for day in days:
        schedule = raw.schedule(start_date=day, end_date=day)
        session = calendar.session_for_date(day)
        if schedule.empty:
            assert session is None, day
        else:
            assert session is not None, day
            assert session.open == schedule.iloc[0]["market_open"].to_pydatetime(), day
            assert session.close == schedule.iloc[0]["market_close"].to_pydatetime(), day
