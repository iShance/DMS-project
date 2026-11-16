"""Run every "-- check:" block in src/quality/checks.sql and report PASS (0 rows) or FAIL.

Run from the project root (needs AGRIPULSE_SQL_CONN, see .env.example):
    python -m src.quality.run_checks
Exits with code 1 if any check returns rows.
"""

from __future__ import annotations

import re
from pathlib import Path

CHECKS_FILE = Path(__file__).with_name("checks.sql")


def load_checks(path: Path = CHECKS_FILE) -> list[tuple[str, str]]:
    """(name, query) for every '-- check: name' block; a check is one statement ending in ';'."""
    text = Path(path).read_text(encoding="utf-8")
    checks = []
    for block in re.split(r"^-- check:\s*", text, flags=re.M)[1:]:
        name, _, rest = block.partition("\n")
        statement = rest[: rest.index(";")]
        query = "\n".join(line for line in statement.splitlines() if not line.lstrip().startswith("--"))
        checks.append((name.strip(), query.strip()))
    return checks


def run_checks(engine) -> list[tuple[str, int]]:
    """(name, number of bad rows) for every check."""
    with engine.connect() as con:
        return [(name, len(con.exec_driver_sql(query).fetchall())) for name, query in load_checks()]


def main() -> int:
    from src.db import get_engine

    results = run_checks(get_engine())
    for name, bad in results:
        print("PASS" if bad == 0 else "FAIL", name, "" if bad == 0 else f"({bad} bad rows)")
    failed = sum(bad > 0 for _, bad in results)
    print(f"{len(results) - failed}/{len(results)} checks passed")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
