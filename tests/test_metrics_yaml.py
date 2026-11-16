"""semantic/metrics.yml: every metric is fully defined (no database needed)."""

import yaml

from src.semantic import sync_metrics as semantic


def _metrics():
    return yaml.safe_load(semantic.METRICS_FILE.read_text(encoding="utf-8"))["metrics"]


def test_every_metric_has_all_required_keys():
    for m in _metrics():
        for key in semantic.REQUIRED_KEYS:
            assert m.get(key), f"metric {m.get('name')} is missing '{key}'"


def test_metrics_file_has_no_problems():
    assert semantic.check_metrics(_metrics()) == []


def test_metric_sql_is_an_expression_over_the_fact():
    # evaluated as SELECT <sql> FROM gold.fact_crop_year f, so it must not bring its own FROM
    for m in _metrics():
        assert "FROM" not in m["sql"].upper(), m["name"]


def test_check_metrics_reports_problems():
    broken = [{"name": "x", "sql": "COUNT(*)"}, {"name": "x"}]
    problems = semantic.check_metrics(broken)
    assert any("missing 'owner'" in p for p in problems)
    assert any("duplicate metric name 'x'" in p for p in problems)
