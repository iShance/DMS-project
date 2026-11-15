/*
=============================================================================
AgriPulse - 10_ml_outputs.sql
=============================================================================
Model outputs written back to SQL Server (SQL -> Python -> SQL).

    gold.features_shock  --read-->  python -m agripulse.score  --write-->  ml.*

    ml.model_run          one row per model per scoring run: version, features,
                          threshold and test metrics
    ml.shock_prediction   one row per model x scored crop-year: probability
                          (score) and predicted label, keyed on the Gold star
                          schema keys
    semantic.v_shock_detection   RQ1: how many shocks each model catches and
                          how many false alarms it raises, from the stored
                          predictions joined to the actual labels

Tables are created only if missing, so earlier runs are kept; each run has its
own run_id. Predictions refer to Gold surrogate keys, which are stable for a
given Silver load: re-run the scoring after reloading Gold from new data.
=============================================================================
*/

USE AgriPulse;
GO

IF OBJECT_ID('ml.model_run', 'U') IS NULL
CREATE TABLE ml.model_run (
    run_id          UNIQUEIDENTIFIER NOT NULL,
    model_name      NVARCHAR(100)    NOT NULL,
    model_version   NVARCHAR(20)     NOT NULL,
    model_role      NVARCHAR(20)     NOT NULL,   -- baseline / improved
    feature_view    NVARCHAR(200)    NOT NULL,   -- where the features were read from
    features        NVARCHAR(1000)   NOT NULL,
    train_years     NVARCHAR(20)     NOT NULL,
    test_years      NVARCHAR(20)     NOT NULL,
    threshold       FLOAT            NOT NULL,   -- chosen on CV predictions, never on test years
    cv_roc_auc      FLOAT            NULL,       -- NULL for the rule baseline (nothing to fit)
    test_roc_auc    FLOAT            NOT NULL,
    test_pr_auc     FLOAT            NOT NULL,
    test_precision  FLOAT            NOT NULL,
    test_recall     FLOAT            NOT NULL,
    test_f1         FLOAT            NOT NULL,
    generated_at    DATETIME2        NOT NULL,
    CONSTRAINT pk_ml_model_run PRIMARY KEY (run_id, model_name)
);
GO

IF OBJECT_ID('ml.shock_prediction', 'U') IS NULL
CREATE TABLE ml.shock_prediction (
    run_id             UNIQUEIDENTIFIER NOT NULL,
    model_name         NVARCHAR(100)    NOT NULL,
    model_version      NVARCHAR(20)     NOT NULL,
    country_key        INT              NOT NULL,   -- -> gold.dim_country
    crop_key           INT              NOT NULL,   -- -> gold.dim_crop
    year_key           INT              NOT NULL,   -- -> gold.dim_year
    shock_probability  FLOAT            NOT NULL,   -- score in [0, 1]
    predicted_shock    TINYINT          NOT NULL,   -- 1 if shock_probability >= the run's threshold
    generated_at       DATETIME2        NOT NULL,
    CONSTRAINT pk_ml_shock_prediction PRIMARY KEY (run_id, model_name, country_key, crop_key, year_key)
);
GO

-- ---------------------------------------------------------------------------
-- RQ1. Can shocks be detected in advance? Detection and false-alarm rates of
-- every stored model run, recomputed in SQL from the predictions.
-- GRAIN: one row per run x model.
-- ---------------------------------------------------------------------------
CREATE OR ALTER VIEW semantic.v_shock_detection AS
WITH counts AS (
    SELECT
        p.run_id,
        p.model_name,
        COUNT(*)                                                             AS scored_crop_years,
        SUM(CAST(f.is_shock AS INT))                                         AS actual_shocks,
        SUM(CAST(p.predicted_shock AS INT))                                  AS predicted_shocks,
        SUM(CASE WHEN p.predicted_shock = 1 AND f.is_shock = 1 THEN 1 ELSE 0 END) AS true_alarms,
        SUM(CASE WHEN p.predicted_shock = 1 AND f.is_shock = 0 THEN 1 ELSE 0 END) AS false_alarms,
        MIN(p.year_key)                                                      AS first_year,
        MAX(p.year_key)                                                      AS last_year
    FROM ml.shock_prediction p
    JOIN gold.fact_crop_year f
        ON  f.country_key = p.country_key
        AND f.crop_key    = p.crop_key
        AND f.year_key    = p.year_key
    GROUP BY p.run_id, p.model_name
)
SELECT
    r.run_id,
    r.generated_at,
    CASE WHEN r.run_id = (SELECT TOP 1 run_id FROM ml.model_run ORDER BY generated_at DESC)
         THEN 1 ELSE 0 END                                                   AS is_latest_run,
    r.model_name,
    r.model_version,
    r.model_role,
    r.threshold,
    c.first_year,
    c.last_year,
    c.scored_crop_years,
    c.actual_shocks,
    c.predicted_shocks,
    c.true_alarms,
    c.false_alarms,
    100.0 * c.true_alarms  / NULLIF(c.actual_shocks, 0)                      AS detection_rate_pct,
    100.0 * c.true_alarms  / NULLIF(c.predicted_shocks, 0)                   AS precision_pct,
    100.0 * c.false_alarms / NULLIF(c.scored_crop_years - c.actual_shocks, 0) AS false_alarm_rate_pct,
    r.test_roc_auc,
    r.test_pr_auc
FROM counts c
JOIN ml.model_run r ON r.run_id = c.run_id AND r.model_name = c.model_name;
GO
