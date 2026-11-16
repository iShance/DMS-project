/*
=============================================================================
AgriPulse - 02_silver.sql
=============================================================================
Silver layer. Run after 01_bronze.sql.
    Part 1  typed tables + silver.reject_log
    Part 2  silver.load_silver: clean, conform, de-duplicate, impute, log rejects
Load with:  EXEC silver.load_silver;
=============================================================================
*/

USE AgriPulse;
GO

/*
=============================================================================
Part 1: tables
=============================================================================
Silver layer tables: typed, trimmed, conformed country names, one row per
natural key. dwh_create_date records when the row was loaded.

    silver.country         conformed country list with ISO3 + World Bank region
    silver.country_alias   source spelling -> conformed country name
    silver.fao_yield       country x crop x year   (yield in hg/ha)
    silver.wb_rainfall     country x year          (complete 1985-2017 grid)
    silver.wb_temperature  country x year          (mean of city records)
    silver.fao_pesticides  country x year          (tonnes of active ingredients)
    silver.reject_log      one row per Bronze row that did not reach Silver, with the reason
=============================================================================
*/

IF OBJECT_ID('silver.country', 'U') IS NOT NULL DROP TABLE silver.country;
GO
CREATE TABLE silver.country (
    country_name     NVARCHAR(100) NOT NULL PRIMARY KEY,
    iso3             NVARCHAR(10),
    region           NVARCHAR(50),
    dwh_create_date  DATETIME2 NOT NULL DEFAULT SYSDATETIME()
);
GO

IF OBJECT_ID('silver.country_alias', 'U') IS NOT NULL DROP TABLE silver.country_alias;
GO
CREATE TABLE silver.country_alias (
    source_name      NVARCHAR(100) NOT NULL PRIMARY KEY,
    country_name     NVARCHAR(100) NOT NULL,
    dwh_create_date  DATETIME2 NOT NULL DEFAULT SYSDATETIME()
);
GO

IF OBJECT_ID('silver.fao_yield', 'U') IS NOT NULL DROP TABLE silver.fao_yield;
GO
CREATE TABLE silver.fao_yield (
    country_name     NVARCHAR(100) NOT NULL,
    source_area      NVARCHAR(100) NOT NULL,   -- name as written by FAO
    fao_area_code    INT           NOT NULL,
    crop_name        NVARCHAR(100) NOT NULL,
    fao_item_code    INT           NOT NULL,
    crop_group       NVARCHAR(30)  NOT NULL,
    year             INT           NOT NULL,
    yield_hg_ha      DECIMAL(18,2) NOT NULL,   -- hectograms per hectare
    dwh_create_date  DATETIME2     NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT pk_silver_fao_yield PRIMARY KEY (country_name, crop_name, year)
);
GO

IF OBJECT_ID('silver.wb_rainfall', 'U') IS NOT NULL DROP TABLE silver.wb_rainfall;
GO
CREATE TABLE silver.wb_rainfall (
    country_name     NVARCHAR(100) NOT NULL,
    year             INT           NOT NULL,
    rainfall_mm      FLOAT         NOT NULL,
    is_imputed       BIT           NOT NULL,   -- 1 = filled with the country mean
    dwh_create_date  DATETIME2     NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT pk_silver_wb_rainfall PRIMARY KEY (country_name, year)
);
GO

IF OBJECT_ID('silver.wb_temperature', 'U') IS NOT NULL DROP TABLE silver.wb_temperature;
GO
CREATE TABLE silver.wb_temperature (
    country_name     NVARCHAR(100) NOT NULL,
    year             INT           NOT NULL,
    avg_temp_c       FLOAT         NOT NULL,
    n_records        INT           NOT NULL,   -- city records averaged
    dwh_create_date  DATETIME2     NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT pk_silver_wb_temperature PRIMARY KEY (country_name, year)
);
GO

IF OBJECT_ID('silver.fao_pesticides', 'U') IS NOT NULL DROP TABLE silver.fao_pesticides;
GO
CREATE TABLE silver.fao_pesticides (
    country_name       NVARCHAR(100) NOT NULL,
    year               INT           NOT NULL,
    pesticides_tonnes  FLOAT         NOT NULL,
    dwh_create_date    DATETIME2     NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT pk_silver_fao_pesticides PRIMARY KEY (country_name, year)
);
GO

