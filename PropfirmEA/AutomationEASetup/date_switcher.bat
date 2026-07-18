@echo off
title MT5 Date Switcher
setlocal enabledelayedexpansion

:: Check admin (required to change system date)
>nul 2>&1 net session
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    timeout /t 1 /nobreak >nul
    powershell -NoProfile -Command "Start-Process cmd -ArgumentList '/c \"\"%~f0\"\"' -Verb RunAs"
    exit /b
)

cd /d "%~dp0"

:menu
cls
echo ===============================================
echo            MT5 Date Switcher
echo ===============================================
echo.

:: Fetch real IST date from internet (timeapi.io)
for /f "tokens=1,2 delims=|" %%a in ('powershell -NoProfile -Command "try { $r = Invoke-RestMethod 'https://timeapi.io/api/Time/current/zone?timeZone=Asia/Kolkata' -UseBasicParsing -TimeoutSec 8; $d = $r.dateTime; Write-Output ($d.Substring(0,10) + '|' + $d.Substring(11,8)) } catch { Write-Output 'ERR|api-fail' }"') do (
    set "real_date=%%a"
    set "real_time=%%b"
)

:: Get system date
for /f "delims=" %%a in ('powershell -NoProfile -Command "(Get-Date).ToString('yyyy-MM-dd HH:mm:ss')"') do set sys_now=%%a
for /f "delims=" %%a in ('powershell -NoProfile -Command "(Get-Date).ToString('yyyy-MM-dd')"') do set sys_date=%%a

:: Compute today/tomorrow based on real date (with fallback to system)
if "%real_date%"=="ERR" (
    echo [WARNING] Could not fetch real date from internet.
    echo            Using system clock as fallback.
    echo.
    for /f "delims=" %%a in ('powershell -NoProfile -Command "(Get-Date).AddDays(1).ToString('yyyy-MM-dd')"') do set tom_date=%%a
    set "today_date=%sys_date%"
    set "real_date=%sys_date%"
    set "real_time=---"
) else (
    for /f "delims=" %%a in ('powershell -NoProfile -Command "([datetime]::ParseExact('%real_date%','yyyy-MM-dd',$null)).AddDays(1).ToString('yyyy-MM-dd')"') do set tom_date=%%a
    set "today_date=%real_date%"
)

echo Real IST date : %real_date%  %real_time%
echo System clock  : %sys_now%
echo.
echo Options:
echo   [1] Set date to TOMORROW  (real: %tom_date%^)
echo       ^> MT5 will let you test today's real data
echo.
echo   [2] Restore date to TODAY  (real: %today_date%^)
echo       ^> Back to normal after testing
echo.
echo   [3] Exit
echo.
set /p choice="Select [1/2/3]: "

if "%choice%"=="1" goto set_tomorrow
if "%choice%"=="2" goto set_today
if "%choice%"=="3" exit /b
goto menu

:set_tomorrow
cls
echo.
echo Setting date to %tom_date% (noon) ...
echo.
powershell -NoProfile -Command "Set-Date '%tom_date% %real_time%'"
if %errorlevel% neq 0 (
    echo [FAILED] Could not set date.
) else (
    echo [OK] Date changed to %tom_date%
    echo.
    echo Now restart MT5 and set test end date to %tom_date%
)
goto result

:set_today
cls
echo.
echo Restoring date to %today_date% (noon) ...
echo.
powershell -NoProfile -Command "Set-Date '%today_date% %real_time%'"
if %errorlevel% neq 0 (
    echo [FAILED] Could not restore date.
) else (
    echo [OK] Date restored to %today_date%
)
goto result

:result
echo.
echo ----------------------------------------
for /f "delims=" %%a in ('powershell -NoProfile -Command "(Get-Date).ToString('Now: yyyy-MM-dd HH:mm:ss')"') do echo %%a
echo ----------------------------------------
echo.
echo Press any key to return to menu ...
pause >nul
goto menu
