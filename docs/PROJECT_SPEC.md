# Project Specification: AgriPulse

*AgriPulse: A Lakehouse-Driven Data Mining Framework for Early Detection of Climate-Induced Crop Yield
Shocks*

## Problem statement

Food-security planners (national agriculture ministries, early-warning systems such as FEWS NET or
FAO GIEWS, humanitarian agencies) usually see a harvest collapse only after it happens. AgriPulse asks
whether a **yield shock**, a sharp drop in a country's crop yield against its own recent baseline, can
be flagged in advance from rainfall deviation, temperature anomaly and pesticide intensity, and which
combinations of climate stress go with shocks. It supports two decisions: where to look first (which
crops and regions are most shock-prone) and whether a given country-crop deserves an early alert this
year.

## Business questions

1. **RQ1.** Can a yield shock be detected in advance from rainfall deviation, temperature anomaly and
   pesticide intensity? How much do crop, region and last year's outcome add?
   (notebook 02, `ml.*`, `semantic.v_shock_detection`)
2. **RQ2.** Which combinations of climate stress and input use produce shocks?
   (notebook 03, `semantic.v_shock_rate_by_climate`)
3. **RQ3.** Do the patterns differ by crop and by region?
   (notebooks 01 and 03, `semantic.v_shock_rate_by_crop_region`)
4. **Trend.** Are shocks becoming more or less frequent as temperatures rise?
   (`semantic.v_shock_rate_by_year`, `sql/08_olap_analysis.sql` Q3 and Q8)

Answers: `reports/findings.md` §5.

## Source contract

All sources are listed in [`data_source_register.csv`](data_source_register.csv) with URI, owner,
licence, modality, native grain, natural keys, timestamps, volume, refresh, missing values and
sensitive fields. Summary:

| source | native grain | rows |
|---|---|---|
| FAO crop yield | country x crop x year, 1961-2016 | 56,717 |
| World Bank rainfall | country x year, 1985-2017 | 6,727 |
| temperature | city/station record x year | 71,311 |
| FAO pesticide use | country x year, 1990-2016 | 4,349 |
| country reference + aliases (project seed tables) | country / source spelling | 210 + 41 |

No source contains personal data. All four sources are static snapshots.

## Target entities

Country (with ISO3 code, World Bank region and climate normals), crop (with crop group), year, climate
band, and the crop-year: one country x crop x year with its yield, baseline, shock label and climate
and input features.

## Layers

- **Bronze** (`sql/01`, `02`): exact copy of each CSV, every column NVARCHAR, plus provenance
  (`source_file`, `ingested_at`). No cleaning.
- **Silver** (`sql/03`, `04`): typed, trimmed, country names conformed, de-duplicated; rainfall grid
  completed. Every row not kept is written to `silver.reject_log` with its reason.
- **Gold** (`sql/05`, `06`): star schema. **Grain of `gold.fact_crop_year`: one row per country x crop
  x year, 1990-2013**, kept only when the shock label and all four sources exist. Dimensions
  `dim_country`, `dim_crop`, `dim_year`, `dim_climate_band`. Feature view `gold.features_shock`, flat
  view `gold.vw_ml_dataset`.
- **Semantic** (`sql/09`, `semantic/metrics.yml`): seven metrics, each with name, label, definition,
  owner, grain, SQL expression, dimensions, null policy and an independent validation query;
  `python -m agripulse.semantic` loads them into `semantic.metric_catalog` and validates them.
- **ML** (`sql/10`, `src/agripulse/score.py`): model runs and predictions written back to SQL.
- **Audit:** every load procedure writes one row per table to `audit.load_log`.

The pandas module `src/agripulse/pipeline.py` applies the same Bronze/Silver/Gold rules, so the
analysis runs without SQL Server; `agripulse.data.compare_with_sql()` and `tests/test_sql.py` check
that both give identical results.

## Integration challenges solved

