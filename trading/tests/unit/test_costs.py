from __future__ import annotations

from intraday_trading.backtest.costs import CostModel
from intraday_trading.broker.base import Side


def test_BT_003_buy_fills_above_quote_sell_fills_below() -> None:
    model = CostModel(slippage_bps=10.0, spread_bps=4.0)
    buy_fill = model.fill_price(Side.BUY, 100.0)
    sell_fill = model.fill_price(Side.SELL, 100.0)
    assert buy_fill > 100.0
    assert sell_fill < 100.0
    assert buy_fill - 100.0 == 100.0 - sell_fill  # symmetric adverse move


def test_BT_003_commission_floors_at_minimum() -> None:
    model = CostModel(commission_per_share=0.0, commission_min=1.0)
    assert model.commission(qty=1) == 1.0
    model2 = CostModel(commission_per_share=0.01, commission_min=1.0)
    assert model2.commission(qty=500) == 5.0  # 0.01*500 > the $1 floor


def test_BT_003_fx_conversion_cost_reduces_usd_amount() -> None:
    model = CostModel(fx_conversion_cost_pct=0.01)
    usd = model.convert_gbp_to_usd(gbp_amount=10_000.0, gbp_usd_rate=1.27)
    assert usd == 10_000.0 * 1.27 * 0.99


def test_BT_004_at_multiplier_scales_slippage_and_spread_only() -> None:
    base = CostModel(slippage_bps=5.0, spread_bps=2.0, commission_min=1.0)
    doubled = base.at_multiplier(2.0)
    assert doubled.slippage_bps == 10.0
    assert doubled.spread_bps == 4.0
    assert doubled.commission_min == 1.0  # commissions aren't a slippage assumption
