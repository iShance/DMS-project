/*
=============================================================================
AgriPulse - 01_bronze.sql
=============================================================================
Bronze layer. Run after 00_init.sql.
    Part 1  raw tables (all NVARCHAR) + provenance columns + load views
    Part 2  bronze.load_bronze: TRUNCATE + BULK INSERT every CSV file
Load with:  EXEC bronze.load_bronze @data_path = 'C:\AgriPulse\data';
=============================================================================
*/

USE AgriPulse;
GO

/*
=============================================================================
Part 1: tables
=============================================================================
Bronze layer tables. One table per source file, columns in the same order as
the CSV header. Every column is NVARCHAR so that the raw load never fails on a
bad value (e.g. the empty rainfall and temperature cells); typing and
cleaning happen in Silver.

    bronze.fao_yield          <- data/raw/yield.csv       (FAO)
    bronze.wb_rainfall        <- data/raw/rainfall.csv    (World Bank)
    bronze.wb_temperature     <- data/raw/temp.csv        (World Bank)
    bronze.fao_pesticides     <- data/raw/pesticides.csv  (FAO)
    bronze.ref_country        <- data/reference/country_reference.csv
    bronze.ref_country_alias  <- data/reference/country_aliases.csv

Provenance: every table ends with two technical columns,
    source_file   full path of the file the row was loaded from
    ingested_at   when bronze.load_bronze wrote the row
BULK INSERT loads through the view bronze.v_<table>_load, which lists only
the CSV columns, so the provenance columns are filled by the procedure and by
their DEFAULT rather than by the file.
=============================================================================
*/

IF OBJECT_ID('bronze.fao_yield', 'U') IS NOT NULL DROP TABLE bronze.fao_yield;
GO
CREATE TABLE bronze.fao_yield (
    domain_code   NVARCHAR(10),
    domain        NVARCHAR(50),
    area_code     NVARCHAR(10),
    area          NVARCHAR(100),
    element_code  NVARCHAR(10),
    element       NVARCHAR(50),
    item_code     NVARCHAR(10),
    item          NVARCHAR(100),
    year_code     NVARCHAR(10),
    year          NVARCHAR(10),
    unit          NVARCHAR(20),
    value         NVARCHAR(30),
    source_file   NVARCHAR(500),
    ingested_at   DATETIME2 NOT NULL DEFAULT SYSDATETIME()
);
GO
CREATE OR ALTER VIEW bronze.v_fao_yield_load AS
SELECT domain_code, domain, area_code, area, element_code, element,
       item_code, item, year_code, year, unit, value
FROM bronze.fao_yield;
GO

IF OBJECT_ID('bronze.wb_rainfall', 'U') IS NOT NULL DROP TABLE bronze.wb_rainfall;
GO
CREATE TABLE bronze.wb_rainfall (
    area                           NVARCHAR(100),
    year                           NVARCHAR(10),
    average_rain_fall_mm_per_year  NVARCHAR(30),
    source_file                    NVARCHAR(500),
    ingested_at                    DATETIME2 NOT NULL DEFAULT SYSDATETIME()
);
GO
CREATE OR ALTER VIEW bronze.v_wb_rainfall_load AS
SELECT area, year, average_rain_fall_mm_per_year
FROM bronze.wb_rainfall;
GO

IF OBJECT_ID('bronze.wb_temperature', 'U') IS NOT NULL DROP TABLE bronze.wb_temperature;
GO
CREATE TABLE bronze.wb_temperature (
    year         NVARCHAR(10),
    country      NVARCHAR(100),
    avg_temp     NVARCHAR(30),
    source_file  NVARCHAR(500),
    ingested_at  DATETIME2 NOT NULL DEFAULT SYSDATETIME()
);
GO
CREATE OR ALTER VIEW bronze.v_wb_temperature_load AS
SELECT year, country, avg_temp
FROM bronze.wb_temperature;
GO

