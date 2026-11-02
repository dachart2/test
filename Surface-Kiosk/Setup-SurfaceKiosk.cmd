@echo off
REM Double-click: requests admin rights (UAC) and runs the full setup with defaults.
REM Arguments are passed through, e.g.
REM   Setup-SurfaceKiosk.cmd -StartUrl https://www.startpage.com -IdleResetMinutes 0
net session >nul 2>&1
if errorlevel 1 (
    if "%~1"=="" (
        powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    ) else (
        powershell.exe -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%*' -Verb RunAs"
    )
    exit /b
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Setup-SurfaceKiosk.ps1" %*
pause
