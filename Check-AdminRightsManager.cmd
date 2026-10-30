@echo off
REM Runs the PowerShell script for the local computer via double-click
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Check-AdminRightsManager.ps1" %*
pause
