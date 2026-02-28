@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion
cls

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

:: OS/Device Specific
:: Ubuntu/Linux (NetworkManager)
set urls[42]=http://connectivity-check.ubuntu.com/
:: Samsung
set urls[43]=http://connectivitycheck.samsung.com/generate_204
:: Huawei/Honor (alternative)
set urls[44]=http://connectivitycheck.platform.hicloud.com/generate_204
:: Amazon FireOS
set urls[45]=http://device.amazon.com/generate_204
:: Apple (additional)
set urls[46]=http://gsp1.apple.com/
set urls[47]=http://www.appleiphonecell.com/
set urls[48]=http://www.itools.info/

:: Microsoft (additional)
:: Microsoft IPv6
set urls[49]=http://ipv6.msftconnecttest.com/connecttest.txt
:: Microsoft Edge alternative
set urls[50]=http://edge-http.microsoft.com/generate_204
:: Microsoft 365 connectivity test
set urls[51]=https://connectivity.m365.cloud.microsoft/

:: Cloudflare & DNS Providers
:: Cloudflare additional endpoints
set urls[52]=http://cp.cloudflare.com/generate_204
set urls[53]=https://1.1.1.1/cdn-cgi/trace
set urls[54]=http://www.cloudflare.com/generate_204
:: Google DNS
set urls[55]=https://dns.google/resolve?name=example.com&type=A
:: OpenDNS/Cisco
set urls[56]=http://www.opendns.com/
:: Quad9 DNS
set urls[57]=https://www.quad9.net/

:: Social Media & Services
:: Meta (Facebook)
set urls[58]=https://www.facebook.com/
set urls[59]=https://m.me/
set urls[60]=https://www.whatsapp.com/
:: Instagram
set urls[61]=https://www.instagram.com/
:: X (Twitter)
set urls[62]=https://twitter.com/
:: LinkedIn
set urls[63]=https://www.linkedin.com/
:: Pinterest
set urls[64]=https://www.pinterest.com/
:: Snapchat
set urls[65]=https://www.snapchat.com/
:: Reddit
set urls[66]=https://www.reddit.com/
:: Tumblr
set urls[67]=https://www.tumblr.com/
:: Threads
set urls[68]=https://www.threads.net/
:: Bluesky
set urls[69]=https://bsky.app/
:: Twitch
set urls[70]=https://www.twitch.tv/
:: TikTok
set urls[71]=https://www.tiktok.com/
:: Signal
set urls[72]=https://signal.org/
:: Telegram Web
set urls[73]=https://web.telegram.org/

:: Search Engines & Portals
set urls[74]=https://duckduckgo.com/
set urls[75]=https://www.bing.com/
set urls[76]=https://www.yahoo.com/
set urls[77]=https://www.baidu.com/

:: Video & Streaming
set urls[78]=https://youtube.com/shorts/
set urls[79]=https://vimeo.com/
set urls[80]=https://www.dailymotion.com/
set urls[81]=https://www.netflix.com/
set urls[82]=https://open.spotify.com/
set urls[83]=https://soundcloud.com/

:: E-commerce & Marketplaces
set urls[84]=https://www.amazon.com/
set urls[85]=https://www.amazon.de/
set urls[86]=https://www.amazon.co.uk/
set urls[87]=https://www.ebay.com/
set urls[88]=https://www.etsy.com/
set urls[89]=https://www.shopify.com/
set urls[90]=http://www.aliexpress.com/
set urls[91]=https://www.alibaba.com/
set urls[92]=https://www.temu.com/
set urls[93]=https://ru.shein.com/

:: Tech & AI Companies
set urls[94]=https://www.microsoft.com/
set urls[95]=https://www.apple.com/
set urls[96]=https://openai.com/
set urls[97]=https://www.anthropic.com/
set urls[98]=https://x.ai/
set urls[99]=https://www.deepseek.com/
set urls[100]=https://ai.google/
set urls[101]=https://ai.meta.com/
set urls[102]=https://www.perplexity.ai/
set urls[103]=https://huggingface.co/
set urls[104]=https://github.com/
set urls[105]=https://about.gitlab.com/
set urls[106]=https://stackoverflow.com/

:: Cloud Services & Hosting
set urls[107]=https://cloud.google.com/
set urls[108]=https://azure.microsoft.com/
set urls[109]=https://www.digitalocean.com/
set urls[110]=https://vercel.com/
set urls[111]=https://www.netlify.com/
set urls[112]=https://www.heroku.com/

:: Education & Science
set urls[113]=https://www.wikipedia.org/
set urls[114]=https://www.coursera.org/
set urls[115]=https://www.edx.org/
set urls[116]=https://www.khanacademy.org/
set urls[117]=https://www.duolingo.com/
set urls[118]=https://arxiv.org/
set urls[119]=https://scholar.google.com/
set urls[120]=https://www.researchgate.net/

:: Crypto & Web3
set urls[121]=https://www.coinbase.com/
set urls[122]=https://www.binance.com/
set urls[123]=https://ethereum.org/
set urls[124]=https://opensea.io/

:: Chinese services
set urls[125]=https://www.wechat.com/
set urls[126]=https://www.baidu.com/
set urls[127]=http://www.aliexpress.com/
set urls[128]=https://www.alibaba.com/

:: Russian services
set urls[129]=https://vk.com/
set urls[130]=https://rutube.ru/
set urls[131]=https://www.wildberries.ru/
set urls[132]=https://www.ozon.ru/
set urls[133]=https://www.avito.ru/
set urls[134]=https://yandex.ru/
set urls[135]=https://mail.ru/
set urls[136]=https://www.rambler.ru/

:: Yandex (captive portal endpoint)
set urls[137]=http://api.browser.yandex.ru/generate_204

echo Checking the following endpoints:
echo.
:: Loop through all possible indices (0 to 137)
for /l %%i in (0,1,137) do (
    if defined urls[%%i] (
        echo   [!urls[%%i]!]
    )
)
echo.
echo ===================================================
echo.

:: Loop through all possible indices (0 to 137)
for /l %%i in (0,1,137) do (
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
