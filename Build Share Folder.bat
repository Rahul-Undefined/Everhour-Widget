@echo off
rem Makes "Share\Everhour Widget" (and a .zip) to give to anyone.
rem On their laptop they double-click "Install Everhour Widget.vbs".
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0EverhourWidget.ps1" -BuildShare
pause
