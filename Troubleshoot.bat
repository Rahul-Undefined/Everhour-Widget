@echo off
rem Run this if the widget will not appear, or to confirm autostart is set up.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0EverhourWidget.ps1" -Diagnose > "%~dp0troubleshoot-log.txt" 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0EverhourWidget.ps1" -Diagnose
echo.
echo A copy was saved to troubleshoot-log.txt
pause
