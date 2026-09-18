"""Cost model applied to every simulated fill: commission, a spread+slippage estimate,
and a one-off FX conversion cost. FX cost is applied once, to the starting capital when
it's converted from GBP to USD to fund the account — not per trade, since every trade
after that happens entirely in USD (see docs/PLAN.md).
"""

from __future__ import annotations

from dataclasses import dataclass

from intraday_trading.broker.base import Side


@dataclass(frozen=True)
class CostModel:
    commission_per_share: float = 0.0
    commission_min: float = 0.0
    slippage_bps: float = 5.0
    spread_bps: float = 2.0
    fx_conversion_cost_pct: float = 0.005

    def fill_price(self, side: Side, quoted_price: float) -> float:
        """A buy fills slightly above the quoted price, a sell slightly below --
        slippage and half the spread both work against the trader in the same
        direction, so they're combined into a single adverse-move estimate."""
        adverse_bps = self.slippage_bps + self.spread_bps / 2
        adverse = quoted_price * adverse_bps / 10_000
        return quoted_price + adverse if side == Side.BUY else quoted_price - adverse

    def commission(self, qty: float) -> float:
        return max(self.commission_min, qty * self.commission_per_share)

    def convert_gbp_to_usd(self, gbp_amount: float, gbp_usd_rate: float) -> float:
        usd_amount = gbp_amount * gbp_usd_rate
        return usd_amount * (1 - self.fx_conversion_cost_pct)

    def at_multiplier(self, multiplier: float) -> CostModel:
        """BT-004: rerun everything at e.g. 2x slippage to see how sensitive the result
        is to the cost assumptions."""
        return CostModel(
            commission_per_share=self.commission_per_share,
            commission_min=self.commission_min,
            slippage_bps=self.slippage_bps * multiplier,
            spread_bps=self.spread_bps * multiplier,
            fx_conversion_cost_pct=self.fx_conversion_cost_pct,
        )
