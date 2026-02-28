@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion

echo ===================================================
echo     Checking captive portal endpoints via curl
echo ===================================================
echo.

:: Check if curl is available
where curl >nul 2>nul
if %errorlevel% neq 0 (
    echo [ERROR] curl not found.
    echo.
    pause
    exit /b 1
) else (
    echo [OK] curl found: 
    where curl
    echo.
)

set urls[0]=http://api.browser.yandex.ru/generate_204
set urls[1]=http://www.google.com/gen_204
set urls[2]=https://www.gstatic.com/generate_204
set urls[3]=http://connectivitycheck.cbg-app.huawei.com/generate_204
set urls[4]=http://connect.rom.miui.com/generate_204
set urls[5]=http://captive.apple.com/hotspot-detect.html
set urls[6]=http://www.msftconnecttest.com/connecttest.txt
set urls[7]=http://connectivitycheck.android.com/generate_204
set urls[8]=http://nmcheck.gnome.org/check_network_status.txt
set urls[9]=https://www.cloudflare.com/cdn-cgi/trace
set urls[10]=http://detectportal.firefox.com/success.txt
set urls[11]=http://clients3.google.com/generate_204

echo Checking the following endpoints:
echo.
for /l %%i in (0,1,10) do (
    if defined urls[%%i] (
        echo   [!urls[%%i]!]
    )
)
echo.
echo ===================================================
echo.

for /l %%i in (0,1,10) do (
    if defined urls[%%i] (
        set "current_url=!urls[%%i]!"
        
        echo [%date% %time%] Checking: !current_url!
        echo ---------------------------------------------------
        
        curl -v --max-time 5 --location "!current_url!"
        
        echo.
        echo curl exit code: !errorlevel!
        echo ---------------------------------------------------
        echo.
        
        timeout /t 1 /nobreak >nul
    )
)

echo.
echo ===================================================
echo Done.
pause