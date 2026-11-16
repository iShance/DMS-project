/*
=============================================================================
AgriPulse - demo_queries.sql
=============================================================================
Queries to run in SSMS during the presentation, one layer at a time.
Select a block with the mouse and press F5 (Execute) to run only that block.
The same queries are at the end of each layer report in docs/.
=============================================================================
*/

USE AgriPulse;
GO

-- ===========================================================================
-- BRONZE: the raw files, exactly as received
-- ===========================================================================

-- the raw yield file, every column is text
SELECT TOP 10 * FROM bronze.fao_yield;

-- 71,311 temperature records (several cities per country and year)
SELECT COUNT(*) AS row_count FROM bronze.wb_temperature;

-- every file load is logged
SELECT target_table, rows_loaded, status, end_time
FROM audit.load_log
WHERE procedure_name = 'bronze.load_bronze'
ORDER BY load_id DESC;

-- blank rainfall cells: 774
SELECT COUNT(*) AS blank_cells FROM bronze.wb_rainfall
WHERE NULLIF(TRIM(REPLACE(average_rain_fall_mm_per_year, CHAR(13), '')), '') IS NULL;

-- ===========================================================================
-- SILVER: cleaned, typed, one name per country, nothing lost silently
-- ===========================================================================

-- every rejected row, by reason (3,783 rows in total)
SELECT source_table, reason, COUNT(*) AS row_count
FROM silver.reject_log GROUP BY source_table, reason;

-- 1988 is missing from the rainfall file: filled with Egypt's average and flagged
SELECT * FROM silver.wb_rainfall
WHERE country_name = 'Egypt' AND year BETWEEN 1986 AND 1990;

-- the most city records averaged into one country-year
SELECT TOP 5 * FROM silver.wb_temperature ORDER BY n_records DESC;

-- 41 spellings mapped to one official country name
SELECT * FROM silver.country_alias;

-- ===========================================================================
-- GOLD: the star schema
-- ===========================================================================

-- the star flattened into one table
SELECT TOP 10 * FROM gold.vw_ml_dataset ORDER BY country_name, crop_name, year;

-- 16,339 crop-years and 1,667 shocks
SELECT COUNT(*) AS crop_years, SUM(CAST(is_shock AS INT)) AS shocks
FROM gold.fact_crop_year;

-- shock rate by region
SELECT c.region, 100.0 * AVG(CAST(f.is_shock AS FLOAT)) AS shock_rate_pct
FROM gold.fact_crop_year f
JOIN gold.dim_country c ON c.country_key = f.country_key
GROUP BY c.region ORDER BY shock_rate_pct DESC;

-- the worked example: Morocco, wheat, 2007 (a drought year)
SELECT country_name, crop_name, year, yield_hg_ha, baseline_yield_hg_ha, yield_dev_pct, is_shock
FROM gold.vw_ml_dataset
WHERE country_name = 'Morocco' AND crop_name = 'Wheat' AND year BETWEEN 2002 AND 2008
ORDER BY year;

-- more OLAP (ROLLUP, CUBE, PIVOT, slice, dice, drill-down): open sql/06_analytics.sql
-- all data-quality checks (each must return no rows): open src/quality/checks.sql
