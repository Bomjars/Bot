"""Interactive Brokers implementation of the `Broker` interface, via `ib_async` and IB
Gateway. Paper by default (`IBKRBroker.paper()`, port `ibkr_port`/4002);
`IBKRBroker.live()` (port `ibkr_live_port`/4001) only ever constructs when
`settings.live_trading is True`, mirroring `AlpacaBroker`'s paper-only-by-construction
pattern -- see CLAUDE.md.

`ib_async` is asyncio-native but designed to be driven synchronously from a plain
script -- `IB.connect()`/`placeOrder()`/... block until they return -- so nothing else
in this codebase needs to become async to use it.

Every order is placed only against a USD, SMART-routed `Stock` contract (never
parameterized by currency or exchange) -- this is the adapter-level half of "US
stocks/ETFs only, no UK-listed shares"; `RiskManager.allowed_currencies` (RISK-027) is
the other half, checked before an order ever reaches this class.

Fills are asynchronous at IBKR: `placeOrder()` returns immediately with a "submitted"
`Trade`, and the actual execution/commission report arrives later via IB's own callback
events. `poll_fills()` is a broker-specific extension -- not part of the shared `Broker`
Protocol, since Alpaca's REST fills are already synchronous and have nothing to poll --
that the paper/live loop calls once per tick to drain newly-completed fills into
storage/fill_log.py.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime

from ib_async import (
    IB,
    AccountValue,
    Contract,
    Fill,
    LimitOrder,
    MarketOrder,
    Order,
    PortfolioItem,
    Stock,
    StopOrder,
    Trade,
)

from intraday_trading.broker.base import (
    AccountInfo,
    BracketOrderRequest,
    BrokerClock,
    OrderInfo,
    PositionInfo,
    Side,
)
from intraday_trading.config import Settings
from intraday_trading.session.calendar import EXCHANGE_TZ, ExchangeCalendar

_SIDE_TO_ACTION = {Side.BUY: "BUY", Side.SELL: "SELL"}
_ACTION_TO_SIDE = {"BUY": Side.BUY, "SELL": Side.SELL}
_EXEC_SIDE_TO_SIDE = {"BOT": Side.BUY, "SLD": Side.SELL}

_STATUS_MAP = {
    "PendingSubmit": "pending",
    "PreSubmitted": "pending",
    "ApiPending": "pending",
    "Submitted": "accepted",
    "Filled": "filled",
    "Cancelled": "canceled",
    "ApiCancelled": "canceled",
    "Inactive": "rejected",
}


@dataclass(frozen=True)
class FillEvent:
    """A completed IBKR execution, drained via `IBKRBroker.poll_fills()` -- everything
    storage/fill_log.py (a stock fill) or storage/fx_conversion_log.py (a currency
    conversion, `sec_type == "CASH"`) needs to record it."""

    client_order_id: str
    broker_order_id: str
    symbol: str
    side: Side
    qty: float
    fill_price: float
    commission: float
    commission_currency: str
    ts: datetime
    currency: str = "USD"
    """The contract's trading (quote) currency -- e.g. "USD" for a US stock, or for a
    GBP.USD conversion (symbol "GBP")."""
    sec_type: str = "STK"
    """IBKR's security type: "STK" for a stock/ETF, "CASH" for a currency conversion."""

    @property
    def is_fx_conversion(self) -> bool:
        return self.sec_type == "CASH"


def _as_date(value: date | datetime) -> date:
    return value.date() if isinstance(value, datetime) else value


def _us_stock_contract(symbol: str) -> Contract:
    return Stock(symbol, exchange="SMART", currency="USD")


def _opposite(side: Side) -> Side:
    return Side.SELL if side == Side.BUY else Side.BUY


def _account_value(values: list[AccountValue], tag: str) -> float | None:
    matches = [v for v in values if v.tag == tag]
    if not matches:
        return None
    preferred = next((v for v in matches if v.currency == "USD"), matches[0])
    return float(preferred.value)


