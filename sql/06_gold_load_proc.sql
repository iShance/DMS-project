/*
=============================================================================
AgriPulse - 06_gold_load_proc.sql
=============================================================================
Stored procedure gold.load_gold

Builds the star schema from Silver (full refresh).

Feature engineering
    yield history   Each country x crop series is densified to one row per
                    calendar year (gap years = NULL) so that window functions
                    work in calendar years, not rows:
                      prev_yield_hg_ha     = LAG(yield)
                      yoy_change_pct       = yield / prev_yield - 1
                      baseline_yield_hg_ha = AVG(yield) over the 5 previous
                                             years (needs >= @min_baseline_years)
                      yield_dev_pct        = yield / baseline - 1
                      is_shock             = yield_dev_pct <= @shock_threshold_pct
                      prev_yield_dev_pct, prev_is_shock = LAG of the two above
                    The history starts in 1961, so 1990 rows have a baseline.
    rainfall        rain_dev_pct   = rainfall / country long-term mean - 1
    temperature     temp_anomaly_c = avg_temp - country mean of 1961-1990
                    (WMO normal period, before the analysis window)
    pesticides      pesticide_intensity = LOG10(1 + tonnes)
                    pesticide_yoy_pct   = tonnes / LAG(tonnes) - 1
    climate band    country temperature normal x rainfall normal

A fact row is kept only when the yield label and all four sources exist.
Each Gold table writes one row to audit.load_log.

Usage
    EXEC gold.load_gold;                                  -- defaults
    EXEC gold.load_gold @shock_threshold_pct = -20.0;     -- stricter shocks
=============================================================================
*/

USE AgriPulse;
GO

