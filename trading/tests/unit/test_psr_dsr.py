from __future__ import annotations

import math

import pytest
from scipy.stats import norm

from intraday_trading.validation.psr_dsr import (
    deflated_sharpe_ratio,
    expected_max_sharpe_under_null,
    minimum_track_record_length,
    probabilistic_sharpe_ratio,
)


def test_VAL_008_psr_at_the_benchmark_sharpe_is_one_half() -> None:
    # z-score is 0 when observed == benchmark, regardless of n/skew/kurtosis
    psr = probabilistic_sharpe_ratio(observed_sharpe=1.0, benchmark_sharpe=1.0, n_obs=100)
    assert psr == pytest.approx(0.5)


def test_psr_reduces_to_textbook_zscore_under_normality() -> None:
    # skew=0, kurtosis=3 (normal) collapses the variance term to exactly 1
    observed, benchmark, n_obs = 1.2, 0.5, 250
    psr = probabilistic_sharpe_ratio(observed, benchmark, n_obs, skewness=0.0, kurtosis=3.0)
    expected_z = (observed - benchmark) * math.sqrt(n_obs - 1)
    assert psr == pytest.approx(float(norm.cdf(expected_z)))


def test_psr_increases_with_observed_sharpe() -> None:
    low = probabilistic_sharpe_ratio(0.5, 0.0, 100)
    high = probabilistic_sharpe_ratio(1.5, 0.0, 100)
    assert high > low


def test_psr_rejects_too_few_observations() -> None:
    with pytest.raises(ValueError, match="at least 2"):
        probabilistic_sharpe_ratio(1.0, 0.0, n_obs=1)


def test_VAL_008_min_track_record_length_is_infinite_below_benchmark() -> None:
    mintrl = minimum_track_record_length(observed_sharpe=0.3, benchmark_sharpe=0.5)
    assert mintrl == float("inf")


def test_min_track_record_length_decreases_as_edge_over_benchmark_grows() -> None:
    small_edge = minimum_track_record_length(observed_sharpe=0.6, benchmark_sharpe=0.5)
    big_edge = minimum_track_record_length(observed_sharpe=1.5, benchmark_sharpe=0.5)
    assert big_edge < small_edge


def test_min_track_record_length_is_positive_and_finite_for_a_real_edge() -> None:
    mintrl = minimum_track_record_length(observed_sharpe=1.5, benchmark_sharpe=0.5)
    assert 0 < mintrl < float("inf")


def test_expected_max_sharpe_is_zero_with_a_single_trial() -> None:
    assert expected_max_sharpe_under_null(n_trials=1, sharpe_variance=1.0) == 0.0


def test_expected_max_sharpe_increases_with_trial_count() -> None:
    few = expected_max_sharpe_under_null(n_trials=5, sharpe_variance=1.0)
    many = expected_max_sharpe_under_null(n_trials=500, sharpe_variance=1.0)
    assert many > few > 0


def test_expected_max_sharpe_rejects_zero_trials() -> None:
    with pytest.raises(ValueError, match=">= 1"):
        expected_max_sharpe_under_null(n_trials=0, sharpe_variance=1.0)


def test_VAL_007_dsr_uses_more_trials_to_deflate_more() -> None:
    dsr_few_trials = deflated_sharpe_ratio(
        observed_sharpe=1.5, n_trials=5, sharpe_variance=1.0, n_obs=250
    )
    dsr_many_trials = deflated_sharpe_ratio(
        observed_sharpe=1.5, n_trials=500, sharpe_variance=1.0, n_obs=250
    )
    assert dsr_many_trials < dsr_few_trials


def test_dsr_with_one_trial_equals_plain_psr_against_zero() -> None:
    dsr = deflated_sharpe_ratio(observed_sharpe=1.0, n_trials=1, sharpe_variance=1.0, n_obs=250)
    psr = probabilistic_sharpe_ratio(observed_sharpe=1.0, benchmark_sharpe=0.0, n_obs=250)
    assert dsr == pytest.approx(psr)
