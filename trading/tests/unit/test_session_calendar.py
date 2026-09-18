from __future__ import annotations

from datetime import date

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
