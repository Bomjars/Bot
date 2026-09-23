"""Cost realism: persists every fill's actual price and commission against what the
order expected, so slippage is a stored, queryable number rather than a claim. Slippage
is always signed so that positive means "cost more than expected" regardless of side --
a buy filled above its expected price, or a sell filled below it, both count as adverse.
"""

from __future__ import annotations

from datetime import UTC, datetime
from pathlib import Path

from intraday_trading.broker.base import Side
from intraday_trading.storage.db import get_connection, init_db


def _signed_slippage(side: Side, expected_price: float, actual_price: float) -> float:
    return (actual_price - expected_price) if side == Side.BUY else (expected_price - actual_price)


class FillLog:
    def __init__(self, database_path: Path) -> None:
        self._database_path = database_path
        init_db(database_path)

    def log(
        self,
        client_order_id: str,
        broker_order_id: str,
        symbol: str,
        side: Side,
        qty: float,
        expected_price: float,
        actual_price: float,
        commission: float,
        commission_currency: str,
        ts: datetime | None = None,
        currency: str = "USD",
        fx_cost: float = 0.0,
    ) -> None:
        slippage = _signed_slippage(side, expected_price, actual_price)
        conn = get_connection(self._database_path)
        try:
            conn.execute(
                """
                INSERT INTO fills (
                    ts, client_order_id, broker_order_id, symbol, side, qty,
                    expected_price, actual_price, slippage, commission, commission_currency,
                    currency, fx_cost
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    (ts or datetime.now(tz=UTC)).isoformat(),
                    client_order_id,
                    broker_order_id,
                    symbol,
                    side.value,
                    qty,
                    expected_price,
                    actual_price,
                    slippage,
                    commission,
                    commission_currency,
                    currency,
                    fx_cost,
                ),
            )
            conn.commit()
        finally:
            conn.close()

    def recent(self, limit: int = 200) -> list[dict[str, object]]:
        conn = get_connection(self._database_path)
        try:
            rows = conn.execute("SELECT * FROM fills ORDER BY ts DESC LIMIT ?", (limit,)).fetchall()
        finally:
            conn.close()
        return [dict(row) for row in rows]

    def total_commission(self) -> float:
        conn = get_connection(self._database_path)
        try:
            row = conn.execute(
                "SELECT COALESCE(SUM(commission), 0.0) AS total FROM fills"
            ).fetchone()
            return float(row["total"])
        finally:
            conn.close()

    def total_fx_cost(self) -> float:
        """Sum of the per-fill FX cost *estimates* -- see fx_conversion_log.py for the
        measured cost of conversions the broker actually executed."""
        conn = get_connection(self._database_path)
        try:
            row = conn.execute("SELECT COALESCE(SUM(fx_cost), 0.0) AS total FROM fills").fetchone()
            return float(row["total"])
        finally:
            conn.close()

    def total_slippage_cost(self) -> float:
        """Sum of `qty * slippage` across every fill -- the total cost (in price *
        share units, i.e. account currency) of fills landing worse than expected,
        net of any that landed better."""
        conn = get_connection(self._database_path)
        try:
            row = conn.execute(
                "SELECT COALESCE(SUM(qty * slippage), 0.0) AS total FROM fills"
            ).fetchone()
            return float(row["total"])
        finally:
            conn.close()
