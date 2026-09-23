"""Bridges a broker-specific fill event (today, only IBKRBroker.poll_fills() produces
one -- Alpaca's REST fills are already synchronous and need no draining) to storage:
a stock fill goes to storage/fill_log.py (with its expected price looked up from
OrderLog, so slippage can be computed), and a currency conversion goes to
storage/fx_conversion_log.py as a measured FX cost.
"""

from __future__ import annotations

from dataclasses import dataclass

from intraday_trading.broker.ibkr_broker import FillEvent
from intraday_trading.storage.fill_log import FillLog
from intraday_trading.storage.fx_conversion_log import FxConversionLog
from intraday_trading.storage.order_log import OrderLog


@dataclass(frozen=True)
class FxEstimate:
    """How to estimate a stock fill's FX cost -- see Settings.fx_cost_per_fill_pct."""

    account_currency: str
    cost_per_fill_pct: float

    def cost(self, fill_currency: str, notional: float) -> float:
        if fill_currency == self.account_currency:
            return 0.0
        return notional * self.cost_per_fill_pct


def record_fill(
    fill_log: FillLog,
    order_log: OrderLog,
    event: FillEvent,
    fx_estimate: FxEstimate | None = None,
) -> bool:
    """Returns False (and writes nothing) if no order matches `event.client_order_id`
    -- e.g. a fill this process didn't originate the order for. Never raises: a fill
    with no matching order is a data-quality gap to notice, not a reason to crash the
    loop mid-tick. `fx_estimate` None records a zero FX cost estimate."""
    order = order_log.find_by_client_order_id(event.client_order_id)
    if order is None:
        return False
    fx_cost = (
        fx_estimate.cost(event.currency, event.qty * event.fill_price)
        if fx_estimate is not None
        else 0.0
    )
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
        currency=event.currency,
        fx_cost=fx_cost,
    )
    return True


def record_fx_conversion(fx_log: FxConversionLog, event: FillEvent) -> None:
    """A currency conversion has no originating order in OrderLog (RiskManager never
    places one -- it's a funding step, done by hand or by the broker), so unlike
    `record_fill` there's nothing to look up: the event itself is the whole record."""
    fx_log.log(
        broker_order_id=event.broker_order_id,
        pair=f"{event.symbol}.{event.currency}",
        side=event.side,
        amount=event.qty,
        rate=event.fill_price,
        commission=event.commission,
        commission_currency=event.commission_currency,
        ts=event.ts,
    )


def record_event(
    fill_log: FillLog,
    fx_log: FxConversionLog,
    order_log: OrderLog,
    event: FillEvent,
    fx_estimate: FxEstimate | None = None,
) -> None:
    """Routes one drained event to the right log. Before this existed, a conversion
    was passed to `record_fill`, found no matching order, and was silently dropped."""
    if event.is_fx_conversion:
        record_fx_conversion(fx_log, event)
    else:
        record_fill(fill_log, order_log, event, fx_estimate)
