# AgriPulse warehouse architecture

## Data flow

```
 data/raw/*.csv ──┐
 data/reference/*.csv┤
                         ▼
 ┌──────────────── BRONZE (raw, NVARCHAR) ────────────────┐
 │ fao_yield  wb_rainfall  wb_temperature  fao_pesticides │  bronze.load_bronze
 │ ref_country  ref_country_alias                         │  TRUNCATE + BULK INSERT
 │ + source_file, ingested_at (provenance)                │  through bronze.v_*_load
 └────────────────────────────────────────────────────────┘
                         ▼
 ┌──────────────── SILVER (typed, clean) ─────────────────┐
 │ country  country_alias                                 │  silver.load_silver
 │ fao_yield       country x crop x year                  │  trim, TRY_CAST, conform
 │ wb_rainfall     country x year (complete 1985-2017)    │  names, de-duplicate,
 │ wb_temperature  country x year (city records averaged) │  impute rainfall gaps
 │ fao_pesticides  country x year                         │
 │ reject_log      every Bronze row not kept + reason     │
 └────────────────────────────────────────────────────────┘
                         ▼
 ┌──────────────── GOLD (star schema) ────────────────────┐
 │ dim_country  dim_crop  dim_year  dim_climate_band      │  gold.load_gold
 │ fact_crop_year   country x crop x year, 1990-2013      │  LAG / moving-window
 │ vw_ml_dataset    flat view for EDA and mining          │  features, shock label
 │ features_shock   feature view read by the model        │
 └────────────────────────────────────────────────────────┘
          ▼                                    ▼
 ┌──── SEMANTIC ───────────────┐     notebooks/01-03 (EDA, OLAP, classification,
 │ metric_catalog (metrics.yml)│     association rules)
 │ v_shock_rate_by_crop_region │     python -m src.mining.score
 │ v_shock_rate_by_climate     │       reads gold.features_shock ──┐
 │ v_shock_rate_by_year        │                                   ▼
 │ v_shock_detection  <────────┼──── ┌──── ML ──────────────────────────┐
 └─────────────────────────────┘     │ model_run  shock_prediction      │
                                     └──────────────────────────────────┘
 AUDIT: audit.load_log, one row per table per load (rows loaded, rows rejected, SUCCESS/FAILED)
```

The same rules are implemented twice:

| layer | SQL Server (reference) | pandas mirror |
|---|---|---|
| Bronze | `sql/01_bronze.sql` | `pipeline.load_bronze()` |
| Silver | `sql/02_silver.sql` | `pipeline.build_silver()` |
| Gold | `sql/03_gold.sql`, `sql/05_feature_views.sql` | `pipeline.build_gold()`, `pipeline.ml_dataset()` |

`src.mining.data.compare_with_sql()` compares the two Gold outputs column by column.

## Bronze

One table per file, with columns in the same order as the CSV header and every column `NVARCHAR`, so
a malformed value can never stop the load. `bronze.load_bronze @data_path` truncates each table and
`BULK INSERT`s the file with `FORMAT = 'CSV'` (quoted fields such as `"Rice, paddy"`),
`CODEPAGE = '65001'` (UTF-8 names such as Côte d'Ivoire) and `ROWTERMINATOR = '0x0a'` (works for both LF
and CRLF files).

Each table ends with two provenance columns, `source_file` (the file path) and `ingested_at` (load
time). `BULK INSERT` loads through a view per table (`bronze.v_<table>_load`) that lists only the CSV
columns, so the provenance columns are filled by the procedure and by their default. Each file loaded
writes a row to `audit.load_log`.

## Silver rules

| table | rule |
|---|---|
| all | `TRIM`; trailing `CHAR(13)` removed; `TRY_CAST(NULLIF(x, ''))`, so blanks, `..` and `NA` become NULL |
| all | source country spelling → conformed name via `silver.country_alias` (41 aliases) |
| `fao_yield` | keep `Element = 'Yield'`, `Unit = 'hg/ha'`; drop FAO area 351 (the "China" aggregate); drop yield ≤ 0; one row per country x crop x year |
| `wb_rainfall` | build a complete country x year grid for 1985-2017; fill gaps with the country mean and set `is_imputed = 1` |
| `wb_temperature` | average all city records of a country-year; keep the count in `n_records` |
| `fao_pesticides` | keep `Use / Pesticides (total)`; drop negative values |
| all | every Bronze row that fails a rule is written to `silver.reject_log` (source table, source key, column, raw value, reason) |

