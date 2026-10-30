@echo off
REM Startet das PowerShell-Skript per Doppelklick fuer den lokalen Rechner
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Check-AdminRightsManager.ps1" %*
pause
