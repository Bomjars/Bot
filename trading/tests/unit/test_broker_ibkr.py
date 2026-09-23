"""IBKRBroker exercised entirely against a fake `IB` client -- no network access, no
running IB Gateway needed. Uses ib_async's own real value types (Stock, Order, Trade,
OrderStatus, PortfolioItem, AccountValue, Fill, Execution, CommissionReport) since
they're plain constructible dataclasses, not vendor objects requiring a live connection
(unlike alpaca-py's pydantic models in test_broker_alpaca.py). Only `IB` itself --
the class that actually talks to a socket -- is faked.

Verifies the same cross-broker invariants test_broker_alpaca.py does for Alpaca: a
bracket order always carries a stop (RISK-010/EXEC-001) with the client_order_id we
were given (EXEC-002, via IBKR's `orderRef`), and there is no live path unless
`settings.live_trading` is already true (SAFE-004).
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import UTC, date, datetime

from ib_async import (
    AccountValue,
    BarData,
    CommissionReport,
    Contract,
    Execution,
    Fill,
    Order,
    OrderStatus,
    PortfolioItem,
    Stock,
    Trade,
)

from intraday_trading.broker.base import BracketOrderRequest, Side
from intraday_trading.broker.ibkr_broker import IBKRBroker
from intraday_trading.config import Settings

T0 = datetime(2024, 1, 2, 15, 0, tzinfo=UTC)  # mid-session ET


@dataclass
class _FakeClient:
    _next_id: int = 1000

    def getReqId(self) -> int:
        self._next_id += 1
        return self._next_id


@dataclass
class FakeIB:
    client: _FakeClient = field(default_factory=_FakeClient)
    placed: list[tuple[Contract, Order]] = field(default_factory=list)
    portfolio_items: list[PortfolioItem] = field(default_factory=list)
    account_values: list[AccountValue] = field(default_factory=list)
    open_trades_list: list[Trade] = field(default_factory=list)
    fills_list: list[Fill] = field(default_factory=list)
    cancelled_orders: list[Order] = field(default_factory=list)
    global_cancel_called: int = 0
    current_time: datetime = T0
    qualify_result: list[Contract] | None = None
    connected: bool = True
    connect_calls: list[tuple[str, int, int]] = field(default_factory=list)
    historical_bars: list[BarData] = field(default_factory=list)

    def isConnected(self) -> bool:
        return self.connected

    def connect(self, host: str, port: int, clientId: int = 1) -> None:
        self.connect_calls.append((host, port, clientId))
        self.connected = True

    def reqHistoricalData(self, contract: Contract, **kwargs: object) -> list[BarData]:
        return list(self.historical_bars)

    def qualifyContracts(self, *contracts: Contract) -> list[Contract]:
        if self.qualify_result is not None:
            return self.qualify_result
        return list(contracts)

    def placeOrder(self, contract: Contract, order: Order) -> Trade:
        order.orderId = order.orderId or self.client.getReqId()
        status = OrderStatus(
            orderId=order.orderId,
            status="Submitted",
            filled=0.0,
            remaining=order.totalQuantity,
            avgFillPrice=0.0,
        )
        trade = Trade(contract, order, status, [], [])
        self.placed.append((contract, order))
        self.open_trades_list.append(trade)
        return trade

    def portfolio(self) -> list[PortfolioItem]:
        return list(self.portfolio_items)

    def accountSummary(self) -> list[AccountValue]:
        return list(self.account_values)

    def openTrades(self) -> list[Trade]:
        return list(self.open_trades_list)

    def fills(self) -> list[Fill]:
        return list(self.fills_list)

    def reqCurrentTime(self) -> datetime:
        return self.current_time

    def cancelOrder(self, order: Order, manualCancelOrderTime: str = "") -> Trade | None:
        self.cancelled_orders.append(order)
        return None

    def reqGlobalCancel(self) -> None:
        self.global_cancel_called += 1


def _broker() -> tuple[IBKRBroker, FakeIB]:
    fake = FakeIB()
    return IBKRBroker(fake), fake  # type: ignore[arg-type]


def test_SAFE_004_live_requires_live_trading_true() -> None:
    settings = Settings(alpaca_api_key="x", alpaca_secret_key="y", live_trading=False)
    try:
        IBKRBroker.live(settings)
    except ValueError as exc:
        assert "live_trading=True" in str(exc)
    else:
        raise AssertionError("expected a ValueError")


def test_is_connected_reflects_the_underlying_ib_client() -> None:
    broker, fake = _broker()
    assert broker.is_connected() is True
    fake.connected = False
    assert broker.is_connected() is False


def test_reconnect_redials_with_the_original_paper_connection_parameters() -> None:
    fake = FakeIB(connected=False)
    broker = IBKRBroker(fake, host="127.0.0.1", port=4002, client_id=7)  # type: ignore[arg-type]

    broker.reconnect()

    assert fake.connect_calls == [("127.0.0.1", 4002, 7)]
    assert broker.is_connected() is True


def test_reconnect_is_a_no_op_when_already_connected() -> None:
    fake = FakeIB(connected=True)
    broker = IBKRBroker(fake, host="127.0.0.1", port=4002, client_id=1)  # type: ignore[arg-type]

    broker.reconnect()

    assert fake.connect_calls == []


def test_EXEC_001_bracket_order_always_carries_stop_loss() -> None:
    broker, fake = _broker()
    request = BracketOrderRequest(
        client_order_id="itd-abc",
        symbol="AAPL",
        side=Side.BUY,
        qty=10,
        stop_loss_price=95.0,
    )

    order_info = broker.submit_bracket_order(request)

    assert len(fake.placed) == 2  # parent + stop only, no take-profit leg
    (parent_contract, parent_order), (stop_contract, stop_order) = fake.placed
    assert parent_contract.symbol == "AAPL"
    assert parent_contract.currency == "USD"
    assert parent_order.action == "BUY"
    assert parent_order.orderType == "MKT"
    assert parent_order.transmit is False
    assert parent_order.orderRef == "itd-abc"

    assert stop_order.action == "SELL"  # opposite side
    assert stop_order.orderType == "STP"
    assert stop_order.auxPrice == 95.0
    assert stop_order.parentId == parent_order.orderId
    assert stop_order.transmit is True  # last leg transmits

    assert order_info.broker_order_id == str(parent_order.orderId)
    assert order_info.client_order_id == "itd-abc"
    assert order_info.status == "accepted"
    assert order_info.filled_qty == 0.0
    assert order_info.filled_avg_price is None


def test_EXEC_001_bracket_order_with_take_profit_places_three_legs() -> None:
    broker, fake = _broker()
    request = BracketOrderRequest(
        client_order_id="itd-xyz",
        symbol="AAPL",
        side=Side.SELL,
        qty=5,
        stop_loss_price=110.0,
        take_profit_price=90.0,
    )

    broker.submit_bracket_order(request)

    assert len(fake.placed) == 3
    parent_order, take_profit_order, stop_order = (o for _c, o in fake.placed)
    assert parent_order.transmit is False
    assert take_profit_order.orderType == "LMT"
    assert take_profit_order.lmtPrice == 90.0
    assert take_profit_order.transmit is False
    assert take_profit_order.parentId == parent_order.orderId
    assert stop_order.transmit is True
    assert stop_order.parentId == parent_order.orderId


def test_get_account_reads_settled_cash_and_net_liquidation() -> None:
    broker, fake = _broker()
    fake.account_values = [
        AccountValue(
            account="U1", tag="NetLiquidation", value="100000.0", currency="USD", modelCode=""
        ),
        AccountValue(
            account="U1", tag="SettledCash", value="50000.0", currency="USD", modelCode=""
        ),
        AccountValue(
            account="U1", tag="BuyingPower", value="100000.0", currency="USD", modelCode=""
        ),
    ]

    account = broker.get_account()

    assert account.equity == 100_000.0
    assert account.cash == 50_000.0
    assert account.buying_power == 100_000.0
    assert account.currency == "USD"


def test_get_account_raises_when_a_required_field_is_missing() -> None:
    broker, fake = _broker()
    fake.account_values = [
        AccountValue(
            account="U1", tag="NetLiquidation", value="100000.0", currency="USD", modelCode=""
        )
    ]  # missing cash and buying_power
    try:
        broker.get_account()
    except ValueError as exc:
        assert "missing required fields" in str(exc)
    else:
        raise AssertionError("expected a ValueError")


def test_get_open_orders_maps_every_open_trade() -> None:
    broker, fake = _broker()
    order = Order(orderId=7, action="BUY", totalQuantity=10, orderType="MKT", orderRef="itd-1")
    status = OrderStatus(orderId=7, status="PreSubmitted", filled=0.0, remaining=10.0)
    fake.open_trades_list = [Trade(Stock("AAPL"), order, status, [], [])]

    orders = broker.get_open_orders()

    assert len(orders) == 1
    assert orders[0].symbol == "AAPL"
    assert orders[0].status == "pending"


def test_get_account_falls_back_to_total_cash_value_when_settled_cash_missing() -> None:
    broker, fake = _broker()
    fake.account_values = [
        AccountValue(
            account="U1", tag="NetLiquidation", value="100000.0", currency="USD", modelCode=""
        ),
        AccountValue(
            account="U1", tag="TotalCashValue", value="80000.0", currency="USD", modelCode=""
        ),
        AccountValue(
            account="U1", tag="BuyingPower", value="100000.0", currency="USD", modelCode=""
        ),
    ]

    account = broker.get_account()

    assert account.cash == 80_000.0


def test_get_positions_maps_portfolio_items() -> None:
    broker, fake = _broker()
    fake.portfolio_items = [
        PortfolioItem(
            contract=Stock("AAPL", "SMART", "USD"),
            position=10.0,
            marketPrice=101.5,
            marketValue=1015.0,
            averageCost=100.0,
            unrealizedPNL=15.0,
            realizedPNL=0.0,
            account="U1",
        ),
        PortfolioItem(
            contract=Stock("MSFT", "SMART", "USD"),
            position=0.0,
            marketPrice=300.0,
            marketValue=0.0,
            averageCost=0.0,
            unrealizedPNL=0.0,
            realizedPNL=0.0,
            account="U1",
        ),
    ]

    positions = broker.get_positions()

    assert len(positions) == 1  # zero-position row excluded
    assert positions[0].symbol == "AAPL"
    assert positions[0].qty == 10.0
    assert positions[0].side == Side.BUY
    assert positions[0].avg_entry_price == 100.0
    assert positions[0].current_price == 101.5
    assert positions[0].unrealized_pl == 15.0


def test_get_positions_reports_a_short_as_sell_side() -> None:
    broker, fake = _broker()
    fake.portfolio_items = [
        PortfolioItem(
            contract=Stock("AAPL", "SMART", "USD"),
            position=-10.0,
            marketPrice=101.5,
            marketValue=-1015.0,
            averageCost=100.0,
            unrealizedPNL=-15.0,
            realizedPNL=0.0,
            account="U1",
        )
    ]

    positions = broker.get_positions()

    assert positions[0].side == Side.SELL
    assert positions[0].qty == 10.0  # always positive


def test_cancel_order_looks_up_the_matching_open_trade() -> None:
    broker, fake = _broker()
    order = Order(orderId=42, action="BUY", totalQuantity=10, orderType="MKT")
    status = OrderStatus(orderId=42, status="Submitted", filled=0.0, remaining=10.0)
    fake.open_trades_list = [Trade(Stock("AAPL"), order, status, [], [])]

    broker.cancel_order("42")

    assert fake.cancelled_orders == [order]


def test_cancel_order_is_a_no_op_for_an_unknown_id() -> None:
    broker, fake = _broker()
    broker.cancel_order("999")
    assert fake.cancelled_orders == []


def test_cancel_all_orders_calls_req_global_cancel() -> None:
    broker, fake = _broker()
    broker.cancel_all_orders()
    assert fake.global_cancel_called == 1


def test_close_position_submits_the_opposite_side_market_order() -> None:
    broker, fake = _broker()
    fake.portfolio_items = [
        PortfolioItem(
            contract=Stock("AAPL", "SMART", "USD"),
            position=10.0,
            marketPrice=101.5,
            marketValue=1015.0,
            averageCost=100.0,
            unrealizedPNL=15.0,
            realizedPNL=0.0,
            account="U1",
        )
    ]

    order_info = broker.close_position("AAPL")

    assert order_info is not None
    (_contract, order) = fake.placed[0]
    assert order.action == "SELL"
    assert order.totalQuantity == 10.0


def test_close_position_returns_none_when_nothing_is_open() -> None:
    broker, _fake = _broker()
    assert broker.close_position("AAPL") is None


def test_close_all_positions_closes_every_open_position() -> None:
    broker, fake = _broker()
    fake.portfolio_items = [
        PortfolioItem(
            contract=Stock("AAPL", "SMART", "USD"),
            position=10.0,
            marketPrice=100.0,
            marketValue=1000.0,
            averageCost=100.0,
            unrealizedPNL=0.0,
            realizedPNL=0.0,
            account="U1",
        ),
        PortfolioItem(
            contract=Stock("MSFT", "SMART", "USD"),
            position=-5.0,
            marketPrice=300.0,
            marketValue=-1500.0,
            averageCost=300.0,
            unrealizedPNL=0.0,
            realizedPNL=0.0,
            account="U1",
        ),
    ]

    broker.close_all_positions()

    assert len(fake.placed) == 2
    actions = {order.action for _c, order in fake.placed}
    assert actions == {"SELL", "BUY"}


def test_poll_fills_returns_new_executions_only_once() -> None:
    broker, fake = _broker()
    execution = Execution(
        execId="exec-1",
        orderId=42,
        orderRef="itd-abc",
        side="BOT",
        shares=10.0,
        price=100.5,
        time=T0,
    )
    commission = CommissionReport(execId="exec-1", commission=1.5, currency="USD")
    fake.fills_list = [Fill(Stock("AAPL"), execution, commission, T0)]

    first = broker.poll_fills()
    second = broker.poll_fills()

    assert len(first) == 1
    event = first[0]
    assert event.client_order_id == "itd-abc"
    assert event.broker_order_id == "42"
    assert event.symbol == "AAPL"
    assert event.side == Side.BUY
    assert event.qty == 10.0
    assert event.fill_price == 100.5
    assert event.commission == 1.5
    assert event.commission_currency == "USD"
    assert second == []  # already seen


def test_get_clock_reports_open_during_a_regular_session() -> None:
    broker, fake = _broker()
    fake.current_time = T0  # 15:00 UTC = 10:00 ET on a Tuesday
    clock = broker.get_clock()
    assert clock.is_open is True
    assert clock.timestamp == T0


def test_get_clock_reports_closed_outside_session_hours() -> None:
    broker, fake = _broker()
    fake.current_time = datetime(2024, 1, 2, 2, 0, tzinfo=UTC)  # 21:00 ET, after close
    clock = broker.get_clock()
    assert clock.is_open is False


def test_get_daily_closes_maps_bar_dates_and_closes() -> None:
    broker, fake = _broker()
    fake.historical_bars = [
        BarData(date=date(2024, 1, 2), close=500.0),
        BarData(date=date(2024, 1, 3), close=505.0),
    ]

    closes = broker.get_daily_closes("SPY", duration_str="2 D")

    assert closes == [(date(2024, 1, 2), 500.0), (date(2024, 1, 3), 505.0)]


def test_get_daily_closes_handles_a_datetime_valued_bar_date() -> None:
    broker, fake = _broker()
    fake.historical_bars = [BarData(date=datetime(2024, 1, 2, 0, 0, tzinfo=UTC), close=500.0)]

    closes = broker.get_daily_closes("SPY")

    assert closes == [(date(2024, 1, 2), 500.0)]


def test_qualify_raises_when_ibkr_cannot_qualify_the_contract() -> None:
    broker, fake = _broker()
    fake.qualify_result = []
    try:
        broker.submit_bracket_order(
            BracketOrderRequest(
                client_order_id="x", symbol="NOTREAL", side=Side.BUY, qty=1, stop_loss_price=1.0
            )
        )
    except ValueError as exc:
        assert "NOTREAL" in str(exc)
    else:
        raise AssertionError("expected a ValueError")
