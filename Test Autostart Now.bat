@echo off
rem Proves the widget will start when you power on - without rebooting.
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0EverhourWidget.ps1" -TestAutostart
pause
