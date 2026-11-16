"""Load the Gold analytical table for mining.

Two interchangeable sources:
  * "csv" (default): data/exports/ml_dataset.csv, built by src.ingest.pipeline
    (rebuilt automatically when missing)
  * "sql": the SQL Server view gold.vw_ml_dataset. Needs a connection string in
    AGRIPULSE_SQL_CONN or in a .env file (see src.db and .env.example), e.g.
        AGRIPULSE_SQL_CONN="Driver={ODBC Driver 18 for SQL Server};Server=localhost;Database=AgriPulse;Trusted_Connection=yes;TrustServerCertificate=yes"
"""

from __future__ import annotations

import numpy as np
import pandas as pd

from src import config as cfg
from src.ingest import pipeline
from src.db import get_engine

ML_CSV = cfg.GOLD_DIR / "ml_dataset.csv"


def load_ml_dataset(source: str = "csv", rebuild: bool = False,
                    conn_str: str | None = None) -> pd.DataFrame:
    if source == "sql":
        df = pd.read_sql("SELECT * FROM gold.vw_ml_dataset", get_engine(conn_str))
        return df.sort_values(["country_name", "crop_name", "year"]).reset_index(drop=True)

    if rebuild or not ML_CSV.exists():
        pipeline.run()
    return pd.read_csv(ML_CSV, encoding="utf-8")


def compare_with_sql(conn_str: str | None = None, tol: float = 1e-6) -> pd.DataFrame:
    """Row-by-row comparison of the SQL Gold view with the pandas Gold table.

    Returns one row per column with the number of mismatching values; an
    all-zero result means the two implementations agree.
    """
    keys = ["country_name", "crop_name", "year"]
    sql = load_ml_dataset("sql", conn_str=conn_str)
    py = load_ml_dataset("csv")
    merged = py.merge(sql, on=keys, how="outer", suffixes=("_py", "_sql"), indicator=True)
    report = [{"column": "(rows only in one source)",
               "mismatches": int((merged["_merge"] != "both").sum())}]
    both = merged[merged["_merge"] == "both"]
    for col in py.columns.difference(keys):
        a, b = both[f"{col}_py"], both[f"{col}_sql"]
        if pd.api.types.is_numeric_dtype(a) and pd.api.types.is_numeric_dtype(b):
            a, b = a.astype(float), b.astype(float)
            bad = ~(np.isclose(a, b, atol=tol, rtol=1e-9) | (a.isna() & b.isna()))
        else:
            bad = a.astype(str) != b.astype(str)
        report.append({"column": col, "mismatches": int(bad.sum())})
    return pd.DataFrame(report)
