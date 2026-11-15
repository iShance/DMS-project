/*
=============================================================================
AgriPulse - 03_silver_ddl.sql
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

USE AgriPulse;
GO

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
