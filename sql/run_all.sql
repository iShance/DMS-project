/*
=============================================================================
AgriPulse - run_all.sql   (SQLCMD mode)
=============================================================================
Builds the whole warehouse from scratch (Bronze, Silver, Gold, semantic and
ml objects) and runs the quality checks. Then, from the project root:

    python -m agripulse.semantic    fill + validate semantic.metric_catalog
    python -m agripulse.score       write model outputs to ml.*
    pytest                          run every test, including tests/test_sql.py

From a terminal, inside the sql\ folder:

    sqlcmd -S localhost -E -i run_all.sql -v DataPath="C:\AgriPulse\datasets\"

or open it in SSMS, enable Query > SQLCMD Mode, add the line
    :setvar DataPath "C:\AgriPulse\datasets\"
at the top, and execute.

DataPath must be readable by the SQL Server service account and end with a
backslash. Folders under a user profile or OneDrive usually are not, so copy
the datasets folder somewhere like C:\AgriPulse\ first.
=============================================================================
*/

:on error exit

:r .\00_init_database.sql
:r .\01_bronze_ddl.sql
:r .\02_bronze_load_proc.sql
:r .\03_silver_ddl.sql
:r .\04_silver_load_proc.sql
:r .\05_gold_ddl.sql
:r .\06_gold_load_proc.sql

USE AgriPulse;
GO

EXEC bronze.load_bronze @data_path = N'$(DataPath)';
EXEC silver.load_silver;
EXEC gold.load_gold;
GO

:r .\09_semantic.sql
:r .\10_ml_outputs.sql
:r .\07_quality_checks.sql
