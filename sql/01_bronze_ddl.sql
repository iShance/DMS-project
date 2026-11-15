/*
=============================================================================
AgriPulse - 01_bronze_ddl.sql
=============================================================================
Bronze layer tables. One table per source file, columns in the same order as
the CSV header. Every column is NVARCHAR so that the raw load never fails on a
bad value (e.g. the empty rainfall cells or 'NA' temperatures); typing and
cleaning happen in Silver.

    bronze.fao_yield          <- datasets/source/yield.csv       (FAO)
    bronze.wb_rainfall        <- datasets/source/rainfall.csv    (World Bank)
    bronze.wb_temperature     <- datasets/source/temp.csv        (World Bank)
    bronze.fao_pesticides     <- datasets/source/pesticides.csv  (FAO)
    bronze.ref_country        <- datasets/reference/country_reference.csv
    bronze.ref_country_alias  <- datasets/reference/country_aliases.csv

Provenance: every table ends with two technical columns,
    source_file   full path of the file the row was loaded from
    ingested_at   when bronze.load_bronze wrote the row
BULK INSERT loads through the view bronze.v_<table>_load, which lists only
the CSV columns, so the provenance columns are filled by the procedure and by
their DEFAULT rather than by the file.
=============================================================================
*/

USE AgriPulse;
GO

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
