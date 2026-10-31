@echo off
cd /d "%~dp0"
echo 1. Direct login - recommended when login works with zapret stopped
echo 2. Use each ALT's DPI strategy for login - try if direct login fails
choice /c 12 /n /m "Select login mode [1/2]: "
if errorlevel 2 goto dpi
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0utils\configure-rocket-league.ps1" -AuthMode Direct
goto done
:dpi
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0utils\configure-rocket-league.ps1" -AuthMode Strategy
:done
pause
