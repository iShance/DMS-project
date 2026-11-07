/*
=============================================================================
AgriPulse - 07_quality_checks.sql
=============================================================================
Data quality checks after a full load. Every query in the "expect 0 rows"
sections should return nothing; the profiling queries document known source
issues for the report.
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
UNION ALL SELECT 'gold.dim_country', COUNT(*) FROM gold.dim_country
UNION ALL SELECT 'gold.dim_crop', COUNT(*) FROM gold.dim_crop
UNION ALL SELECT 'gold.dim_year', COUNT(*) FROM gold.dim_year
UNION ALL SELECT 'gold.dim_climate_band', COUNT(*) FROM gold.dim_climate_band
UNION ALL SELECT 'gold.fact_crop_year', COUNT(*) FROM gold.fact_crop_year;

-- ===========================================================================
-- Silver: expect 0 rows
-- ===========================================================================

-- Yield countries that are missing from the country reference
SELECT DISTINCT y.country_name
FROM silver.fao_yield y
LEFT JOIN silver.country c ON c.country_name = y.country_name
WHERE c.country_name IS NULL;

-- Aliases that point to a name not in the reference
SELECT a.*
FROM silver.country_alias a
LEFT JOIN silver.country c ON c.country_name = a.country_name
WHERE c.country_name IS NULL;

-- Non-positive yields, or temperatures outside a physical range
SELECT * FROM silver.fao_yield WHERE yield_hg_ha <= 0;
SELECT * FROM silver.wb_temperature WHERE avg_temp_c NOT BETWEEN -30 AND 45;

-- ===========================================================================
-- Gold: expect 0 rows
-- ===========================================================================

-- Duplicate grain
SELECT country_key, crop_key, year_key, COUNT(*) AS n
FROM gold.fact_crop_year
GROUP BY country_key, crop_key, year_key
HAVING COUNT(*) > 1;

-- Orphan foreign keys
SELECT f.*
FROM gold.fact_crop_year f
LEFT JOIN gold.dim_country c ON c.country_key = f.country_key
LEFT JOIN gold.dim_crop cr ON cr.crop_key = f.crop_key
LEFT JOIN gold.dim_year y ON y.year_key = f.year_key
WHERE c.country_key IS NULL OR cr.crop_key IS NULL OR y.year_key IS NULL;

-- Facts without a climate band
SELECT * FROM gold.fact_crop_year WHERE climate_band_key IS NULL;

-- Label consistent with the deviation (threshold -15 %)
SELECT *
FROM gold.fact_crop_year
WHERE (is_shock = 1 AND yield_dev_pct > -15)
   OR (is_shock = 0 AND yield_dev_pct <= -15);

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

-- 4. Shock rate (class balance of the label)
SELECT
    COUNT(*)                         AS fact_rows,
    SUM(CAST(is_shock AS INT))       AS shocks,
    AVG(CAST(is_shock AS FLOAT))     AS shock_rate
FROM gold.fact_crop_year;
GO
