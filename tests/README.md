# Tests

Run `pytest` from the project root.

| file | what it checks | needs |
|---|---|---|
| `test_metrics_yaml.py` | every metric in `semantic/metrics.yml` has all required keys | nothing |
| `test_pipeline.py` | pandas Bronze/Silver/Gold: reproduces `data/exports/`, provenance, Bronze = kept + rejected rows, unique keys, referential integrity, accepted ranges, label, no look-ahead in the baseline | nothing |
| `test_mining.py` | time-ordered split and CV folds, thresholds, rules, transactions; the scoring model reproduces the reported results (`slow`) | nothing |
| `test_sql.py` | every check in `src/quality/checks.sql`, SQL Gold = pandas Gold, SQL reject log = pandas reject log, audit row counts, metric validation, metric views, ML output completeness | SQL Server (`AGRIPULSE_SQL_CONN`) |

`test_sql.py` is skipped when no connection is configured. With a connection, build the warehouse
first (`build_database.bat` or `sql/run_all.sql`), then run `python -m src.semantic.sync_metrics` and
`python -m src.mining.score`.

Useful options: `pytest -m "not slow"` skips the model training test (about 30 s);
`pytest -m sql` runs only the database tests. The database checks also run on their own with
`python -m src.quality.run_checks`.
