@echo off
REM Double-click: asks for computer name(s); empty input = this computer.
REM With arguments, they are passed through to the script, e.g.
REM   Check-AdminRightsManager.cmd -ComputerName NB-001,NB-002
if "%~1"=="" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Check-AdminRightsManager.ps1" -Prompt
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Check-AdminRightsManager.ps1" %*
)
pause
