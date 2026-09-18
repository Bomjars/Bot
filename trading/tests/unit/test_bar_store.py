from __future__ import annotations

from pathlib import Path

import pandas as pd

from intraday_trading.storage.bar_store import BarStore

DAY_START = pd.Timestamp("2024-01-02", tz="UTC")
DAY_END = pd.Timestamp("2024-01-03", tz="UTC")


def _bar_row(symbol: str, ts: str, feed: str, close: float = 100.0) -> dict:
    return {
        "symbol": symbol,
        "ts": pd.Timestamp(ts, tz="UTC"),
        "open": close,
        "high": close,
        "low": close,
        "close": close,
        "volume": 1000.0,
        "feed": feed,
    }


def test_DATA_001_same_symbol_and_timestamp_kept_separate_per_feed(tmp_path: Path) -> None:
    store = BarStore(tmp_path / "bars.db")
    df = pd.DataFrame(
        [
            _bar_row("AAPL", "2024-01-02 09:30", "iex", close=100.0),
            _bar_row("AAPL", "2024-01-02 09:30", "sip", close=100.5),
        ]
    )
    store.upsert_bars(df)

    iex_bars = store.get_bars("AAPL", DAY_START, DAY_END, feed="iex")
    sip_bars = store.get_bars("AAPL", DAY_START, DAY_END, feed="sip")

    assert len(iex_bars) == 1
    assert len(sip_bars) == 1
    assert iex_bars.iloc[0]["close"] == 100.0
    assert sip_bars.iloc[0]["close"] == 100.5


def test_DATA_002_get_bars_never_returns_a_bar_after_as_of(tmp_path: Path) -> None:
    store = BarStore(tmp_path / "bars.db")
    df = pd.DataFrame(
        [
            _bar_row("AAPL", "2024-01-02 09:30", "iex", close=100.0),
            _bar_row("AAPL", "2024-01-02 09:31", "iex", close=101.0),  # "future" bar
        ]
    )
    store.upsert_bars(df)

    as_of = pd.Timestamp("2024-01-02 09:30:30", tz="UTC")
    bars = store.get_bars("AAPL", DAY_START, DAY_END, feed="iex", as_of=as_of)

    assert len(bars) == 1
    assert bars.iloc[0]["ts"] <= as_of


def test_DATA_003_gap_returns_only_bars_that_exist(tmp_path: Path) -> None:
    store = BarStore(tmp_path / "bars.db")
    df = pd.DataFrame(
        [
            _bar_row("AAPL", "2024-01-02 09:30", "iex"),
            _bar_row("AAPL", "2024-01-02 09:35", "iex"),  # gap: 09:31-09:34 missing
        ]
    )
    store.upsert_bars(df)

    bars = store.get_bars("AAPL", DAY_START, DAY_END, feed="iex")

    assert len(bars) == 2
    assert list(bars["ts"].dt.minute) == [30, 35]


def test_upsert_is_idempotent_on_conflict(tmp_path: Path) -> None:
    store = BarStore(tmp_path / "bars.db")
    df = pd.DataFrame([_bar_row("AAPL", "2024-01-02 09:30", "iex", close=100.0)])
    store.upsert_bars(df)
    store.upsert_bars(pd.DataFrame([_bar_row("AAPL", "2024-01-02 09:30", "iex", close=101.0)]))

    bars = store.get_bars("AAPL", DAY_START, DAY_END, feed="iex")
    assert len(bars) == 1
    assert bars.iloc[0]["close"] == 101.0
