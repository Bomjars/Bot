"""Polls Alpaca's REST minute-bar endpoint for new bars, standing in for a websocket
stream -- see event_loop.py's module docstring for why polling was chosen. One instance
tracks a fixed set of symbols and only returns a bar once, the first time it's seen.
"""

from __future__ import annotations

from datetime import UTC, datetime, timedelta

from intraday_trading.config import DataFeed
from intraday_trading.data.client import MarketDataClient
from intraday_trading.strategies.base import Bar


class AlpacaPollingFeed:
    def __init__(
        self,
        client: MarketDataClient,
        symbols: list[str],
        feed: DataFeed,
        lookback: timedelta = timedelta(minutes=5),
    ) -> None:
        self._client = client
        self._symbols = symbols
        self._feed = feed
        self._lookback = lookback
        self._last_seen: dict[str, datetime] = {}

    def poll(self) -> dict[str, Bar]:
        if not self._symbols:
            return {}
        now = datetime.now(tz=UTC)
        df = self._client.get_minute_bars(
            self._symbols, start=now - self._lookback, end=now, feed=self._feed
        )
        if df.empty:
            return {}

        new_bars: dict[str, Bar] = {}
        for symbol_value, group in df.groupby("symbol"):
            symbol = str(symbol_value)
            latest = group.sort_values("ts").iloc[-1]
            ts = latest["ts"].to_pydatetime()
            if symbol in self._last_seen and ts <= self._last_seen[symbol]:
                continue
            self._last_seen[symbol] = ts
            new_bars[symbol] = Bar(
                ts=ts,
                open=float(latest["open"]),
                high=float(latest["high"]),
                low=float(latest["low"]),
                close=float(latest["close"]),
                volume=float(latest["volume"]),
            )
        return new_bars