IF OBJECT_ID('bronze.fao_pesticides', 'U') IS NOT NULL DROP TABLE bronze.fao_pesticides;
GO
CREATE TABLE bronze.fao_pesticides (
    domain       NVARCHAR(50),
    area         NVARCHAR(100),
    element      NVARCHAR(50),
    item         NVARCHAR(100),
    year         NVARCHAR(10),
    unit         NVARCHAR(50),
    value        NVARCHAR(30),
    source_file  NVARCHAR(500),
    ingested_at  DATETIME2 NOT NULL DEFAULT SYSDATETIME()
);
GO
CREATE OR ALTER VIEW bronze.v_fao_pesticides_load AS
SELECT domain, area, element, item, year, unit, value
FROM bronze.fao_pesticides;
GO

IF OBJECT_ID('bronze.ref_country', 'U') IS NOT NULL DROP TABLE bronze.ref_country;
GO
CREATE TABLE bronze.ref_country (
    country_name  NVARCHAR(100),
    iso3          NVARCHAR(10),
    region        NVARCHAR(50),
    source_file   NVARCHAR(500),
    ingested_at   DATETIME2 NOT NULL DEFAULT SYSDATETIME()
);
GO
CREATE OR ALTER VIEW bronze.v_ref_country_load AS
SELECT country_name, iso3, region
FROM bronze.ref_country;
GO

IF OBJECT_ID('bronze.ref_country_alias', 'U') IS NOT NULL DROP TABLE bronze.ref_country_alias;
GO
CREATE TABLE bronze.ref_country_alias (
    source_name   NVARCHAR(100),
    country_name  NVARCHAR(100),
    source_file   NVARCHAR(500),
    ingested_at   DATETIME2 NOT NULL DEFAULT SYSDATETIME()
);
GO
CREATE OR ALTER VIEW bronze.v_ref_country_alias_load AS
SELECT source_name, country_name
FROM bronze.ref_country_alias;
GO

/*
=============================================================================
Part 2: load procedure bronze.load_bronze
=============================================================================
Stored procedure bronze.load_bronze

Full-refresh load of the raw CSV files: TRUNCATE each Bronze table, then
BULK INSERT the file into it through its load view (bronze.v_<table>_load)
and stamp the provenance column source_file. No transformation happens here.
Every file writes one row to audit.load_log (SUCCESS or FAILED).

Parameter
    @data_path  The project's "data" folder (the one holding raw\ and
                reference\) as seen BY THE SQL SERVER SERVICE, e.g.
                'C:\AgriPulse\data'. A trailing backslash is optional.

Notes
    * Requires SQL Server 2017+ (FORMAT = 'CSV' handles quoted fields such as
      "Rice, paddy" and "China, Hong Kong SAR").
    * CODEPAGE 65001 = UTF-8 (needed for names like Côte d'Ivoire, Réunion).
    * ROWTERMINATOR 0x0a works for both LF and CRLF files; a trailing CR on
      the last column is stripped in Silver.
    * BULK INSERT does not accept a variable path, so dynamic SQL is used.

Usage
    EXEC bronze.load_bronze @data_path = 'C:\AgriPulse\data';
=============================================================================
*/

