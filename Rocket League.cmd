@echo off
:: Rocket League + Discord launcher for zapret (Windows 10 / Windows 11).
:: This file is .cmd on purpose: service.bat and "utils\test zapret.ps1" treat
:: every *.bat in this folder as a zapret strategy, and this is not one.
setlocal DisableDelayedExpansion
chcp 437 >nul
cd /d "%~dp0"

:: WinDivert (the packet driver used by winws.exe) requires administrator rights.
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
title Zapret - Rocket League + Discord
set "DEFAULT_STRATEGY=general (ALT9).bat"
set "STRATEGY_FILE=%~dp0utils\rl-strategy.txt"
set "PS=powershell -NoProfile -ExecutionPolicy Bypass -File"
call :load_strategy

:: cmd.exe limits a command line to 8191 characters. Every list/fake file in a
:: strategy is passed with its full path, so long folder paths make the longest
:: strategies (ALT11, EXP, ALT12) fail with "The input line is too long".
set "ROOT_PATH=%~dp0"
if not "%ROOT_PATH:~57,1%"=="" (
    echo.
    echo   WARNING: this folder path is too long for some strategies.
    echo   Move the folder somewhere short, for example C:\zapret
    echo.
    pause
)

:: Double-click = start the saved strategy right away, then show the menu.
goto start


:: MENU ==================================================================
:menu
cls
call :read_status
echo.
echo   ZAPRET - ROCKET LEAGUE + DISCORD
echo   ------------------------------------------------------------
echo   Strategy     : %STRATEGY%
echo   Zapret       : %ZSTATE%
echo   RL login     : %RL_AUTH%
echo   Discord fake : %DFAKE%
echo   ------------------------------------------------------------
echo   1. Start / restart zapret with this strategy
echo   2. Choose another strategy (ALT)
echo   3. Stop zapret
echo.
echo   4. Test all strategies (find one where Discord works)
echo   5. Switch Discord voice fake (voice stuck on "RTC Connecting")
echo   6. Rocket League login mode (Direct / DPI)
echo   7. Rocket League network diagnostics
echo   8. Advanced settings (service.bat: Game Filter, IPSet, service)
echo.
echo   0. Exit
echo.
set "choice_menu="
set /p "choice_menu=  Select option: "
if "%choice_menu%"=="1" goto start
if "%choice_menu%"=="2" goto choose
if "%choice_menu%"=="3" goto stop
if "%choice_menu%"=="4" goto tests
if "%choice_menu%"=="5" goto discord_fake
if "%choice_menu%"=="6" goto login_mode
if "%choice_menu%"=="7" goto diagnostics
if "%choice_menu%"=="8" goto advanced
if "%choice_menu%"=="0" exit /b
goto menu


:: START =================================================================
:start
cls
call :service_running
if not errorlevel 1 goto service_conflict
if not exist "%~dp0%STRATEGY%" (
    echo Strategy file not found. Choose a strategy first.
    pause
    goto choose
)

call :stop_winws
echo Starting "%STRATEGY%" ...
:: Upstream update checks point to Flowseal releases, which do not contain the
:: Rocket League rules, and run in the background where they can eat keypresses.
set "NO_UPDATE_CHECK=1"
call "%~dp0%STRATEGY%"
cd /d "%~dp0"
chcp 437 >nul

timeout /t 3 /nobreak >nul
call :winws_running
if errorlevel 1 goto start_failed
echo.
echo   Zapret is running ("%STRATEGY%").
echo   Restart Discord and Rocket League now so they open new connections.
echo   If Discord still does not work, use option 4 to find a working ALT.
echo.
pause
goto menu

:start_failed
echo.
echo   winws.exe stopped right after starting.
echo   Run "%STRATEGY%" as administrator to read its error, close other
echo   bypass tools (GoodbyeDPI, other zapret copies, VPN clients with a
echo   packet filter) and run service.bat - Run Diagnostics.
echo.
pause
goto menu

:service_conflict
echo.
echo   The zapret Windows service is running. Two copies of winws cannot run
echo   at the same time. Open service.bat (option 8) and choose
echo   "Remove Services", or keep using the installed service.
echo.
pause
goto menu


:: STOP ==================================================================
:stop
cls
call :service_running
if not errorlevel 1 goto service_conflict
call :stop_winws
echo Zapret stopped.
pause
goto menu


:: CHOOSE STRATEGY =======================================================
:choose
cls
echo.
echo   All strategies include the Rocket League rules. Discord/YouTube
echo   support differs by provider - use option 4 to test them.
echo.
setlocal EnableDelayedExpansion
set "count=0"
for %%F in ("general*.bat") do (
    set /a count+=1
    set "strategy_!count!=%%~nxF"
    echo   !count!. %%~nxF
)
echo   0. Back
echo.
set "pick="
set /p "pick=  Select strategy: "
if not defined pick (endlocal & goto menu)
:: Reject anything that is not only digits (no pipe: piped commands lose !vars!).
for /f "delims=0123456789" %%A in ("!pick!") do (endlocal & goto choose)
if "!pick!"=="0" (endlocal & goto menu)
set "picked=!strategy_%pick%!"
if not defined picked (endlocal & goto choose)
endlocal & set "STRATEGY=%picked%"
>"%STRATEGY_FILE%" echo %STRATEGY%
echo.
choice /c YN /n /m "  Saved. Start it now? [Y/N]: "
if errorlevel 2 goto menu
goto start


