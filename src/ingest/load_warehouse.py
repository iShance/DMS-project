"""Load the warehouse from Python: Bronze, then Silver, then Gold.

Runs the three load procedures created by sql/01_bronze.sql, 02_silver.sql and
03_gold.sql (run those scripts, or sql/run_all.sql, first), then prints this
run's rows from audit.load_log.

BULK INSERT runs on the SQL Server machine, so --data-path must be the
project's data folder as THAT machine sees it, and the SQL Server service
account must be able to read it (e.g. C:\\AgriPulse\\data, not a folder
under your user profile or OneDrive).

Run from the project root (needs AGRIPULSE_SQL_CONN, see .env.example):
    python -m src.ingest.load_warehouse --data-path C:\\AgriPulse\\data
"""

from __future__ import annotations

import argparse

import pandas as pd

from src import config as cfg


def load_warehouse(engine, data_path: str) -> pd.DataFrame:
    """EXEC the three load procedures; return this run's audit rows."""
    from sqlalchemy import text

    with engine.connect() as con:
        before = con.execute(text("SELECT ISNULL(MAX(load_id), 0) FROM audit.load_log")).scalar()
    for statement, params in [("EXEC bronze.load_bronze @data_path = :p", {"p": data_path}),
                              ("EXEC silver.load_silver", {}),
                              ("EXEC gold.load_gold", {})]:
        with engine.begin() as con:
            con.execute(text(statement), params)
    return pd.read_sql(text(
        "SELECT procedure_name, target_table, rows_loaded, rows_rejected, status "
        "FROM audit.load_log WHERE load_id > :before ORDER BY load_id"), engine, params={"before": before})


def main() -> int:
    parser = argparse.ArgumentParser(description="EXEC bronze/silver/gold load procedures")
    parser.add_argument("--data-path", default=str(cfg.DATA_DIR),
                        help="data folder as seen by the SQL Server service (default: this project's data/)")
    args = parser.parse_args()

    from src.db import get_engine

    log = load_warehouse(get_engine(), args.data_path)
    print(log.to_string(index=False))
    failed = int((log.status != "SUCCESS").sum())
    print("warehouse loaded" if not failed else f"{failed} table load(s) FAILED")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
