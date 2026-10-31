@echo off
:: Tests every general*.bat strategy on this connection, saves the one that
:: works best for Discord (then YouTube, Rocket League) and starts it.
:: .cmd on purpose: service.bat and the upstream tester treat *.bat as strategies.
setlocal DisableDelayedExpansion
chcp 437 >nul
cd /d "%~dp0"

fltmc >nul 2>&1
if not errorlevel 1 goto elevated
if "%~1"=="admin" goto no_admin
echo Requesting administrator rights...
powershell -NoProfile -Command "Start-Process -FilePath $env:ComSpec -ArgumentList '/c \"\"%~f0\" admin\"' -Verb RunAs"
if errorlevel 1 pause
exit /b

:no_admin
echo Administrator rights were not granted. Zapret cannot run without them.
pause
exit /b 1

:elevated
title Zapret - auto select strategy
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0utils\auto-select.ps1"
echo.
pause
