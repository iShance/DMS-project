/*
=============================================================================
AgriPulse - 00_init_database.sql
=============================================================================
Creates the AgriPulse database and the three Medallion schemas:
    bronze  - raw CSV data, loaded as-is (all columns NVARCHAR)
    silver  - cleaned, typed, standardized, de-duplicated data
    gold    - star schema used for OLAP and data mining

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
