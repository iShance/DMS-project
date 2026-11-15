/*
=============================================================================
AgriPulse - 02_bronze_load_proc.sql
=============================================================================
Stored procedure bronze.load_bronze

Full-refresh load of the raw CSV files: TRUNCATE each Bronze table, then
BULK INSERT the file into it through its load view (bronze.v_<table>_load)
and stamp the provenance column source_file. No transformation happens here.
Every file writes one row to audit.load_log (SUCCESS or FAILED).

Parameter
    @data_path  Folder that contains the project's "datasets" directory as
                seen BY THE SQL SERVER SERVICE, with a trailing backslash,
                e.g. 'C:\AgriPulse\datasets\'.

Notes
    * Requires SQL Server 2017+ (FORMAT = 'CSV' handles quoted fields such as
      "Rice, paddy" and "China, Hong Kong SAR").
    * CODEPAGE 65001 = UTF-8 (needed for names like Côte d'Ivoire, Réunion).
    * ROWTERMINATOR 0x0a works for both LF and CRLF files; a trailing CR on
      the last column is stripped in Silver.
    * BULK INSERT does not accept a variable path, so dynamic SQL is used.

Usage
    EXEC bronze.load_bronze @data_path = 'C:\AgriPulse\datasets\';
=============================================================================
*/

USE AgriPulse;
GO

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
        (1, 'bronze.fao_yield',         'bronze.v_fao_yield_load',         'source\yield.csv'),
        (2, 'bronze.wb_rainfall',       'bronze.v_wb_rainfall_load',       'source\rainfall.csv'),
        (3, 'bronze.wb_temperature',    'bronze.v_wb_temperature_load',    'source\temp.csv'),
        (4, 'bronze.fao_pesticides',    'bronze.v_fao_pesticides_load',    'source\pesticides.csv'),
        (5, 'bronze.ref_country',       'bronze.v_ref_country_load',       'reference\country_reference.csv'),
        (6, 'bronze.ref_country_alias', 'bronze.v_ref_country_alias_load', 'reference\country_aliases.csv');

    DECLARE @table SYSNAME, @view SYSNAME, @file NVARCHAR(200), @full_path NVARCHAR(600), @rows INT;

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