-- Every Bronze row that silver.load_silver does not keep is written here with
-- the rule it failed, so Bronze rows = accepted rows + rejected rows.
-- (Rows that are averaged, e.g. several city temperatures for one
-- country-year, are aggregated, not rejected.)
IF OBJECT_ID('silver.reject_log', 'U') IS NOT NULL DROP TABLE silver.reject_log;
GO
CREATE TABLE silver.reject_log (
    reject_id        BIGINT IDENTITY(1,1) PRIMARY KEY,
    source_table     NVARCHAR(100) NOT NULL,   -- Bronze table the row came from
    business_key     NVARCHAR(400) NULL,       -- natural key as written in the source
    column_name      NVARCHAR(100) NULL,       -- column that failed the rule
    raw_value        NVARCHAR(100) NULL,       -- that column's value as received
    reason           NVARCHAR(200) NOT NULL,
    dwh_create_date  DATETIME2     NOT NULL DEFAULT SYSDATETIME()
);
GO

/*
=============================================================================
Part 2: load procedure silver.load_silver
=============================================================================
Stored procedure silver.load_silver

Full refresh Bronze -> Silver. For every table: TRUNCATE, then INSERT the
cleaned rows. Cleaning rules (the pandas mirror is src/ingest/pipeline.py):

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

Every Bronze row that is not kept goes to silver.reject_log with the rule it
failed, so for each source  Bronze rows = rows kept + rows rejected  (rows
that are averaged into one country-year are kept, not rejected). Each Silver
table writes one row to audit.load_log.

Usage
    EXEC silver.load_silver;
=============================================================================
*/

