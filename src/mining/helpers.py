"""Modeling helpers shared by the AgriPulse notebooks.

Evaluation protocol (no information from the future reaches a prediction):
  * train = 1990-TRAIN_END_YEAR, test = later years (time-ordered hold-out)
  * cross-validation on the training years is forward-chaining: each fold
    trains on all years before a two-year validation block
  * the decision threshold of every model is chosen on the pooled
    out-of-fold CV predictions (max F1), never on the test years
"""

from __future__ import annotations

import numpy as np
import pandas as pd
from sklearn.base import clone
from sklearn.compose import ColumnTransformer
from sklearn.ensemble import AdaBoostClassifier, BaggingClassifier
from sklearn.impute import SimpleImputer
from sklearn.metrics import (accuracy_score, average_precision_score, f1_score,
                             precision_score, recall_score, roc_auc_score)
from sklearn.naive_bayes import GaussianNB
from sklearn.neighbors import KNeighborsClassifier
from sklearn.pipeline import Pipeline, make_pipeline
from sklearn.preprocessing import OneHotEncoder, StandardScaler
from sklearn.tree import DecisionTreeClassifier, _tree

from src import config as cfg

TARGET = "is_shock"

# The three proposal features, then context and history added on top.
CLIMATE = ["rain_dev_pct", "temp_anomaly_c", "pesticide_intensity"]
CONTEXT = ["rainfall_mm"]
HISTORY = ["prev_yield_dev_pct", "prev_is_shock"]
CATEGORICAL = ["crop_name", "region"]

FEATURE_SETS = {
    "A. Climate only": (CLIMATE, []),
    "B. + crop, region, rainfall level": (CLIMATE + CONTEXT, CATEGORICAL),
    "C. + last year's yield (full)": (CLIMATE + CONTEXT + HISTORY, CATEGORICAL),
}


def prepare(df: pd.DataFrame) -> pd.DataFrame:
    out = df.copy()
    out["prev_is_shock"] = out["prev_is_shock"].astype(float)
    return out


def split_train_test(df: pd.DataFrame) -> tuple[pd.DataFrame, pd.DataFrame]:
    return df[df.year <= cfg.TRAIN_END_YEAR], df[df.year > cfg.TRAIN_END_YEAR]


def time_folds(years: pd.Series, first_val_year: int = 2000, block: int = 2):
    """Forward-chaining folds: (train_idx, val_idx) over two-year blocks."""
    last = years.max()
    for start in range(first_val_year, last + 1, block):
        train_idx = np.where(years < start)[0]
        val_idx = np.where((years >= start) & (years < start + block))[0]
        if len(val_idx):
            yield train_idx, val_idx


def preprocessor(numeric: list[str], categorical: list[str], scale: bool) -> ColumnTransformer:
    num_steps = [SimpleImputer(strategy="median")] + ([StandardScaler()] if scale else [])
    parts = [("num", make_pipeline(*num_steps), numeric)]
    if categorical:
        parts.append(("cat", OneHotEncoder(handle_unknown="ignore", sparse_output=False), categorical))
    return ColumnTransformer(parts, verbose_feature_names_out=False)


def make_models(numeric: list[str], categorical: list[str]) -> dict[str, Pipeline]:
    rs = cfg.RANDOM_STATE
    return {
        "Decision Tree": Pipeline([
            ("prep", preprocessor(numeric, categorical, scale=False)),
            ("model", DecisionTreeClassifier(max_depth=6, min_samples_leaf=40,
                                             class_weight="balanced", random_state=rs)),
        ]),
        "Naive Bayes": Pipeline([
            ("prep", preprocessor(numeric, categorical, scale=True)),
            ("model", GaussianNB()),
        ]),
        "k-NN": Pipeline([
            ("prep", preprocessor(numeric, categorical, scale=True)),
            ("model", KNeighborsClassifier(n_neighbors=50, weights="distance")),
        ]),
        "Bagging": Pipeline([
            ("prep", preprocessor(numeric, categorical, scale=False)),
            ("model", BaggingClassifier(
                DecisionTreeClassifier(min_samples_leaf=10, class_weight="balanced"),
                n_estimators=200, random_state=rs)),
        ]),
        "AdaBoost": Pipeline([
            ("prep", preprocessor(numeric, categorical, scale=False)),
            ("model", AdaBoostClassifier(DecisionTreeClassifier(max_depth=2),
                                         n_estimators=300, learning_rate=0.1, random_state=rs)),
        ]),
    }


