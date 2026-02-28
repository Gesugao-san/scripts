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

:: Clear screen (CLS)
cls

:: Google HTTPS (main)
set urls[0]=https://www.google.com/generate_204
:: Google HTTP (main)  
set urls[1]=http://connectivitycheck.gstatic.com/generate_204
:: Google HTTP fallback
set urls[2]=http://www.google.com/gen_204
:: Google HTTPS fallback
set urls[3]=https://www.gstatic.com/generate_204

:: Google clients (international)
set urls[4]=https://clients1.google.com/generate_204
set urls[5]=https://clients2.google.com/generate_204
set urls[6]=https://clients3.google.com/generate_204
:: clients4.google.com commented out (no resolve)
:: set urls[7]=https://clients4.google.com/generate_204
set urls[7]=https://clients5.google.com/generate_204
set urls[8]=https://clients6.google.com/generate_204
:: clients7.google.com commented out (no resolve)
:: set urls[9]=https://clients7.google.com/generate_204

:: Google clients (Russia) - most don't resolve, keeping only working ones
set urls[9]=https://clients1.google.ru/generate_204
:: clients2.google.ru commented out (no resolve)
:: set urls[10]=https://clients2.google.ru/generate_204
:: clients3.google.ru commented out (no resolve)
:: set urls[11]=https://clients3.google.ru/generate_204
:: clients4.google.ru commented out (no resolve)
:: set urls[12]=https://clients4.google.ru/generate_204
:: clients5.google.ru commented out (no resolve)
:: set urls[13]=https://clients5.google.ru/generate_204
set urls[10]=https://clients6.google.ru/generate_204
:: clients7.google.ru commented out (no resolve)
:: set urls[14]=https://clients7.google.ru/generate_204

:: Google Maps endpoints (see stackoverflow.com/q/1989214)
set urls[11]=http://maps.google.com/generate_204
set urls[12]=http://mt.google.com/generate_204
set urls[13]=https://mt0.google.com/generate_204
set urls[14]=https://mt1.google.com/generate_204
set urls[15]=https://mt2.google.com/generate_204
set urls[16]=https://mt3.google.com/generate_204

:: Google Maps (Russia) - most don't resolve
set urls[17]=http://maps.google.ru/generate_204
:: mt.google.ru commented out (no resolve)
:: set urls[18]=http://mt.google.ru/generate_204
:: mt0.google.ru commented out (no resolve)
:: set urls[19]=https://mt0.google.ru/generate_204
:: mt1.google.ru commented out (no resolve)
:: set urls[20]=https://mt1.google.ru/generate_204
:: mt2.google.ru commented out (no resolve)
:: set urls[21]=https://mt2.google.ru/generate_204
:: mt3.google.ru commented out (no resolve)
:: set urls[22]=https://mt3.google.ru/generate_204

:: Cloudflare
set urls[18]=https://cp.cloudflare.com
set urls[19]=https://www.cloudflare.com/cdn-cgi/trace

:: Popular platforms
set urls[20]=https://www.youtube.com/
set urls[21]=https://discord.com/
set urls[22]=https://t.me/

:: Microsoft (combined)
set urls[23]=http://www.msftconnecttest.com/connecttest.txt
set urls[24]=http://www.msftncsi.com/ncsi.txt

:: Firefox
set urls[25]=http://detectportal.firefox.com/success.txt
set urls[26]=http://detectportal.firefox.com/canonical.html
:: GNOME
set urls[27]=http://nmcheck.gnome.org/check_network_status.txt
:: Huawei
set urls[28]=http://connectivitycheck.cbg-app.huawei.com/generate_204

:: Android
set urls[29]=http://connectivitycheck.android.com/generate_204

:: Apple
set urls[30]=http://captive.apple.com/hotspot-detect.html
set urls[31]=https://captive.apple.com/generate_204
set urls[32]=https://captive.apple.com/
set urls[33]=https://captive.apple.com/probe-info.html
set urls[34]=http://www.apple.com/library/test/success.html
set urls[35]=http://attwifi.apple.com/library/test/success.html

:: Xiaomi
set urls[36]=http://connect.rom.miui.com/generate_204

:: Kuketz (privacy-friendly)
set urls[37]=http://captiveportal.kuketz.de
:: /e/ Foundation & eCloud Global
set urls[38]=https://e.foundation/net_204/
set urls[39]=https://204.ecloud.global/
:: elementary OS
set urls[40]=https://elementary.io/generate_204
:: HTTP status service
set urls[41]=http://httpstat.us/204

:: Yandex
set urls[42]=http://api.browser.yandex.ru/generate_204

echo Checking the following endpoints:
echo.
:: Loop through all possible indices (0 to 42)
for /l %%i in (0,1,42) do (
    if defined urls[%%i] (
        echo   [!urls[%%i]!]
    )
)
echo.
echo ===================================================
echo.

:: Loop through all possible indices (0 to 42)
for /l %%i in (0,1,42) do (
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
