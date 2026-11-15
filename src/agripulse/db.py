"""Connection to the AgriPulse SQL Server warehouse.

The connection string comes from the environment variable AGRIPULSE_SQL_CONN
(SQLSERVER_CONN, the name used by the course skeleton, also works). It can be
set in a .env file at the project root: copy .env.example to .env and edit it.

Two forms are accepted:
  * an ODBC connection string (normal case; needs pyodbc and the Microsoft
    ODBC Driver 18 for SQL Server), e.g.
        Driver={ODBC Driver 18 for SQL Server};Server=localhost;Database=AgriPulse;Trusted_Connection=yes;TrustServerCertificate=yes
  * a full SQLAlchemy URL, e.g.
        mssql+pymssql://user:password@localhost/AgriPulse
"""

from __future__ import annotations

import os
from urllib.parse import quote_plus

from agripulse import config as cfg

ENV_VARS = ("AGRIPULSE_SQL_CONN", "SQLSERVER_CONN")


def connection_string(conn_str: str | None = None) -> str | None:
    """The explicit argument, else the first environment variable that is set."""
    if conn_str:
        return conn_str
    try:
        from dotenv import load_dotenv  # optional: python-dotenv
        load_dotenv(cfg.PROJECT_ROOT / ".env")
    except ImportError:
        pass
    for name in ENV_VARS:
        if os.environ.get(name):
            return os.environ[name]
    return None


def get_engine(conn_str: str | None = None):
    """SQLAlchemy engine for the warehouse (raises if no connection is configured)."""
    from sqlalchemy import create_engine

    conn = connection_string(conn_str)
    if not conn:
        raise RuntimeError(
            "No SQL Server connection configured: set AGRIPULSE_SQL_CONN "
            "(copy .env.example to .env and edit it).")
    if "://" in conn:  # already a SQLAlchemy URL
        return create_engine(conn)
    return create_engine("mssql+pyodbc:///?odbc_connect=" + quote_plus(conn),
                         fast_executemany=True)
