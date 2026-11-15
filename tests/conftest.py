"""Shared fixtures. Run the whole suite from the project root with:  pytest"""

import pytest

from agripulse import pipeline


@pytest.fixture(scope="session")
def layers():
    """Bronze, Silver and Gold rebuilt in memory from the raw files (nothing written)."""
    return pipeline.run(write=False)


@pytest.fixture(scope="session")
def ml(layers):
    return layers["gold"]["ml_dataset"]


@pytest.fixture(scope="session")
def engine():
    """SQL Server engine; SQL tests are skipped when no connection is configured."""
    from agripulse.db import connection_string, get_engine

    if not connection_string():
        pytest.skip("no SQL Server connection: set AGRIPULSE_SQL_CONN (see .env.example)")
    eng = get_engine()
    try:
        with eng.connect() as con:
            con.exec_driver_sql("SELECT 1")
    except Exception as exc:  # configured but unreachable: fail loudly, do not hide it
        pytest.fail(f"AGRIPULSE_SQL_CONN is set but SQL Server is not reachable: {exc}")
    return eng
