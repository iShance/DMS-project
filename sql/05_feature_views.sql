/*
=============================================================================
AgriPulse - 05_feature_views.sql
=============================================================================
Feature views on the Gold star schema. Mining reads ONLY these documented views.

    gold.vw_ml_dataset    the star flattened into one table (EDA, notebooks,
                          src.mining.data.load_ml_dataset(source="sql"))
    gold.features_shock   keys + model features + label, read by the classifier
                          (python -m src.mining.score)
Run after 03_gold.sql.
=============================================================================
*/

USE AgriPulse;
GO

-- ---------------------------------------------------------------------------
-- Flat analytical view. GRAIN: one row per country x crop x year.
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- Feature view for shock classification.
-- GRAIN: one row per country x crop x year (= gold.fact_crop_year).
-- Every column is known before the harvest it predicts, except the label.
--   climate   rain_dev_pct, temp_anomaly_c, pesticide_intensity
--   context   rainfall_mm (aridity level), crop_name, region
--   history   prev_yield_dev_pct, prev_is_shock (last year's outcome)
--   label     is_shock
-- Feature sets A/B/C in src/mining/helpers.py are subsets of these columns.
-- ---------------------------------------------------------------------------
CREATE OR ALTER VIEW gold.features_shock AS
SELECT
    f.country_key,
    f.crop_key,
    f.year_key,
    c.country_name,
    cr.crop_name,
    c.region,
    f.year_key           AS year,
    f.rain_dev_pct,
    f.temp_anomaly_c,
    f.pesticide_intensity,
    f.rainfall_mm,
    f.prev_yield_dev_pct,
    f.prev_is_shock,
    f.is_shock
FROM gold.fact_crop_year f
JOIN gold.dim_country c ON c.country_key = f.country_key
JOIN gold.dim_crop cr   ON cr.crop_key = f.crop_key;
GO