def classification_metrics(y_true, proba, threshold: float) -> dict[str, float]:
    pred = (proba >= threshold).astype(int)
    return {
        "Accuracy": accuracy_score(y_true, pred),
        "Precision": precision_score(y_true, pred, zero_division=0),
        "Recall": recall_score(y_true, pred, zero_division=0),
        "F1": f1_score(y_true, pred, zero_division=0),
        "ROC-AUC": roc_auc_score(y_true, proba),
        "PR-AUC": average_precision_score(y_true, proba),
    }


def best_f1_threshold(y_true, proba) -> float:
    grid = np.round(np.arange(0.02, 0.99, 0.01), 2)
    scores = [f1_score(y_true, proba >= t, zero_division=0) for t in grid]
    return float(grid[int(np.argmax(scores))])


def evaluate(model: Pipeline, train: pd.DataFrame, test: pd.DataFrame,
             features: list[str]) -> dict:
    """Forward-chaining CV on train, threshold from OOF, then fit + score on test."""
    X, y, years = train[features], train[TARGET].to_numpy(), train.year.to_numpy()
    oof_idx, oof_proba, fold_rows = [], [], []
    for fold, (tr_idx, va_idx) in enumerate(time_folds(pd.Series(years)), start=1):
        m = clone(model).fit(X.iloc[tr_idx], y[tr_idx])
        p = m.predict_proba(X.iloc[va_idx])[:, 1]
        oof_idx.append(va_idx)
        oof_proba.append(p)
        fold_rows.append({"fold": fold, "val_years": f"{years[va_idx].min()}-{years[va_idx].max()}",
                          "ROC-AUC": roc_auc_score(y[va_idx], p),
                          "PR-AUC": average_precision_score(y[va_idx], p)})
    oof_idx = np.concatenate(oof_idx)
    oof_proba = np.concatenate(oof_proba)
    threshold = best_f1_threshold(y[oof_idx], oof_proba)
    cv = classification_metrics(y[oof_idx], oof_proba, threshold)

    fitted = clone(model).fit(X, y)
    test_proba = fitted.predict_proba(test[features])[:, 1]
    return {
        "model": fitted,
        "threshold": threshold,
        "cv": cv,
        "cv_folds": pd.DataFrame(fold_rows),
        "test": classification_metrics(test[TARGET].to_numpy(), test_proba, threshold),
        "test_proba": test_proba,
    }