class IBKRBroker:
    def __init__(
        self, ib: IB, host: str = "127.0.0.1", port: int = 4002, client_id: int = 1
    ) -> None:
        self._ib = ib
        self._host = host
        self._port = port
        self._client_id = client_id
        self._calendar = ExchangeCalendar()
        self._seen_exec_ids: set[str] = set()

    @classmethod
    def paper(cls, settings: Settings) -> IBKRBroker:
        """The only supported way to connect to IB Gateway's paper-trading socket --
        always `ibkr_port` (default 4002). There is no live path here; see `.live()`."""
        ib = IB()
        ib.connect(settings.ibkr_host, settings.ibkr_port, clientId=settings.ibkr_client_id)
        return cls(ib, settings.ibkr_host, settings.ibkr_port, settings.ibkr_client_id)

    @classmethod
    def live(cls, settings: Settings) -> IBKRBroker:
        """Port `ibkr_live_port` (default 4001) -- only ever constructs when
        `settings.live_trading is True` (itself gated by the SAFE-002/003 confirmation
        string in `Settings`). See CLAUDE.md."""
        if not settings.live_trading:
            raise ValueError(
                "IBKRBroker.live() requires settings.live_trading=True -- use "
                "IBKRBroker.paper() for IB Gateway's paper port."
            )
        ib = IB()
        ib.connect(settings.ibkr_host, settings.ibkr_live_port, clientId=settings.ibkr_client_id)
        return cls(ib, settings.ibkr_host, settings.ibkr_live_port, settings.ibkr_client_id)

    def is_connected(self) -> bool:
        return bool(self._ib.isConnected())

    def reconnect(self) -> None:
        """Re-dials with the same host/port/clientId this instance was constructed
        with (paper or live, whichever it already was) -- a no-op if already
        connected. Callers should wrap this in `execution/reconnect.py`'s
        `retry_with_backoff` rather than call it bare, since a dropped Gateway may take
        a few attempts to come back."""
        if not self.is_connected():
            self._ib.connect(self._host, self._port, clientId=self._client_id)

    def get_account(self) -> AccountInfo:
        values = self._ib.accountSummary()
        equity = _account_value(values, "NetLiquidation")
        # SettledCash, not TotalCashValue: this is what RiskManager's cash_account_only
        # check (RISK-026) compares an order's notional against, so it must reflect
        # money actually available to trade today, not cash still pending settlement.
        cash = _account_value(values, "SettledCash")
        if cash is None:
            cash = _account_value(values, "TotalCashValue")
        buying_power = _account_value(values, "BuyingPower")
        if equity is None or cash is None or buying_power is None:
            raise ValueError(f"IBKR account summary missing required fields: {values!r}")
        currency = next((v.currency for v in values if v.tag == "NetLiquidation"), "USD")
        return AccountInfo(equity=equity, cash=cash, buying_power=buying_power, currency=currency)

    def get_positions(self) -> list[PositionInfo]:
        return [
            _position_info_from_portfolio_item(item)
            for item in self._ib.portfolio()
            if item.position != 0
        ]

    def get_open_orders(self) -> list[OrderInfo]:
        return [self._order_info_from_trade(t) for t in self._ib.openTrades()]

    def get_clock(self) -> BrokerClock:
        ts = self._ib.reqCurrentTime()
        session = self._calendar.session_for_date(ts.astimezone(EXCHANGE_TZ).date())
        is_open = session is not None and session.open <= ts <= session.close
        return BrokerClock(timestamp=ts, is_open=is_open)

    def submit_bracket_order(self, request: BracketOrderRequest) -> OrderInfo:
        contract = self._qualify(request.symbol)
        action = _SIDE_TO_ACTION[request.side]
        reverse_action = _SIDE_TO_ACTION[_opposite(request.side)]

        parent_id = self._ib.client.getReqId()
        parent: Order = MarketOrder(
            action, request.qty, orderId=parent_id, orderRef=request.client_order_id, transmit=False
        )
        legs: list[Order] = [parent]
        if request.take_profit_price is not None:
            take_profit: Order = LimitOrder(
                reverse_action,
                request.qty,
                request.take_profit_price,
                orderId=self._ib.client.getReqId(),
                orderRef=request.client_order_id,
                parentId=parent_id,
                transmit=False,
            )
            legs.append(take_profit)
        stop: Order = StopOrder(
            reverse_action,
            request.qty,
            request.stop_loss_price,
            orderId=self._ib.client.getReqId(),
            orderRef=request.client_order_id,
            parentId=parent_id,
            transmit=True,
        )
        legs.append(stop)

        parent_trade: Trade | None = None
        for leg in legs:
            trade = self._ib.placeOrder(contract, leg)
            if leg is parent:
                parent_trade = trade
        assert parent_trade is not None  # `parent` is always the first leg placed
        return self._order_info_from_trade(parent_trade)

    def cancel_order(self, broker_order_id: str) -> None:
        order_id = int(broker_order_id)
        trade = next((t for t in self._ib.openTrades() if t.order.orderId == order_id), None)
        if trade is not None:
            self._ib.cancelOrder(trade.order)

    def cancel_all_orders(self) -> None:
        self._ib.reqGlobalCancel()  # type: ignore[no-untyped-call] # untyped upstream

    def close_position(self, symbol: str) -> OrderInfo | None:
        item = next(
            (p for p in self._ib.portfolio() if p.contract.symbol == symbol and p.position != 0),
            None,
        )
        if item is None:
            return None
        contract = self._qualify(symbol)
        action = "SELL" if item.position > 0 else "BUY"
        order = MarketOrder(action, abs(item.position), orderRef=f"close-{symbol}")
        trade = self._ib.placeOrder(contract, order)
        return self._order_info_from_trade(trade)

    def close_all_positions(self) -> None:
        for item in self._ib.portfolio():
            if item.position != 0:
                self.close_position(item.contract.symbol)

    def poll_fills(self) -> list[FillEvent]:
        """Drains newly-seen executions since the last call -- `ib.fills()` itself
        returns every fill cached since connection, not just new ones, so this tracks
        which `execId`s have already been returned.

        IBKR sends an execution's commission report as a separate message, usually just
        after the execution itself. Until it arrives, `fill.commissionReport` is an empty
        placeholder (commission 0.0, no execId) -- so a fill is held back, not marked
        seen, until its own report is attached, rather than being recorded once with a
        commission of zero that never gets corrected."""
        events = []
        for fill in self._ib.fills():
            exec_id = fill.execution.execId
            if exec_id in self._seen_exec_ids:
                continue
            if fill.commissionReport.execId != exec_id:
                continue  # commission report not in yet -- pick it up on a later tick
            self._seen_exec_ids.add(exec_id)
            events.append(_fill_event_from_fill(fill))
        return events

    def get_daily_closes(self, symbol: str, duration_str: str = "5 D") -> list[tuple[date, float]]:
        """Daily closing prices for `symbol` over `duration_str` (IBKR's own duration
        format, e.g. "5 D", "1 Y") -- used only by reporting/benchmark.py's
        buy-and-hold comparison, never by a strategy (CLAUDE.md rule 9: strategies only
        ever read market data through `StrategyContext`, not a broker call of their
        own)."""
        contract = self._qualify(symbol)
        bars = self._ib.reqHistoricalData(
            contract,
            endDateTime="",
            durationStr=duration_str,
            barSizeSetting="1 day",
            whatToShow="TRADES",
            useRTH=True,
        )
        return [(_as_date(bar.date), bar.close) for bar in bars]

    def _qualify(self, symbol: str) -> Contract:
        qualified = self._ib.qualifyContracts(_us_stock_contract(symbol))
        if not qualified:
            raise ValueError(f"IBKR could not qualify a USD/SMART contract for {symbol!r}")
        return qualified[0]

    def _order_info_from_trade(self, trade: Trade) -> OrderInfo:
        status = trade.orderStatus
        return OrderInfo(
            broker_order_id=str(trade.order.orderId),
            client_order_id=trade.order.orderRef,
            symbol=trade.contract.symbol,
            side=_ACTION_TO_SIDE[trade.order.action],
            qty=trade.order.totalQuantity,
            status=_STATUS_MAP.get(status.status, status.status.lower()),
            filled_qty=status.filled,
            filled_avg_price=status.avgFillPrice if status.filled > 0 else None,
        )


def _position_info_from_portfolio_item(item: PortfolioItem) -> PositionInfo:
    return PositionInfo(
        symbol=item.contract.symbol,
        qty=abs(item.position),
        side=Side.BUY if item.position >= 0 else Side.SELL,
        avg_entry_price=item.averageCost,
        current_price=item.marketPrice,
        unrealized_pl=item.unrealizedPNL,
    )


def _fill_event_from_fill(fill: Fill) -> FillEvent:
    execution = fill.execution
    return FillEvent(
        client_order_id=execution.orderRef,
        broker_order_id=str(execution.orderId),
        symbol=fill.contract.symbol,
        side=_EXEC_SIDE_TO_SIDE.get(execution.side, Side.BUY),
        qty=execution.shares,
        fill_price=execution.price,
        commission=fill.commissionReport.commission,
        commission_currency=fill.commissionReport.currency,
        ts=fill.time,
        currency=fill.contract.currency or "USD",
        sec_type=fill.contract.secType or "STK",
    )
