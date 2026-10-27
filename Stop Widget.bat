@echo off
rem Stops the Everhour widget for this session.
rem It starts again at next login unless you turn that off in Settings.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0EverhourWidget.ps1" -StopOthers
timeout /t 2 >nul
