"""RiskManager: the only code path allowed to call `Broker.submit_bracket_order` (see
CLAUDE.md and RISK-021's static check in tests/unit/test_risk_manager_gate.py). Every
hard limit from `RiskLimits` is checked here, in the order a human would want to know
about a rejection reason, and any unexpected exception rejects the order rather than
letting it through (RISK-020: fail closed).
"""

from __future__ import annotations

import threading
from dataclasses import replace
from datetime import date, datetime, timedelta

from intraday_trading.broker.base import (
    BracketOrderRequest,
    Broker,
    OrderInfo,
    Side,
    make_client_order_id,
)
from intraday_trading.config import RiskLimits
from intraday_trading.risk.signals import EntrySignal, HaltType, RiskDecision
from intraday_trading.session.clock import SessionClock
from intraday_trading.storage.order_log import OrderLog
from intraday_trading.storage.position_record_store import PositionRecordStore
from intraday_trading.storage.rejection_log import RejectionLog
from intraday_trading.storage.risk_state_store import RiskState, RiskStateStore


def _week_start(day: date) -> date:
    return day - timedelta(days=day.weekday())


class RiskManager:
    def __init__(
        self,
        broker: Broker,
        limits: RiskLimits,
        clock: SessionClock,
        state_store: RiskStateStore,
        rejection_log: RejectionLog,
        leveraged_etf_symbols: frozenset[str] = frozenset(),
        position_records: PositionRecordStore | None = None,
        order_log: OrderLog | None = None,
        live_notional_cap_usd: float | None = None,
    ) -> None:
        self._broker = broker
        self._limits = limits
        self._clock = clock
        self._state_store = state_store
        self._rejection_log = rejection_log
        self._leveraged_etf_symbols = leveraged_etf_symbols
        self._position_records = position_records
        self._order_log = order_log
        self._live_notional_cap_usd = live_notional_cap_usd
        self._lock = threading.Lock()

    def is_halted(self) -> bool:
        return self._state_store.load().halted

    def halt_status(self) -> RiskState:
        return self._state_store.load()

    @property
    def live_notional_cap_usd(self) -> float | None:
        """None in paper (the normal case); a positive USD figure only when wired up
        for live trading (GOLIVE-006) -- exposed read-only for the dashboard/gate to
        display, never settable after construction."""
        return self._live_notional_cap_usd

    def begin_session(self) -> None:
        """Call once at/before the start of each trading day. Resets the daily trade
        counter and baseline equity, auto-clears a DAILY_LOSS halt (RISK-007: "halt for
        the rest of the day", not forever), and rolls the weekly baseline over on a new
        week without touching a WEEKLY_LOSS/DRAWDOWN/KILL_SWITCH halt — those need
        `re_enable()` (RISK-008/009)."""
        with self._lock:
            state = self._state_store.load()
            today = self._clock.now().date()
            equity = self._broker.get_account().equity

            if state.trading_day != today:
                if state.halt_type == HaltType.DAILY_LOSS:
                    state = replace(state, halted=False, halt_type=HaltType.NONE, halt_reason=None)
                state = replace(
                    state, trading_day=today, daily_starting_equity=equity, trades_today=0
                )

            week_start = _week_start(today)
            if state.week_start != week_start:
                state = replace(state, week_start=week_start, weekly_starting_equity=equity)

            if state.peak_equity is None:
                state = replace(state, peak_equity=equity)

            self._state_store.save(state)

    def check_and_submit_entry(self, signal: EntrySignal) -> RiskDecision:
        with self._lock:
            try:
                return self._check_and_submit_entry_locked(signal)
            except Exception as exc:  # RISK-020: fail closed on any unexpected error
                reason = f"internal_error: {exc}"
                self._rejection_log.log(signal, reason)
                return RiskDecision(accepted=False, reason=reason)

    def _reject(self, signal: EntrySignal, reason: str) -> RiskDecision:
        self._rejection_log.log(signal, reason)
        return RiskDecision(accepted=False, reason=reason)

    def _check_and_submit_entry_locked(self, signal: EntrySignal) -> RiskDecision:
        state = self._state_store.load()

        if state.halted:
            return self._reject(signal, f"halted: {state.halt_reason or state.halt_type.value}")
        if signal.current_price < self._limits.min_price_usd:
            return self._reject(signal, "price_below_minimum")
        if signal.avg_dollar_volume < self._limits.min_avg_dollar_volume_usd:
            return self._reject(signal, "avg_dollar_volume_below_minimum")
        if signal.spread_pct > self._limits.max_spread_pct:
            return self._reject(signal, "spread_too_wide")
        if signal.symbol in self._leveraged_etf_symbols and not self._limits.allow_leveraged_etfs:
            return self._reject(signal, "leveraged_etf_excluded")
        if not self._clock.can_enter():
            return self._reject(signal, "outside_entry_window")
        if state.trades_today >= self._limits.max_trades_per_day:
            return self._reject(signal, "max_trades_per_day_reached")
        if signal.stop_price <= 0:
            return self._reject(signal, "missing_stop_loss")

        stop_distance = abs(signal.entry_price - signal.stop_price)
        if stop_distance <= 0:
            return self._reject(signal, "invalid_stop_distance")
        if signal.qty <= 0:
            return self._reject(signal, "qty_not_positive")

        positions = self._broker.get_positions()
        if len(positions) >= self._limits.max_open_positions:
            return self._reject(signal, "max_open_positions_reached")

        equity = self._broker.get_account().equity
        risk_amount = signal.qty * stop_distance
        if risk_amount > equity * self._limits.max_risk_per_trade_pct:
            return self._reject(signal, "risk_per_trade_exceeded")

        notional = signal.qty * signal.entry_price
        if notional > equity * self._limits.max_position_pct_of_equity:
            return self._reject(signal, "position_pct_exceeded")

        if self._live_notional_cap_usd is not None and notional > self._live_notional_cap_usd:
            # GOLIVE-006: the "start live with <= a small cap" constraint, independent
            # of account equity -- only ever set when settings.live_trading is True
            # (see execution/wiring.py), never in paper.
            return self._reject(signal, "live_notional_cap_exceeded")

        existing_notional = sum(p.qty * p.current_price for p in positions)
        if existing_notional + notional > equity * self._limits.max_leverage:
            return self._reject(signal, "leverage_exceeded")

        client_order_id = make_client_order_id(signal.strategy, signal.symbol, signal.signal_seq)
        request = BracketOrderRequest(
            client_order_id=client_order_id,
            symbol=signal.symbol,
            side=signal.side,
            qty=signal.qty,
            stop_loss_price=signal.stop_price,
            take_profit_price=signal.take_profit_price,
        )
        order = self._broker.submit_bracket_order(request)
        if self._order_log is not None:
            self._order_log.log(signal, order)
        if self._position_records is not None:
            self._position_records.record_open(
                symbol=signal.symbol,
                stop_price=signal.stop_price,
                take_profit_price=signal.take_profit_price,
                client_order_id=client_order_id,
                opened_at=self._clock.now(),
            )

        state.trades_today += 1
        self._state_store.save(state)
        return RiskDecision(accepted=True, broker_order_id=order.broker_order_id)

    def flatten_all(self) -> None:
        """KILL-001: cancel every open order before closing positions, so a fill racing
        the flatten can't slip through without its stop having already been cancelled
        out from under it."""
        self._broker.cancel_all_orders()
        self._broker.close_all_positions()

    def flatten_one(self, symbol: str) -> OrderInfo | None:
        """Dashboard's per-position "Flatten" control -- still routed through
        RiskManager (RISK-021), not a direct broker call from dashboard code
        (CLAUDE.md). Does not halt; closing one position isn't an emergency."""
        with self._lock:
            return self._broker.close_position(symbol)

    def pause_entries(self, reason: str) -> None:
        """Dashboard's "Pause entries" control: blocks new entries like any other halt,
        but -- unlike `trip_kill_switch` -- does not flatten anything. `re_enable()`
        clears it, same as any other halt."""
        with self._lock:
            self._halt(HaltType.MANUAL_PAUSE, reason)

    def _halt(self, halt_type: HaltType, reason: str) -> None:
        state = self._state_store.load()
        state = replace(state, halted=True, halt_type=halt_type, halt_reason=reason)
        self._state_store.save(state)

    def trip_kill_switch(self, reason: str) -> None:
        with self._lock:
            self.flatten_all()
            self._halt(HaltType.KILL_SWITCH, reason)

    def re_enable(self) -> None:
        with self._lock:
            state = self._state_store.load()
            state = replace(state, halted=False, halt_type=HaltType.NONE, halt_reason=None)
            self._state_store.save(state)

    def check_loss_limits(self) -> RiskState:
        """Call periodically from the event loop (step 8). Flattens and halts on the
        first breached limit; returns the resulting state either way."""
        with self._lock:
            state = self._state_store.load()
            if state.halted:
                return state

            equity = self._broker.get_account().equity
            if state.peak_equity is None or equity > state.peak_equity:
                state = replace(state, peak_equity=equity)
                self._state_store.save(state)

            if state.daily_starting_equity:
                daily_pnl_pct = (equity - state.daily_starting_equity) / state.daily_starting_equity
                if daily_pnl_pct <= -self._limits.daily_loss_limit_pct:
                    self.flatten_all()
                    self._halt(HaltType.DAILY_LOSS, f"daily loss {daily_pnl_pct:.2%}")
                    return self._state_store.load()

            if state.weekly_starting_equity:
                weekly_pnl_pct = (
                    equity - state.weekly_starting_equity
                ) / state.weekly_starting_equity
                if weekly_pnl_pct <= -self._limits.weekly_loss_limit_pct:
                    self.flatten_all()
                    self._halt(HaltType.WEEKLY_LOSS, f"weekly loss {weekly_pnl_pct:.2%}")
                    return self._state_store.load()

            if state.peak_equity:
                drawdown_pct = (state.peak_equity - equity) / state.peak_equity
                if drawdown_pct >= self._limits.drawdown_circuit_breaker_pct:
                    self.flatten_all()
                    self._halt(HaltType.DRAWDOWN, f"drawdown {drawdown_pct:.2%}")
                    return self._state_store.load()

            return state

    def restore_missing_stop(
        self,
        symbol: str,
        side: Side,
        qty: float,
        stop_price: float,
        take_profit_price: float | None,
    ) -> OrderInfo:
        """EXEC-007: the reconciler's only way to re-place a stop -- still goes through
        RiskManager (RISK-021: the only code path allowed to call
        `Broker.submit_bracket_order`), it just skips the entry checks because this
        isn't a new position, it's restoring protection on one that already exists."""
        request = BracketOrderRequest(
            client_order_id=make_client_order_id("reconcile", symbol, datetime.now().isoformat()),
            symbol=symbol,
            side=side,
            qty=qty,
            stop_loss_price=stop_price,
            take_profit_price=take_profit_price,
        )
        return self._broker.submit_bracket_order(request)

    def halt_for_unrecognized_position(self, reason: str) -> None:
        """EXEC-008: an open broker position with no matching local record is an alert
        and a halt on new entries, not a guess -- deliberately does NOT flatten,
        unlike `trip_kill_switch`, since we don't know enough about this position to
        safely close it ourselves."""
        with self._lock:
            self._halt(HaltType.RECONCILIATION_MISMATCH, reason)

    def halt_for_clock_drift(self, reason: str) -> None:
        """EXEC-010: trading on a skewed clock is dangerous in ways a simple halt
        can't fix by flattening -- same shape as the reconciliation halt, no flatten."""
        with self._lock:
            self._halt(HaltType.CLOCK_DRIFT, reason)

    def check_session_flatten(self) -> bool:
        """RISK-014/015: flatten (no halt) once inside the flatten-before-close window,
        already correct on half days since `SessionClock` derives it from the actual
        close time."""
        if self._clock.should_flatten():
            self.flatten_all()
            return True
        return False