def tree_rules(tree_pipeline: Pipeline, X: pd.DataFrame, y) -> pd.DataFrame:
    """Turn every leaf of a fitted tree pipeline into an IF-THEN rule.

    Leaf statistics come from the rows in X/y (normally the training data):
    support = share of rows that reach the leaf, shock_rate = share of those
    rows that are shocks, lift = shock_rate / overall shock rate.
    """
    prep, tree = tree_pipeline.named_steps["prep"], tree_pipeline.named_steps["model"]
    names = list(prep.get_feature_names_out())
    t = tree.tree_

    # path conditions per leaf, simplified to the tightest bound per feature
    paths: dict[int, dict[str, list]] = {}

    def walk(node: int, bounds: dict[str, list]):
        if t.feature[node] == _tree.TREE_UNDEFINED:
            paths[node] = bounds
            return
        f, thr = names[t.feature[node]], float(t.threshold[node])
        lo, hi = bounds.get(f, [-np.inf, np.inf])
        walk(t.children_left[node], {**bounds, f: [lo, min(hi, thr)]})
        walk(t.children_right[node], {**bounds, f: [max(lo, thr), hi]})

    walk(0, {})

    def describe(bounds: dict[str, list]) -> str:
        parts, cats = [], {}
        for f, (lo, hi) in bounds.items():
            cat = next((c for c in CATEGORICAL if f.startswith(c + "_")), None)
            if cat:  # one-hot column: > 0.5 means "is", <= 0.5 means "is not"
                level = f[len(cat) + 1:]
                cats.setdefault(cat, {"is": [], "not": []})["is" if lo >= 0.5 else "not"].append(level)
            elif f == "prev_is_shock":
                parts.append("prev_is_shock = 1" if lo >= 0.5 else "prev_is_shock = 0")
            elif np.isfinite(lo) and np.isfinite(hi):
                parts.append(f"{lo:.2f} < {f} <= {hi:.2f}")
            elif np.isfinite(hi):
                parts.append(f"{f} <= {hi:.2f}")
            else:
                parts.append(f"{f} > {lo:.2f}")
        for cat, d in cats.items():
            if d["is"]:
                parts.append(f"{cat} = {d['is'][0]}")
            else:
                parts.append(f"{cat} not in ({', '.join(d['not'])})")
        return " AND ".join(parts) if parts else "(all rows)"

    leaves = tree.apply(prep.transform(X))
    y = np.asarray(y)
    base_rate = y.mean()
    rows = []
    for leaf, bounds in paths.items():
        mask = leaves == leaf
        if not mask.any():
            continue
        rate = y[mask].mean()
        rows.append({
            "rule": "IF " + describe(bounds),
            "prediction": "SHOCK" if tree.classes_[np.argmax(t.value[leaf][0])] == 1 else "no shock",
            "n_rows": int(mask.sum()),
            "support": mask.mean(),
            "shock_rate": rate,
            "lift": rate / base_rate,
        })
    return pd.DataFrame(rows).sort_values("shock_rate", ascending=False).reset_index(drop=True)


# ---------------------------------------------------------------------------
# Association rules: discretised "shock recipes"
# ---------------------------------------------------------------------------

def _cut(series: pd.Series, edges: list[float], labels: list[str]) -> pd.Series:
    return pd.cut(series, bins=[-np.inf] + edges + [np.inf], labels=labels, right=False).astype(str)


def transactions(df: pd.DataFrame) -> pd.DataFrame:
    """One-hot item table for Apriori / FP-growth (one transaction per crop-year).

    Bins use fixed, interpretable cut points; pesticide intensity uses tertiles
    of the whole dataset (low / medium / high use).
    """
    items = pd.DataFrame(index=df.index)
    items["temp"] = "temp=" + _cut(df.temp_anomaly_c, [0.0, 0.5, 1.0],
                                   ["cooler", "near-normal", "warm(+0.5..1C)", "hot(>+1C)"])
    items["rain"] = "rain=" + _cut(df.rain_dev_pct, [-5.0, 5.0], ["dry(<-5%)", "normal", "wet(>+5%)"])
    items["aridity"] = "climate=" + df.rain_band.astype(str)
    terciles = df.pesticide_intensity.quantile([1 / 3, 2 / 3]).tolist()
    items["pest"] = "pesticide=" + _cut(df.pesticide_intensity, terciles, ["low", "medium", "high"])
    items["pest_change"] = "pesticide_change=" + _cut(
        df.pesticide_yoy_pct.fillna(0), [-20.0, 20.0], ["cut(<-20%)", "stable", "up(>+20%)"])
    prev = df.prev_is_shock.astype(float)
    items["history"] = "last_year=" + np.select([prev == 1, prev == 0], ["shock", "no-shock"], "unknown")
    items["crop"] = "crop_group=" + df.crop_group.astype(str)
    items["region"] = "region=" + df.region.astype(str)
    items["label"] = np.where(df.is_shock == 1, "SHOCK", "NO_SHOCK")
    return pd.get_dummies(items, prefix="", prefix_sep="").astype(bool)
