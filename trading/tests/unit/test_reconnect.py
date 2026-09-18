from __future__ import annotations

import pytest

from intraday_trading.execution.reconnect import RetriesExhausted, retry_with_backoff


def test_succeeds_on_first_attempt_without_sleeping() -> None:
    sleeps: list[float] = []
    result = retry_with_backoff(lambda: 42, sleep=sleeps.append)
    assert result == 42
    assert sleeps == []


def test_EXEC_005_succeeds_after_transient_failures() -> None:
    attempts = {"n": 0}

    def flaky() -> str:
        attempts["n"] += 1
        if attempts["n"] < 3:
            raise ConnectionError("dropped")
        return "reconnected"

    sleeps: list[float] = []
    result = retry_with_backoff(flaky, max_attempts=5, base_delay_seconds=1.0, sleep=sleeps.append)

    assert result == "reconnected"
    assert attempts["n"] == 3
    assert sleeps == [1.0, 2.0]  # exponential backoff between the 2 failed attempts


def test_EXEC_005_raises_RetriesExhausted_after_max_attempts() -> None:
    def always_fails() -> None:
        raise ConnectionError("still down")

    with pytest.raises(RetriesExhausted) as exc_info:
        retry_with_backoff(
            always_fails, max_attempts=3, base_delay_seconds=0.0, sleep=lambda _: None
        )

    assert exc_info.value.attempts == 3
    assert isinstance(exc_info.value.last_error, ConnectionError)


def test_EXEC_009_backoff_delay_is_capped() -> None:
    sleeps: list[float] = []

    def always_fails() -> None:
        raise TimeoutError("429")

    with pytest.raises(RetriesExhausted):
        retry_with_backoff(
            always_fails,
            max_attempts=6,
            base_delay_seconds=10.0,
            max_delay_seconds=15.0,
            sleep=sleeps.append,
        )

    assert max(sleeps) <= 15.0


def test_non_retryable_exception_is_not_retried() -> None:
    calls = {"n": 0}

    def raises_value_error() -> None:
        calls["n"] += 1
        raise ValueError("not a transient error")

    with pytest.raises(ValueError, match="not a transient error"):
        retry_with_backoff(
            raises_value_error,
            is_retryable=lambda exc: isinstance(exc, ConnectionError),
            max_attempts=5,
            sleep=lambda _: None,
        )

    assert calls["n"] == 1
