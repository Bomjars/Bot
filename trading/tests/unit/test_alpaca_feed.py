from __future__ import annotations

from datetime import datetime, timedelta

import pandas as pd

from intraday_trading.config import DataFeed
from intraday_trading.data.client import BAR_COLUMNS
from intraday_trading.execution.alpaca_feed import AlpacaPollingFeed


class FakeMarketDataClient:
    def __init__(self) -> None:
        self.frames: list[pd.DataFrame] = []

    def get_minute_bars(self, symbols, start, end, feed):  # type: ignore[no-untyped-def]
        return self.frames.pop(0) if self.frames else pd.DataFrame(columns=BAR_COLUMNS)


def _row(symbol: str, ts: datetime, close: float) -> dict:
    return {
        "symbol": symbol,
        "ts": pd.Timestamp(ts),
        "open": close,
        "high": close,
        "low": close,
        "close": close,
        "volume": 1000.0,
        "feed": "iex",
    }


def test_no_symbols_returns_empty_without_calling_client() -> None:
    feed = AlpacaPollingFeed(FakeMarketDataClient(), symbols=[], feed=DataFeed.IEX)
    assert feed.poll() == {}


def test_empty_response_returns_empty_dict() -> None:
    client = FakeMarketDataClient()
    client.frames.append(pd.DataFrame(columns=BAR_COLUMNS))
    feed = AlpacaPollingFeed(client, symbols=["AAPL"], feed=DataFeed.IEX)
    assert feed.poll() == {}


def test_returns_latest_bar_per_symbol() -> None:
    t1 = datetime(2024, 1, 2, 9, 30)
    t2 = t1 + timedelta(minutes=1)
    client = FakeMarketDataClient()
    client.frames.append(
        pd.DataFrame([_row("AAPL", t1, 100.0), _row("AAPL", t2, 101.0), _row("MSFT", t2, 200.0)])
    )
    feed = AlpacaPollingFeed(client, symbols=["AAPL", "MSFT"], feed=DataFeed.IEX)

    bars = feed.poll()

    assert set(bars.keys()) == {"AAPL", "MSFT"}
    assert bars["AAPL"].close == 101.0  # the later of the two AAPL rows


def test_does_not_return_the_same_bar_twice() -> None:
    t1 = datetime(2024, 1, 2, 9, 30)
    client = FakeMarketDataClient()
    client.frames.append(pd.DataFrame([_row("AAPL", t1, 100.0)]))
    client.frames.append(pd.DataFrame([_row("AAPL", t1, 100.0)]))  # same bar again
    feed = AlpacaPollingFeed(client, symbols=["AAPL"], feed=DataFeed.IEX)

    first = feed.poll()
    second = feed.poll()

    assert "AAPL" in first
    assert second == {}


def test_returns_a_newer_bar_once_it_arrives() -> None:
    t1 = datetime(2024, 1, 2, 9, 30)
    t2 = t1 + timedelta(minutes=1)
    client = FakeMarketDataClient()
    client.frames.append(pd.DataFrame([_row("AAPL", t1, 100.0)]))
    client.frames.append(pd.DataFrame([_row("AAPL", t2, 101.0)]))
    feed = AlpacaPollingFeed(client, symbols=["AAPL"], feed=DataFeed.IEX)

    feed.poll()
    second = feed.poll()

    assert second["AAPL"].close == 101.0
