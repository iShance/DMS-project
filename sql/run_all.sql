/*
=============================================================================
AgriPulse - run_all.sql   (SQLCMD mode)
=============================================================================
Builds the whole warehouse from scratch (Bronze, Silver, Gold, semantic and
ml objects), loads it and runs the quality checks.

Easiest: run  build_database.bat  from the project root. It copies the data
folder to C:\AgriPulse\data and runs this script.

By hand, from a terminal inside the sql\ folder:

    sqlcmd -S localhost -E -C -i run_all.sql -v DataPath="C:\AgriPulse\data"

DataPath is the project's data folder (holding raw\ and reference\) as seen
by the SQL Server service account. Folders under a user profile or OneDrive
usually are not readable by the service, so copy the data folder to
C:\AgriPulse\data first.

In SSMS, :r with relative paths depends on SSMS's working folder; run the
scripts one by one instead (README, "Option B").

Then, from the project root:
    python -m src.semantic.sync_metrics   fill + validate semantic.metric_catalog
    python -m src.mining.score            write model outputs to ml.*
    python -m src.quality.run_checks      PASS/FAIL for every quality check
    pytest                                every test, including tests/test_sql.py
=============================================================================
*/

:on error exit

:r .\00_init.sql
:r .\01_bronze.sql
:r .\02_silver.sql
:r .\03_gold.sql
:r .\04_semantic.sql
:r .\05_feature_views.sql
:r .\07_ml_outputs.sql

USE AgriPulse;
GO

EXEC bronze.load_bronze @data_path = N'$(DataPath)';
EXEC silver.load_silver;
EXEC gold.load_gold;
GO

:r ..\src\quality\checks.sql
