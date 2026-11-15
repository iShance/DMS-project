# Naming conventions

The conventions AgriPulse follows, in SQL Server and in Python.

## Schemas, tables, columns

- Everything is `lowercase_snake_case`.
- Six schemas, one per layer: `bronze`, `silver`, `gold`, `semantic`, `ml`, `audit`.
- **Bronze** tables are named after the source and publisher: `<publisher>_<content>`, e.g.
  `bronze.fao_yield`, `bronze.wb_rainfall` (`fao` = FAO, `wb` = World Bank, `ref` = seed tables written
  for the project). Columns keep the order and meaning of the CSV header. The load view for each table is
  `bronze.v_<table>_load`.
- **Silver** tables keep the Bronze table's name (`silver.fao_yield`, `silver.wb_rainfall`, ...);
  the reference tables become `silver.country` and `silver.country_alias`, and rejected rows go to
  `silver.reject_log`.
- **Gold:** `dim_<entity>` for dimensions, `fact_<grain>` for facts (`fact_crop_year`: one row per
  country x crop x year), `features_<topic>` for the feature views mining reads (`gold.features_shock`).
  `gold.vw_ml_dataset` is the flat EDA view (the `vw_` prefix predates the course skeleton and is kept
  so existing notebooks and docs stay valid).
- **Semantic:** `semantic.metric_catalog` and `semantic.v_<metric_or_topic>` metric views.
- **ML outputs:** `ml.<topic>_<result>` (`ml.shock_prediction`) and `ml.model_run`.
- **Audit:** `audit.load_log`.

## Keys

- `<entity>_key` is a surrogate key assigned in Gold (`country_key`, `crop_key`, `climate_band_key`).
  `year_key` is the calendar year itself.
- Business (natural) keys keep their source meaning: `country_name` (conformed through
  `silver.country_alias`), `crop_name`, `year`; FAO codes are `fao_area_code`, `fao_item_code`.

## Columns

- Units go in the name: `_hg_ha` (hectograms per hectare), `_mm`, `_c` (°C), `_tonnes`, `_pct` (percent).
- `prev_<column>` is last calendar year's value of `<column>` (LAG 1).
- `is_<flag>` is a 0/1 flag (`is_shock`, `is_imputed`), `n_<thing>` a count.
- Technical columns: `dwh_create_date` (when the pipeline wrote the row; the course skeleton calls it
  `DW_create_date`), `source_file` and `ingested_at` (Bronze provenance).

## Scripts and code

- SQL scripts: two-digit prefix in run order and an action, e.g. `04_silver_load_proc.sql`.
  `sql/run_all.sql` runs them in the right order.
- Load procedures: `<schema>.load_<schema>` (`bronze.load_bronze`, `silver.load_silver`, `gold.load_gold`).
- Quality checks in `sql/07_quality_checks.sql` start with `-- check: <name>` and must return zero rows.
- Python: the package is `src/agripulse`; command-line entry points run as `python -m agripulse.<module>`.
- Metric names in `semantic/metrics.yml` are snake_case and end in their unit where it helps
  (`shock_rate_pct`, `avg_temp_anomaly_c`).
