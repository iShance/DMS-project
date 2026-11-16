@echo off
rem ==========================================================================
rem  AgriPulse - START HERE
rem  Double-click this file. It checks what the project needs, installs what
rem  is missing (after asking you), builds the SQL Server database, runs the
rem  quality checks and opens everything for the presentation.
rem  Details: setup\START_HERE.ps1   Log: setup_log.txt
rem ==========================================================================
title AgriPulse - setup and presentation
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup\START_HERE.ps1" %*
if errorlevel 1 pause
