/*
=============================================================================
AgriPulse - src/quality/profiling.sql
=============================================================================
Profiling after a full load: row counts per layer and the known source
issues documented in docs/data_quality.md and the layer reports in docs/.
These queries return rows on purpose; the zero-row checks are in checks.sql.
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
