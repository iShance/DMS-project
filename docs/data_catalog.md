# Data catalog

The analytical tables and views. Every column of every layer, with type, nullability, source and quality
rule, is also listed in [`data_dictionary.csv`](data_dictionary.csv).

The Gold layer exists in SQL Server (`gold.*`) and as CSV files in `data/exports/` (written by
`src.ingest.pipeline`). `ml_dataset.csv` / `gold.vw_ml_dataset` is the flat table used for mining.

## gold.fact_crop_year: one row per country x crop x year (1990-2013)

| column | type | description |
|---|---|---|
| country_key | INT | → dim_country |
| crop_key | INT | → dim_crop |
| year_key | INT | → dim_year (= calendar year) |
| climate_band_key | INT | → dim_climate_band (from the country's climate normals) |
| yield_hg_ha | FLOAT | yield, hectograms per hectare (10 hg/ha = 1 kg/ha) |
| prev_yield_hg_ha | FLOAT | yield of the previous calendar year (NULL if that year is missing) |
| yoy_change_pct | FLOAT | yield / previous yield - 1, in % |
| baseline_yield_hg_ha | FLOAT | mean yield of the previous 5 calendar years (at least 3 present) |
| baseline_n_years | INT | number of years present in that window (3-5) |
| yield_dev_pct | FLOAT | yield / baseline - 1, in % |
| **is_shock** | TINYINT | **label**: 1 if yield_dev_pct ≤ −15 |
| prev_yield_dev_pct | FLOAT | last year's yield_dev_pct |
| prev_is_shock | TINYINT | last year's label |
| rainfall_mm | FLOAT | annual rainfall (static long-term value in this source, see data_quality.md) |
| rain_dev_pct | FLOAT | rainfall / country long-term mean - 1, in % |
| rain_is_imputed | TINYINT | 1 if the rainfall value was filled with the country mean |
| avg_temp_c | FLOAT | annual mean temperature (°C), mean of the source records |
| temp_anomaly_c | FLOAT | avg_temp_c minus the country's 1961-1990 mean |
| pesticides_tonnes | FLOAT | pesticide use, tonnes of active ingredients (country total) |
| pesticide_intensity | FLOAT | log10(1 + pesticides_tonnes) |
| pesticide_yoy_pct | FLOAT | pesticide use / last year's use - 1, in % |

## gold.dim_country

| column | description |
|---|---|
| country_key | surrogate key (ROW_NUMBER over the name) |
| country_name | conformed name (`data/reference/country_reference.csv`) |
| iso3 | ISO 3166-1 alpha-3 (historical codes for former states, e.g. SUN, YUG) |
| region | World Bank region (7 regions) |
| temp_normal_c | mean annual temperature 1961-1990 |
| rainfall_normal_mm | long-term mean annual rainfall |

## gold.dim_crop

| column | description |
|---|---|
| crop_key | surrogate key |
| crop_name | FAO item name (Cassava, Maize, Plantains and others, Potatoes, Rice paddy, Sorghum, Soybeans, Sweet potatoes, Wheat, Yams) |
| fao_item_code | FAO item code |
| crop_group | Cereals, Roots & Tubers, Oilseeds, Starchy Fruits |

## gold.dim_year

| column | description |
|---|---|
| year_key / year | calendar year 1990-2013 |
| decade | 1990s, 2000s, 2010s |
| five_year_period | 1990-1994 ... 2010-2014 |

## gold.dim_climate_band

Temperature band (from `temp_normal_c`) x rainfall band (from `rainfall_normal_mm`); the lower bound is
inclusive and the upper bound exclusive.

| temperature band | range (°C) | | rainfall band | range (mm/yr) |
|---|---|---|---|---|
| Cold | < 10 | | Arid | < 250 |
| Temperate | 10-20 | | Semi-arid | 250-500 |
| Warm | 20-25 | | Sub-humid | 500-1,000 |
| Hot | ≥ 25 | | Humid | 1,000-2,000 |
| | | | Very humid | ≥ 2,000 |

## gold.vw_ml_dataset / data/exports/ml_dataset.csv

All fact measures plus the descriptive attributes `country_name, iso3, region, crop_name, crop_group,
year, decade, climate_band, temp_band, rain_band`. 16,339 rows, 10.2 % shocks.

## gold.features_shock: one row per country x crop x year

The documented feature view the classifier reads (`python -m src.mining.score`): the keys
`country_key, crop_key, year_key`, the descriptive `country_name, crop_name, region, year`, the
features `rain_dev_pct, temp_anomaly_c, pesticide_intensity, rainfall_mm, prev_yield_dev_pct,
prev_is_shock`, and the label `is_shock`. Feature sets A, B and C in `src/mining/helpers.py` are
subsets of these columns.

## Semantic metric views

| view | grain | columns |
|---|---|---|
| `semantic.v_shock_rate_by_crop_region` | region x crop | region, crop_group, crop_name, crop_years, shocks, shock_rate_pct, avg_yield_dev_pct |
| `semantic.v_shock_rate_by_climate` | climate band x pesticide use | climate_band, temp_band, rain_band, pesticide_use (low/medium/high tercile), countries, crop_years, shocks, shock_rate_pct, avg_temp_anomaly_c, avg_pesticide_intensity |
| `semantic.v_shock_rate_by_year` | year | year, decade, crop_years, shocks, shock_rate_pct, avg_temp_anomaly_c, hot_year_share_pct |
| `semantic.v_shock_detection` | run x model | model, role, threshold, scored_crop_years, actual_shocks, predicted_shocks, true_alarms, false_alarms, detection_rate_pct, precision_pct, false_alarm_rate_pct, test_roc_auc, test_pr_auc, is_latest_run |

`semantic.metric_catalog` holds the definitions from `semantic/metrics.yml` and the result of the last
validation (`metric_value`, `validation_value`, `validation_status`).

## ml.shock_prediction: one row per run x model x test crop-year

| column | description |
|---|---|
| run_id, model_name, model_version | which run and model produced the row |
| country_key, crop_key, year_key | → Gold dimensions |
| shock_probability | predicted probability of a shock |
| predicted_shock | 1 if shock_probability ≥ the run's threshold |
| generated_at | when the run was scored |

`ml.model_run` has one row per run x model: role (baseline / improved), feature view and features,
train and test years, threshold (chosen on CV predictions), CV ROC-AUC and the test ROC-AUC, PR-AUC,
precision, recall and F1.

## silver.reject_log and audit.load_log

`silver.reject_log` has one row per Bronze row that did not reach Silver: source_table, business_key
(the source's own key), column_name, raw_value and reason. `audit.load_log` has one row per table per
load: batch_id, procedure_name, source_name, target_table, start and end time, rows_loaded,
rows_rejected, status and message.
