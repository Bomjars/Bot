from __future__ import annotations

import httpx
import respx

from intraday_trading.alerting.telegram import TelegramAlerter


def test_ALERT_005_skips_silently_when_not_configured() -> None:
    alerter = TelegramAlerter(bot_token="", chat_id="")
    alerter.alert("should not crash")  # no network call, no exception
    alerter.daily_summary("should not crash either")


@respx.mock
def test_alert_posts_to_telegram_api_when_configured() -> None:
    route = respx.post("https://api.telegram.org/bottoken123/sendMessage").mock(
        return_value=httpx.Response(200, json={"ok": True})
    )
    alerter = TelegramAlerter(bot_token="token123", chat_id="chat456")

    alerter.alert("halted")

    assert route.called
    request = route.calls.last.request
    assert b"chat456" in request.content


@respx.mock
def test_daily_summary_posts_to_telegram_api() -> None:
    route = respx.post("https://api.telegram.org/bottoken123/sendMessage").mock(
        return_value=httpx.Response(200, json={"ok": True})
    )
    alerter = TelegramAlerter(bot_token="token123", chat_id="chat456")

    alerter.daily_summary("session closed")

    assert route.called


@respx.mock
def test_send_failure_is_logged_not_raised() -> None:
    respx.post("https://api.telegram.org/bottoken123/sendMessage").mock(
        return_value=httpx.Response(500)
    )
    alerter = TelegramAlerter(bot_token="token123", chat_id="chat456")

    alerter.alert("this should not raise even though telegram 500s")
