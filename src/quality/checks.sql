/*
=============================================================================
AgriPulse - src/quality/checks.sql
=============================================================================
Data-quality checks after a full load. Every query marked "-- check: <name>"
must return ZERO rows.

    python -m src.quality.run_checks    runs each check and prints PASS / FAIL
    pytest tests/test_sql.py            runs them as tests
    SSMS                                run this file against the AgriPulse database

Profiling queries (row counts, known source issues) are in profiling.sql.
=============================================================================
*/

USE AgriPulse;
GO

-- ===========================================================================
-- Bronze and Silver: expect 0 rows
-- ===========================================================================

-- check: bronze_rows_have_provenance
SELECT 'bronze.fao_yield' AS table_name FROM bronze.fao_yield WHERE source_file IS NULL
UNION ALL SELECT 'bronze.wb_rainfall' FROM bronze.wb_rainfall WHERE source_file IS NULL
UNION ALL SELECT 'bronze.wb_temperature' FROM bronze.wb_temperature WHERE source_file IS NULL
UNION ALL SELECT 'bronze.fao_pesticides' FROM bronze.fao_pesticides WHERE source_file IS NULL
UNION ALL SELECT 'bronze.ref_country' FROM bronze.ref_country WHERE source_file IS NULL
UNION ALL SELECT 'bronze.ref_country_alias' FROM bronze.ref_country_alias WHERE source_file IS NULL;

-- check: bronze_rows_equal_kept_rows_plus_rejects
-- Every Bronze row is either kept in Silver or written to silver.reject_log.
-- Kept rows: rainfall counts observed cells (not imputed ones), temperature
-- counts the city records that were averaged.
WITH counts AS (
              SELECT 'bronze.fao_yield' AS source_table,
                     (SELECT COUNT(*) FROM bronze.fao_yield) AS bronze_rows,
                     (SELECT COUNT(*) FROM silver.fao_yield) AS kept_rows
    UNION ALL SELECT 'bronze.wb_rainfall', (SELECT COUNT(*) FROM bronze.wb_rainfall),
                     (SELECT COUNT(*) FROM silver.wb_rainfall WHERE is_imputed = 0)
    UNION ALL SELECT 'bronze.wb_temperature', (SELECT COUNT(*) FROM bronze.wb_temperature),
                     (SELECT SUM(n_records) FROM silver.wb_temperature)
    UNION ALL SELECT 'bronze.fao_pesticides', (SELECT COUNT(*) FROM bronze.fao_pesticides),
                     (SELECT COUNT(*) FROM silver.fao_pesticides)
    UNION ALL SELECT 'bronze.ref_country', (SELECT COUNT(*) FROM bronze.ref_country),
                     (SELECT COUNT(*) FROM silver.country)
    UNION ALL SELECT 'bronze.ref_country_alias', (SELECT COUNT(*) FROM bronze.ref_country_alias),
                     (SELECT COUNT(*) FROM silver.country_alias)
)
SELECT c.source_table, c.bronze_rows, c.kept_rows, r.rejected_rows
FROM counts c
CROSS APPLY (SELECT COUNT(*) AS rejected_rows FROM silver.reject_log l
             WHERE l.source_table = c.source_table) r
WHERE c.bronze_rows <> c.kept_rows + r.rejected_rows;

-- check: yield_countries_in_reference
-- Yield countries that are missing from the country reference
SELECT DISTINCT y.country_name
FROM silver.fao_yield y
LEFT JOIN silver.country c ON c.country_name = y.country_name
WHERE c.country_name IS NULL;

-- check: aliases_point_to_reference
-- Aliases that point to a name not in the reference
SELECT a.*
FROM silver.country_alias a
LEFT JOIN silver.country c ON c.country_name = a.country_name
WHERE c.country_name IS NULL;

-- check: yield_positive
SELECT * FROM silver.fao_yield WHERE yield_hg_ha <= 0;

-- check: temperature_in_physical_range
SELECT * FROM silver.wb_temperature WHERE avg_temp_c NOT BETWEEN -30 AND 45;

-- check: rainfall_grid_complete
-- 33 years (1985-2017) for every rainfall country
SELECT country_name, COUNT(*) AS years
FROM silver.wb_rainfall
GROUP BY country_name
HAVING COUNT(*) <> 2017 - 1985 + 1;

-- ===========================================================================
-- Gold: expect 0 rows
-- ===========================================================================

-- check: fact_grain_unique
SELECT country_key, crop_key, year_key, COUNT(*) AS n
FROM gold.fact_crop_year
GROUP BY country_key, crop_key, year_key
HAVING COUNT(*) > 1;

-- check: fact_no_orphan_keys
SELECT f.*
FROM gold.fact_crop_year f
LEFT JOIN gold.dim_country c ON c.country_key = f.country_key
LEFT JOIN gold.dim_crop cr ON cr.crop_key = f.crop_key
LEFT JOIN gold.dim_year y ON y.year_key = f.year_key
WHERE c.country_key IS NULL OR cr.crop_key IS NULL OR y.year_key IS NULL;

-- check: fact_has_climate_band
SELECT * FROM gold.fact_crop_year WHERE climate_band_key IS NULL;

-- check: label_matches_threshold
-- Label consistent with the deviation (threshold -15 %)
SELECT *
FROM gold.fact_crop_year
WHERE (is_shock = 1 AND yield_dev_pct > -15)
   OR (is_shock = 0 AND yield_dev_pct <= -15);

-- check: feature_view_covers_fact
SELECT 'row count differs' AS problem
WHERE (SELECT COUNT(*) FROM gold.features_shock) <> (SELECT COUNT(*) FROM gold.fact_crop_year);

-- ===========================================================================
-- Audit: expect 0 rows
-- ===========================================================================

-- check: latest_run_of_each_procedure_succeeded
SELECT l.procedure_name, l.target_table, l.message
FROM audit.load_log l
WHERE l.status <> 'SUCCESS'
  AND l.batch_id IN (
      SELECT batch_id
      FROM (SELECT batch_id,
                   ROW_NUMBER() OVER (PARTITION BY procedure_name ORDER BY MAX(load_id) DESC) AS rn
            FROM audit.load_log
            GROUP BY procedure_name, batch_id) b
      WHERE rn = 1);
GO
