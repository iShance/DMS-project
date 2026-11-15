/*
=============================================================================
AgriPulse - 07_quality_checks.sql
=============================================================================
Data quality checks after a full load. Every query marked "-- check: <name>"
must return ZERO rows; tests/test_sql.py runs each of them (pytest), and they
can be run here in SSMS as well. The profiling queries at the end document
known source issues for the report.
=============================================================================
*/

USE AgriPulse;
GO

-- ===========================================================================
-- Row counts per layer
-- ===========================================================================
SELECT 'bronze.fao_yield' AS table_name, COUNT(*) AS n FROM bronze.fao_yield
UNION ALL SELECT 'bronze.wb_rainfall', COUNT(*) FROM bronze.wb_rainfall
UNION ALL SELECT 'bronze.wb_temperature', COUNT(*) FROM bronze.wb_temperature
UNION ALL SELECT 'bronze.fao_pesticides', COUNT(*) FROM bronze.fao_pesticides
UNION ALL SELECT 'silver.country', COUNT(*) FROM silver.country
UNION ALL SELECT 'silver.fao_yield', COUNT(*) FROM silver.fao_yield
UNION ALL SELECT 'silver.wb_rainfall', COUNT(*) FROM silver.wb_rainfall
UNION ALL SELECT 'silver.wb_temperature', COUNT(*) FROM silver.wb_temperature
UNION ALL SELECT 'silver.fao_pesticides', COUNT(*) FROM silver.fao_pesticides
UNION ALL SELECT 'silver.reject_log', COUNT(*) FROM silver.reject_log
UNION ALL SELECT 'gold.dim_country', COUNT(*) FROM gold.dim_country
UNION ALL SELECT 'gold.dim_crop', COUNT(*) FROM gold.dim_crop
UNION ALL SELECT 'gold.dim_year', COUNT(*) FROM gold.dim_year
UNION ALL SELECT 'gold.dim_climate_band', COUNT(*) FROM gold.dim_climate_band
UNION ALL SELECT 'gold.fact_crop_year', COUNT(*) FROM gold.fact_crop_year;

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

-- ===========================================================================
-- Profiling: known source issues (documented in docs/data_quality.md)
-- ===========================================================================

-- 1. The Kaggle rainfall file is a long-term average repeated every year:
--    count countries whose rainfall never changes.
SELECT
    COUNT(*)                                               AS countries,
    SUM(CASE WHEN n_distinct = 1 THEN 1 ELSE 0 END)        AS constant_rainfall,
    SUM(CASE WHEN n_distinct > 1 THEN 1 ELSE 0 END)        AS varying_rainfall
FROM (
    SELECT country_name, COUNT(DISTINCT rainfall_mm) AS n_distinct
    FROM silver.wb_rainfall
    WHERE is_imputed = 0
    GROUP BY country_name
) r;

-- 2. Share of fact rows with any rainfall deviation, and imputed rainfall
SELECT
    COUNT(*)                                                         AS fact_rows,
    SUM(CASE WHEN ABS(rain_dev_pct) > 0.01 THEN 1 ELSE 0 END)        AS rows_with_rain_deviation,
    SUM(CAST(rain_is_imputed AS INT))                                AS rows_with_imputed_rain
FROM gold.fact_crop_year;

-- 3. Yield countries (1990-2013) that drop out of Gold, and which source is missing
SELECT
    y.country_name,
    COUNT(*)                                                                   AS yield_rows,
    CASE WHEN NOT EXISTS (SELECT 1 FROM silver.wb_rainfall r WHERE r.country_name = y.country_name)
         THEN 'x' ELSE '' END                                                  AS no_rainfall,
    CASE WHEN NOT EXISTS (SELECT 1 FROM silver.wb_temperature t WHERE t.country_name = y.country_name)
         THEN 'x' ELSE '' END                                                  AS no_temperature,
    CASE WHEN NOT EXISTS (SELECT 1 FROM silver.fao_pesticides p WHERE p.country_name = y.country_name)
         THEN 'x' ELSE '' END                                                  AS no_pesticides
FROM silver.fao_yield y
WHERE y.year BETWEEN 1990 AND 2013
  AND y.country_name NOT IN (SELECT country_name FROM gold.dim_country)
GROUP BY y.country_name
ORDER BY yield_rows DESC;

-- 4. Rows rejected in Silver, by source and reason
SELECT source_table, reason, COUNT(*) AS rows_rejected
FROM silver.reject_log
GROUP BY source_table, reason
ORDER BY source_table, rows_rejected DESC;

-- 5. Shock rate (class balance of the label)
SELECT
    COUNT(*)                         AS fact_rows,
    SUM(CAST(is_shock AS INT))       AS shocks,
    AVG(CAST(is_shock AS FLOAT))     AS shock_rate
FROM gold.fact_crop_year;
GO
