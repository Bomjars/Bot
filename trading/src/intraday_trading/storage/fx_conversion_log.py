"""Measured FX cost: every currency conversion the broker actually executed (e.g. an IBKR
GBP.USD trade to fund USD stock purchases from a GBP account), with its real rate and
commission. The counterpart to `fills.fx_cost`, which is only an estimate.

Commission is what's measurable directly. The spread paid on the rate itself isn't --
that needs a reference mid-rate this system doesn't record -- so `total_commission()`
is a floor on true FX cost, not the whole of it.
"""

from __future__ import annotations

from datetime import UTC, datetime
from pathlib import Path

from intraday_trading.broker.base import Side
from intraday_trading.storage.db import get_connection, init_db


class FxConversionLog:
    def __init__(self, database_path: Path) -> None:
        self._database_path = database_path
        init_db(database_path)

    def log(
        self,
        broker_order_id: str,
        pair: str,
        side: Side,
        amount: float,
        rate: float,
        commission: float,
        commission_currency: str,
        ts: datetime | None = None,
    ) -> None:
        conn = get_connection(self._database_path)
        try:
            conn.execute(
                """
                INSERT INTO fx_conversions (
                    ts, broker_order_id, pair, side, amount, rate, commission,
                    commission_currency
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    (ts or datetime.now(tz=UTC)).isoformat(),
                    broker_order_id,
                    pair,
                    side.value,
                    amount,
                    rate,
                    commission,
                    commission_currency,
                ),
            )
            conn.commit()
        finally:
            conn.close()

    def recent(self, limit: int = 200) -> list[dict[str, object]]:
        conn = get_connection(self._database_path)
        try:
            rows = conn.execute(
                "SELECT * FROM fx_conversions ORDER BY ts DESC LIMIT ?", (limit,)
            ).fetchall()
        finally:
            conn.close()
        return [dict(row) for row in rows]

    def total_commission(self) -> float:
        conn = get_connection(self._database_path)
        try:
            row = conn.execute(
                "SELECT COALESCE(SUM(commission), 0.0) AS total FROM fx_conversions"
            ).fetchone()
            return float(row["total"])
        finally:
            conn.close()
