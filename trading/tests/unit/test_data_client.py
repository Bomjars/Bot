from __future__ import annotations

from dataclasses import dataclass

import pandas as pd

from intraday_trading.config import DataFeed
from intraday_trading.data.client import AlpacaMarketDataClient


@dataclass
class FakeBarSet:
    df: pd.DataFrame


class FakeHistoricalDataClient:
    def __init__(self, df: pd.DataFrame) -> None:
        self._df = df
        self.last_request = None

    def get_stock_bars(self, request_params):
        self.last_request = request_params
        return FakeBarSet(df=self._df)


def _sample_df() -> pd.DataFrame:
    index = pd.MultiIndex.from_tuples(
        [
            ("AAPL", pd.Timestamp("2024-01-02 09:30", tz="UTC")),
            ("AAPL", pd.Timestamp("2024-01-02 09:31", tz="UTC")),
        ],
        names=["symbol", "timestamp"],
    )
    return pd.DataFrame(
        {
            "open": [100.0, 100.5],
            "high": [100.6, 100.7],
            "low": [99.9, 100.2],
            "close": [100.5, 100.6],
            "volume": [1000, 1200],
        },
        index=index,
    )


def test_DATA_001_bars_tagged_with_requested_feed() -> None:
    fake_client = FakeHistoricalDataClient(_sample_df())
    client = AlpacaMarketDataClient(fake_client)

    df = client.get_minute_bars(
        ["AAPL"],
        start=pd.Timestamp("2024-01-02 09:30", tz="UTC"),
        end=pd.Timestamp("2024-01-02 09:35", tz="UTC"),
        feed=DataFeed.IEX,
    )

    assert list(df.columns) == ["symbol", "ts", "open", "high", "low", "close", "volume", "feed"]
    assert (df["feed"] == "iex").all()
    assert len(df) == 2


def test_empty_symbols_returns_empty_frame_without_calling_client() -> None:
    fake_client = FakeHistoricalDataClient(_sample_df())
    client = AlpacaMarketDataClient(fake_client)

    df = client.get_minute_bars(
        [],
        start=pd.Timestamp("2024-01-02", tz="UTC"),
        end=pd.Timestamp("2024-01-03", tz="UTC"),
        feed=DataFeed.IEX,
    )

    assert df.empty
    assert fake_client.last_request is None
