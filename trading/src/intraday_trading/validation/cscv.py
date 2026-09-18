"""Probability of Backtest Overfitting via Combinatorially Symmetric Cross-Validation
(Bailey, Borwein, López de Prado & Zhu, 2015). This module only EVALUATES a set of
trials that has already been run in full -- CLAUDE.md: never let a PBO value feed back
into which parameters get tried next, or you're overfitting to the overfitting detector.
"""

from __future__ import annotations

import itertools
from dataclasses import dataclass

import numpy as np
import pandas as pd

DEFAULT_N_BLOCKS = 16


@dataclass(frozen=True)
class CSCVResult:
    n_splits: int
    n_configs: int
    logits: list[float]
    is_sharpes: list[float]
    oos_sharpes: list[float]
    pbo: float
    p_oos_sharpe_negative: float
    oos_sharpes_pooled: list[float]
    """Every config's OOS Sharpe from every split, pooled -- the "all configs"
    distribution for the stochastic-dominance comparison against `oos_sharpes` (the
    "selected" distribution)."""

    @property
    def regression_slope(self) -> float:
        """Slope of OOS Sharpe on IS Sharpe across splits. Near-zero or negative is the
        classic overfitting signature: in-sample skill predicting nothing (or worse)
        out-of-sample."""
        if len(self.is_sharpes) < 2:
            return float("nan")
        slope, _ = np.polyfit(self.is_sharpes, self.oos_sharpes, 1)
        return float(slope)


@dataclass(frozen=True)
class CSCVVerdict:
    passed: bool
    reason: str


def _sharpe_from_sums(total: np.ndarray, total_sq: np.ndarray, n: int) -> np.ndarray:
    """Sharpe ratio per column from block-aggregated sufficient statistics (sum, sum of
    squares, count) rather than re-scanning raw rows -- this is what makes 12,870 splits
    tractable. Uses population variance (ddof=0): since every config in a given IS or
    OOS half shares the same `n`, this differs from the sample (ddof=1) Sharpe by a
    constant factor for that half, which cannot change the IS ranking (the argmax) or
    which OOS values sit above/below the selected one (the rank) -- the only two things
    CSCV actually uses.
    """
    mean = total / n
    variance = np.maximum(total_sq / n - mean**2, 0.0)
    std = np.sqrt(variance)
    return np.divide(mean, std, out=np.zeros_like(mean), where=std > 0)


def cscv_pbo(returns: pd.DataFrame, n_blocks: int = DEFAULT_N_BLOCKS) -> CSCVResult:
    """`returns`: rows = trading days, columns = one per configuration/trial, values =
    that day's return (or P&L) for that config. `n_blocks` must be even (split into IS
    and OOS halves); rows are trimmed from the start if they don't divide evenly into
    `n_blocks` equal contiguous blocks.
    """
    if n_blocks % 2 != 0:
        raise ValueError("n_blocks must be even")

    returns = returns.sort_index()
    n_configs = returns.shape[1]
    if n_configs < 2:
        raise ValueError("CSCV needs at least 2 configurations to compare")

    remainder = len(returns) % n_blocks
    if remainder:
        returns = returns.iloc[remainder:]
    block_size = len(returns) // n_blocks
    if block_size < 1:
        raise ValueError(f"not enough rows ({len(returns)}) for {n_blocks} blocks")

    values = returns.to_numpy(dtype=float)
    blocks = values.reshape(n_blocks, block_size, n_configs)
    block_sum = blocks.sum(axis=1)
    block_sumsq = (blocks**2).sum(axis=1)

    half = n_blocks // 2
    is_n = block_size * half
    oos_n = block_size * (n_blocks - half)
    all_indices = set(range(n_blocks))

    is_sharpes: list[float] = []
    oos_sharpes: list[float] = []
    logits: list[float] = []
    oos_sharpes_pooled: list[float] = []

    for is_indices in itertools.combinations(range(n_blocks), half):
        oos_indices = list(all_indices.difference(is_indices))

        is_sharpe = _sharpe_from_sums(
            block_sum[list(is_indices)].sum(axis=0), block_sumsq[list(is_indices)].sum(axis=0), is_n
        )
        oos_sharpe = _sharpe_from_sums(
            block_sum[oos_indices].sum(axis=0), block_sumsq[oos_indices].sum(axis=0), oos_n
        )

        best_config = int(np.argmax(is_sharpe))
        is_sharpes.append(float(is_sharpe[best_config]))
        selected_oos_sharpe = float(oos_sharpe[best_config])
        oos_sharpes.append(selected_oos_sharpe)
        oos_sharpes_pooled.extend(float(v) for v in oos_sharpe)

        # 1-indexed rank of the selected config's OOS Sharpe among all configs' OOS
        # Sharpes; omega=rank/(n+1) keeps it strictly in (0,1) so the logit never blows
        # up (VAL-004).
        rank = int(np.sum(oos_sharpe <= selected_oos_sharpe))
        omega = rank / (n_configs + 1)
        logits.append(float(np.log(omega / (1 - omega))))

    pbo = float(np.mean([lam <= 0 for lam in logits]))
    p_oos_negative = float(np.mean([s < 0 for s in oos_sharpes]))

    return CSCVResult(
        n_splits=len(logits),
        n_configs=n_configs,
        logits=logits,
        is_sharpes=is_sharpes,
        oos_sharpes=oos_sharpes,
        pbo=pbo,
        p_oos_sharpe_negative=p_oos_negative,
        oos_sharpes_pooled=oos_sharpes_pooled,
    )


def evaluate(
    result: CSCVResult,
    pbo_threshold: float = 0.05,
    p_oos_negative_threshold: float = 0.5,
) -> CSCVVerdict:
    """A pass/fail verdict from an *already-computed* `CSCVResult`. Never wire this
    verdict (or the PBO value it's based on) back into choosing a parameter grid,
    search, or config -- see the module docstring and CLAUDE.md."""
    if result.pbo > pbo_threshold:
        return CSCVVerdict(False, f"PBO {result.pbo:.2%} exceeds threshold {pbo_threshold:.2%}")
    if result.p_oos_sharpe_negative > p_oos_negative_threshold:
        return CSCVVerdict(
            False,
            f"P(OOS Sharpe < 0) {result.p_oos_sharpe_negative:.2%} exceeds threshold "
            f"{p_oos_negative_threshold:.2%}",
        )
    return CSCVVerdict(True, "PBO and P(OOS Sharpe < 0) within thresholds")
