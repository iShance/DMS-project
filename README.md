# AgriPulse: Climate-Shock Early Detection Lakehouse for Global Crop Yields

> *AgriPulse: A Lakehouse-Driven Data Mining Framework for Early Detection of Climate-Induced Crop Yield
> Shocks*

Food-security planners usually see a harvest collapse only after it happens. AgriPulse asks whether a
**yield shock**, a sharp drop in a country's crop yield against its own recent baseline, can be
detected in advance from rainfall deviation, temperature anomaly and pesticide intensity. It also asks
which combinations of climate stress produce shocks and whether the patterns differ by crop and region.

It integrates four public sources into a **Bronze → Silver → Gold** warehouse (SQL Server) with a
semantic metric layer, mines the Gold dataset with EDA, OLAP, five classifiers, a regression baseline
and association rules, and writes the model's predictions back to SQL (`ml.*`).

```
Sources -> Bronze -> Silver -> Gold -> Semantic layer -> Mining / ML -> ml.* tables -> reports / BI
           (+ provenance) (+ reject log)  (star schema,     (metric catalog,   (SQL -> Python -> SQL)
                                          feature view)    metric views)
```

## Results at a glance

| | |
|---|---|
| Gold dataset | 16,339 crop-years · 119 countries · 10 crops · 1990-2013 · 10.2 % shocks |
| Climate features alone (test ROC-AUC) | 0.52-0.57: barely above chance |
| Full model, best by CV: Bagging (test 2008-2013) | ROC-AUC 0.764 · PR-AUC 0.338 · recall 0.44 · F1 0.377 |
| Strongest rule | last year's yield > 26.6 % below baseline AND low pesticide use → 60 % shocks (5.7x the base rate); 71 % in the test years |
| Strongest climate recipe | semi-arid climate AND low pesticide use → 20-22 % shocks (lift 2.0-2.2) |
| Key data issue | the Kaggle rainfall file is a static long-term average, so rainfall *deviation* is zero for 97.7 % of rows |

Full write-up: [`reports/findings.md`](reports/findings.md). Data issues:
[`docs/data_quality.md`](docs/data_quality.md).

## Data sources