CREATE OR ALTER PROCEDURE silver.load_silver
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @batch_id UNIQUEIDENTIFIER = NEWID();
    DECLARE @start_time DATETIME2, @batch_start DATETIME2;
    DECLARE @rows BIGINT, @rejected BIGINT, @target NVARCHAR(200), @source NVARCHAR(200);

    BEGIN TRY
        SET @batch_start = SYSDATETIME();
        PRINT '================================================';
        PRINT 'Loading Silver layer';
        PRINT '================================================';

        TRUNCATE TABLE silver.reject_log;

        ---------------------------------------------------------------
        -- silver.country
        ---------------------------------------------------------------
        SELECT @start_time = SYSDATETIME(), @target = 'silver.country', @source = 'bronze.ref_country';
        TRUNCATE TABLE silver.country;
        DROP TABLE IF EXISTS #country;

        SELECT
            TRIM(country_name)                                AS country_name,
            UPPER(TRIM(iso3))                                 AS iso3,
            NULLIF(TRIM(REPLACE(region, CHAR(13), '')), '')   AS region,
            ROW_NUMBER() OVER (PARTITION BY TRIM(country_name) ORDER BY (SELECT NULL)) AS rn
        INTO #country
        FROM bronze.ref_country;

        INSERT INTO silver.country (country_name, iso3, region)
        SELECT country_name, iso3, region
        FROM #country
        WHERE NULLIF(country_name, '') IS NOT NULL AND rn = 1;
        SET @rows = @@ROWCOUNT;

        INSERT INTO silver.reject_log (source_table, business_key, column_name, raw_value, reason)
        SELECT @source, country_name, 'country_name', country_name,
               CASE WHEN NULLIF(country_name, '') IS NULL THEN 'missing country_name'
                    ELSE 'duplicate country_name (first row kept)' END
        FROM #country
        WHERE NULLIF(country_name, '') IS NULL OR rn > 1;
        SET @rejected = @@ROWCOUNT;

        INSERT INTO audit.load_log (batch_id, procedure_name, source_name, target_table,
                                    start_time, end_time, rows_loaded, rows_rejected, status)
        VALUES (@batch_id, 'silver.load_silver', @source, @target,
                @start_time, SYSDATETIME(), @rows, @rejected, 'SUCCESS');
        PRINT '>> silver.country: ' + CAST(@rows AS NVARCHAR(20)) + ' rows, '
            + CAST(@rejected AS NVARCHAR(20)) + ' rejected';

        ---------------------------------------------------------------
        -- silver.country_alias
        ---------------------------------------------------------------
        SELECT @start_time = SYSDATETIME(), @target = 'silver.country_alias', @source = 'bronze.ref_country_alias';
        TRUNCATE TABLE silver.country_alias;
        DROP TABLE IF EXISTS #alias;

        SELECT
            TRIM(source_name)                          AS source_name,
            TRIM(REPLACE(country_name, CHAR(13), ''))  AS country_name,
            ROW_NUMBER() OVER (PARTITION BY TRIM(source_name) ORDER BY (SELECT NULL)) AS rn
        INTO #alias
        FROM bronze.ref_country_alias;

        INSERT INTO silver.country_alias (source_name, country_name)
        SELECT source_name, country_name
        FROM #alias
        WHERE NULLIF(source_name, '') IS NOT NULL AND rn = 1;
        SET @rows = @@ROWCOUNT;

        INSERT INTO silver.reject_log (source_table, business_key, column_name, raw_value, reason)
        SELECT @source, source_name, 'source_name', source_name,
               CASE WHEN NULLIF(source_name, '') IS NULL THEN 'missing source_name'
                    ELSE 'duplicate source_name (first row kept)' END
        FROM #alias
        WHERE NULLIF(source_name, '') IS NULL OR rn > 1;
        SET @rejected = @@ROWCOUNT;

        INSERT INTO audit.load_log (batch_id, procedure_name, source_name, target_table,
                                    start_time, end_time, rows_loaded, rows_rejected, status)
        VALUES (@batch_id, 'silver.load_silver', @source, @target,
                @start_time, SYSDATETIME(), @rows, @rejected, 'SUCCESS');
        PRINT '>> silver.country_alias: ' + CAST(@rows AS NVARCHAR(20)) + ' rows, '
            + CAST(@rejected AS NVARCHAR(20)) + ' rejected';

        ---------------------------------------------------------------
        -- silver.fao_yield
        ---------------------------------------------------------------
        SELECT @start_time = SYSDATETIME(), @target = 'silver.fao_yield', @source = 'bronze.fao_yield';
        TRUNCATE TABLE silver.fao_yield;
        DROP TABLE IF EXISTS #yield;

        WITH typed AS (
            SELECT
                TRIM(area)                                                       AS source_area,
                TRY_CAST(NULLIF(TRIM(area_code), '') AS INT)                     AS fao_area_code,
                TRIM(item)                                                       AS crop_name,
                TRY_CAST(NULLIF(TRIM(item_code), '') AS INT)                     AS fao_item_code,
                TRY_CAST(NULLIF(TRIM(year), '') AS INT)                          AS year,
                TRY_CAST(NULLIF(TRIM(REPLACE(value, CHAR(13), '')), '') AS DECIMAL(18,2)) AS yield_hg_ha,
                TRIM(element)                                                    AS element,
                TRIM(unit)                                                       AS unit,
                TRIM(area_code)                                                  AS raw_area_code,
                TRIM(year)                                                       AS raw_year,
                TRIM(REPLACE(value, CHAR(13), ''))                               AS raw_value
            FROM bronze.fao_yield
        ),
        classified AS (
            SELECT
                COALESCE(a.country_name, t.source_area) AS country_name,
                t.*,
                CASE
                    WHEN ISNULL(t.element, '') <> 'Yield' OR ISNULL(t.unit, '') <> 'hg/ha'
                                                        THEN 'element'
                    WHEN t.year IS NULL                 THEN 'year'
                    WHEN t.fao_area_code = 351          THEN 'area_code'   -- FAO "China" aggregate
                    WHEN ISNULL(t.yield_hg_ha, 0) <= 0  THEN 'value'
                END AS failed_column
            FROM typed t
            LEFT JOIN silver.country_alias a ON a.source_name = t.source_area
        )
        SELECT
            *,
            -- de-duplication only among rows that passed the rules above
            CASE WHEN failed_column IS NULL THEN
                ROW_NUMBER() OVER (
                    PARTITION BY failed_column, country_name, crop_name, year
                    ORDER BY fao_area_code)
            END AS rn
        INTO #yield
        FROM classified;

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
        FROM #yield
        WHERE failed_column IS NULL AND rn = 1;
        SET @rows = @@ROWCOUNT;

        INSERT INTO silver.reject_log (source_table, business_key, column_name, raw_value, reason)
        SELECT
            @source,
            CONCAT(source_area, ' | ', crop_name, ' | ', raw_year),
            ISNULL(failed_column, 'area'),
            CASE failed_column
                WHEN 'element'   THEN CONCAT(element, ' / ', unit)
                WHEN 'year'      THEN raw_year
                WHEN 'area_code' THEN raw_area_code
                WHEN 'value'     THEN raw_value
                ELSE source_area
            END,
            CASE failed_column
                WHEN 'element'   THEN 'not a yield record (element / unit)'
                WHEN 'year'      THEN 'missing or invalid year'
                WHEN 'area_code' THEN 'FAO China aggregate (area 351) double counts its parts'
                WHEN 'value'     THEN 'missing or zero yield (FAO missing record)'
                ELSE 'duplicate country x crop x year after name conforming (lowest area code kept)'
            END
        FROM #yield
        WHERE failed_column IS NOT NULL OR rn > 1;
        SET @rejected = @@ROWCOUNT;

        INSERT INTO audit.load_log (batch_id, procedure_name, source_name, target_table,
                                    start_time, end_time, rows_loaded, rows_rejected, status)
        VALUES (@batch_id, 'silver.load_silver', @source, @target,
                @start_time, SYSDATETIME(), @rows, @rejected, 'SUCCESS');
        PRINT '>> silver.fao_yield: ' + CAST(@rows AS NVARCHAR(20)) + ' rows, '
            + CAST(@rejected AS NVARCHAR(20)) + ' rejected ('
            + CAST(DATEDIFF(MILLISECOND, @start_time, SYSDATETIME()) AS NVARCHAR(20)) + ' ms)';

        ---------------------------------------------------------------
        -- silver.wb_rainfall
        ---------------------------------------------------------------
        SELECT @start_time = SYSDATETIME(), @target = 'silver.wb_rainfall', @source = 'bronze.wb_rainfall';
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
        SET @rows = @@ROWCOUNT;

        -- rejected cells; their country-year is then filled with the country mean above
        INSERT INTO silver.reject_log (source_table, business_key, column_name, raw_value, reason)
        SELECT
            @source,
            CONCAT(area, ' | ', raw_year),
            CASE WHEN year IS NULL THEN 'year' ELSE 'average_rain_fall_mm_per_year' END,
            CASE WHEN year IS NULL THEN raw_year ELSE raw_value END,
            CASE WHEN year IS NULL        THEN 'missing or invalid year'
                 WHEN rainfall_mm IS NULL THEN 'missing or non-numeric rainfall (blank or ..)'
                 ELSE 'negative rainfall'
            END
        FROM (
            SELECT
                TRIM(area)                                                           AS area,
                TRIM(year)                                                           AS raw_year,
                TRIM(REPLACE(average_rain_fall_mm_per_year, CHAR(13), ''))           AS raw_value,
                TRY_CAST(NULLIF(TRIM(year), '') AS INT)                              AS year,
                TRY_CAST(NULLIF(TRIM(REPLACE(average_rain_fall_mm_per_year, CHAR(13), '')), '') AS FLOAT) AS rainfall_mm
            FROM bronze.wb_rainfall
        ) r
        WHERE year IS NULL OR rainfall_mm IS NULL OR rainfall_mm < 0;
        SET @rejected = @@ROWCOUNT;

        INSERT INTO audit.load_log (batch_id, procedure_name, source_name, target_table,
                                    start_time, end_time, rows_loaded, rows_rejected, status, message)
        VALUES (@batch_id, 'silver.load_silver', @source, @target,
                @start_time, SYSDATETIME(), @rows, @rejected, 'SUCCESS',
                'rows_loaded = complete country x year grid, including imputed years');
        PRINT '>> silver.wb_rainfall: ' + CAST(@rows AS NVARCHAR(20)) + ' rows, '
            + CAST(@rejected AS NVARCHAR(20)) + ' rejected ('
            + CAST(DATEDIFF(MILLISECOND, @start_time, SYSDATETIME()) AS NVARCHAR(20)) + ' ms)';

        ---------------------------------------------------------------
        -- silver.wb_temperature
        ---------------------------------------------------------------
        SELECT @start_time = SYSDATETIME(), @target = 'silver.wb_temperature', @source = 'bronze.wb_temperature';
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
        SET @rows = @@ROWCOUNT;

        INSERT INTO silver.reject_log (source_table, business_key, column_name, raw_value, reason)
        SELECT
            @source,
            CONCAT(country, ' | ', raw_year),
            CASE WHEN year IS NULL THEN 'year' ELSE 'avg_temp' END,
            CASE WHEN year IS NULL THEN raw_year ELSE raw_value END,
            CASE WHEN year IS NULL THEN 'missing or invalid year'
                 ELSE 'missing or non-numeric temperature'
            END
        FROM (
            SELECT
                TRIM(REPLACE(country, CHAR(13), ''))                             AS country,
                TRIM(year)                                                       AS raw_year,
                TRIM(REPLACE(avg_temp, CHAR(13), ''))                            AS raw_value,
                TRY_CAST(NULLIF(TRIM(year), '') AS INT)                          AS year,
                TRY_CAST(NULLIF(TRIM(REPLACE(avg_temp, CHAR(13), '')), '') AS FLOAT) AS avg_temp
            FROM bronze.wb_temperature
        ) t
        WHERE year IS NULL OR avg_temp IS NULL;
        SET @rejected = @@ROWCOUNT;

        INSERT INTO audit.load_log (batch_id, procedure_name, source_name, target_table,
                                    start_time, end_time, rows_loaded, rows_rejected, status, message)
        VALUES (@batch_id, 'silver.load_silver', @source, @target,
                @start_time, SYSDATETIME(), @rows, @rejected, 'SUCCESS',
                'rows_loaded = country-years (city records averaged)');
        PRINT '>> silver.wb_temperature: ' + CAST(@rows AS NVARCHAR(20)) + ' rows, '
            + CAST(@rejected AS NVARCHAR(20)) + ' rejected ('
            + CAST(DATEDIFF(MILLISECOND, @start_time, SYSDATETIME()) AS NVARCHAR(20)) + ' ms)';

        ---------------------------------------------------------------
        -- silver.fao_pesticides
        ---------------------------------------------------------------
        SELECT @start_time = SYSDATETIME(), @target = 'silver.fao_pesticides', @source = 'bronze.fao_pesticides';
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
        SET @rows = @@ROWCOUNT;

        INSERT INTO silver.reject_log (source_table, business_key, column_name, raw_value, reason)
        SELECT
            @source,
            CONCAT(area, ' | ', raw_year),
            CASE WHEN ISNULL(element, '') <> 'Use' OR ISNULL(item, '') <> 'Pesticides (total)' THEN 'item'
                 WHEN year IS NULL THEN 'year'
                 ELSE 'value' END,
            CASE WHEN ISNULL(element, '') <> 'Use' OR ISNULL(item, '') <> 'Pesticides (total)'
                      THEN CONCAT(element, ' / ', item)
                 WHEN year IS NULL THEN raw_year
                 ELSE raw_value END,
            CASE WHEN ISNULL(element, '') <> 'Use' OR ISNULL(item, '') <> 'Pesticides (total)'
                      THEN 'not Use / Pesticides (total)'
                 WHEN year IS NULL THEN 'missing or invalid year'
                 ELSE 'missing or negative pesticide value' END
        FROM (
            SELECT
                TRIM(area)                                                        AS area,
                TRIM(element)                                                     AS element,
                TRIM(item)                                                        AS item,
                TRIM(year)                                                        AS raw_year,
                TRIM(REPLACE(value, CHAR(13), ''))                                AS raw_value,
                TRY_CAST(NULLIF(TRIM(year), '') AS INT)                           AS year,
                TRY_CAST(NULLIF(TRIM(REPLACE(value, CHAR(13), '')), '') AS FLOAT) AS pesticides_tonnes
            FROM bronze.fao_pesticides
        ) p
        WHERE ISNULL(element, '') <> 'Use'
           OR ISNULL(item, '') <> 'Pesticides (total)'
           OR year IS NULL
           OR pesticides_tonnes IS NULL
           OR pesticides_tonnes < 0;
        SET @rejected = @@ROWCOUNT;

        INSERT INTO audit.load_log (batch_id, procedure_name, source_name, target_table,
                                    start_time, end_time, rows_loaded, rows_rejected, status)
        VALUES (@batch_id, 'silver.load_silver', @source, @target,
                @start_time, SYSDATETIME(), @rows, @rejected, 'SUCCESS');
        PRINT '>> silver.fao_pesticides: ' + CAST(@rows AS NVARCHAR(20)) + ' rows, '
            + CAST(@rejected AS NVARCHAR(20)) + ' rejected ('
            + CAST(DATEDIFF(MILLISECOND, @start_time, SYSDATETIME()) AS NVARCHAR(20)) + ' ms)';

        PRINT '================================================';
        PRINT 'Silver load completed in '
            + CAST(DATEDIFF(SECOND, @batch_start, SYSDATETIME()) AS NVARCHAR(20)) + ' s';
        PRINT '================================================';
    END TRY
    BEGIN CATCH
        INSERT INTO audit.load_log (batch_id, procedure_name, source_name, target_table,
                                    start_time, end_time, status, message)
        VALUES (@batch_id, 'silver.load_silver', ISNULL(@source, '(none)'), ISNULL(@target, '(none)'),
                ISNULL(@start_time, SYSDATETIME()), SYSDATETIME(), 'FAILED', ERROR_MESSAGE());
        PRINT '================================================';
        PRINT 'ERROR while loading Silver layer';
        PRINT 'Message: ' + ERROR_MESSAGE();
        PRINT 'Number : ' + CAST(ERROR_NUMBER() AS NVARCHAR(20));
        PRINT '================================================';
        THROW;
    END CATCH;
END;
GO