| challenge | solution | where |
|---|---|---|
| key reconciliation across sources | 41 country-name aliases map every source spelling to one conformed name | `country_aliases.csv`, `silver.country_alias` |
| double counting | FAO "China" aggregate (area 351) rejected | `silver.load_silver` |
| type and category normalisation | TRY_CAST of text, crop groups, climate bands | Silver, Gold |
| time alignment | analysis window 1990-2013 where all four sources overlap; yield history from 1961 for the baseline; series densified to calendar years before LAG / moving windows | `gold.load_gold` |
| duplicates | one row per country x crop x year (lowest FAO area code wins); city temperature records averaged | Silver |
| missing values | rainfall gaps imputed with the country mean and flagged; zero yields treated as missing; rejected rows logged | Silver, `docs/data_quality.md` |
| provenance | `source_file`, `ingested_at` in Bronze; `audit.load_log` per load | Bronze, audit |

## SQL checklist

| item | where |
|---|---|
| joins across sources | `gold.load_gold` step 4 (yield + rainfall + temperature + pesticides) |
| CTEs | `silver.load_silver`, `gold.load_gold`, `semantic.v_shock_rate_by_climate` |
| window functions | LAG and `AVG ... ROWS BETWEEN 5 PRECEDING AND 1 PRECEDING` in `gold.load_gold`; ROW_NUMBER de-duplication in Silver |
| conditional aggregation | `sql/07` profiling, `semantic.v_shock_detection`, `sql/08` |
| data-quality queries | `sql/07_quality_checks.sql` (13 zero-row checks) |
| temporal analysis | baseline windows, `semantic.v_shock_rate_by_year`, `sql/08` Q3, Q8 |
| dimensional loading | `gold.load_gold` (surrogate keys by ROW_NUMBER) |
| OLAP | `sql/08_olap_analysis.sql`: ROLLUP, CUBE, PIVOT, slice, dice, drill-down |
| feature views | `gold.features_shock` |
| semantic metric views | `semantic.v_*` |
| metric reconciled independently | every metric in `semantic/metrics.yml` has a validation query rebuilt from Silver by a different route; the whole Gold layer is also reconciled against the pandas implementation |

## Mining checklist

- Feature view: `gold.features_shock` (keys, features, label).
- Baselines vs improved methods: the "last year's label" rule and linear regression vs Decision Tree,
  Naive Bayes, k-NN, Bagging and AdaBoost, each on three feature sets (climate only, + context,
  + history). Forward-chaining CV on 1990-2007, test 2008-2013, threshold chosen on CV only.
- Outputs written to SQL: `ml.shock_prediction` (keys, `shock_probability`, `predicted_shock`,
  `model_name`, `model_version`, `run_id`, `generated_at`) and `ml.model_run` (one row per model with
  threshold and metrics).
- Association rules (Apriori and FP-growth) for shock recipes: `notebooks/03`, `reports/tables/`.

## Testing

`pytest` from the project root (`tests/`):

| type | tests |
|---|---|
| schema and type | Bronze keeps the CSV columns; data dictionary generated from the live schema |
| uniqueness | Silver natural keys, Gold fact grain |
| referential integrity | fact keys exist in every dimension; yield countries in the reference |
| accepted ranges | yields > 0, temperatures -30..45 °C, baseline 3-5 years, 0/1 flags |
| source-to-target reconciliation | Bronze rows = kept + rejected rows; SQL Gold = pandas Gold; SQL reject log = pandas reject log |
| metric tests | every metric's validation query matches; metric views match pandas |
| model-output completeness | one prediction per model and test crop-year, keys exist in Gold, reported metrics reproduced |
| leakage | baselines use only the 5 previous years; CV folds never train on later years |

The SQL tests run when `AGRIPULSE_SQL_CONN` is set and are skipped otherwise.

## Milestones

| milestone | status |
|---|---|
| M1 problem and sources | done: README, this file, source register |
| M2 Bronze and profiling | done: `sql/01`-`02`, `docs/data_quality.md` |
| M3 Silver and quality | done: `sql/03`-`04`, reject log, `sql/07` |
| M4 Gold and semantic layer | done: `sql/05`-`06`, `sql/09`, `semantic/metrics.yml` |
| M5 mining | done: notebooks 02-03, `agripulse.score`, `ml.*` |
| M6 dashboard or app | not built: the semantic views are ready to connect to Power BI or a similar tool |
| M7 report and demo | `reports/findings.md`; the notebooks are the reproducible demo |

## Marking (set by the instructor)

[Criterion: marks]
