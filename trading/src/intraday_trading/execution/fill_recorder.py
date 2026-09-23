"""Bridges a broker-specific fill event (today, only IBKRBroker.poll_fills() produces
one -- Alpaca's REST fills are already synchronous and need no draining) to
storage/fill_log.py: looks up the order's *expected* price from OrderLog so slippage can
be computed, and writes the fills row.
"""

from __future__ import annotations

from intraday_trading.broker.ibkr_broker import FillEvent
from intraday_trading.storage.fill_log import FillLog
from intraday_trading.storage.order_log import OrderLog


def record_fill(fill_log: FillLog, order_log: OrderLog, event: FillEvent) -> bool:
    """Returns False (and writes nothing) if no order matches `event.client_order_id`
    -- e.g. a fill this process didn't originate the order for. Never raises: a fill
    with no matching order is a data-quality gap to notice, not a reason to crash the
    loop mid-tick."""
    order = order_log.find_by_client_order_id(event.client_order_id)
    if order is None:
        return False
    fill_log.log(
        client_order_id=event.client_order_id,
        broker_order_id=event.broker_order_id,
        symbol=event.symbol,
        side=event.side,
        qty=event.qty,
        expected_price=float(order["entry_price"]),  # type: ignore[arg-type]
        actual_price=event.fill_price,
        commission=event.commission,
        commission_currency=event.commission_currency,
        ts=event.ts,
    )
    return True