Two successor-state aliases keep long series continuous: `Sudan (former)` → `Sudan` (the split is in
2011/12) and `Ethiopia PDR` → `Ethiopia` (1992/93). The other historical entities (USSR, Yugoslav SFR,
Czechoslovakia, Serbia and Montenegro, Belgium-Luxembourg) stay separate and drop out of Gold because no
climate source covers them.

## Gold

### Grain and label

`gold.fact_crop_year` has one row per **country x crop x year**, for 1990-2013, the years where all four
sources overlap. A row is kept only when the label and all four sources are present.

```
baseline_yield = AVG(yield) over the 5 previous calendar years   (at least 3 present)
yield_dev_pct  = (yield / baseline_yield - 1) * 100
is_shock       = 1 if yield_dev_pct <= -15 else 0
```

Before the window functions run, each country-crop series is **densified** to one row per calendar
year (gap years are NULL). `LAG` then always means "previous calendar year", and
`ROWS BETWEEN 5 PRECEDING AND 1 PRECEDING` always means "previous five calendar years", even across the
50 gaps in the FAO series. The history starts in 1961, so 1990 rows have a full baseline.

### Features

| column | definition | known before harvest? |
|---|---|---|
| `rain_dev_pct` | rainfall / country long-term mean - 1 (%) | yes (season observation) |
| `temp_anomaly_c` | annual mean temperature - country 1961-1990 mean (WMO normal) | yes |
| `pesticide_intensity` | log10(1 + tonnes of active ingredients) | yes (inputs applied in season) |
| `pesticide_yoy_pct` | tonnes / last year's tonnes - 1 (%) | yes |
| `prev_yield_dev_pct`, `prev_is_shock` | last year's deviation and label (`LAG`) | yes |
| `yoy_change_pct`, `yield_dev_pct` | current-year yield measures | **no**: label side only, never a feature |

### Dimensions

* `dim_country`: conformed name, ISO3, World Bank region, temperature normal, rainfall normal
* `dim_crop`: FAO item code, crop group (Cereals, Roots & Tubers, Oilseeds, Starchy Fruits)
* `dim_year`: year, decade, five-year period
* `dim_climate_band`: 4 temperature bands x 5 rainfall bands = 20 bands with inclusive/exclusive bounds,
  assigned from each country's normals

Foreign keys are not declared, so every table can be truncated on reload. Integrity is checked in
`src/quality/checks.sql` (duplicate grain, orphan keys, label consistency).

### Parameters

`gold.load_gold` accepts `@shock_threshold_pct` (default −15), `@min_baseline_years` (3), `@start_year`
(1990) and `@end_year` (2013). The pandas constants are in `src/config.py`; change both
together.

## Semantic layer

`semantic/metrics.yml` defines seven metrics (crop-years, shocks, shock rate, average yield deviation,
shock persistence, average temperature anomaly, average pesticide intensity), each with a definition,
owner, grain, SQL expression, dimensions, null policy and an **independent validation query**: a query
that rebuilds the number from Silver by a different route (correlated subqueries instead of the Gold
window functions, for example). `python -m src.semantic.sync_metrics` copies the file into
`semantic.metric_catalog`, computes every metric both ways and stores the two values and PASS/FAIL.

The metric views (`sql/04_semantic.sql`, one per business question) use these definitions:

| view | grain | question |
|---|---|---|
| `semantic.v_shock_rate_by_crop_region` | region x crop | RQ3: differences by crop and region |
| `semantic.v_shock_rate_by_climate` | climate band x pesticide-use tercile | RQ2: climate and input recipes |
| `semantic.v_shock_rate_by_year` | year | trend |
| `semantic.v_shock_detection` | scoring run x model | RQ1: detection and false-alarm rates |

## ML outputs (SQL -> Python -> SQL)

`python -m src.mining.score` reads `gold.features_shock`, trains the baseline ("last year's label") and
the improved model (Bagging, the best by CV in notebook 02) with the evaluation protocol of
`src.mining.helpers`, and appends to:

* `ml.model_run`: one row per model and run (version, features, train and test years, threshold, CV and
  test metrics)
* `ml.shock_prediction`: one row per model and test crop-year, keyed on `country_key, crop_key,
  year_key`, with `shock_probability`, `predicted_shock`, `model_name`, `model_version`, `run_id` and
  `generated_at`

`semantic.v_shock_detection` recomputes detection and false-alarm rates in SQL from the stored
predictions, and `tests/test_sql.py` checks that they match the metrics in `ml.model_run` and in
`reports/tables/classification_results.csv`.

## Audit

Every load procedure writes one row per target table to `audit.load_log`: a `batch_id` per call,
source, target, start and end time, rows loaded, rows rejected (Silver) and `SUCCESS`, or `FAILED` with
the error message (written in the `CATCH` block before the error is re-thrown).
