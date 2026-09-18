"""Reconciliation: the broker is the source of truth (CLAUDE.md). On every restart --
and periodically while running -- this compares the broker's actual positions/orders
against RiskManager's own local record of what it believes it opened, and either repairs
a missing stop (EXEC-007) or halts and alerts on anything it can't explain (EXEC-008).
STATE-001's "rebuild state entirely from the broker" is mostly automatic here: RiskManager
already queries the broker fresh on every call rather than caching positions in memory,
so there's no separate in-memory cache to rebuild -- the only local state that can go
stale is `open_position_records`, which is exactly what this reconciles.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from intraday_trading.alerting.base import Alerter
from intraday_trading.broker.base import Broker
from intraday_trading.risk.risk_manager import RiskManager
from intraday_trading.storage.position_record_store import PositionRecordStore


@dataclass(frozen=True)
class ReconciliationResult:
    stops_restored: list[str] = field(default_factory=list)
    unrecognized_positions: list[str] = field(default_factory=list)
    stale_records_cleared: list[str] = field(default_factory=list)


class Reconciler:
    def __init__(
        self,
        broker: Broker,
        position_records: PositionRecordStore,
        risk_manager: RiskManager,
        alerter: Alerter,
    ) -> None:
        self._broker = broker
        self._position_records = position_records
        self._risk_manager = risk_manager
        self._alerter = alerter

    def reconcile(self) -> ReconciliationResult:
        positions = {p.symbol: p for p in self._broker.get_positions()}
        symbols_with_open_orders = {o.symbol for o in self._broker.get_open_orders()}
        records = {r.symbol: r for r in self._position_records.all()}

        stops_restored: list[str] = []
        unrecognized: list[str] = []

        for symbol, position in positions.items():
            record = records.get(symbol)
            if record is None:
                unrecognized.append(symbol)
                continue
            if symbol not in symbols_with_open_orders:
                # EXEC-007: a known open position with no resting order at all means its
                # protective stop is missing -- restore it from our own record.
                self._risk_manager.restore_missing_stop(
                    symbol=symbol,
                    side=position.side,
                    qty=position.qty,
                    stop_price=record.stop_price,
                    take_profit_price=record.take_profit_price,
                )
                stops_restored.append(symbol)

        if unrecognized:
            self._alerter.alert(
                f"Reconciliation found broker position(s) with no local record: "
                f"{', '.join(sorted(unrecognized))}. Entries halted until acknowledged."
            )
            self._risk_manager.halt_for_unrecognized_position(
                f"unrecognized broker position(s): {', '.join(sorted(unrecognized))}"
            )

        stale = [symbol for symbol in records if symbol not in positions]
        for symbol in stale:
            self._position_records.remove(symbol)

        if stops_restored:
            self._alerter.alert(
                f"Reconciliation restored missing stop-loss order(s) for: "
                f"{', '.join(sorted(stops_restored))}."
            )

        return ReconciliationResult(
            stops_restored=stops_restored,
            unrecognized_positions=unrecognized,
            stale_records_cleared=stale,
        )
