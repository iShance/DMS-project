"""Build the AgriPulse warehouse on SQL Server for Linux (GitHub Codespaces, Docker).

Runs automatically when the codespace starts (.devcontainer/devcontainer.json).
SQL Server on Linux has no BULK INSERT CODEPAGE option, so this script
  1. converts the CSV files to UTF-16, which BULK INSERT reads natively,
     into .codespace/data (git-ignored; the SQL Server container sees it too)
  2. runs sql/00-07 in order; for 01_bronze.sql it swaps the CODEPAGE option
     for DATAFILETYPE = 'widechar' in memory (the files in sql/ are not changed)
  3. loads Bronze, Silver and Gold and runs the 13 data-quality checks

Run it again at any time to rebuild the database:
    python setup/build_on_linux.py
"""

from __future__ import annotations

import os
import pathlib
import re
import sys
import time

import pymssql

ROOT = pathlib.Path(__file__).resolve().parents[1]
SERVER = os.environ.get("AGRIPULSE_SQL_SERVER", "localhost")
PORT = int(os.environ.get("AGRIPULSE_SQL_PORT", "1433"))
USER = os.environ.get("AGRIPULSE_SQL_USER", "sa")
PASSWORD = os.environ.get("AGRIPULSE_SQL_PASSWORD", "AgriPulse!2026")
LOCAL_DATA = ROOT / ".codespace" / "data"
# the same folder as the SQL Server container sees it (see .devcontainer/docker-compose.yml)
SERVER_DATA = os.environ.get("AGRIPULSE_SERVER_DATA", "/agripulse/.codespace/data")
STATUS_FILE = ROOT / ".codespace" / "STATUS.txt"

SCRIPTS = ["00_init.sql", "01_bronze.sql", "02_silver.sql", "03_gold.sql",
           "04_semantic.sql", "05_feature_views.sql", "07_ml_outputs.sql"]
GO = re.compile(r"(?im)^[ \t]*GO[ \t]*;?[ \t]*\r?$")


def connect(database: str = "master"):
    return pymssql.connect(server=SERVER, port=PORT, user=USER, password=PASSWORD,
                           database=database, autocommit=True, login_timeout=5)


def wait_for_server(timeout: int = 240) -> None:
    start = time.time()
    while True:
        try:
            connect().close()
            return
        except Exception as exc:  # SQL Server needs 10-30 s to start
            if time.time() - start > timeout:
                sys.exit(f"SQL Server did not start within {timeout} s: {exc}")
            time.sleep(3)


def convert_data() -> int:
    """UTF-8 CSV -> UTF-16LE with a byte-order mark and LF line ends."""
    count = 0
    for sub in ("raw", "reference"):
        target = LOCAL_DATA / sub
        target.mkdir(parents=True, exist_ok=True)
        os.chmod(target, 0o755)
        for src in sorted((ROOT / "data" / sub).glob("*.csv")):
            text = src.read_text(encoding="utf-8").replace("\r\n", "\n")
            out = target / src.name
            out.write_bytes(b"\xff\xfe" + text.encode("utf-16-le"))
            os.chmod(out, 0o644)
            count += 1
    for folder in (LOCAL_DATA.parent, LOCAL_DATA):
        os.chmod(folder, 0o755)
    return count


def linux_bronze(sql: str) -> str:
    codepage = "CODEPAGE        = ''65001'',"
    rowterm = "ROWTERMINATOR   = ''0x0a'',"
    if codepage not in sql or rowterm not in sql:
        sys.exit("01_bronze.sql changed: update linux_bronze() in setup/build_on_linux.py")
    return (sql.replace(codepage, "DATAFILETYPE    = ''widechar'',")
               .replace(rowterm, "ROWTERMINATOR   = ''\\n'',"))


def run_script(name: str) -> None:
    sql = (ROOT / "sql" / name).read_text(encoding="utf-8")
    if name == "01_bronze.sql":
        sql = linux_bronze(sql)
    con = connect()
    try:
        cur = con.cursor()
        for batch in GO.split(sql):
            if batch.strip():
                cur.execute(batch)
    finally:
        con.close()


def quality_checks() -> list[tuple[str, int]]:
    text = (ROOT / "src" / "quality" / "checks.sql").read_text(encoding="utf-8")
    results = []
    con = connect("AgriPulse")
    try:
        cur = con.cursor()
        for block in re.split(r"(?m)^-- check:[ \t]*", text)[1:]:
            nl = block.index("\n")
            name, rest = block[:nl].strip(), block[nl + 1:]
            statement = rest[: rest.index(";")]
            query = "\n".join(l for l in statement.split("\n") if not l.lstrip().startswith("--"))
            cur.execute(query)
            results.append((name, len(cur.fetchall())))
    finally:
        con.close()
    return results


def main() -> int:
    lines = []

    def say(msg: str) -> None:
        print(msg, flush=True)
        lines.append(msg)

    say("AgriPulse: building the warehouse on SQL Server (Linux)")
    wait_for_server()
    say("  OK  SQL Server is running")
    say(f"  OK  {convert_data()} data files prepared in .codespace/data")
    for name in SCRIPTS:
        run_script(name)
        say(f"  OK  ran sql/{name}")
    con = connect("AgriPulse")
    try:
        cur = con.cursor()
        cur.execute("EXEC bronze.load_bronze @data_path = %s", (SERVER_DATA,))
        cur.execute("EXEC silver.load_silver")
        cur.execute("EXEC gold.load_gold")
        cur.execute("""
            SELECT (SELECT COUNT(*) FROM bronze.fao_yield) + (SELECT COUNT(*) FROM bronze.wb_rainfall)
                 + (SELECT COUNT(*) FROM bronze.wb_temperature) + (SELECT COUNT(*) FROM bronze.fao_pesticides)
                 + (SELECT COUNT(*) FROM bronze.ref_country) + (SELECT COUNT(*) FROM bronze.ref_country_alias),
                   (SELECT COUNT(*) FROM silver.reject_log),
                   (SELECT COUNT(*) FROM gold.fact_crop_year),
                   (SELECT SUM(CAST(is_shock AS INT)) FROM gold.fact_crop_year)""")
        bronze, rejected, gold, shocks = cur.fetchone()
    finally:
        con.close()
    say(f"  OK  Bronze {bronze:,} rows | Silver reject_log {rejected:,} rows | Gold {gold:,} rows, {shocks:,} shocks")
    checks = quality_checks()
    passed = sum(bad == 0 for _, bad in checks)
    for name, bad in checks:
        say(f"  {'PASS' if bad == 0 else 'FAIL'}  {name}" + ("" if bad == 0 else f" ({bad} bad rows)"))
    say(f"  {passed}/{len(checks)} quality checks passed")
    say("READY: open the SQL Server panel on the left, connection 'AgriPulse (Codespace)'.")
    STATUS_FILE.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return 0 if passed == len(checks) else 1


if __name__ == "__main__":
    raise SystemExit(main())
