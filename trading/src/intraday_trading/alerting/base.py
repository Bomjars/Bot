"""Alerter interface, so tests (and any future alert channel beyond Telegram) don't need
a real `TelegramAlerter` -- structurally typed like `Broker`/`Strategy`.
"""

from __future__ import annotations

from typing import Protocol


class Alerter(Protocol):
    def alert(self, text: str) -> None: ...

    def daily_summary(self, text: str) -> None: ...
