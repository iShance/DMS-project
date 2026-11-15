"""Semantic layer: copy semantic/metrics.yml into SQL Server and validate every metric.

semantic/metrics.yml is the source of truth. For each metric this module
  1. writes its definition to semantic.metric_catalog, then
  2. computes the metric over Gold    (SELECT <sql> FROM gold.fact_crop_year f)
     and runs its independent validation_query; both must give the same number.
The two values and PASS/FAIL are stored back in the catalog.

Run from the project root (with src/ on PYTHONPATH):
    python -m agripulse.semantic            sync + validate (needs AGRIPULSE_SQL_CONN)
    python -m agripulse.semantic --check    check the YAML file only, no database
"""

from __future__ import annotations

import argparse
import math
from pathlib import Path

import pandas as pd
import yaml

from agripulse import config as cfg

METRICS_FILE = cfg.PROJECT_ROOT / "semantic" / "metrics.yml"
REQUIRED_KEYS = ("name", "label", "definition", "owner", "grain", "sql", "dimensions",
                 "null_policy", "validation_query")


def check_metrics(metrics: list[dict]) -> list[str]:
    """Problems in the metric definitions (an empty list means the file is valid)."""
    problems = []
    if not metrics:
        return ["metrics.yml defines no metrics"]
    names = [m.get("name") for m in metrics]
    for m in metrics:
        label = m.get("name", "<unnamed>")
        problems += [f"{label}: missing '{k}'" for k in REQUIRED_KEYS if not m.get(k)]
        if not isinstance(m.get("dimensions", []), list):
            problems.append(f"{label}: 'dimensions' must be a list")
        if m.get("validation_query") and not m["validation_query"].lstrip().upper().startswith("SELECT"):
            problems.append(f"{label}: validation_query must be a SELECT")
    problems += [f"duplicate metric name '{n}'" for n in sorted({n for n in names if names.count(n) > 1})]
    return problems


def load_metrics(path: Path = METRICS_FILE) -> list[dict]:
    metrics = yaml.safe_load(Path(path).read_text(encoding="utf-8"))["metrics"]
    problems = check_metrics(metrics)
    if problems:
        raise ValueError("Invalid metrics.yml:\n  " + "\n  ".join(problems))
    return metrics


def sync_metrics(engine, metrics: list[dict] | None = None) -> int:
    """Replace the contents of semantic.metric_catalog with the YAML definitions."""
    from sqlalchemy import text

    metrics = metrics or load_metrics()
    with engine.begin() as con:
        con.execute(text("DELETE FROM semantic.metric_catalog"))
        for m in metrics:
            con.execute(text(
                "INSERT INTO semantic.metric_catalog (metric_name, label, definition, owner, grain, "
                "sql_expression, dimensions, null_policy, validation_query) "
                "VALUES (:n, :l, :d, :o, :g, :s, :dim, :np, :v)"),
                {"n": m["name"], "l": m["label"], "d": m["definition"].strip(), "o": m["owner"],
                 "g": m["grain"], "s": m["sql"], "dim": ", ".join(m["dimensions"]),
                 "np": m["null_policy"].strip(), "v": m["validation_query"].strip()})
    return len(metrics)


def validate_metrics(engine, metrics: list[dict] | None = None,
                     rel_tol: float = 1e-9, abs_tol: float = 1e-9) -> pd.DataFrame:
    """Compute every metric two ways and record the result in semantic.metric_catalog."""
    from sqlalchemy import text

    metrics = metrics or load_metrics()
    rows = []
    with engine.begin() as con:
        for m in metrics:
            value = con.execute(text(f"SELECT {m['sql']} FROM gold.fact_crop_year f")).scalar()
            check = con.execute(text(m["validation_query"])).scalar()
            ok = (value is not None and check is not None
                  and math.isclose(float(value), float(check), rel_tol=rel_tol, abs_tol=abs_tol))
            status = "PASS" if ok else "FAIL"
            con.execute(text(
                "UPDATE semantic.metric_catalog SET metric_value = :v, validation_value = :c, "
                "validation_status = :s, validated_at = SYSDATETIME() WHERE metric_name = :n"),
                {"v": None if value is None else float(value),
                 "c": None if check is None else float(check), "s": status, "n": m["name"]})
            rows.append({"metric": m["name"], "value": value, "validation": check, "status": status})
    return pd.DataFrame(rows)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true", help="validate metrics.yml only (no database)")
    args = parser.parse_args()

    metrics = load_metrics()
    print(f"metrics.yml: {len(metrics)} metrics, all required keys present")
    if args.check:
        return 0

    from agripulse.db import get_engine

    engine = get_engine()
    print(f"synced {sync_metrics(engine, metrics)} metrics to semantic.metric_catalog")
    report = validate_metrics(engine, metrics)
    with pd.option_context("display.float_format", "{:,.6f}".format, "display.width", 120):
        print(report.to_string(index=False))
    failed = int((report.status != "PASS").sum())
    print("all metrics validated" if not failed else f"{failed} metric(s) FAILED validation")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
