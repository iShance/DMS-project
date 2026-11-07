/*
=============================================================================
AgriPulse - 02_bronze_load_proc.sql
=============================================================================
Stored procedure bronze.load_bronze

Full-refresh load of the raw CSV files: TRUNCATE each Bronze table, then
BULK INSERT the file into it. No transformation happens here.

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

    DECLARE @start_time DATETIME2, @batch_start DATETIME2, @sql NVARCHAR(MAX);
    DECLARE @files TABLE (
        load_order  INT,
        table_name  SYSNAME,
        file_name   NVARCHAR(200)
    );

    INSERT INTO @files VALUES
        (1, 'bronze.fao_yield',         'source\yield.csv'),
        (2, 'bronze.wb_rainfall',       'source\rainfall.csv'),
        (3, 'bronze.wb_temperature',    'source\temp.csv'),
        (4, 'bronze.fao_pesticides',    'source\pesticides.csv'),
        (5, 'bronze.ref_country',       'reference\country_reference.csv'),
        (6, 'bronze.ref_country_alias', 'reference\country_aliases.csv');

    BEGIN TRY
        SET @batch_start = SYSDATETIME();
        PRINT '================================================';
        PRINT 'Loading Bronze layer from ' + @data_path;
        PRINT '================================================';

        DECLARE @table SYSNAME, @file NVARCHAR(200), @rows INT;
        DECLARE file_cursor CURSOR LOCAL FAST_FORWARD FOR
            SELECT table_name, file_name FROM @files ORDER BY load_order;

        OPEN file_cursor;
        FETCH NEXT FROM file_cursor INTO @table, @file;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @start_time = SYSDATETIME();

            SET @sql = N'TRUNCATE TABLE ' + @table + N';
                BULK INSERT ' + @table + N'
                FROM N''' + REPLACE(@data_path + @file, '''', '''''') + N'''
                WITH (
                    FORMAT          = ''CSV'',
                    FIRSTROW        = 2,
                    FIELDQUOTE      = ''"'',
                    FIELDTERMINATOR = '','',
                    ROWTERMINATOR   = ''0x0a'',
                    CODEPAGE        = ''65001'',
                    TABLOCK
                );';
            EXEC sp_executesql @sql;

            SET @sql = N'SELECT @n = COUNT(*) FROM ' + @table + N';';
            EXEC sp_executesql @sql, N'@n INT OUTPUT', @n = @rows OUTPUT;

            PRINT '>> ' + @table + ': ' + CAST(@rows AS NVARCHAR(20)) + ' rows ('
                + CAST(DATEDIFF(MILLISECOND, @start_time, SYSDATETIME()) AS NVARCHAR(20)) + ' ms)';

            FETCH NEXT FROM file_cursor INTO @table, @file;
        END;
        CLOSE file_cursor;
        DEALLOCATE file_cursor;

        PRINT '================================================';
        PRINT 'Bronze load completed in '
            + CAST(DATEDIFF(SECOND, @batch_start, SYSDATETIME()) AS NVARCHAR(20)) + ' s';
        PRINT '================================================';
    END TRY
    BEGIN CATCH
        PRINT '================================================';
        PRINT 'ERROR while loading Bronze layer';
        PRINT 'Message: ' + ERROR_MESSAGE();
        PRINT 'Number : ' + CAST(ERROR_NUMBER() AS NVARCHAR(20));
        PRINT '================================================';
        THROW;
    END CATCH;
END;
GO