CREATE OR ALTER PROCEDURE gold.load_gold
    @shock_threshold_pct FLOAT = -15.0,
    @min_baseline_years  INT   = 3,
    @start_year          INT   = 1990,
    @end_year            INT   = 2013
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @batch_id UNIQUEIDENTIFIER = NEWID();
    DECLARE @start_time DATETIME2, @batch_start DATETIME2, @rows BIGINT, @target NVARCHAR(200);
    DECLARE @min_year INT, @max_year INT;

    BEGIN TRY
        SET @batch_start = SYSDATETIME();
        PRINT '================================================';
        PRINT 'Loading Gold layer';
        PRINT '================================================';

        ---------------------------------------------------------------
        -- 1. Climate normals
        ---------------------------------------------------------------
        DROP TABLE IF EXISTS #temp_normal, #rain_normal, #yield_features, #pest_features, #stage;

        SELECT country_name, AVG(avg_temp_c) AS temp_normal_c
        INTO #temp_normal
        FROM silver.wb_temperature
        WHERE year BETWEEN 1961 AND 1990
        GROUP BY country_name
        HAVING COUNT(*) >= 20;

        SELECT country_name, AVG(rainfall_mm) AS rainfall_normal_mm
        INTO #rain_normal
        FROM silver.wb_rainfall
        WHERE is_imputed = 0
        GROUP BY country_name;

        ---------------------------------------------------------------
        -- 2. Yield history features (densified series + window functions)
        ---------------------------------------------------------------
        SET @start_time = SYSDATETIME();
        SELECT @min_year = MIN(year), @max_year = MAX(year) FROM silver.fao_yield;

        WITH spans AS (
            SELECT country_name, crop_name, MIN(year) AS first_year, MAX(year) AS last_year
            FROM silver.fao_yield
            GROUP BY country_name, crop_name
        ),
        calendar AS (
            SELECT TOP (@max_year - @min_year + 1)
                @min_year - 1 + ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS year
            FROM sys.all_objects
        ),
        dense AS (
            SELECT
                s.country_name,
                s.crop_name,
                c.year,
                CAST(y.yield_hg_ha AS FLOAT) AS yield_hg_ha
            FROM spans s
            JOIN calendar c
                ON c.year BETWEEN s.first_year AND s.last_year
            LEFT JOIN silver.fao_yield y
                ON  y.country_name = s.country_name
                AND y.crop_name    = s.crop_name
                AND y.year         = c.year
        ),
        w1 AS (
            SELECT
                *,
                LAG(yield_hg_ha) OVER (
                    PARTITION BY country_name, crop_name ORDER BY year) AS prev_yield_hg_ha,
                AVG(yield_hg_ha) OVER (
                    PARTITION BY country_name, crop_name ORDER BY year
                    ROWS BETWEEN 5 PRECEDING AND 1 PRECEDING)          AS baseline_raw,
                COUNT(yield_hg_ha) OVER (
                    PARTITION BY country_name, crop_name ORDER BY year
                    ROWS BETWEEN 5 PRECEDING AND 1 PRECEDING)          AS baseline_n_years
            FROM dense
        ),
        w2 AS (
            SELECT
                *,
                CASE WHEN baseline_n_years >= @min_baseline_years THEN baseline_raw END AS baseline_yield_hg_ha
            FROM w1
        ),
        w3 AS (
            SELECT
                *,
                (yield_hg_ha / NULLIF(prev_yield_hg_ha, 0) - 1) * 100      AS yoy_change_pct,
                (yield_hg_ha / NULLIF(baseline_yield_hg_ha, 0) - 1) * 100  AS yield_dev_pct
            FROM w2
        ),
        w4 AS (
            SELECT
                *,
                CASE
                    WHEN yield_dev_pct IS NULL                 THEN NULL
                    WHEN yield_dev_pct <= @shock_threshold_pct THEN 1
                    ELSE 0
                END AS is_shock
            FROM w3
        ),
        w5 AS (
            SELECT
                *,
                LAG(yield_dev_pct) OVER (PARTITION BY country_name, crop_name ORDER BY year) AS prev_yield_dev_pct,
                LAG(is_shock)      OVER (PARTITION BY country_name, crop_name ORDER BY year) AS prev_is_shock
            FROM w4
        )
        SELECT
            country_name, crop_name, year,
            yield_hg_ha, prev_yield_hg_ha, yoy_change_pct,
            baseline_yield_hg_ha, baseline_n_years, yield_dev_pct, is_shock,
            prev_yield_dev_pct, prev_is_shock
        INTO #yield_features
        FROM w5
        WHERE yield_hg_ha IS NOT NULL;

        PRINT '>> yield features: ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows ('
            + CAST(DATEDIFF(MILLISECOND, @start_time, SYSDATETIME()) AS NVARCHAR(20)) + ' ms)';

        ---------------------------------------------------------------
        -- 3. Pesticide features
        ---------------------------------------------------------------
        WITH lagged AS (
            SELECT
                country_name,
                year,
                pesticides_tonnes,
                LAG(year)              OVER (PARTITION BY country_name ORDER BY year) AS prev_year,
                LAG(pesticides_tonnes) OVER (PARTITION BY country_name ORDER BY year) AS prev_tonnes
            FROM silver.fao_pesticides
        )
        SELECT
            country_name,
            year,
            pesticides_tonnes,
            LOG10(1 + pesticides_tonnes) AS pesticide_intensity,
            CASE
                WHEN year - prev_year = 1 AND prev_tonnes > 0
                THEN (pesticides_tonnes / prev_tonnes - 1) * 100
            END AS pesticide_yoy_pct
        INTO #pest_features
        FROM lagged;

        ---------------------------------------------------------------
        -- 4. Integrate the four sources (inner joins = complete rows only)
        ---------------------------------------------------------------
        SELECT
            yf.*,
            r.rainfall_mm,
            r.is_imputed                                        AS rain_is_imputed,
            rn.rainfall_normal_mm,
            CASE WHEN rn.rainfall_normal_mm > 0
                 THEN (r.rainfall_mm / rn.rainfall_normal_mm - 1) * 100
            END                                                 AS rain_dev_pct,
            t.avg_temp_c,
            tn.temp_normal_c,
            t.avg_temp_c - tn.temp_normal_c                     AS temp_anomaly_c,
            p.pesticides_tonnes,
            p.pesticide_intensity,
            p.pesticide_yoy_pct
        INTO #stage
        FROM #yield_features yf
        JOIN silver.country c         ON c.country_name = yf.country_name
        JOIN silver.wb_rainfall r     ON r.country_name = yf.country_name AND r.year = yf.year
        JOIN #rain_normal rn          ON rn.country_name = yf.country_name
        JOIN silver.wb_temperature t  ON t.country_name = yf.country_name AND t.year = yf.year
        JOIN #temp_normal tn          ON tn.country_name = yf.country_name
        JOIN #pest_features p         ON p.country_name = yf.country_name AND p.year = yf.year
        WHERE yf.year BETWEEN @start_year AND @end_year
          AND yf.is_shock IS NOT NULL;

        ---------------------------------------------------------------
        -- 5. Dimensions
        ---------------------------------------------------------------
        SET @start_time = SYSDATETIME();
        TRUNCATE TABLE gold.fact_crop_year;
        TRUNCATE TABLE gold.dim_country;
        TRUNCATE TABLE gold.dim_crop;
        TRUNCATE TABLE gold.dim_year;
        TRUNCATE TABLE gold.dim_climate_band;

        INSERT INTO gold.dim_country (country_key, country_name, iso3, region, temp_normal_c, rainfall_normal_mm)
        SELECT
            ROW_NUMBER() OVER (ORDER BY c.country_name),
            c.country_name,
            c.iso3,
            c.region,
            tn.temp_normal_c,
            rn.rainfall_normal_mm
        FROM silver.country c
        LEFT JOIN #temp_normal tn ON tn.country_name = c.country_name
        LEFT JOIN #rain_normal rn ON rn.country_name = c.country_name
        WHERE c.country_name IN (SELECT country_name FROM #stage);
        SET @rows = @@ROWCOUNT;
        INSERT INTO audit.load_log (batch_id, procedure_name, source_name, target_table,
                                    start_time, end_time, rows_loaded, status)
        VALUES (@batch_id, 'gold.load_gold', 'silver.country, #stage', 'gold.dim_country',
                @start_time, SYSDATETIME(), @rows, 'SUCCESS');
        PRINT '>> gold.dim_country: ' + CAST(@rows AS NVARCHAR(20)) + ' rows';

        INSERT INTO gold.dim_crop (crop_key, crop_name, fao_item_code, crop_group)
        SELECT
            ROW_NUMBER() OVER (ORDER BY crop_name),
            crop_name,
            fao_item_code,
            crop_group
        FROM (
            SELECT DISTINCT y.crop_name, y.fao_item_code, y.crop_group
            FROM silver.fao_yield y
            WHERE y.crop_name IN (SELECT crop_name FROM #stage)
        ) crops;
        SET @rows = @@ROWCOUNT;
        INSERT INTO audit.load_log (batch_id, procedure_name, source_name, target_table,
                                    start_time, end_time, rows_loaded, status)
        VALUES (@batch_id, 'gold.load_gold', 'silver.fao_yield, #stage', 'gold.dim_crop',
                @start_time, SYSDATETIME(), @rows, 'SUCCESS');
        PRINT '>> gold.dim_crop: ' + CAST(@rows AS NVARCHAR(20)) + ' rows';

        INSERT INTO gold.dim_year (year_key, year, decade, five_year_period)
        SELECT
            year,
            year,
            CAST(year / 10 * 10 AS NVARCHAR(4)) + 's',
            CAST(year / 5 * 5 AS NVARCHAR(4)) + '-' + CAST(year / 5 * 5 + 4 AS NVARCHAR(4))
        FROM (
            SELECT TOP (@end_year - @start_year + 1)
                @start_year - 1 + ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS year
            FROM sys.all_objects
        ) yrs;
        SET @rows = @@ROWCOUNT;
        INSERT INTO audit.load_log (batch_id, procedure_name, source_name, target_table,
                                    start_time, end_time, rows_loaded, status)
        VALUES (@batch_id, 'gold.load_gold', 'generated calendar years', 'gold.dim_year',
                @start_time, SYSDATETIME(), @rows, 'SUCCESS');
        PRINT '>> gold.dim_year: ' + CAST(@rows AS NVARCHAR(20)) + ' rows';

        INSERT INTO gold.dim_climate_band (
            climate_band_key, climate_band, temp_band, rain_band,
            temp_min_c, temp_max_c, rain_min_mm, rain_max_mm
        )
        SELECT
            ROW_NUMBER() OVER (ORDER BY t.ord, r.ord),
            t.label + ' / ' + r.label,
            t.label,
            r.label,
            t.lo, t.hi, r.lo, r.hi
        FROM (VALUES
            (1, 'Cold',      -100.0,  10.0),
            (2, 'Temperate',   10.0,  20.0),
            (3, 'Warm',        20.0,  25.0),
            (4, 'Hot',         25.0, 100.0)
        ) t (ord, label, lo, hi)
        CROSS JOIN (VALUES
            (1, 'Arid',           0.0,    250.0),
            (2, 'Semi-arid',    250.0,    500.0),
            (3, 'Sub-humid',    500.0,   1000.0),
            (4, 'Humid',       1000.0,   2000.0),
            (5, 'Very humid',  2000.0, 100000.0)
        ) r (ord, label, lo, hi);
        SET @rows = @@ROWCOUNT;
        INSERT INTO audit.load_log (batch_id, procedure_name, source_name, target_table,
                                    start_time, end_time, rows_loaded, status)
        VALUES (@batch_id, 'gold.load_gold', 'band definitions (static)', 'gold.dim_climate_band',
                @start_time, SYSDATETIME(), @rows, 'SUCCESS');
        PRINT '>> gold.dim_climate_band: ' + CAST(@rows AS NVARCHAR(20)) + ' rows';

        ---------------------------------------------------------------
        -- 6. Fact
        ---------------------------------------------------------------
        SET @start_time = SYSDATETIME();
        INSERT INTO gold.fact_crop_year (
            country_key, crop_key, year_key, climate_band_key,
            yield_hg_ha, prev_yield_hg_ha, yoy_change_pct,
            baseline_yield_hg_ha, baseline_n_years, yield_dev_pct, is_shock,
            prev_yield_dev_pct, prev_is_shock,
            rainfall_mm, rain_dev_pct, rain_is_imputed,
            avg_temp_c, temp_anomaly_c,
            pesticides_tonnes, pesticide_intensity, pesticide_yoy_pct
        )
        SELECT
            dc.country_key,
            dr.crop_key,
            dy.year_key,
            b.climate_band_key,
            s.yield_hg_ha, s.prev_yield_hg_ha, s.yoy_change_pct,
            s.baseline_yield_hg_ha, s.baseline_n_years, s.yield_dev_pct, s.is_shock,
            s.prev_yield_dev_pct, s.prev_is_shock,
            s.rainfall_mm, s.rain_dev_pct, s.rain_is_imputed,
            s.avg_temp_c, s.temp_anomaly_c,
            s.pesticides_tonnes, s.pesticide_intensity, s.pesticide_yoy_pct
        FROM #stage s
        JOIN gold.dim_country dc ON dc.country_name = s.country_name
        JOIN gold.dim_crop dr    ON dr.crop_name = s.crop_name
        JOIN gold.dim_year dy    ON dy.year = s.year
        LEFT JOIN gold.dim_climate_band b
            ON  s.temp_normal_c      >= b.temp_min_c  AND s.temp_normal_c      < b.temp_max_c
            AND s.rainfall_normal_mm >= b.rain_min_mm AND s.rainfall_normal_mm < b.rain_max_mm;
        SET @rows = @@ROWCOUNT;
        INSERT INTO audit.load_log (batch_id, procedure_name, source_name, target_table,
                                    start_time, end_time, rows_loaded, status, message)
        VALUES (@batch_id, 'gold.load_gold', 'silver.* (yield, rainfall, temperature, pesticides)',
                'gold.fact_crop_year', @start_time, SYSDATETIME(), @rows, 'SUCCESS',
                CONCAT('shock threshold ', @shock_threshold_pct, ' %, years ', @start_year, '-', @end_year));
        PRINT '>> gold.fact_crop_year: ' + CAST(@rows AS NVARCHAR(20)) + ' rows ('
            + CAST(DATEDIFF(MILLISECOND, @start_time, SYSDATETIME()) AS NVARCHAR(20)) + ' ms)';

        PRINT '================================================';
        PRINT 'Gold load completed in '
            + CAST(DATEDIFF(SECOND, @batch_start, SYSDATETIME()) AS NVARCHAR(20)) + ' s';
        PRINT '================================================';
    END TRY
    BEGIN CATCH
        INSERT INTO audit.load_log (batch_id, procedure_name, source_name, target_table,
                                    start_time, end_time, status, message)
        VALUES (@batch_id, 'gold.load_gold', 'silver.*', 'gold.*',
                ISNULL(@start_time, SYSDATETIME()), SYSDATETIME(), 'FAILED', ERROR_MESSAGE());
        PRINT '================================================';
        PRINT 'ERROR while loading Gold layer';
        PRINT 'Message: ' + ERROR_MESSAGE();
        PRINT 'Number : ' + CAST(ERROR_NUMBER() AS NVARCHAR(20));
        PRINT '================================================';
        THROW;
    END CATCH;
END;
GO
