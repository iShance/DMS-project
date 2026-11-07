/*
=============================================================================
AgriPulse - 05_gold_ddl.sql
=============================================================================
Gold layer: star schema at the grain  country x crop x year  (1990-2013).

                         gold.dim_year
                               |
    gold.dim_country --- gold.fact_crop_year --- gold.dim_crop
                               |
                      gold.dim_climate_band

gold.vw_ml_dataset flattens the star into one table for data mining.

Surrogate keys are assigned by gold.load_gold (ROW_NUMBER over the natural
key), so they are stable for a given Silver load. Foreign keys are not
declared, so every table can be TRUNCATEd on reload; referential integrity is
verified by sql/07_quality_checks.sql instead.
=============================================================================
*/

USE AgriPulse;
GO

IF OBJECT_ID('gold.fact_crop_year', 'U') IS NOT NULL DROP TABLE gold.fact_crop_year;
IF OBJECT_ID('gold.dim_country', 'U') IS NOT NULL DROP TABLE gold.dim_country;
IF OBJECT_ID('gold.dim_crop', 'U') IS NOT NULL DROP TABLE gold.dim_crop;
IF OBJECT_ID('gold.dim_year', 'U') IS NOT NULL DROP TABLE gold.dim_year;
IF OBJECT_ID('gold.dim_climate_band', 'U') IS NOT NULL DROP TABLE gold.dim_climate_band;
GO

CREATE TABLE gold.dim_country (
    country_key         INT           NOT NULL PRIMARY KEY,
    country_name        NVARCHAR(100) NOT NULL,
    iso3                NVARCHAR(10),
    region              NVARCHAR(50),
    temp_normal_c       FLOAT,        -- mean annual temperature 1961-1990
    rainfall_normal_mm  FLOAT         -- long-term mean annual rainfall
);
GO

CREATE TABLE gold.dim_crop (
    crop_key       INT           NOT NULL PRIMARY KEY,
    crop_name      NVARCHAR(100) NOT NULL,
    fao_item_code  INT           NOT NULL,
    crop_group     NVARCHAR(30)  NOT NULL
);
GO

CREATE TABLE gold.dim_year (
    year_key          INT          NOT NULL PRIMARY KEY,   -- = calendar year
    year              INT          NOT NULL,
    decade            NVARCHAR(10) NOT NULL,               -- e.g. '1990s'
    five_year_period  NVARCHAR(10) NOT NULL                -- e.g. '1990-1994'
);
GO

CREATE TABLE gold.dim_climate_band (
    climate_band_key  INT          NOT NULL PRIMARY KEY,
    climate_band      NVARCHAR(40) NOT NULL,   -- e.g. 'Hot / Semi-arid'
    temp_band         NVARCHAR(20) NOT NULL,
    rain_band         NVARCHAR(20) NOT NULL,
    temp_min_c        FLOAT        NOT NULL,   -- inclusive
    temp_max_c        FLOAT        NOT NULL,   -- exclusive
    rain_min_mm       FLOAT        NOT NULL,   -- inclusive
    rain_max_mm       FLOAT        NOT NULL    -- exclusive
);
GO

CREATE TABLE gold.fact_crop_year (
    country_key           INT     NOT NULL,
    crop_key              INT     NOT NULL,
    year_key              INT     NOT NULL,
    climate_band_key      INT,
    -- yield measures (hg/ha)
    yield_hg_ha           FLOAT   NOT NULL,
    prev_yield_hg_ha      FLOAT,            -- LAG 1 year
    yoy_change_pct        FLOAT,            -- year-over-year change
    baseline_yield_hg_ha  FLOAT   NOT NULL, -- mean of previous 5 years
    baseline_n_years      INT     NOT NULL, -- years present in that window
    yield_dev_pct         FLOAT   NOT NULL, -- % deviation from baseline
    is_shock              TINYINT NOT NULL, -- 1 = yield_dev_pct <= threshold
    prev_yield_dev_pct    FLOAT,            -- last year's deviation (known in advance)
    prev_is_shock         TINYINT,          -- last year's label (known in advance)
    -- climate and input features
    rainfall_mm           FLOAT   NOT NULL,
    rain_dev_pct          FLOAT,            -- % deviation from country long-term mean
    rain_is_imputed       TINYINT NOT NULL,
    avg_temp_c            FLOAT   NOT NULL,
    temp_anomaly_c        FLOAT   NOT NULL, -- vs 1961-1990 normal
    pesticides_tonnes     FLOAT   NOT NULL,
    pesticide_intensity   FLOAT   NOT NULL, -- LOG10(1 + tonnes)
    pesticide_yoy_pct     FLOAT,
    CONSTRAINT pk_gold_fact_crop_year PRIMARY KEY (country_key, crop_key, year_key)
);
GO

CREATE OR ALTER VIEW gold.vw_ml_dataset AS
SELECT
    c.country_name,
    c.iso3,
    c.region,
    cr.crop_name,
    cr.crop_group,
    y.year,
    y.decade,
    b.climate_band,
    b.temp_band,
    b.rain_band,
    f.yield_hg_ha,
    f.prev_yield_hg_ha,
    f.yoy_change_pct,
    f.baseline_yield_hg_ha,
    f.yield_dev_pct,
    f.is_shock,
    f.prev_yield_dev_pct,
    f.prev_is_shock,
    f.rainfall_mm,
    f.rain_dev_pct,
    f.rain_is_imputed,
    f.avg_temp_c,
    f.temp_anomaly_c,
    f.pesticides_tonnes,
    f.pesticide_intensity,
    f.pesticide_yoy_pct
FROM gold.fact_crop_year f
JOIN gold.dim_country c       ON c.country_key = f.country_key
JOIN gold.dim_crop cr         ON cr.crop_key = f.crop_key
JOIN gold.dim_year y          ON y.year_key = f.year_key
LEFT JOIN gold.dim_climate_band b ON b.climate_band_key = f.climate_band_key;
GO
