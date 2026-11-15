"""Mining helpers: time-ordered evaluation without leakage, rules, transactions."""

import numpy as np
import pandas as pd
import pytest

from agripulse import config as cfg
from agripulse import mining as mn
from agripulse import score


def test_split_is_time_ordered(ml):
    train, test = mn.split_train_test(ml)
    assert train.year.max() == cfg.TRAIN_END_YEAR < test.year.min()
    assert len(train) + len(test) == len(ml)


def test_forward_chaining_folds_never_train_on_the_future():
    years = pd.Series(np.repeat(np.arange(1990, cfg.TRAIN_END_YEAR + 1), 3))
    folds = list(mn.time_folds(years))
    assert len(folds) == 4  # validation blocks 2000-01, 2002-03, 2004-05, 2006-07
    for train_idx, val_idx in folds:
        assert years[train_idx].max() < years[val_idx].min()
        assert years[val_idx].nunique() == 2


def test_best_f1_threshold_is_on_the_grid():
    y = np.array([0, 0, 1, 1, 0, 1])
    p = np.array([0.1, 0.2, 0.8, 0.7, 0.3, 0.9])
    t = mn.best_f1_threshold(y, p)
    assert 0.02 <= t <= 0.98 and round(t, 2) == t
    assert mn.classification_metrics(y, p, t)["F1"] == 1.0


def test_tree_rules_partition_the_training_rows(ml):
    train, _ = mn.split_train_test(mn.prepare(ml))
    num, cat = mn.FEATURE_SETS["C. + last year's yield (full)"]
    tree = mn.make_models(num, cat)["Decision Tree"].fit(train[num + cat], train[mn.TARGET])
    rules = mn.tree_rules(tree, train[num + cat], train[mn.TARGET])
    assert rules.n_rows.sum() == len(train)
    assert rules.support.sum() == pytest.approx(1.0)
    assert rules.rule.str.startswith("IF ").all()


def test_transactions_have_one_item_per_attribute(ml):
    items = mn.transactions(ml)
    assert len(items) == len(ml)
    groups = ["temp=", "rain=", "climate=", "pesticide=", "pesticide_change=", "last_year=",
              "crop_group=", "region="]
    for g in groups:
        cols = [c for c in items.columns if c.startswith(g)]
        assert (items[cols].sum(axis=1) == 1).all(), g
    assert (items[["SHOCK", "NO_SHOCK"]].sum(axis=1) == 1).all()


@pytest.mark.slow
def test_scoring_reproduces_the_reported_model_and_is_complete():
    """agripulse.score on the Gold CSVs: same Bagging metrics as notebook 02, one prediction per test row."""
    runs, preds = score.score(score.load_features_csv())
    report = pd.read_csv(cfg.PROJECT_ROOT / "reports" / "tables" / "classification_results.csv")
    row = report[(report.model == "Bagging") & report.feature_set.str.startswith("C.")].iloc[0]
    bagging = runs.set_index("model_name").loc[score.IMPROVED_MODEL]
    assert bagging.threshold == row["threshold"]
    assert bagging.test_roc_auc == pytest.approx(row["Test ROC-AUC"], abs=1e-12)
    assert bagging.cv_roc_auc == pytest.approx(row["CV ROC-AUC"], abs=1e-12)

    n_test = int((pd.read_csv(cfg.GOLD_DIR / "fact_crop_year.csv").year_key > cfg.TRAIN_END_YEAR).sum())
    assert set(runs.model_role) == {"baseline", "improved"}
    for name, p in preds.groupby("model_name"):
        assert len(p) == n_test, name
        assert not p.duplicated(score.KEYS).any(), name
        assert p.shock_probability.between(0, 1).all(), name
        threshold = runs.set_index("model_name").loc[name, "threshold"]
        assert (p.predicted_shock == (p.shock_probability >= threshold)).all(), name
    assert preds.run_id.nunique() == 1 and preds.model_version.notna().all()
