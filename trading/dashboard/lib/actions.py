"""Actions the dashboard can trigger -- every one of them routed through RiskManager,
never a direct broker call from this package (CLAUDE.md: the dashboard never places,
modifies, or cancels an order itself). Broker/RiskManager construction here mirrors
execution/wiring.py but doesn't build the full paper-trading loop -- the dashboard only
needs a handful of RiskManager methods and a live account/positions snapshot.
"""

from __future__ import annotations

from dataclasses import dataclass

from intraday_trading.broker.alpaca_broker import AlpacaBroker
from intraday_trading.broker.base import AccountInfo, OrderInfo, PositionInfo
from intraday_trading.config import Settings
from intraday_trading.killswitch.kill_switch import trip
from intraday_trading.risk.risk_manager import RiskManager
from intraday_trading.session.calendar import ExchangeCalendar
from intraday_trading.session.clock import SessionClock
from intraday_trading.storage.go_live_checklist_store import GoLiveChecklistStore
from intraday_trading.storage.order_log import OrderLog
from intraday_trading.storage.position_record_store import PositionRecordStore
from intraday_trading.storage.rejection_log import RejectionLog
from intraday_trading.storage.risk_state_store import RiskStateStore


def build_risk_manager(settings: Settings, broker: AlpacaBroker | None = None) -> RiskManager:
    broker = broker or AlpacaBroker.paper(settings)
    clock = SessionClock(
        calendar=ExchangeCalendar(),
        no_entry_first_minutes=settings.risk.no_entry_first_minutes,
        no_entry_last_minutes=settings.risk.no_entry_last_minutes,
        flatten_before_close_minutes=settings.risk.flatten_before_close_minutes,
    )
    return RiskManager(
        broker=broker,
        limits=settings.risk,
        clock=clock,
        state_store=RiskStateStore(settings.database_path),
        rejection_log=RejectionLog(settings.database_path),
        position_records=PositionRecordStore(settings.database_path),
        order_log=OrderLog(settings.database_path),
    )


@dataclass(frozen=True)
class LiveSnapshot:
    account: AccountInfo | None
    positions: list[PositionInfo]
    error: str | None


def load_live_snapshot(settings: Settings) -> LiveSnapshot:
    """Never raises -- callers show `error` in the UI instead of crashing the page."""
    try:
        broker = AlpacaBroker.paper(settings)
        return LiveSnapshot(
            account=broker.get_account(), positions=broker.get_positions(), error=None
        )
    except Exception as exc:  # broker unreachable, bad/missing keys, etc.
        return LiveSnapshot(account=None, positions=[], error=str(exc))


def trip_kill_switch(settings: Settings, reason: str = "dashboard kill switch") -> None:
    trip(build_risk_manager(settings), reason=reason)


def pause_entries(settings: Settings, reason: str = "paused from dashboard") -> None:
    build_risk_manager(settings).pause_entries(reason)


def re_enable(settings: Settings) -> None:
    build_risk_manager(settings).re_enable()


def flatten_one(settings: Settings, symbol: str) -> OrderInfo | None:
    return build_risk_manager(settings).flatten_one(symbol)


def flatten_all(settings: Settings) -> None:
    build_risk_manager(settings).flatten_all()


def mark_kill_switch_tested(settings: Settings) -> None:
    """GOLIVE-004: a human's record of having deliberately tripped the kill switch in
    paper and confirmed it worked. A checklist write, not an order -- CLAUDE.md's "no
    direct broker call from dashboard code" doesn't apply here."""
    GoLiveChecklistStore(settings.database_path).mark_kill_switch_tested()


def mark_reconciliation_tested(settings: Settings) -> None:
    """GOLIVE-004: a human's record of having deliberately restarted the paper loop and
    confirmed reconciliation worked."""
    GoLiveChecklistStore(settings.database_path).mark_reconciliation_tested()
