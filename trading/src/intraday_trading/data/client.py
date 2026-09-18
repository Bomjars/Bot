"""Market data client interface + Alpaca historical-bars implementation.

Only historical minute bars for now (needed by the backtester, step 4). Live streaming
is deferred to step 8 (paper-trading loop), where it needs to be integrated with the
event loop's reconnect/backoff logic (EXEC-005) rather than bolted on here.
"""

from __future__ import annotations

from collections.abc import Sequence
from datetime import datetime
from typing import Protocol

import pandas as pd
from alpaca.data.enums import DataFeed as AlpacaDataFeed
from alpaca.data.historical.stock import StockHistoricalDataClient
from alpaca.data.requests import StockBarsRequest
from alpaca.data.timeframe import TimeFrame

from intraday_trading.config import DataFeed, Settings

BAR_COLUMNS = ["symbol", "ts", "open", "high", "low", "close", "volume", "feed"]

_FEED_TO_ALPACA = {DataFeed.IEX: AlpacaDataFeed.IEX, DataFeed.SIP: AlpacaDataFeed.SIP}


class MarketDataClient(Protocol):
    def get_minute_bars(
        self,
        symbols: Sequence[str],
        start: datetime,
        end: datetime,
        feed: DataFeed,
    ) -> pd.DataFrame:
        """Return a DataFrame with columns `BAR_COLUMNS`, one row per (symbol, minute)."""
        ...


class AlpacaMarketDataClient:
    def __init__(self, client: StockHistoricalDataClient) -> None:
        self._client = client

    @classmethod
    def from_settings(cls, settings: Settings) -> AlpacaMarketDataClient:
        client = StockHistoricalDataClient(
            api_key=settings.alpaca_api_key,
            secret_key=settings.alpaca_secret_key,
        )
        return cls(client)

    def get_minute_bars(
        self,
        symbols: Sequence[str],
        start: datetime,
        end: datetime,
        feed: DataFeed,
    ) -> pd.DataFrame:
        if not symbols:
            return pd.DataFrame(columns=BAR_COLUMNS)

        request = StockBarsRequest(
            symbol_or_symbols=list(symbols),
            start=start,
            end=end,
            timeframe=TimeFrame.Minute,
            feed=_FEED_TO_ALPACA[feed],
        )
        bar_set = self._client.get_stock_bars(request)
        if isinstance(bar_set, dict):
            raise TypeError(f"unexpected raw dict response from Alpaca: {bar_set!r}")
        df = bar_set.df
        if df.empty:
            return pd.DataFrame(columns=BAR_COLUMNS)

        df = df.reset_index().rename(columns={"timestamp": "ts"})
        df["feed"] = feed.value
        return df[BAR_COLUMNS]
