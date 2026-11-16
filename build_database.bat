@echo off
setlocal
rem ==========================================================================
rem  AgriPulse - build the SQL Server warehouse on this Windows PC
rem
rem  Usage: double-click this file, or run it from a terminal:
rem      build_database.bat                  default instance (localhost)
rem      build_database.bat .\SQLEXPRESS     SQL Server Express
rem
rem  1. copies data\raw and data\reference to C:\AgriPulse\data
rem     BULK INSERT runs as the SQL Server service, which usually cannot read
rem     folders under your user profile, Desktop or OneDrive.
rem  2. runs sql\run_all.sql with sqlcmd: creates the AgriPulse database,
rem     loads Bronze, Silver and Gold, and runs the quality checks.
rem  Needs SQL Server 2017 or later and sqlcmd. Uses Windows authentication.
rem ==========================================================================

set "SERVER=%~1"
if "%SERVER%"=="" set "SERVER=localhost"
set "TARGET=C:\AgriPulse\data"
set "PROJECT=%~dp0"

where sqlcmd >nul 2>nul
if errorlevel 1 goto :nosqlcmd

echo [1/2] Copying the data files to %TARGET% ...
robocopy "%PROJECT%data\raw" "%TARGET%\raw" *.csv /NFL /NDL /NJH /NJS /NP >nul
if errorlevel 8 goto :copyfail
robocopy "%PROJECT%data\reference" "%TARGET%\reference" *.csv /NFL /NDL /NJH /NJS /NP >nul
if errorlevel 8 goto :copyfail

echo [2/2] Building the AgriPulse database on %SERVER% ...
pushd "%PROJECT%sql"
sqlcmd -S "%SERVER%" -E -C -b -i run_all.sql -v DataPath="%TARGET%"
set "RESULT=%ERRORLEVEL%"
popd
if not "%RESULT%"=="0" goto :fail

echo.
echo Done: the AgriPulse database is built and loaded on %SERVER%.
echo Open SSMS and look at the bronze, silver and gold schemas.
endlocal
pause
exit /b 0

:nosqlcmd
echo sqlcmd was not found. Install the SQL Server command line tools,
echo or run the scripts in SSMS instead: see README, Option B.
goto :fail

:copyfail
echo Could not copy the data files to %TARGET%.

:fail
echo.
echo BUILD FAILED - read the messages above.
endlocal
pause
exit /b 1
