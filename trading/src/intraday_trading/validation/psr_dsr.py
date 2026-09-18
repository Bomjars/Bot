"""Probabilistic Sharpe Ratio and Minimum Track Record Length (Bailey & López de Prado,
2012), and Deflated Sharpe Ratio (Bailey & López de Prado, 2014).

Note on verification: these are the standard closed-form formulas from the two papers,
implemented directly from their equations. I do not have a verified worked numeric
example from either paper memorized precisely enough to hardcode as a regression test
without risking asserting a wrong number with false confidence -- so the tests here are
property/edge-case tests (monotonicity, the known reduction to a textbook z-score when
skew=0/kurtosis=3, DSR collapsing to PSR at n_trials=1) rather than an exact-match
regression test against the papers' own worked example. If you can get me that worked
example, I'll add the exact regression test VAL-008 asks for.
"""

from __future__ import annotations

import math

from scipy.stats import norm

EULER_MASCHERONI = 0.5772156649015329


def probabilistic_sharpe_ratio(
    observed_sharpe: float,
    benchmark_sharpe: float,
    n_obs: int,
    skewness: float = 0.0,
    kurtosis: float = 3.0,
) -> float:
    """PSR(SR*): probability the *true* Sharpe ratio exceeds `benchmark_sharpe`, given
    `n_obs` observations of a Sharpe estimated at `observed_sharpe` with sample
    `skewness` and (non-excess) `kurtosis` (normal: skew=0, kurtosis=3). Bailey & López
    de Prado (2012), eq. 5.
    """
    if n_obs < 2:
        raise ValueError("PSR needs at least 2 observations")
    variance_term = 1 - skewness * observed_sharpe + ((kurtosis - 1) / 4) * observed_sharpe**2
    if variance_term <= 0:
        raise ValueError("degenerate PSR variance term -- check skewness/kurtosis inputs")
    z = (observed_sharpe - benchmark_sharpe) * math.sqrt(n_obs - 1) / math.sqrt(variance_term)
    return float(norm.cdf(z))


def minimum_track_record_length(
    observed_sharpe: float,
    benchmark_sharpe: float,
    skewness: float = 0.0,
    kurtosis: float = 3.0,
    target_psr: float = 0.95,
) -> float:
    """MinTRL: number of observations needed for PSR(benchmark_sharpe) to reach
    `target_psr`, at the same observed Sharpe/skew/kurtosis. Bailey & López de Prado
    (2012), eq. 10. +inf if `observed_sharpe <= benchmark_sharpe` -- no amount of
    additional data gets you there if your edge isn't even nominally better than the
    benchmark.
    """
    if observed_sharpe <= benchmark_sharpe:
        return float("inf")
    variance_term = 1 - skewness * observed_sharpe + ((kurtosis - 1) / 4) * observed_sharpe**2
    if variance_term <= 0:
        raise ValueError("degenerate MinTRL variance term -- check skewness/kurtosis inputs")
    z_alpha = norm.ppf(target_psr)
    return float(1 + variance_term * (z_alpha / (observed_sharpe - benchmark_sharpe)) ** 2)


def expected_max_sharpe_under_null(n_trials: int, sharpe_variance: float) -> float:
    """E[max Sharpe | n_trials independent trials, each ~ N(0, sharpe_variance)] -- the
    benchmark DSR deflates the observed Sharpe against. Bailey & López de Prado (2014)'s
    closed-form approximation using the Euler-Mascheroni constant. Returns 0.0 at
    n_trials=1 (no multiple-testing inflation with only one trial).
    """
    if n_trials < 1:
        raise ValueError("n_trials must be >= 1")
    if n_trials == 1:
        return 0.0
    inner = (1 - EULER_MASCHERONI) * norm.ppf(1 - 1 / n_trials) + EULER_MASCHERONI * norm.ppf(
        1 - 1 / (n_trials * math.e)
    )
    return float(math.sqrt(sharpe_variance) * inner)


def deflated_sharpe_ratio(
    observed_sharpe: float,
    n_trials: int,
    sharpe_variance: float,
    n_obs: int,
    skewness: float = 0.0,
    kurtosis: float = 3.0,
) -> float:
    """DSR: PSR evaluated against the expected maximum Sharpe you'd see under the null
    across `n_trials` independent attempts -- how much of the observed Sharpe survives
    after deflating for how many parameter combinations were tried. `n_trials` should
    come from `TrialRegistry.trial_count(strategy)` (retired trials included -- see
    registry.py's docstring on why).
    """
    benchmark = expected_max_sharpe_under_null(n_trials, sharpe_variance)
    return probabilistic_sharpe_ratio(observed_sharpe, benchmark, n_obs, skewness, kurtosis)
