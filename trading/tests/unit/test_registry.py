from __future__ import annotations

from datetime import date
from pathlib import Path

import pandas as pd
import pytest

from intraday_trading.validation.registry import TrialRegistry


def _pnl_series(start: date, values: list[float]) -> pd.Series:
    dates = pd.date_range(start=start, periods=len(values), freq="D")
    return pd.Series(values, index=dates)


def test_log_and_get_trial_round_trips(tmp_path: Path) -> None:
    registry = TrialRegistry(tmp_path / "trials.db")
    trial_id = registry.log_trial(
        strategy="orb",
        params={"atr_stop_fraction": 0.1, "top_n": 20},
        daily_pnl=_pnl_series(date(2024, 1, 2), [10.0, -5.0, 3.0]),
    )

    trials = registry.get_trials("orb")
    assert len(trials) == 1
    assert trials[0].trial_id == trial_id
    assert trials[0].params == {"atr_stop_fraction": 0.1, "top_n": 20}
    assert trials[0].status == "active"
    assert trials[0].search_type == "grid"


def test_log_trial_rejects_unknown_search_type(tmp_path: Path) -> None:
    registry = TrialRegistry(tmp_path / "trials.db")
    with pytest.raises(ValueError, match="search_type"):
        registry.log_trial(
            "orb", {"x": 1}, _pnl_series(date(2024, 1, 2), [1.0]), search_type="bogus"
        )


def test_VAL_009_optimizer_search_type_logs_only_the_converged_result(tmp_path: Path) -> None:
    registry = TrialRegistry(tmp_path / "trials.db")
    # Simulating a caller doing the right thing: only the search's final, converged
    # config gets logged -- TrialRegistry doesn't run the optimiser, it just needs to
    # accept and correctly tag this case distinctly from a grid point.
    trial_id = registry.log_trial(
        "spy_momentum",
        {"band_multiplier": 1.37},
        _pnl_series(date(2024, 1, 2), [5.0, 5.0]),
        search_type="optimizer",
    )
    trials = registry.get_trials("spy_momentum")
    assert len(trials) == 1
    assert trials[0].trial_id == trial_id
    assert trials[0].search_type == "optimizer"


def test_VAL_006_retiring_a_trial_marks_it_not_deletes_it(tmp_path: Path) -> None:
    registry = TrialRegistry(tmp_path / "trials.db")
    trial_id = registry.log_trial("orb", {"x": 1}, _pnl_series(date(2024, 1, 2), [1.0]))

    registry.retire_trial(trial_id, reason="superseded by a corrected stop formula")

    trials = registry.get_trials("orb", include_retired=True)
    assert len(trials) == 1
    assert trials[0].status == "retired"
    assert trials[0].retired_reason == "superseded by a corrected stop formula"

    active_only = registry.get_trials("orb", include_retired=False)
    assert active_only == []


def test_VAL_007_trial_count_includes_retired_trials_by_default(tmp_path: Path) -> None:
    registry = TrialRegistry(tmp_path / "trials.db")
    keep_id = registry.log_trial("orb", {"x": 1}, _pnl_series(date(2024, 1, 2), [1.0]))
    retired_id = registry.log_trial("orb", {"x": 2}, _pnl_series(date(2024, 1, 2), [1.0]))
    registry.retire_trial(retired_id, reason="bad grid point")

    assert registry.trial_count("orb") == 2
    assert registry.trial_count("orb", include_retired=False) == 1
    assert keep_id != retired_id


def test_daily_pnl_matrix_has_dates_as_rows_and_trials_as_columns(tmp_path: Path) -> None:
    registry = TrialRegistry(tmp_path / "trials.db")
    id_a = registry.log_trial("orb", {"x": 1}, _pnl_series(date(2024, 1, 2), [10.0, 20.0]))
    id_b = registry.log_trial("orb", {"x": 2}, _pnl_series(date(2024, 1, 2), [-5.0, 15.0]))

    matrix = registry.daily_pnl_matrix("orb")

    assert set(matrix.columns) == {id_a, id_b}
    assert matrix.loc["2024-01-02", id_a] == 10.0
    assert matrix.loc["2024-01-03", id_b] == 15.0


def test_daily_pnl_matrix_filters_by_trial_ids(tmp_path: Path) -> None:
    registry = TrialRegistry(tmp_path / "trials.db")
    id_a = registry.log_trial("orb", {"x": 1}, _pnl_series(date(2024, 1, 2), [10.0]))
    registry.log_trial("orb", {"x": 2}, _pnl_series(date(2024, 1, 2), [20.0]))

    matrix = registry.daily_pnl_matrix("orb", trial_ids=[id_a])

    assert list(matrix.columns) == [id_a]


def test_daily_pnl_matrix_empty_for_unknown_strategy(tmp_path: Path) -> None:
    registry = TrialRegistry(tmp_path / "trials.db")
    assert registry.daily_pnl_matrix("unknown_strategy").empty


def test_VAL_015_retired_trials_leave_the_matrix_but_still_count(tmp_path: Path) -> None:
    registry = TrialRegistry(tmp_path / "trials.db")
    keep_id = registry.log_trial("orb", {"x": 1}, _pnl_series(date(2024, 1, 2), [1.0]))
    retired_id = registry.log_trial("orb", {"x": 2}, _pnl_series(date(2024, 1, 2), [2.0]))
    registry.retire_trial(retired_id, reason="sizing bug -- never traded")

    assert list(registry.daily_pnl_matrix("orb").columns) == [keep_id]
    assert set(registry.daily_pnl_matrix("orb", include_retired=True).columns) == {
        keep_id,
        retired_id,
    }
    assert registry.trial_count("orb") == 2  # DSR still sees both attempts


def test_VAL_015_retire_all_marks_every_active_trial(tmp_path: Path) -> None:
    registry = TrialRegistry(tmp_path / "trials.db")
    for x in range(3):
        registry.log_trial("orb", {"x": x}, _pnl_series(date(2024, 1, 2), [1.0]))
    registry.log_trial("other", {"x": 0}, _pnl_series(date(2024, 1, 2), [1.0]))

    assert registry.retire_all("orb", reason="bad run") == 3
    assert registry.retire_all("orb", reason="again") == 0  # already retired

    assert registry.get_trials("orb", include_retired=False) == []
    assert registry.trial_count("orb") == 3  # nothing deleted
    assert {t.retired_reason for t in registry.get_trials("orb")} == {"bad run"}
    assert len(registry.get_trials("other", include_retired=False)) == 1