CREATE OR ALTER PROCEDURE bronze.load_bronze
    @data_path NVARCHAR(400)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @batch_id UNIQUEIDENTIFIER = NEWID();
    DECLARE @start_time DATETIME2, @batch_start DATETIME2, @sql NVARCHAR(MAX);
    DECLARE @files TABLE (
        load_order  INT,
        table_name  SYSNAME,
        view_name   SYSNAME,
        file_name   NVARCHAR(200)
    );

    INSERT INTO @files VALUES
        (1, 'bronze.fao_yield',         'bronze.v_fao_yield_load',         'raw\yield.csv'),
        (2, 'bronze.wb_rainfall',       'bronze.v_wb_rainfall_load',       'raw\rainfall.csv'),
        (3, 'bronze.wb_temperature',    'bronze.v_wb_temperature_load',    'raw\temp.csv'),
        (4, 'bronze.fao_pesticides',    'bronze.v_fao_pesticides_load',    'raw\pesticides.csv'),
        (5, 'bronze.ref_country',       'bronze.v_ref_country_load',       'reference\country_reference.csv'),
        (6, 'bronze.ref_country_alias', 'bronze.v_ref_country_alias_load', 'reference\country_aliases.csv');

    DECLARE @table SYSNAME, @view SYSNAME, @file NVARCHAR(200), @full_path NVARCHAR(600), @rows INT;

    -- accept the folder with or without a trailing separator
    IF RIGHT(@data_path, 1) NOT IN ('\', '/')
        SET @data_path = @data_path + CASE WHEN CHARINDEX('/', @data_path) > 0 THEN '/' ELSE '\' END;

    BEGIN TRY
        SET @batch_start = SYSDATETIME();
        PRINT '================================================';
        PRINT 'Loading Bronze layer from ' + @data_path;
        PRINT '================================================';

        DECLARE file_cursor CURSOR LOCAL FAST_FORWARD FOR
            SELECT table_name, view_name, file_name FROM @files ORDER BY load_order;

        OPEN file_cursor;
        FETCH NEXT FROM file_cursor INTO @table, @view, @file;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @start_time = SYSDATETIME();
            SET @full_path = @data_path + @file;

            SET @sql = N'TRUNCATE TABLE ' + @table + N';
                BULK INSERT ' + @view + N'
                FROM N''' + REPLACE(@full_path, '''', '''''') + N'''
                WITH (
                    FORMAT          = ''CSV'',
                    FIRSTROW        = 2,
                    FIELDQUOTE      = ''"'',
                    FIELDTERMINATOR = '','',
                    ROWTERMINATOR   = ''0x0a'',
                    CODEPAGE        = ''65001'',
                    TABLOCK
                );
                UPDATE ' + @table + N' SET source_file = @path;';
            EXEC sp_executesql @sql, N'@path NVARCHAR(600)', @path = @full_path;

            SET @sql = N'SELECT @n = COUNT(*) FROM ' + @table + N';';
            EXEC sp_executesql @sql, N'@n INT OUTPUT', @n = @rows OUTPUT;

            INSERT INTO audit.load_log (batch_id, procedure_name, source_name, target_table,
                                        start_time, end_time, rows_loaded, status)
            VALUES (@batch_id, 'bronze.load_bronze', @full_path, @table,
                    @start_time, SYSDATETIME(), @rows, 'SUCCESS');

            PRINT '>> ' + @table + ': ' + CAST(@rows AS NVARCHAR(20)) + ' rows ('
                + CAST(DATEDIFF(MILLISECOND, @start_time, SYSDATETIME()) AS NVARCHAR(20)) + ' ms)';

            FETCH NEXT FROM file_cursor INTO @table, @view, @file;
        END;
        CLOSE file_cursor;
        DEALLOCATE file_cursor;

        PRINT '================================================';
        PRINT 'Bronze load completed in '
            + CAST(DATEDIFF(SECOND, @batch_start, SYSDATETIME()) AS NVARCHAR(20)) + ' s';
        PRINT '================================================';
    END TRY
    BEGIN CATCH
        INSERT INTO audit.load_log (batch_id, procedure_name, source_name, target_table,
                                    start_time, end_time, status, message)
        VALUES (@batch_id, 'bronze.load_bronze', ISNULL(@full_path, @data_path), ISNULL(@table, '(none)'),
                ISNULL(@start_time, SYSDATETIME()), SYSDATETIME(), 'FAILED', ERROR_MESSAGE());
        PRINT '================================================';
        PRINT 'ERROR while loading Bronze layer';
        PRINT 'Message: ' + ERROR_MESSAGE();
        PRINT 'Number : ' + CAST(ERROR_NUMBER() AS NVARCHAR(20));
        PRINT '================================================';
        THROW;
    END CATCH;
END;
GO
