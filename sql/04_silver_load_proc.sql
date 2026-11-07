/*
=============================================================================
AgriPulse - 04_silver_load_proc.sql
=============================================================================
Stored procedure silver.load_silver

Full refresh Bronze -> Silver. For every table: TRUNCATE, then INSERT the
cleaned rows. Cleaning rules (the pandas mirror is src/agripulse/pipeline.py):

    all text      TRIM, and CHAR(13) removed from the last CSV column
    numbers       TRY_CAST(NULLIF(TRIM(x), '')): blanks, '..' and 'NA' -> NULL
    countries     source spelling mapped through silver.country_alias,
                  unmapped names kept as written
    fao_yield     only Element = 'Yield' and Unit = 'hg/ha'; FAO area 351
                  ("China" aggregate = mainland + HK + Macao + Taiwan) dropped
                  to avoid double counting; yield <= 0 treated as missing;
                  one row per country x crop x year (lowest FAO area code wins)
    wb_rainfall   complete country x year grid 1985-2017; missing years
                  (blank cells, and 1988/2003 which are absent from the file)
                  filled with the country mean and flagged is_imputed = 1
    temperature   several city records per country-year -> averaged
    pesticides    only Use / Pesticides (total); negative values dropped

Usage
    EXEC silver.load_silver;
=============================================================================
*/

USE AgriPulse;
GO

