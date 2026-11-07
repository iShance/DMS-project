/*
=============================================================================
AgriPulse - 08_olap_analysis.sql
=============================================================================
OLAP queries on the Gold star schema: roll-up, drill-down, slice, dice and
pivot of the shock rate by crop, region, decade and climate band.
=============================================================================
*/

USE AgriPulse;
GO

-- ---------------------------------------------------------------------------
-- Q1. Roll-up: region -> crop group -> crop  (GROUPING() labels the subtotals)
-- ---------------------------------------------------------------------------
SELECT
    CASE WHEN GROUPING(c.region) = 1 THEN '(All regions)' ELSE c.region END          AS region,
    CASE WHEN GROUPING(cr.crop_group) = 1 THEN '(All groups)' ELSE cr.crop_group END  AS crop_group,
    CASE WHEN GROUPING(cr.crop_name) = 1 THEN '(All crops)' ELSE cr.crop_name END     AS crop_name,
    COUNT(*)                                        AS crop_years,
    SUM(CAST(f.is_shock AS INT))                    AS shocks,
    CAST(100.0 * AVG(CAST(f.is_shock AS FLOAT)) AS DECIMAL(5,1)) AS shock_rate_pct
FROM gold.fact_crop_year f
JOIN gold.dim_country c ON c.country_key = f.country_key
JOIN gold.dim_crop cr   ON cr.crop_key = f.crop_key
GROUP BY ROLLUP (c.region, cr.crop_group, cr.crop_name)
ORDER BY GROUPING(c.region), c.region, GROUPING(cr.crop_group), cr.crop_group,
         GROUPING(cr.crop_name), cr.crop_name;

-- ---------------------------------------------------------------------------
-- Q2. Cube: crop group x decade, every combination of subtotals
-- ---------------------------------------------------------------------------
SELECT
    CASE WHEN GROUPING(cr.crop_group) = 1 THEN '(All)' ELSE cr.crop_group END AS crop_group,
    CASE WHEN GROUPING(y.decade) = 1 THEN '(All)' ELSE y.decade END           AS decade,
    COUNT(*)                                                   AS crop_years,
    CAST(100.0 * AVG(CAST(f.is_shock AS FLOAT)) AS DECIMAL(5,1)) AS shock_rate_pct,
    CAST(AVG(f.temp_anomaly_c) AS DECIMAL(5,2))                AS avg_temp_anomaly_c
FROM gold.fact_crop_year f
JOIN gold.dim_crop cr ON cr.crop_key = f.crop_key
JOIN gold.dim_year y  ON y.year_key = f.year_key
GROUP BY CUBE (cr.crop_group, y.decade)
ORDER BY GROUPING(cr.crop_group), cr.crop_group, GROUPING(y.decade), y.decade;

-- ---------------------------------------------------------------------------
-- Q3. Pivot: shock rate (%) per region and five-year period
-- ---------------------------------------------------------------------------
SELECT region, [1990-1994], [1995-1999], [2000-2004], [2005-2009], [2010-2014]
FROM (
    SELECT c.region, y.five_year_period, 100.0 * f.is_shock AS shock
    FROM gold.fact_crop_year f
    JOIN gold.dim_country c ON c.country_key = f.country_key
    JOIN gold.dim_year y    ON y.year_key = f.year_key
) src
PIVOT (AVG(shock) FOR five_year_period IN
       ([1990-1994], [1995-1999], [2000-2004], [2005-2009], [2010-2014])) p
ORDER BY region;

-- ---------------------------------------------------------------------------
-- Q4. Slice: climate band (country climate normal) vs. shock rate
-- ---------------------------------------------------------------------------
SELECT
    b.climate_band,
    COUNT(DISTINCT f.country_key)                              AS countries,
    COUNT(*)                                                   AS crop_years,
    CAST(100.0 * AVG(CAST(f.is_shock AS FLOAT)) AS DECIMAL(5,1)) AS shock_rate_pct,
    CAST(AVG(f.yield_dev_pct) AS DECIMAL(6,1))                 AS avg_yield_dev_pct
FROM gold.fact_crop_year f
JOIN gold.dim_climate_band b ON b.climate_band_key = f.climate_band_key
GROUP BY b.climate_band, b.climate_band_key
ORDER BY shock_rate_pct DESC;

-- ---------------------------------------------------------------------------
-- Q5. Dice: hot-anomaly years (> +1 C vs 1961-1990) for cereals in
--     Sub-Saharan Africa, compared with all other cereal-years there
-- ---------------------------------------------------------------------------
SELECT
    CASE WHEN f.temp_anomaly_c > 1 THEN 'anomaly > +1 C' ELSE 'anomaly <= +1 C' END AS temperature,
    COUNT(*)                                                   AS crop_years,
    CAST(100.0 * AVG(CAST(f.is_shock AS FLOAT)) AS DECIMAL(5,1)) AS shock_rate_pct
FROM gold.fact_crop_year f
JOIN gold.dim_country c ON c.country_key = f.country_key
JOIN gold.dim_crop cr   ON cr.crop_key = f.crop_key
WHERE c.region = 'Sub-Saharan Africa'
  AND cr.crop_group = 'Cereals'
GROUP BY CASE WHEN f.temp_anomaly_c > 1 THEN 'anomaly > +1 C' ELSE 'anomaly <= +1 C' END;

-- ---------------------------------------------------------------------------
-- Q6. Drill-down: the 15 most shock-prone country x crop series
--     (at least 15 observed years)
-- ---------------------------------------------------------------------------
SELECT TOP (15)
    c.country_name,
    cr.crop_name,
    COUNT(*)                                                   AS years,
    SUM(CAST(f.is_shock AS INT))                               AS shocks,
    CAST(100.0 * AVG(CAST(f.is_shock AS FLOAT)) AS DECIMAL(5,1)) AS shock_rate_pct,
    CAST(MIN(f.yield_dev_pct) AS DECIMAL(6,1))                 AS worst_dev_pct
FROM gold.fact_crop_year f
JOIN gold.dim_country c ON c.country_key = f.country_key
JOIN gold.dim_crop cr   ON cr.crop_key = f.crop_key
GROUP BY c.country_name, cr.crop_name
HAVING COUNT(*) >= 15
ORDER BY shock_rate_pct DESC, shocks DESC;

-- ---------------------------------------------------------------------------
-- Q7. Shock persistence: P(shock this year | shock last year)
-- ---------------------------------------------------------------------------
SELECT
    f.prev_is_shock,
    COUNT(*)                                                   AS crop_years,
    CAST(100.0 * AVG(CAST(f.is_shock AS FLOAT)) AS DECIMAL(5,1)) AS shock_rate_pct
FROM gold.fact_crop_year f
WHERE f.prev_is_shock IS NOT NULL
GROUP BY f.prev_is_shock;

-- ---------------------------------------------------------------------------
-- Q8. Worst global shock years: share of crop-years in shock, by year
-- ---------------------------------------------------------------------------
SELECT
    y.year,
    COUNT(*)                                                   AS crop_years,
    CAST(100.0 * AVG(CAST(f.is_shock AS FLOAT)) AS DECIMAL(5,1)) AS shock_rate_pct,
    CAST(AVG(f.temp_anomaly_c) AS DECIMAL(5,2))                AS avg_temp_anomaly_c
FROM gold.fact_crop_year f
JOIN gold.dim_year y ON y.year_key = f.year_key
GROUP BY y.year
ORDER BY y.year;
GO
