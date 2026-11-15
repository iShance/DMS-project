"""Score crop-years for shock risk and write the results back to SQL Server.

SQL -> Python -> SQL:
  1. read the documented feature view gold.features_shock
  2. fit the baseline and the improved model with the protocol of
     agripulse.mining (train 1990-2007 with forward-chaining CV, threshold from
     the CV predictions, test 2008-2013), using the full feature set C
  3. write one row per model to ml.model_run and the test-year predictions to
     ml.shock_prediction, all tagged with model_name, model_version, run_id
     and generated_at

The improved model is the one with the best CV ROC-AUC in notebook 02
(Bagging), so its test metrics equal that row of
reports/tables/classification_results.csv.

Run from the project root (with src/ on PYTHONPATH):
    python -m agripulse.score              read SQL, write SQL (needs AGRIPULSE_SQL_CONN)
    python -m agripulse.score --dry-run    read the Gold CSV files, write nothing
"""

from __future__ import annotations

import argparse
import datetime as dt
import uuid

import pandas as pd

from agripulse import config as cfg
from agripulse import mining as mn

MODEL_VERSION = "1.0"
FEATURE_VIEW = "gold.features_shock"
FEATURE_SET = "C. + last year's yield (full)"
IMPROVED_MODEL = "Bagging"
BASELINE_MODEL = "Last-year label rule"
KEYS = ["country_key", "crop_key", "year_key"]
SORT = ["country_name", "crop_name", "year"]  # same row order as ml_dataset -> same bootstrap samples


def load_features(engine) -> pd.DataFrame:
    """The feature view from SQL Server."""
    df = pd.read_sql(f"SELECT * FROM {FEATURE_VIEW}", engine)
    return df.sort_values(SORT).reset_index(drop=True)


def load_features_csv() -> pd.DataFrame:
    """The same columns as gold.features_shock, built from the Gold CSV files."""
    fact = pd.read_csv(cfg.GOLD_DIR / "fact_crop_year.csv")
    country = pd.read_csv(cfg.GOLD_DIR / "dim_country.csv")[["country_key", "country_name", "region"]]
    crop = pd.read_csv(cfg.GOLD_DIR / "dim_crop.csv")[["crop_key", "crop_name"]]
    df = fact.merge(country, on="country_key").merge(crop, on="crop_key")
    df["year"] = df.year_key
    cols = KEYS + ["country_name", "crop_name", "region", "year"] + \
        mn.CLIMATE + mn.CONTEXT + mn.HISTORY + [mn.TARGET]
    return df[cols].sort_values(SORT).reset_index(drop=True)


def _years(df: pd.DataFrame) -> str:
    return f"{df.year.min()}-{df.year.max()}"


def score(features: pd.DataFrame) -> tuple[pd.DataFrame, pd.DataFrame]:
    """Fit baseline + improved model; return (model_run rows, shock_prediction rows)."""
    df = mn.prepare(features)
    train, test = mn.split_train_test(df)
    num, cat = mn.FEATURE_SETS[FEATURE_SET]
    run_id = str(uuid.uuid4())
    generated_at = dt.datetime.now().replace(microsecond=0)

    result = mn.evaluate(mn.make_models(num, cat)[IMPROVED_MODEL], train, test, num + cat)
    baseline_proba = test.prev_is_shock.fillna(0).to_numpy()  # "a shock follows a shock"
    models = [
        {"model_name": BASELINE_MODEL, "model_role": "baseline", "features": "prev_is_shock",
         "proba": baseline_proba, "threshold": 0.5, "cv_roc_auc": None,
         "test": mn.classification_metrics(test[mn.TARGET], baseline_proba, 0.5)},
        {"model_name": IMPROVED_MODEL, "model_role": "improved", "features": ", ".join(num + cat),
         "proba": result["test_proba"], "threshold": result["threshold"],
         "cv_roc_auc": result["cv"]["ROC-AUC"], "test": result["test"]},
    ]

    runs, preds = [], []
    for m in models:
        runs.append({
            "run_id": run_id, "model_name": m["model_name"], "model_version": MODEL_VERSION,
            "model_role": m["model_role"], "feature_view": FEATURE_VIEW, "features": m["features"],
            "train_years": _years(train), "test_years": _years(test), "threshold": m["threshold"],
            "cv_roc_auc": m["cv_roc_auc"], "test_roc_auc": m["test"]["ROC-AUC"],
            "test_pr_auc": m["test"]["PR-AUC"], "test_precision": m["test"]["Precision"],
            "test_recall": m["test"]["Recall"], "test_f1": m["test"]["F1"],
            "generated_at": generated_at,
        })
        p = test[KEYS].copy()
        p.insert(0, "model_version", MODEL_VERSION)
        p.insert(0, "model_name", m["model_name"])
        p.insert(0, "run_id", run_id)
        p["shock_probability"] = m["proba"]
        p["predicted_shock"] = (m["proba"] >= m["threshold"]).astype(int)
        p["generated_at"] = generated_at
        preds.append(p)
    return pd.DataFrame(runs), pd.concat(preds, ignore_index=True)


def write(engine, runs: pd.DataFrame, predictions: pd.DataFrame) -> None:
    """Append one run to ml.model_run and ml.shock_prediction in a single transaction."""
    with engine.begin() as con:
        runs.to_sql("model_run", con, schema="ml", if_exists="append", index=False)
        predictions.to_sql("shock_prediction", con, schema="ml", if_exists="append",
                           index=False, chunksize=1000)


def main() -> int:
    parser = argparse.ArgumentParser(description="Score crop-years and write predictions to ml.*")
    parser.add_argument("--dry-run", action="store_true",
                        help="read the Gold CSV files instead of SQL and write nothing")
    args = parser.parse_args()

    if args.dry_run:
        engine, features = None, load_features_csv()
        print(f"read {len(features):,} rows from datasets/gold/ (dry run)")
    else:
        from agripulse.db import get_engine

        engine = get_engine()
        features = load_features(engine)
        print(f"read {len(features):,} rows from {FEATURE_VIEW}")

    runs, predictions = score(features)
    cols = ["model_name", "model_role", "threshold", "cv_roc_auc", "test_roc_auc", "test_pr_auc",
            "test_precision", "test_recall", "test_f1"]
    with pd.option_context("display.float_format", "{:.3f}".format, "display.width", 140):
        print(runs[cols].to_string(index=False))

    if engine is not None:
        write(engine, runs, predictions)
        print(f"wrote {len(runs)} model runs and {len(predictions):,} predictions "
              f"to ml.* (run_id {runs.run_id.iloc[0]})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
