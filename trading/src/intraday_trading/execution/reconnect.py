"""Generic retry-with-exponential-backoff, used for both a dropped data stream
(EXEC-005) and broker rate limits (EXEC-009) -- same shape either way: try, and if it
fails in a way worth retrying, wait longer each time, up to a limit.
"""

from __future__ import annotations

import time
from collections.abc import Callable


class RetriesExhausted(Exception):
    def __init__(self, attempts: int, last_error: Exception) -> None:
        super().__init__(f"gave up after {attempts} attempt(s): {last_error}")
        self.attempts = attempts
        self.last_error = last_error


def retry_with_backoff[T](
    operation: Callable[[], T],
    is_retryable: Callable[[Exception], bool] = lambda exc: True,
    max_attempts: int = 5,
    base_delay_seconds: float = 1.0,
    max_delay_seconds: float = 60.0,
    sleep: Callable[[float], None] = time.sleep,
) -> T:
    attempt = 0
    while True:
        attempt += 1
        try:
            return operation()
        except Exception as exc:
            if not is_retryable(exc):
                raise
            if attempt >= max_attempts:
                raise RetriesExhausted(attempt, exc) from exc
            delay = min(base_delay_seconds * (2 ** (attempt - 1)), max_delay_seconds)
            sleep(delay)