CREATE OR ALTER PROCEDURE silver.load_silver
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @start_time DATETIME2, @batch_start DATETIME2;

    BEGIN TRY
        SET @batch_start = SYSDATETIME();
        PRINT '================================================';
        PRINT 'Loading Silver layer';
        PRINT '================================================';

        ---------------------------------------------------------------
        -- silver.country
        ---------------------------------------------------------------
        SET @start_time = SYSDATETIME();
        TRUNCATE TABLE silver.country;
        INSERT INTO silver.country (country_name, iso3, region)
        SELECT country_name, iso3, region
        FROM (
            SELECT
                TRIM(country_name)                                AS country_name,
                UPPER(TRIM(iso3))                                 AS iso3,
                NULLIF(TRIM(REPLACE(region, CHAR(13), '')), '')   AS region,
                ROW_NUMBER() OVER (PARTITION BY TRIM(country_name) ORDER BY (SELECT NULL)) AS rn
            FROM bronze.ref_country
            WHERE NULLIF(TRIM(country_name), '') IS NOT NULL
        ) t
        WHERE rn = 1;
        PRINT '>> silver.country: ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows ('
            + CAST(DATEDIFF(MILLISECOND, @start_time, SYSDATETIME()) AS NVARCHAR(20)) + ' ms)';

        ---------------------------------------------------------------
        -- silver.country_alias
        ---------------------------------------------------------------
        SET @start_time = SYSDATETIME();
        TRUNCATE TABLE silver.country_alias;
        INSERT INTO silver.country_alias (source_name, country_name)
        SELECT source_name, country_name
        FROM (
            SELECT
                TRIM(source_name)                          AS source_name,
                TRIM(REPLACE(country_name, CHAR(13), ''))  AS country_name,
                ROW_NUMBER() OVER (PARTITION BY TRIM(source_name) ORDER BY (SELECT NULL)) AS rn
            FROM bronze.ref_country_alias
            WHERE NULLIF(TRIM(source_name), '') IS NOT NULL
        ) t
        WHERE rn = 1;
        PRINT '>> silver.country_alias: ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows ('
            + CAST(DATEDIFF(MILLISECOND, @start_time, SYSDATETIME()) AS NVARCHAR(20)) + ' ms)';

        ---------------------------------------------------------------
        -- silver.fao_yield
        ---------------------------------------------------------------
        SET @start_time = SYSDATETIME();
        TRUNCATE TABLE silver.fao_yield;
        WITH typed AS (
            SELECT
                TRIM(area)                                                       AS source_area,
                TRY_CAST(NULLIF(TRIM(area_code), '') AS INT)                     AS fao_area_code,
                TRIM(item)                                                       AS crop_name,
                TRY_CAST(NULLIF(TRIM(item_code), '') AS INT)                     AS fao_item_code,
                TRY_CAST(NULLIF(TRIM(year), '') AS INT)                          AS year,
                TRY_CAST(NULLIF(TRIM(REPLACE(value, CHAR(13), '')), '') AS DECIMAL(18,2)) AS yield_hg_ha,
                TRIM(element)                                                    AS element,
                TRIM(unit)                                                       AS unit
            FROM bronze.fao_yield
        ),
        conformed AS (
            SELECT
                COALESCE(a.country_name, t.source_area) AS country_name,
                t.*,
                ROW_NUMBER() OVER (
                    PARTITION BY COALESCE(a.country_name, t.source_area), t.crop_name, t.year
                    ORDER BY t.fao_area_code
                ) AS rn
            FROM typed t
            LEFT JOIN silver.country_alias a ON a.source_name = t.source_area
            WHERE t.element = 'Yield'
              AND t.unit = 'hg/ha'
              AND ISNULL(t.fao_area_code, -1) <> 351   -- FAO "China" aggregate
              AND t.year IS NOT NULL
              AND t.yield_hg_ha > 0
        )
        INSERT INTO silver.fao_yield (
            country_name, source_area, fao_area_code, crop_name, fao_item_code,
            crop_group, year, yield_hg_ha
        )
        SELECT
            country_name,
            source_area,
            fao_area_code,
            crop_name,
            fao_item_code,
            CASE
                WHEN crop_name IN ('Maize', 'Wheat', 'Rice, paddy', 'Sorghum')              THEN 'Cereals'
                WHEN crop_name IN ('Potatoes', 'Sweet potatoes', 'Cassava', 'Yams')          THEN 'Roots & Tubers'
                WHEN crop_name = 'Soybeans'                                                  THEN 'Oilseeds'
                WHEN crop_name = 'Plantains and others'                                      THEN 'Starchy Fruits'
                ELSE 'Other'
            END AS crop_group,
            year,
            yield_hg_ha
        FROM conformed
        WHERE rn = 1;
        PRINT '>> silver.fao_yield: ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows ('
            + CAST(DATEDIFF(MILLISECOND, @start_time, SYSDATETIME()) AS NVARCHAR(20)) + ' ms)';

        ---------------------------------------------------------------
        -- silver.wb_rainfall
        ---------------------------------------------------------------
        SET @start_time = SYSDATETIME();
        TRUNCATE TABLE silver.wb_rainfall;
        WITH typed AS (
            SELECT
                COALESCE(a.country_name, TRIM(r.area))                                        AS country_name,
                TRY_CAST(NULLIF(TRIM(r.year), '') AS INT)                                     AS year,
                TRY_CAST(NULLIF(TRIM(REPLACE(r.average_rain_fall_mm_per_year, CHAR(13), '')), '') AS FLOAT) AS rainfall_mm
            FROM bronze.wb_rainfall r
            LEFT JOIN silver.country_alias a ON a.source_name = TRIM(r.area)
        ),
        valid AS (
            SELECT country_name, year, AVG(rainfall_mm) AS rainfall_mm
            FROM typed
            WHERE year IS NOT NULL AND rainfall_mm >= 0
            GROUP BY country_name, year
        ),
        years AS (   -- 1985 .. 2017
            SELECT TOP (2017 - 1985 + 1)
                1984 + ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) AS year
            FROM sys.all_objects
        ),
        grid AS (
            SELECT c.country_name, y.year
            FROM (SELECT DISTINCT country_name FROM valid) c
            CROSS JOIN years y
        ),
        filled AS (
            SELECT
                g.country_name,
                g.year,
                v.rainfall_mm,
                AVG(v.rainfall_mm) OVER (PARTITION BY g.country_name) AS country_mean
            FROM grid g
            LEFT JOIN valid v
                ON v.country_name = g.country_name AND v.year = g.year
        )
        INSERT INTO silver.wb_rainfall (country_name, year, rainfall_mm, is_imputed)
        SELECT
            country_name,
            year,
            COALESCE(rainfall_mm, country_mean),
            CASE WHEN rainfall_mm IS NULL THEN 1 ELSE 0 END
        FROM filled;
        PRINT '>> silver.wb_rainfall: ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows ('
            + CAST(DATEDIFF(MILLISECOND, @start_time, SYSDATETIME()) AS NVARCHAR(20)) + ' ms)';

        ---------------------------------------------------------------
        -- silver.wb_temperature
        ---------------------------------------------------------------
        SET @start_time = SYSDATETIME();
        TRUNCATE TABLE silver.wb_temperature;
        WITH typed AS (
            SELECT
                COALESCE(a.country_name, TRIM(REPLACE(t.country, CHAR(13), '')))      AS country_name,
                TRY_CAST(NULLIF(TRIM(t.year), '') AS INT)                             AS year,
                TRY_CAST(NULLIF(TRIM(REPLACE(t.avg_temp, CHAR(13), '')), '') AS FLOAT) AS avg_temp
            FROM bronze.wb_temperature t
            LEFT JOIN silver.country_alias a
                ON a.source_name = TRIM(REPLACE(t.country, CHAR(13), ''))
        )
        INSERT INTO silver.wb_temperature (country_name, year, avg_temp_c, n_records)
        SELECT country_name, year, AVG(avg_temp), COUNT(*)
        FROM typed
        WHERE year IS NOT NULL AND avg_temp IS NOT NULL
        GROUP BY country_name, year;
        PRINT '>> silver.wb_temperature: ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows ('
            + CAST(DATEDIFF(MILLISECOND, @start_time, SYSDATETIME()) AS NVARCHAR(20)) + ' ms)';

        ---------------------------------------------------------------
        -- silver.fao_pesticides
        ---------------------------------------------------------------
        SET @start_time = SYSDATETIME();
        TRUNCATE TABLE silver.fao_pesticides;
        WITH typed AS (
            SELECT
                COALESCE(a.country_name, TRIM(p.area))                               AS country_name,
                TRY_CAST(NULLIF(TRIM(p.year), '') AS INT)                            AS year,
                TRY_CAST(NULLIF(TRIM(REPLACE(p.value, CHAR(13), '')), '') AS FLOAT)  AS pesticides_tonnes,
                TRIM(p.element)                                                      AS element,
                TRIM(p.item)                                                         AS item
            FROM bronze.fao_pesticides p
            LEFT JOIN silver.country_alias a ON a.source_name = TRIM(p.area)
        )
        INSERT INTO silver.fao_pesticides (country_name, year, pesticides_tonnes)
        SELECT country_name, year, AVG(pesticides_tonnes)
        FROM typed
        WHERE element = 'Use'
          AND item = 'Pesticides (total)'
          AND year IS NOT NULL
          AND pesticides_tonnes >= 0
        GROUP BY country_name, year;
        PRINT '>> silver.fao_pesticides: ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows ('
            + CAST(DATEDIFF(MILLISECOND, @start_time, SYSDATETIME()) AS NVARCHAR(20)) + ' ms)';

        PRINT '================================================';
        PRINT 'Silver load completed in '
            + CAST(DATEDIFF(SECOND, @batch_start, SYSDATETIME()) AS NVARCHAR(20)) + ' s';
        PRINT '================================================';
    END TRY
    BEGIN CATCH
        PRINT '================================================';
        PRINT 'ERROR while loading Silver layer';
        PRINT 'Message: ' + ERROR_MESSAGE();
        PRINT 'Number : ' + CAST(ERROR_NUMBER() AS NVARCHAR(20));
        PRINT '================================================';
        THROW;
    END CATCH;
END;
GO