:: TESTS =================================================================
:tests
cls
echo Opening the zapret strategy tester in a new window.
echo Choose "Standard tests", then test all strategies. Pick the strategy
echo where the Discord lines pass, then select it with option 2.
start "zapret tests" %PS% "%~dp0utils\test zapret.ps1"
pause
goto menu


:: DISCORD VOICE FAKE ====================================================
:discord_fake
cls
echo.
echo   Discord voice uses a fake packet to pass DPI. Providers react differently.
echo.
echo   1. steamcommunity  - zapret 1.10.4 default
echo   2. dbankcloud      - used by this folder before the 1.10.4 update
echo   0. Back
echo.
choice /c 120 /n /m "  Select [1/2/0]: "
if errorlevel 3 goto menu
set "fake_src=quic_initial_steamcommunity_com.bin"
if errorlevel 2 set "fake_src=quic_initial_dbankcloud_ru.bin"
copy /y "%~dp0bin\%fake_src%" "%~dp0bin\ACTIVE_DISCORD_UDP.bin" >nul || goto copy_failed
goto ask_restart

:copy_failed
echo   Could not replace bin\ACTIVE_DISCORD_UDP.bin. Stop zapret and try again.
pause
goto menu


:: ROCKET LEAGUE LOGIN MODE ==============================================
:login_mode
cls
echo.
echo   1. Direct login - RL/Epic login traffic is not modified (default)
echo   2. DPI login    - apply the strategy's TCP desync to RL/Epic login
echo                     (try this if Rocket League cannot log in)
echo   0. Back
echo.
choice /c 120 /n /m "  Select [1/2/0]: "
if errorlevel 3 goto menu
if errorlevel 2 (set "auth_mode=Strategy") else set "auth_mode=Direct"
%PS% "%~dp0utils\configure-rocket-league.ps1" -AuthMode %auth_mode%
if errorlevel 1 (
    echo   Failed to update the strategies.
    pause
    goto menu
)
goto ask_restart


:: DIAGNOSTICS ===========================================================
:diagnostics
cls
%PS% "%~dp0utils\test-rocket-league.ps1"
pause
goto menu


:: ADVANCED ==============================================================
:advanced
start "zapret service" /d "%~dp0." cmd /c service.bat admin
goto menu


:: HELPERS ===============================================================
:ask_restart
call :winws_running
if errorlevel 1 (
    echo   Saved. It applies the next time zapret starts.
    pause
    goto menu
)
echo.
choice /c YN /n /m "  Saved. Restart zapret now to apply? [Y/N]: "
if errorlevel 2 goto menu
goto start

:load_strategy
set "STRATEGY=%DEFAULT_STRATEGY%"
if exist "%STRATEGY_FILE%" set /p "STRATEGY=" <"%STRATEGY_FILE%"
if /i not "%STRATEGY:~0,7%"=="general" set "STRATEGY=%DEFAULT_STRATEGY%"
if /i not "%STRATEGY:~-4%"==".bat" set "STRATEGY=%DEFAULT_STRATEGY%"
if not exist "%~dp0%STRATEGY%" set "STRATEGY=%DEFAULT_STRATEGY%"
exit /b

:read_status
set "ZSTATE=stopped"
call :winws_running
if not errorlevel 1 set "ZSTATE=RUNNING"
call :service_running
if not errorlevel 1 set "ZSTATE=RUNNING as Windows service (see option 8)"
set "RL_AUTH=Direct"
findstr /i /r /c:"AuthMode.*Strategy" "%~dp0utils\rocket-league.json" >nul 2>&1
if not errorlevel 1 set "RL_AUTH=DPI"
set "DFAKE=custom (set in service.bat)"
fc /b "%~dp0bin\ACTIVE_DISCORD_UDP.bin" "%~dp0bin\quic_initial_steamcommunity_com.bin" >nul 2>&1
if not errorlevel 1 set "DFAKE=steamcommunity (1.10.4 default)"
fc /b "%~dp0bin\ACTIVE_DISCORD_UDP.bin" "%~dp0bin\quic_initial_dbankcloud_ru.bin" >nul 2>&1
if not errorlevel 1 set "DFAKE=dbankcloud (pre-1.10.4 setup)"
exit /b

:winws_running
tasklist /fi "IMAGENAME eq winws.exe" 2>nul | find /i "winws.exe" >nul
exit /b

:service_running
sc query zapret 2>nul | find /i "RUNNING" >nul
exit /b

:stop_winws
call :winws_running
if errorlevel 1 exit /b 0
taskkill /f /im winws.exe >nul 2>&1
timeout /t 2 /nobreak >nul
exit /b 0
