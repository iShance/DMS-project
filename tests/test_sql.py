"""SQL Server warehouse tests (skipped unless AGRIPULSE_SQL_CONN is set).

Expected state: the warehouse built with sql/run_all.sql, then
    python -m agripulse.semantic
    python -m agripulse.score
"""

import re

import pandas as pd
import pytest

from agripulse import config as cfg
from agripulse import data, semantic

pytestmark = pytest.mark.sql

CHECKS_FILE = cfg.PROJECT_ROOT / "sql" / "07_quality_checks.sql"


def _quality_checks():
    """(name, query) for every '-- check: name' block in 07_quality_checks.sql."""
    text = CHECKS_FILE.read_text(encoding="utf-8")
    checks = []
    for block in re.split(r"^-- check:\s*", text, flags=re.M)[1:]:
        name, _, rest = block.partition("\n")
        statement = rest[: rest.index(";")]
        query = "\n".join(line for line in statement.splitlines() if not line.lstrip().startswith("--"))
        checks.append((name.strip(), query.strip()))
    return checks


def test_quality_checks_file_has_checks():
    assert len(_quality_checks()) >= 10


@pytest.mark.parametrize("name,query", _quality_checks(), ids=[n for n, _ in _quality_checks()])
def test_quality_check_returns_no_rows(engine, name, query):
    with engine.connect() as con:
        rows = con.exec_driver_sql(query).fetchall()
    assert rows == [], f"{name}: {len(rows)} bad rows, e.g. {rows[:3]}"


def test_sql_gold_matches_pandas_gold(engine):
    report = data.compare_with_sql()
    assert report.mismatches.sum() == 0, report[report.mismatches > 0]


def test_sql_reject_log_matches_pandas(engine, layers):
    cols = ["source_table", "business_key", "column_name", "raw_value", "reason"]

    def counts(df):
        return df[cols].astype(object).where(df[cols].notna(), "<NULL>").astype(str).value_counts()

    sql = pd.read_sql(f"SELECT {', '.join(cols)} FROM silver.reject_log", engine)
    py = layers["silver"]["reject_log"]
    both = pd.concat([counts(py).rename("py"), counts(sql).rename("sql")], axis=1).fillna(0)
    assert (both.py == both.sql).all(), both[both.py != both.sql].head()


def test_audit_log_row_counts_match_the_tables(engine):
    latest = pd.read_sql("""
        SELECT target_table, rows_loaded
        FROM (SELECT target_table, rows_loaded,
                     ROW_NUMBER() OVER (PARTITION BY target_table ORDER BY load_id DESC) AS rn
              FROM audit.load_log WHERE status = 'SUCCESS') l
        WHERE rn = 1""", engine)
    assert len(latest) == 17  # 6 Bronze + 6 Silver + 5 Gold tables
    with engine.connect() as con:
        for t in latest.itertuples():
            actual = con.exec_driver_sql(f"SELECT COUNT(*) FROM {t.target_table}").scalar()
            assert actual == t.rows_loaded, t.target_table


def test_semantic_metrics_validate(engine):
    semantic.sync_metrics(engine)
    report = semantic.validate_metrics(engine)
    assert (report.status == "PASS").all(), report[report.status != "PASS"]
    catalog = pd.read_sql("SELECT metric_name, validation_status FROM semantic.metric_catalog", engine)
    assert set(catalog.metric_name) == {m["name"] for m in semantic.load_metrics()}


def test_semantic_views_match_pandas(engine, ml):
    by_crop = pd.read_sql("SELECT * FROM semantic.v_shock_rate_by_crop_region", engine)
    expected = ml.groupby(["region", "crop_name"]).is_shock.agg(["size", "sum", "mean"]).reset_index()
    got = expected.merge(by_crop, on=["region", "crop_name"], validate="one_to_one")
    assert len(got) == len(by_crop) == len(expected)
    assert (got["size"] == got.crop_years).all() and (got["sum"] == got.shocks).all()
    pd.testing.assert_series_equal(got["mean"] * 100, got.shock_rate_pct, check_names=False)

    by_year = pd.read_sql("SELECT * FROM semantic.v_shock_rate_by_year ORDER BY year", engine)
    expected = ml.groupby("year").is_shock.mean().mul(100).reset_index(drop=True)
    pd.testing.assert_series_equal(expected, by_year.shock_rate_pct, check_names=False)

    # pesticide-use levels use the same tercile cut points as the association rules
    by_climate = pd.read_sql("SELECT * FROM semantic.v_shock_rate_by_climate", engine)
    q1, q2 = ml.pesticide_intensity.quantile([1 / 3, 2 / 3])
    level = pd.cut(ml.pesticide_intensity, [-float("inf"), q1, q2, float("inf")],
                   labels=["low", "medium", "high"], right=False).astype(str)
    expected = ml.assign(pesticide_use=level).groupby(["climate_band", "pesticide_use"]).size()
    got = by_climate.set_index(["climate_band", "pesticide_use"]).crop_years
    pd.testing.assert_series_equal(expected.sort_index(), got.sort_index(), check_names=False)


def _latest_run(engine):
    runs = pd.read_sql("SELECT * FROM ml.model_run", engine)
    if runs.empty:
        pytest.fail("ml.model_run is empty: run  python -m agripulse.score  first")
    return runs[runs.generated_at == runs.generated_at.max()]


def test_ml_outputs_are_complete(engine):
    runs = _latest_run(engine)
    assert set(runs.model_role) == {"baseline", "improved"}
    n_test = pd.read_sql(
        f"SELECT COUNT(*) AS n FROM gold.fact_crop_year WHERE year_key > {cfg.TRAIN_END_YEAR}", engine).n[0]
    for run in runs.itertuples():
        preds = pd.read_sql(
            "SELECT p.*, f.year_key AS fact_year FROM ml.shock_prediction p "
            "LEFT JOIN gold.fact_crop_year f ON f.country_key = p.country_key "
            "AND f.crop_key = p.crop_key AND f.year_key = p.year_key "
            f"WHERE p.run_id = '{run.run_id}' AND p.model_name = '{run.model_name}'", engine)
        assert len(preds) == n_test, run.model_name                    # one row per test crop-year
        assert preds.fact_year.notna().all(), run.model_name            # keys exist in Gold
        assert preds.shock_probability.between(0, 1).all(), run.model_name
        assert (preds.predicted_shock == (preds.shock_probability >= run.threshold)).all()
        assert preds[["model_version", "generated_at"]].notna().all().all()


def test_ml_outputs_reproduce_the_reported_results(engine):
    runs = _latest_run(engine).set_index("model_name")
    report = pd.read_csv(cfg.PROJECT_ROOT / "reports" / "tables" / "classification_results.csv")
    row = report[(report.model == "Bagging") & report.feature_set.str.startswith("C.")].iloc[0]
    assert runs.loc["Bagging", "test_roc_auc"] == pytest.approx(row["Test ROC-AUC"], abs=1e-12)

    # the SQL view recomputes detection from the stored predictions
    view = pd.read_sql("SELECT * FROM semantic.v_shock_detection WHERE is_latest_run = 1",
                       engine).set_index("model_name")
    for name, run in runs.iterrows():
        assert view.loc[name, "detection_rate_pct"] == pytest.approx(100 * run.test_recall)
        assert view.loc[name, "precision_pct"] == pytest.approx(100 * run.test_precision)
