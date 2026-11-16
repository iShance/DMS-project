/*
=============================================================================
AgriPulse - 00_init.sql
=============================================================================
Creates the AgriPulse database and its six schemas:
    bronze    - raw CSV data, loaded as-is (all columns NVARCHAR) + provenance
    silver    - cleaned, typed, standardized, de-duplicated data + reject log
    gold      - star schema and feature views used for OLAP and data mining
    semantic  - metric catalog and metric views (sql/04_semantic.sql)
    ml        - model runs and predictions written back by Python (sql/07_ml_outputs.sql)
    audit     - one row per table loaded by a pipeline run (audit.load_log)

WARNING: this script DROPS the AgriPulse database if it already exists.
=============================================================================
*/

USE master;
GO

IF EXISTS (SELECT 1 FROM sys.databases WHERE name = 'AgriPulse')
BEGIN
    ALTER DATABASE AgriPulse SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE AgriPulse;
END;
GO

CREATE DATABASE AgriPulse;
GO

USE AgriPulse;
GO

CREATE SCHEMA bronze;
GO
CREATE SCHEMA silver;
GO
CREATE SCHEMA gold;
GO
CREATE SCHEMA semantic;
GO
CREATE SCHEMA ml;
GO
CREATE SCHEMA audit;
GO

-- One row per target table per load procedure run. Written by bronze.load_bronze,
-- silver.load_silver and gold.load_gold, on success and on failure.
CREATE TABLE audit.load_log (
    load_id         BIGINT IDENTITY(1,1) PRIMARY KEY,
    batch_id        UNIQUEIDENTIFIER NOT NULL,   -- one per procedure call
    procedure_name  SYSNAME          NOT NULL,
    source_name     NVARCHAR(200)    NOT NULL,   -- file or upstream table(s)
    target_table    NVARCHAR(200)    NOT NULL,
    start_time      DATETIME2        NOT NULL,
    end_time        DATETIME2        NULL,
    rows_loaded     BIGINT           NULL,
    rows_rejected   BIGINT           NULL,       -- rows written to silver.reject_log
    status          NVARCHAR(20)     NOT NULL,   -- SUCCESS / FAILED
    message         NVARCHAR(4000)   NULL
);
GO
