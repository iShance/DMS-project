/*
=============================================================================
AgriPulse - 04_semantic.sql
=============================================================================
Semantic layer: the metric catalog and one metric view per business question.
Everyone (notebooks, reports, a dashboard) reads these views instead of
rewriting the joins, so a metric means the same thing everywhere.

    semantic.metric_catalog              definitions, copied from semantic/metrics.yml
                                         by  python -m src.semantic.sync_metrics
                                         (which also runs every validation query)
    semantic.v_shock_rate_by_crop_region RQ3  do shocks differ by crop and region?
    semantic.v_shock_rate_by_climate     RQ2  which climate/input conditions go with shocks?
    semantic.v_shock_rate_by_year        trend: are shocks getting more or less frequent?
    semantic.v_shock_detection           RQ1  how well do the models detect shocks?
                                         (defined in sql/07_ml_outputs.sql, it reads ml.*)

All rates use the metric definitions in semantic/metrics.yml:
    shock_rate_pct = 100 * AVG(is_shock) over crop-years
=============================================================================
*/

USE AgriPulse;
GO

IF OBJECT_ID('semantic.metric_catalog', 'U') IS NOT NULL DROP TABLE semantic.metric_catalog;
GO
CREATE TABLE semantic.metric_catalog (
    metric_name        NVARCHAR(100)  NOT NULL PRIMARY KEY,
    label              NVARCHAR(200)  NOT NULL,
    definition         NVARCHAR(1000) NOT NULL,
    owner              NVARCHAR(100)  NOT NULL,
    grain              NVARCHAR(200)  NOT NULL,
    sql_expression     NVARCHAR(1000) NOT NULL,   -- evaluated over gold.fact_crop_year f
    dimensions         NVARCHAR(500)  NULL,
    null_policy        NVARCHAR(500)  NOT NULL,
    validation_query   NVARCHAR(MAX)  NOT NULL,   -- independent query, must give the same number
    metric_value       FLOAT          NULL,       -- filled by the last validation run
    validation_value   FLOAT          NULL,
    validation_status  NVARCHAR(10)   NULL,       -- PASS / FAIL
    validated_at       DATETIME2      NULL,
    dwh_create_date    DATETIME2      NOT NULL DEFAULT SYSDATETIME()
);
GO

-- ---------------------------------------------------------------------------
-- RQ3. Do shock rates differ by crop and region?
-- GRAIN: one row per region x crop.
-- ---------------------------------------------------------------------------
CREATE OR ALTER VIEW semantic.v_shock_rate_by_crop_region AS
SELECT
    c.region,
    cr.crop_group,
    cr.crop_name,
    COUNT(*)                                  AS crop_years,
    SUM(CAST(f.is_shock AS INT))              AS shocks,
    100.0 * AVG(CAST(f.is_shock AS FLOAT))    AS shock_rate_pct,
    AVG(f.yield_dev_pct)                      AS avg_yield_dev_pct
FROM gold.fact_crop_year f
JOIN gold.dim_country c ON c.country_key = f.country_key
JOIN gold.dim_crop cr   ON cr.crop_key = f.crop_key
GROUP BY c.region, cr.crop_group, cr.crop_name;
GO

-- ---------------------------------------------------------------------------
-- RQ2. Which climate and input conditions go with shocks?
-- GRAIN: one row per climate band (country temperature normal x rainfall
-- normal) x pesticide-use level.
-- Pesticide use: terciles of pesticide_intensity over all crop-years, the same
-- cut points as the association rules (src.mining.helpers.transactions):
-- low < 1st tercile <= medium < 2nd tercile <= high.
-- ---------------------------------------------------------------------------
CREATE OR ALTER VIEW semantic.v_shock_rate_by_climate AS
WITH cuts AS (
    SELECT DISTINCT
        PERCENTILE_CONT(1.0 / 3) WITHIN GROUP (ORDER BY pesticide_intensity) OVER () AS q1,
        PERCENTILE_CONT(2.0 / 3) WITHIN GROUP (ORDER BY pesticide_intensity) OVER () AS q2
    FROM gold.fact_crop_year
),
banded AS (
    SELECT
        f.*,
        CASE WHEN f.pesticide_intensity < q.q1 THEN 1
             WHEN f.pesticide_intensity < q.q2 THEN 2
             ELSE 3 END AS pesticide_tercile
    FROM gold.fact_crop_year f
    CROSS JOIN cuts q
)
SELECT
    b.climate_band,
    b.temp_band,
    b.rain_band,
    CASE f.pesticide_tercile WHEN 1 THEN 'low' WHEN 2 THEN 'medium' ELSE 'high' END AS pesticide_use,
    COUNT(DISTINCT f.country_key)             AS countries,
    COUNT(*)                                  AS crop_years,
    SUM(CAST(f.is_shock AS INT))              AS shocks,
    100.0 * AVG(CAST(f.is_shock AS FLOAT))    AS shock_rate_pct,
    AVG(f.temp_anomaly_c)                     AS avg_temp_anomaly_c,
    AVG(f.pesticide_intensity)                AS avg_pesticide_intensity
FROM banded f
JOIN gold.dim_climate_band b ON b.climate_band_key = f.climate_band_key
GROUP BY b.climate_band, b.temp_band, b.rain_band, f.pesticide_tercile;
GO

-- ---------------------------------------------------------------------------
-- Trend. Are shocks getting more or less frequent, and how warm was each year?
-- GRAIN: one row per year.
-- ---------------------------------------------------------------------------
CREATE OR ALTER VIEW semantic.v_shock_rate_by_year AS
SELECT
    y.year,
    y.decade,
    COUNT(*)                                                       AS crop_years,
    SUM(CAST(f.is_shock AS INT))                                   AS shocks,
    100.0 * AVG(CAST(f.is_shock AS FLOAT))                         AS shock_rate_pct,
    AVG(f.temp_anomaly_c)                                          AS avg_temp_anomaly_c,
    100.0 * AVG(CAST(CASE WHEN f.temp_anomaly_c > 1 THEN 1 ELSE 0 END AS FLOAT)) AS hot_year_share_pct
FROM gold.fact_crop_year f
JOIN gold.dim_year y ON y.year_key = f.year_key
GROUP BY y.year, y.decade;
GO
