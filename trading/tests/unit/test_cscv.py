from __future__ import annotations

import itertools
import math

import numpy as np
import pandas as pd
import pytest

from intraday_trading.validation.cscv import CSCVResult, CSCVVerdict, cscv_pbo, evaluate


def _random_walk_returns(n_days: int, n_configs: int, seed: int = 42) -> pd.DataFrame:
    rng = np.random.default_rng(seed)
    return pd.DataFrame(
        rng.normal(0, 1, size=(n_days, n_configs)),
        columns=[f"config_{i}" for i in range(n_configs)],
    )


def test_VAL_001_random_walk_gives_high_pbo() -> None:
    returns = _random_walk_returns(n_days=320, n_configs=15)
    result = cscv_pbo(returns)
    assert result.pbo > 0.4


def test_VAL_002_injected_effect_gives_low_pbo() -> None:
    returns = _random_walk_returns(n_days=320, n_configs=15)
    returns["config_0"] = returns["config_0"] + 0.5  # persistent, real edge
    result = cscv_pbo(returns)
    assert result.pbo < 0.1


def test_VAL_003_default_16_blocks_gives_exactly_12870_splits() -> None:
    returns = _random_walk_returns(n_days=32, n_configs=3)
    result = cscv_pbo(returns)
    assert result.n_splits == 12870
    assert math.comb(16, 8) == 12870


def test_VAL_004_omega_is_never_exactly_0_or_1() -> None:
    returns = _random_walk_returns(n_days=32, n_configs=3)
    result = cscv_pbo(returns)
    assert all(math.isfinite(lam) for lam in result.logits)


def test_VAL_005_matches_a_brute_force_reference_on_a_tiny_example() -> None:
    """Independent, unoptimized reference implementation (plain pandas, no sufficient-
    statistics shortcut) on a small fixed dataset -- the fast path in cscv.py must agree
    with it, not just "look reasonable"."""
    rng = np.random.default_rng(7)
    returns = pd.DataFrame(rng.normal(0, 1, size=(8, 3)), columns=["a", "b", "c"])
    n_blocks = 4
    blocks = [returns.iloc[i * 2 : (i + 1) * 2] for i in range(n_blocks)]

    expected_logits = []
    for is_idx in itertools.combinations(range(n_blocks), 2):
        oos_idx = [i for i in range(n_blocks) if i not in is_idx]
        is_data = pd.concat([blocks[i] for i in is_idx])
        oos_data = pd.concat([blocks[i] for i in oos_idx])
        is_sharpe = is_data.mean() / is_data.std(ddof=0)
        oos_sharpe = oos_data.mean() / oos_data.std(ddof=0)
        best = is_sharpe.idxmax()
        selected_oos = oos_sharpe[best]
        rank = int((oos_sharpe <= selected_oos).sum())
        omega = rank / (3 + 1)
        expected_logits.append(math.log(omega / (1 - omega)))

    result = cscv_pbo(returns, n_blocks=n_blocks)

    assert result.n_splits == math.comb(4, 2) == 6
    assert result.logits == pytest.approx(expected_logits)


def test_regression_slope_is_nan_with_fewer_than_two_splits() -> None:
    # cscv_pbo itself can never produce fewer than 2 splits (minimum is C(2,1)=2), so
    # this constructs the degenerate case directly to exercise the guard clause.
    result = CSCVResult(
        n_splits=1,
        n_configs=2,
        logits=[0.1],
        is_sharpes=[0.5],
        oos_sharpes=[0.3],
        pbo=0.0,
        p_oos_sharpe_negative=0.0,
        oos_sharpes_pooled=[0.3, 0.2],
    )
    assert math.isnan(result.regression_slope)


def test_regression_slope_is_finite_for_a_real_run() -> None:
    returns = _random_walk_returns(n_days=32, n_configs=3)
    result = cscv_pbo(returns, n_blocks=2)  # C(2,1) = 2 splits
    assert math.isfinite(result.regression_slope)


def test_VAL_010_evaluate_rejects_on_pbo_alone() -> None:
    returns = _random_walk_returns(n_days=320, n_configs=15)
    result = cscv_pbo(returns)
    verdict = evaluate(result)
    assert isinstance(verdict, CSCVVerdict)
    assert verdict.passed is False
    assert "PBO" in verdict.reason


def test_evaluate_passes_a_clean_injected_effect() -> None:
    returns = _random_walk_returns(n_days=320, n_configs=15)
    returns["config_0"] = returns["config_0"] + 0.5
    result = cscv_pbo(returns)
    verdict = evaluate(result)
    assert verdict.passed is True


def test_rejects_fewer_than_two_configs() -> None:
    returns = _random_walk_returns(n_days=32, n_configs=1)
    with pytest.raises(ValueError, match="at least 2"):
        cscv_pbo(returns)


def test_rejects_odd_n_blocks() -> None:
    returns = _random_walk_returns(n_days=32, n_configs=3)
    with pytest.raises(ValueError, match="even"):
        cscv_pbo(returns, n_blocks=5)


def test_trims_rows_that_dont_divide_evenly() -> None:
    returns = _random_walk_returns(n_days=35, n_configs=3)  # 35 % 16 == 3
    result = cscv_pbo(returns)
    assert result.n_splits == 12870