All four files come from the Kaggle dataset
[Crop Yield Prediction Dataset](https://www.kaggle.com/datasets/patelris/crop-yield-prediction-dataset)
and are stored unchanged in `data/raw/`.

| file | content | original source | rows |
|---|---|---|---|
| `yield.csv` | crop yield (hg/ha) by country, crop, year 1961-2016 | [FAO](https://www.fao.org/home/en/) | 56,717 |
| `rainfall.csv` | average annual rainfall (mm) by country, 1985-2017 | [World Bank](https://data.worldbank.org/) | 6,727 |
| `temp.csv` | average temperature (°C) by country and year | World Bank (per the Kaggle page) | 71,311 |
| `pesticides.csv` | pesticide use (tonnes of active ingredients), 1990-2016 | [FAO](https://www.fao.org/home/en/) | 4,349 |

`data/reference/` holds two seed tables written for this project: the conformed country list with ISO3
codes and World Bank regions, and 41 country-name aliases that reconcile the four sources.

## Gold Layer evaluation checklist

What to have open on grading day, in the order of the instructor's list:

| required | open this |
|---|---|
| Sources links and datasets | `docs/data_source_register.csv` (links, owner, grain, keys), the data files in `data/raw/` and `data/reference/`, the "Data sources" section above |
| Idea, question | `docs/PROJECT_SPEC.md` (problem statement and business questions) |
| Bronze SQL script | `sql/01_bronze.sql` (+ `sql/00_init.sql`) |
| Bronze database | SSMS: `AgriPulse` → `bronze.*` tables (6 tables) |
| Bronze report | `docs/bronze_report.docx` |
| Silver SQL script | `sql/02_silver.sql` |
| Silver database | SSMS: `silver.*` tables, incl. `silver.reject_log` |
| Silver report | `docs/silver_report.docx` |
| Gold script | `sql/03_gold.sql` (+ `sql/05_feature_views.sql`) |
| Gold database | SSMS: `gold.*` star schema (4 dimensions + `fact_crop_year`) |
| Gold report | `docs/gold_report.docx` |

Build the database on the lab PC beforehand: `build_database.bat` (see "Option B" below), then run
`src/quality/checks.sql` in SSMS to show that every check returns no rows.

## Repository layout

The folders follow the course skeleton (`DM_DW_Project_Skeleton_SQLServer`).

```
data/
  raw/           the four source CSV files, unchanged (Bronze input)
  reference/     country reference + name aliases (seed tables written for the project)
  exports/       Gold layer exported by the pandas pipeline (fact, dimensions, ml_dataset.csv)
sql/
  00_init.sql            database + bronze/silver/gold/semantic/ml/audit schemas, audit.load_log
  01_bronze.sql          Bronze tables (provenance columns, load views) + bronze.load_bronze
  02_silver.sql          Silver tables + silver.reject_log + silver.load_silver
  03_gold.sql            star schema (4 dimensions + fact_crop_year) + gold.load_gold
  04_semantic.sql        semantic.metric_catalog + metric views
  05_feature_views.sql   gold.vw_ml_dataset, gold.features_shock
  06_analytics.sql       OLAP: ROLLUP, CUBE, PIVOT, slice, dice, drill-down
  07_ml_outputs.sql      ml.model_run, ml.shock_prediction, semantic.v_shock_detection
  run_all.sql            builds and loads everything (SQLCMD mode)
semantic/
  metrics.yml            the 7 business metrics: definition, owner, grain, SQL, validation query
src/
  config.py              shared constants (threshold, windows, years, paths)
  db.py                  SQL Server connection (AGRIPULSE_SQL_CONN or .env)
  ingest/pipeline.py     the same Bronze/Silver/Gold rules in pandas (incl. the reject log)
  ingest/load_warehouse.py   EXEC the three load procedures from Python
  quality/checks.sql     13 zero-row data-quality checks ("-- check:")
  quality/profiling.sql  row counts and known source issues
  quality/run_checks.py  PASS / FAIL for every check
  semantic/sync_metrics.py   load metrics.yml into SQL and validate every metric
  mining/helpers.py      models, forward-chaining CV, rule extraction, transactions
  mining/score.py        SQL -> Python -> SQL: read gold.features_shock, write predictions to ml.*
  mining/data.py         loads the Gold table from CSV or from SQL Server
  mining/plotting.py     figure style
notebooks/
  00_smoke_test.ipynb                 runs the whole pipeline end to end (needs the database)
  01_warehouse_eda_olap.ipynb         layers, data quality, EDA, OLAP
  02_shock_classification.ipynb       DT / NB / k-NN / Bagging / AdaBoost, rules, regression
  03_shock_recipes_association.ipynb  Apriori / FP-growth shock recipes
models/          (saved models; empty, the scoring step retrains in about 30 s)
tests/           pytest: pipeline, mining, metrics.yml, and the SQL warehouse (when connected)
reports/
  findings.md    results summary for the paper
  figures/       15 figures (PNG)
  tables/        result tables (CSV)
docs/
  bronze_report.docx, silver_report.docx, gold_report.docx   one report per layer
  PROJECT_SPEC.md           problem, questions, layers, checklists, milestones
  architecture.md           layers, rules, star schema
  data_catalog.md           Gold, semantic and ml columns
  data_dictionary.csv       every column of every layer (type, definition, source, rule)
  data_source_register.csv  sources: links, owner, licence, grain, keys, volume, missing values
  data_quality.md           source issues, how they were handled, rejected rows
  naming_conventions.md     schema, table, key and column names
build_database.bat   builds the SQL Server database on a Windows PC in one step
```

## How to run

Run every command from the project root (the folder with this README).

### Option A: Python only (no database needed)

```bash
python -m venv .venv
.venv\Scripts\activate            # macOS/Linux: source .venv/bin/activate
pip install -r requirements.txt
jupyter lab                       # open notebooks/ and run 01, 02, 03 in order
pytest                            # SQL tests are skipped without a database
```

Notebook 01 rebuilds `data/exports/` from the raw files. Without Jupyter:

```bash
python -m src.ingest.pipeline
python -m src.mining.score --dry-run   # train and evaluate the scoring model, write nothing
```

### Option B: SQL Server warehouse (SQL Server 2017+ on Windows)

**One step:** double-click `build_database.bat`, or run it from a terminal in the project root:

```bat
build_database.bat                 :: default instance (localhost)
build_database.bat .\SQLEXPRESS    :: SQL Server Express
```

It copies `data\` to `C:\AgriPulse\data` (a folder the SQL Server service can read; folders under
your user profile or OneDrive usually are not) and runs `sql\run_all.sql` with `sqlcmd`, which
creates the database, loads Bronze, Silver and Gold and runs the quality checks. It takes about 10
seconds. Rehearse it on the lab PC before grading day.

**In SSMS, by hand:** copy the `data` folder to `C:\AgriPulse\data`, then open and execute, in
order, `sql/00_init.sql`, `01_bronze.sql`, `02_silver.sql`, `03_gold.sql`, `04_semantic.sql`,
`05_feature_views.sql` and `07_ml_outputs.sql`, and run:

```sql
USE AgriPulse;
EXEC bronze.load_bronze @data_path = 'C:\AgriPulse\data';
EXEC silver.load_silver;
EXEC gold.load_gold;            -- optional: @shock_threshold_pct = -20.0
```

Then execute `src/quality/checks.sql` (every `-- check:` query must return no rows),
`src/quality/profiling.sql` and `sql/06_analytics.sql`.

**Connect Python to the warehouse:** install the Microsoft ODBC Driver 18 for SQL Server, copy
`.env.example` to `.env` and check `AGRIPULSE_SQL_CONN` (for SQL Server Express use
`Server=.\SQLEXPRESS`). Then:

```bash
python -m src.quality.run_checks       # PASS / FAIL for the 13 quality checks
python -m src.semantic.sync_metrics    # fill semantic.metric_catalog and validate the 7 metrics
python -m src.mining.score             # read gold.features_shock, write predictions to ml.*
pytest                                 # now also runs tests/test_sql.py against the warehouse
```

`python -m src.ingest.load_warehouse --data-path C:\AgriPulse\data` reloads Bronze, Silver and Gold
from Python. `load_ml_dataset(source="sql")` reads the Gold view from the warehouse, and
`src.mining.data.compare_with_sql()` checks that the SQL Gold layer matches the pandas one row by row.

The Bronze load uses `BULK INSERT ... CODEPAGE = '65001'`, which SQL Server on Linux (and so Docker on
a Mac) does not support; run the warehouse on SQL Server for Windows.

## Deliverables (course skeleton)

| deliverable | where |
|---|---|
| architecture diagram | `docs/architecture.md`, the diagram above |
| source register, data dictionary | `docs/data_source_register.csv`, `docs/data_dictionary.csv` |
| Bronze, Silver, Gold layers | `sql/01_bronze.sql`, `02_silver.sql`, `03_gold.sql` (SQL Server) and `src/ingest/pipeline.py` (pandas) |
| layer reports | `docs/bronze_report.docx`, `docs/silver_report.docx`, `docs/gold_report.docx` |
| data-quality report | `docs/data_quality.md`, `src/quality/checks.sql`, `silver.reject_log`, `audit.load_log` |
| semantic metrics with validation queries | `semantic/metrics.yml`, `sql/04_semantic.sql`, `python -m src.semantic.sync_metrics` |
| mining task with a baseline | notebooks 02-03; `python -m src.mining.score` writes baseline + model to `ml.*` |
| tests | `tests/` (`pytest`), `notebooks/00_smoke_test.ipynb` |
| final report, reproducible demo | `reports/findings.md`, the notebooks |
| project specification | `docs/PROJECT_SPEC.md` |

## Method

* **Label:** `is_shock = 1` when the yield is at least 15 % below the mean of the previous five
  calendar years for the same country and crop (`AVG ... OVER (ROWS BETWEEN 5 PRECEDING AND 1
  PRECEDING)` on a gap-free calendar; the history from 1961 supplies the baseline for 1990).
* **Features:** rainfall deviation from the country's long-term mean, temperature anomaly against the
  1961-1990 normal, pesticide intensity log10(1 + tonnes), and, added in the ablation, crop, region,
  rainfall level and last year's yield outcome. All of them are known before the predicted harvest.
* **Evaluation:** time-ordered hold-out (train 1990-2007, test 2008-2013) plus forward-chaining CV
  inside the training years. Each model's decision threshold is chosen on the CV predictions, never on
  the test years. Metrics: Accuracy, Precision, Recall, F1, ROC-AUC, PR-AUC.
* **Models:** Decision Tree (with IF-THEN rule extraction), Naive Bayes, k-NN, Bagging, AdaBoost, and
  linear regression as the baseline for the continuous yield change.
* **Association rules:** Apriori, cross-checked with FP-growth, on discretised climate, input,
  history, crop and region items, ranked by support, confidence and lift.

## Limitations

The rainfall source has no year-to-year variation, national annual averages hide growing-season
extremes, pesticide use is a country total without cropland area, and several food-insecure countries
lack pesticide or temperature data. See `reports/findings.md` §7.
