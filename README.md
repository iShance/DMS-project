# AgriPulse: Climate-Shock Early Detection Lakehouse for Global Crop Yields

> *AgriPulse: A Lakehouse-Driven Data Mining Framework for Early Detection of Climate-Induced Crop Yield
> Shocks*

Food-security planners usually see a harvest collapse only after it happens. AgriPulse asks whether a
**yield shock**, a sharp drop in a country's crop yield against its own recent baseline, can be
detected in advance from rainfall deviation, temperature anomaly and pesticide intensity. It also asks
which combinations of climate stress produce shocks and whether the patterns differ by crop and region.

It integrates four public sources into a **Bronze → Silver → Gold** warehouse (SQL Server) and mines
the Gold dataset with EDA, OLAP, five classifiers, a regression baseline and association rules.

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
and are stored unchanged in `datasets/source/`.

| file | content | original source | rows |
|---|---|---|---|
| `yield.csv` | crop yield (hg/ha) by country, crop, year 1961-2016 | [FAO](https://www.fao.org/home/en/) | 56,717 |
| `rainfall.csv` | average annual rainfall (mm) by country, 1985-2017 | [World Bank](https://data.worldbank.org/) | 6,727 |
| `temp.csv` | average temperature (°C) by country and year | World Bank (per the Kaggle page) | 71,311 |
| `pesticides.csv` | pesticide use (tonnes of active ingredients), 1990-2016 | [FAO](https://www.fao.org/home/en/) | 4,349 |

`datasets/reference/` holds two seed tables written for this project: the conformed country list with ISO3
codes and World Bank regions, and 41 country-name aliases that reconcile the four sources.

## Repository layout

```
datasets/
  source/        the four raw CSV files (Bronze input)
  reference/     country reference + name aliases (seed tables)
  gold/          Gold layer exported by the pandas pipeline (fact, dimensions, ml_dataset.csv)
sql/
  00_init_database.sql       database + bronze/silver/gold schemas
  01_bronze_ddl.sql          raw tables
  02_bronze_load_proc.sql    bronze.load_bronze  (TRUNCATE + BULK INSERT)
  03_silver_ddl.sql          typed tables
  04_silver_load_proc.sql    silver.load_silver  (clean, conform, de-duplicate, impute)
  05_gold_ddl.sql            star schema + gold.vw_ml_dataset
  06_gold_load_proc.sql      gold.load_gold      (LAG / window features, shock label)
  07_quality_checks.sql      integrity checks and data profiling
  08_olap_analysis.sql       ROLLUP, CUBE, PIVOT, slice, dice, drill-down
  run_all.sql                builds everything (SQLCMD mode)
src/agripulse/
  pipeline.py    the same Bronze/Silver/Gold rules in pandas
  mining.py      models, forward-chaining CV, rule extraction, transactions
  data.py        loads the Gold table from CSV or from SQL Server
  config.py      shared constants (threshold, windows, years)
  plotting.py    figure style
notebooks/
  01_warehouse_eda_olap.ipynb         layers, data quality, EDA, OLAP
  02_shock_classification.ipynb       DT / NB / k-NN / Bagging / AdaBoost, rules, regression
  03_shock_recipes_association.ipynb  Apriori / FP-growth shock recipes
reports/
  findings.md    results summary for the paper
  figures/       15 figures (PNG)
  tables/        result tables (CSV)
docs/
  architecture.md   layers, rules, star schema
  data_catalog.md   Gold columns
  data_quality.md   source issues and how they were handled
```

## How to run

### Option A: Python only (no database needed)

```bash
python -m venv .venv
.venv\Scripts\activate            # macOS/Linux: source .venv/bin/activate
pip install -r requirements.txt
jupyter lab                       # open notebooks/ and run 01, 02, 03 in order
```

Notebook 01 rebuilds `datasets/gold/` from the raw files. To rebuild it without Jupyter:

```bash
set PYTHONPATH=src                # macOS/Linux: export PYTHONPATH=src
python -m agripulse.pipeline
```

### Option B: SQL Server warehouse (SQL Server 2017+)

1. Copy the `datasets` folder somewhere the SQL Server service can read, e.g. `C:\AgriPulse\datasets\`.
   Folders under OneDrive or a user profile usually aren't readable by the service.
2. From the `sql` folder run:

   ```bash
   sqlcmd -S localhost -E -i run_all.sql -v DataPath="C:\AgriPulse\datasets\"
   ```

   Or open the scripts in SSMS and run `00` to `06` in order, then:

   ```sql
   EXEC bronze.load_bronze @data_path = 'C:\AgriPulse\datasets\';
   EXEC silver.load_silver;
   EXEC gold.load_gold;            -- optional: @shock_threshold_pct = -20.0
   ```

3. Run `07_quality_checks.sql` (the "expect 0 rows" queries must return nothing) and
   `08_olap_analysis.sql`.
4. To mine straight from the warehouse: `pip install pyodbc`, set `AGRIPULSE_SQL_CONN`, and call
   `load_ml_dataset(source="sql")`. `agripulse.data.compare_with_sql()` checks that the SQL Gold layer
   matches the pandas one row by row.

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
