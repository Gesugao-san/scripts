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
set urls[7]=https://clients4.google.com/generate_204
set urls[8]=https://clients5.google.com/generate_204
set urls[9]=https://clients6.google.com/generate_204
set urls[10]=https://clients7.google.com/generate_204

:: Google clients (Russia)
set urls[11]=https://clients1.google.ru/generate_204
set urls[12]=https://clients2.google.ru/generate_204
set urls[13]=https://clients3.google.ru/generate_204
set urls[14]=https://clients4.google.ru/generate_204
set urls[15]=https://clients5.google.ru/generate_204
set urls[16]=https://clients6.google.ru/generate_204
set urls[17]=https://clients7.google.ru/generate_204

:: Google Maps endpoints (see stackoverflow.com/q/1989214)
set urls[18]=http://maps.google.com/generate_204
set urls[19]=http://mt.google.com/generate_204
set urls[20]=https://mt0.google.com/generate_204
set urls[21]=https://mt1.google.com/generate_204
set urls[22]=https://mt2.google.com/generate_204
set urls[23]=https://mt3.google.com/generate_204

:: Google Maps (Russia)
set urls[24]=http://maps.google.ru/generate_204
set urls[25]=http://mt.google.ru/generate_204
set urls[26]=https://mt0.google.ru/generate_204
set urls[27]=https://mt1.google.ru/generate_204
set urls[28]=https://mt2.google.ru/generate_204
set urls[29]=https://mt3.google.ru/generate_204

:: Android
set urls[30]=http://connectivitycheck.android.com/generate_204
:: Cloudflare
set urls[31]=https://cp.cloudflare.com
set urls[32]=https://www.cloudflare.com/cdn-cgi/trace
:: Microsoft (basic)
set urls[33]=http://www.msftconnecttest.com/connecttest.txt
:: Firefox
set urls[34]=http://detectportal.firefox.com/success.txt
set urls[35]=http://detectportal.firefox.com/canonical.html
:: GNOME
set urls[36]=http://nmcheck.gnome.org/check_network_status.txt
:: Huawei
set urls[37]=http://connectivitycheck.cbg-app.huawei.com/generate_204

:: Apple
set urls[38]=http://captive.apple.com/hotspot-detect.html
set urls[39]=https://captive.apple.com/generate_204
set urls[40]=https://captive.apple.com/
set urls[41]=https://captive.apple.com/probe-info.html
set urls[42]=http://www.apple.com/library/test/success.html
set urls[43]=http://attwifi.apple.com/library/test/success.html

:: Xiaomi
set urls[44]=http://connect.rom.miui.com/generate_204

:: Kuketz (privacy-friendly)
set urls[45]=http://captiveportal.kuketz.de
:: /e/ Foundation
set urls[46]=https://e.foundation/net_204/
:: elementary OS
set urls[47]=https://elementary.io/generate_204
:: HTTP status service
set urls[48]=http://httpstat.us/204

:: Microsoft (alternative NCSI)
set urls[49]=http://www.msftncsi.com/ncsi.txt

:: Yandex
set urls[50]=http://api.browser.yandex.ru/generate_204

echo Checking the following endpoints:
echo.
:: Loop through all possible indices (0 to 50)
for /l %%i in (0,1,50) do (
    if defined urls[%%i] (
        echo   [!urls[%%i]!]
    )
)
echo.
echo ===================================================
echo.

:: Loop through all possible indices (0 to 50)
for /l %%i in (0,1,50) do (
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
