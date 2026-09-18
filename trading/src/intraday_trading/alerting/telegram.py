"""Telegram alerting: instant alerts for halts/errors/disconnects/kill-switch use, and a
daily post-close summary. ALERT-005: if credentials aren't configured, every call is a
silent local-log no-op rather than a crash -- alerting must never be a single point of
failure for the rest of the system.
"""

from __future__ import annotations

import httpx
import structlog

logger = structlog.get_logger(__name__)


class TelegramAlerter:
    def __init__(self, bot_token: str, chat_id: str, client: httpx.Client | None = None) -> None:
        self._bot_token = bot_token
        self._chat_id = chat_id
        self._client = client or httpx.Client(timeout=10.0)

    @property
    def _configured(self) -> bool:
        return bool(self._bot_token and self._chat_id)

    def _send(self, text: str) -> None:
        if not self._configured:
            logger.info("telegram_alert_skipped_not_configured", text=text)
            return
        url = f"https://api.telegram.org/bot{self._bot_token}/sendMessage"
        try:
            response = self._client.post(url, json={"chat_id": self._chat_id, "text": text})
            response.raise_for_status()
        except httpx.HTTPError:
            logger.exception("telegram_send_failed", text=text)

    def alert(self, text: str) -> None:
        self._send(f"\U0001f6a8 {text}")

    def daily_summary(self, text: str) -> None:
        self._send(f"\U0001f4ca {text}")
