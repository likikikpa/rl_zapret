@echo off
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0utils\start-rocket-league.ps1"
if errorlevel 1 pause
