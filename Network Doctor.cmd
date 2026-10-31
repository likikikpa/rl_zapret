@echo off
:: Finds where high ping / lag comes from (PC, Wi-Fi, cable, USB adapter,
:: router, ISP, route to Europe) and turns off network power saving on request.
:: .cmd on purpose: service.bat and the upstream tester treat *.bat as strategies.
setlocal DisableDelayedExpansion
cd /d "%~dp0"

fltmc >nul 2>&1
if not errorlevel 1 goto elevated
if "%~1"=="admin" goto no_admin
echo Requesting administrator rights...
powershell -NoProfile -Command "Start-Process -FilePath $env:ComSpec -ArgumentList '/c \"\"%~f0\" admin\"' -Verb RunAs"
if errorlevel 1 pause
exit /b

:no_admin
echo Administrator rights were not granted.
pause
exit /b 1

:elevated
title Network Doctor - ping and lag diagnostics
:menu
cls
echo.
echo   NETWORK DOCTOR - why is my ping high?
echo   ------------------------------------------------------------
echo   1. Diagnose (1-2 min), then optionally apply safe fixes
echo   2. Undo all changes made by Network Doctor
echo   0. Exit
echo.
choice /c 120 /n /m "  Select [1/2/0]: "
if errorlevel 3 exit /b
if errorlevel 2 goto revert
cls
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0utils\network-doctor.ps1"
echo.
pause
goto menu

:revert
cls
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0utils\network-doctor.ps1" -Revert
echo.
pause
goto menu
