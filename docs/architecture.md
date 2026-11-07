# AgriPulse warehouse architecture

## Data flow

```
 datasets/source/*.csv ──┐
 datasets/reference/*.csv┤
                         ▼
 ┌──────────────── BRONZE (raw, NVARCHAR) ────────────────┐
 │ fao_yield  wb_rainfall  wb_temperature  fao_pesticides │  bronze.load_bronze
 │ ref_country  ref_country_alias                         │  TRUNCATE + BULK INSERT
 └────────────────────────────────────────────────────────┘
                         ▼
 ┌──────────────── SILVER (typed, clean) ─────────────────┐
 │ country  country_alias                                 │  silver.load_silver
 │ fao_yield       country x crop x year                  │  trim, TRY_CAST, conform
 │ wb_rainfall     country x year (complete 1985-2017)    │  names, de-duplicate,
 │ wb_temperature  country x year (city records averaged) │  impute rainfall gaps
 │ fao_pesticides  country x year                         │
 └────────────────────────────────────────────────────────┘
                         ▼
 ┌──────────────── GOLD (star schema) ────────────────────┐
 │ dim_country  dim_crop  dim_year  dim_climate_band      │  gold.load_gold
 │ fact_crop_year   country x crop x year, 1990-2013      │  LAG / moving-window
 │ vw_ml_dataset    flat view for data mining             │  features, shock label
 └────────────────────────────────────────────────────────┘
                         ▼
     notebooks/01-03  (EDA, OLAP, classification, association rules)
```

The same rules are implemented twice:

| layer | SQL Server (reference) | pandas mirror |
|---|---|---|
| Bronze | `sql/01_bronze_ddl.sql`, `sql/02_bronze_load_proc.sql` | `pipeline.load_bronze()` |
| Silver | `sql/03_silver_ddl.sql`, `sql/04_silver_load_proc.sql` | `pipeline.build_silver()` |
| Gold | `sql/05_gold_ddl.sql`, `sql/06_gold_load_proc.sql` | `pipeline.build_gold()`, `pipeline.ml_dataset()` |

`agripulse.data.compare_with_sql()` compares the two Gold outputs column by column.

## Bronze

One table per file, with columns in the same order as the CSV header and every column `NVARCHAR`, so
a malformed value can never stop the load. `bronze.load_bronze @data_path` truncates each table and
`BULK INSERT`s the file with `FORMAT = 'CSV'` (quoted fields such as `"Rice, paddy"`),
`CODEPAGE = '65001'` (UTF-8 names such as Côte d'Ivoire) and `ROWTERMINATOR = '0x0a'` (works for both LF
and CRLF files).

## Silver rules

| table | rule |
|---|---|
| all | `TRIM`; trailing `CHAR(13)` removed; `TRY_CAST(NULLIF(x, ''))`, so blanks, `..` and `NA` become NULL |
| all | source country spelling → conformed name via `silver.country_alias` (41 aliases) |
| `fao_yield` | keep `Element = 'Yield'`, `Unit = 'hg/ha'`; drop FAO area 351 (the "China" aggregate); drop yield ≤ 0; one row per country x crop x year |
| `wb_rainfall` | build a complete country x year grid for 1985-2017; fill gaps with the country mean and set `is_imputed = 1` |
| `wb_temperature` | average all city records of a country-year; keep the count in `n_records` |
| `fao_pesticides` | keep `Use / Pesticides (total)`; drop negative values |

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
`sql/07_quality_checks.sql` (duplicate grain, orphan keys, label consistency).

### Parameters

`gold.load_gold` accepts `@shock_threshold_pct` (default −15), `@min_baseline_years` (3), `@start_year`
(1990) and `@end_year` (2013). The pandas constants are in `src/agripulse/config.py`; change both
together.
