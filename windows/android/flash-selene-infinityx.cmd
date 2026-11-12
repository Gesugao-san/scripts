@ECHO OFF
:: =============================================================================
:: flash-selene-infinityx.cmd
::
:: Installs the Infinity X GSI (Android 16) on a Xiaomi Redmi 10 / 10 2022 /
:: 10 Prime ("selene", the bootloader may call it "eos") on top of the
:: "dieD" vendor and boot by creativchic (4PDA), and can roll the phone back
:: to stock MIUI. It repeats a manual session that is known to work:
::
::   1. Stock: MIUI 14.0.7.0 Global by the stock flash_all.bat (NOT the
::      "_lock" one), so super, vendor and firmware are clean.
::   2. Check: IMEI, SIM and the Treble/A-B properties on stock.
::   3. GSI: vbmeta x3 with verification off, dieD boot, then in fastbootd:
::      product_a/_b deleted (no room for the GSI otherwise), system =
::      Infinity X, vendor = dieD, userdata and metadata wiped.
::   4. Log: waits for adb while Infinity X boots and records logcat and
::      dmesg into the "logs" folder.
::
:: Why dieD: on "eos" devices the stock MIUI 14 vendor hangs on the Mi logo
:: with Android 13+ GSIs; dieD fixes that and its boot.img can mount EROFS.
::
:: All files live next to the script. Missing ones are downloaded with aria2
:: (mirrors and checksums where they are known), archives are unpacked.
:: Every destructive group of steps asks for confirmation first.
::
:: Usage:  flash-selene-infinityx.cmd          menu
::         flash-selene-infinityx.cmd /full    stock, check, GSI, log
::         flash-selene-infinityx.cmd /gsi     GSI and log only (phone is
::                                             already on stock 14.0.7.0)
::         flash-selene-infinityx.cmd /stock   roll back to stock only
::         flash-selene-infinityx.cmd /log     record a boot log only
::         add /dry to print the commands instead of running them
::         flash-selene-infinityx.cmd /?       show help
:: Needs:  adb and fastboot (Android SDK Platform-Tools); aria2c to download,
::         7z or xz to unpack the GSI, tar (built into Windows 10+).
::         Missing tools are offered to be installed with Scoop.
::         With several devices connected, set ANDROID_SERIAL=<serial> first.
:: Exit:   0 - done
::         1 - a required tool is missing
::         2 - device not found, not selene/eos, or failed a check
::         3 - a file is missing, broken or could not be unpacked
::         4 - a flashing command failed
::         5 - cancelled by the user
:: =============================================================================
SETLOCAL EnableExtensions DisableDelayedExpansion

:: --- Files and sources -------------------------------------------------------
SET "WORK=%~dp0"
SET "LOG_DIR=%~dp0logs"

SET "STOCK_VER=V14.0.7.0.TKUMIXM"
SET "STOCK_TGZ=selene_global_images_V14.0.7.0.TKUMIXM_20240424.0000.00_13.0"
SET "STOCK_TGZ=%STOCK_TGZ%_global_c12670bd1a.tgz"
SET "STOCK_DIR=selene_global_images_V14.0.7.0.TKUMIXM_13.0"
SET "STOCK_MD5=c12670bd1a63ce588cb80544cbaf946d"
SET "STOCK_PATH=%STOCK_VER%/%STOCK_TGZ%"
SET "STOCK_URLS=https://bkt-sgp-miui-ota-update-alisgp.oss-ap-southeast-1"
SET "STOCK_URLS=%STOCK_URLS%.aliyuncs.com/%STOCK_PATH%"
SET "STOCK_URLS=%STOCK_URLS% https://bigota.d.miui.com/%STOCK_PATH%"
SET "STOCK_URLS=%STOCK_URLS% https://cdnorg.d.miui.com/%STOCK_PATH%"
SET "STOCK_URLS=%STOCK_URLS% https://hugeota.d.miui.com/%STOCK_PATH%"
SET "STOCK_URLS=%STOCK_URLS% https://bn.d.miui.com/%STOCK_PATH%"

:: GApps variant; VANILLA and MICROG ones sit in the same GitHub release.
SET "GSI_IMG=Infinity-X-3.12-GSI_treble_arm64-ab-GAPPS-Official-20260917.img"
SET "GSI_XZ=%GSI_IMG%.xz"
SET "GSI_SHA=ef9f2d0e1d3f7abe75c407ebfd850c6bbcf13d7b8dd08b2712b13717a053a36d"
SET "GSI_URLS=https://github.com/Doze-off/ProjectInfinity-X_gsi/releases"
SET "GSI_URLS=%GSI_URLS%/download/2026-09-17/%GSI_XZ%"

SET "DIED_ZIP=dieD_vendor_v2.3.zip"
SET "DIED_DIR=dieD\dieD_vendor_v2.3"
SET "DIED_URLS=https://drive.usercontent.google.com/download"
SET "DIED_URLS=%DIED_URLS%?id=1nWhBBPSUCWDWJ1XDENCBSgZxxLrot7rh"
SET "DIED_URLS=%DIED_URLS%&export=download&confirm=t"

:: --- Behaviour ---------------------------------------------------------------
:: Seconds to wait for adb while Infinity X boots (first boot: 5-15 min).
SET "BOOT_WAIT=1200"
:: Seconds between device polls.
SET "POLL=5"

:: Lookup table: bootloader "product" -> accepted (selene and its variants).
SET "PRODUCT_OK_selene=1"
SET "PRODUCT_OK_eos=1"

:: Lookup table: command -> Scoop package that provides it.
SET "SCOOP_PKG_adb=adb"
SET "SCOOP_PKG_fastboot=adb"
SET "SCOOP_PKG_aria2c=aria2"
SET "SCOOP_PKG_7z=7zip"

:: Lookup table: command -> page to download it from by hand.
SET "URL_adb=https://developer.android.com/tools/releases/platform-tools"
SET "URL_fastboot=%URL_adb%"
SET "URL_aria2c=https://github.com/aria2/aria2/releases"
SET "URL_7z=https://www.7-zip.org/download.html"
SET "URL_tar=https://learn.microsoft.com/windows/whats-new (Windows 10 1803+)"

:: Lookup table: menu key -> mode.
SET "MENU_1=full"
SET "MENU_2=gsi"
SET "MENU_3=stock"
SET "MENU_4=log"

:: "/?" is checked apart: "?" is a wildcard inside FOR's set.
IF "%~1"=="/?" GOTO :usage
SET "MODE="
SET "DRY_RUN="
FOR %%A IN (%*) DO (
  IF /I "%%~A"=="/full" SET "MODE=full"
  IF /I "%%~A"=="/gsi" SET "MODE=gsi"
  IF /I "%%~A"=="/stock" SET "MODE=stock"
  IF /I "%%~A"=="/log" SET "MODE=log"
  IF /I "%%~A"=="/dry" SET "DRY_RUN=1"
  IF /I "%%~A"=="--dry-run" SET "DRY_RUN=1"
)

CALL :Main
SET "RC=%ERRORLEVEL%"
ECHO.
IF %RC% EQU 0 (ECHO Done.) ELSE (ECHO Stopped with code %RC%.)
IF DEFINED SCRIPT_LOG ECHO Script log: "%SCRIPT_LOG%"
:: Always wait: the script is meant to be started by double-click.
PAUSE
EXIT /B %RC%


:: -----------------------------------------------------------------------------
:: Main
:: Picks the mode, gets tools and files ready, then runs the mode's stages.
:: @returns exit code of the first failed stage, or 0
:: -----------------------------------------------------------------------------
:Main
  CALL :Banner
  IF NOT DEFINED MODE CALL :Menu
  IF NOT DEFINED MODE EXIT /B 5
  CALL :InitLog
  CALL :Log "Mode: %MODE%"
  IF DEFINED DRY_RUN CALL :Log "Dry run"

  CALL :NeedFiles
  CALL :CheckTools
  IF ERRORLEVEL 1 EXIT /B 1
  CALL :PrepareFiles
  IF ERRORLEVEL 1 EXIT /B 3

  GOTO :Main_%MODE%

:Main_full
  CALL :StageStock
  IF ERRORLEVEL 1 EXIT /B %ERRORLEVEL%
  CALL :StageCheck
  IF ERRORLEVEL 1 EXIT /B %ERRORLEVEL%
  CALL :StageGsi
  IF ERRORLEVEL 1 EXIT /B %ERRORLEVEL%
  CALL :StageBootLog
EXIT /B 0

:Main_gsi
  CALL :StageCheck
  IF ERRORLEVEL 1 EXIT /B %ERRORLEVEL%
  CALL :StageGsi
  IF ERRORLEVEL 1 EXIT /B %ERRORLEVEL%
  CALL :StageBootLog
EXIT /B 0

:Main_stock
  CALL :StageStock
  IF ERRORLEVEL 1 EXIT /B %ERRORLEVEL%
EXIT /B 0

:Main_log
  CALL :StageBootLog
EXIT /B 0


:: -----------------------------------------------------------------------------
:: Banner
:: Prints what the script does and the dry-run note.
:: -----------------------------------------------------------------------------
:Banner
  ECHO =====================================================================
  ECHO  Redmi 10 / 10 2022 ^(selene/eos^): Infinity X GSI + dieD vendor
  ECHO =====================================================================
  IF DEFINED DRY_RUN ECHO  DRY RUN: commands are printed, nothing is changed.
  ECHO.
EXIT /B


:: -----------------------------------------------------------------------------
:: Menu
:: Asks for the mode; sets MODE, or leaves it undefined on Quit.
:: -----------------------------------------------------------------------------
:Menu
  ECHO  1. Full: stock MIUI, checks, Infinity X + dieD, boot log
  ECHO  2. Infinity X + dieD only ^(phone already on stock %STOCK_VER%^)
  ECHO  3. Roll back to stock MIUI only
  ECHO  4. Record a boot log only
  ECHO  Q. Quit
  ECHO.
  CHOICE /C 1234Q /N /M "Choose 1-4 or Q: "
  :: Q (5), Ctrl+C (0) or an error (255) have no MENU_n: MODE stays empty.
  CALL SET "MODE=%%MENU_%ERRORLEVEL%%%"
  ECHO.
EXIT /B


:: -----------------------------------------------------------------------------
:: NeedFiles
:: Sets NEED_STOCK and NEED_GSI for the chosen mode.
:: -----------------------------------------------------------------------------
:NeedFiles
  SET "NEED_STOCK="
  SET "NEED_GSI="
  IF "%MODE%"=="full" SET "NEED_STOCK=1"
  IF "%MODE%"=="stock" SET "NEED_STOCK=1"
  IF "%MODE%"=="full" SET "NEED_GSI=1"
  IF "%MODE%"=="gsi" SET "NEED_GSI=1"
EXIT /B


:: =============================================================================
:: Tools
:: =============================================================================

:: -----------------------------------------------------------------------------
:: CheckTools
:: Finds the tools this run needs. Missing ones are offered to be installed
:: with Scoop; without Scoop, download pages are listed.
:: @returns 0 if all tools are there, 1 otherwise
:: -----------------------------------------------------------------------------
:CheckTools
  ECHO Checking tools...
  SET "MISSING="
  SET "PKGS="
  CALL :NeedTool adb
  CALL :NeedTool fastboot
  CALL :NeedDownloadTools
  CALL :NeedUnpackTools
  IF NOT DEFINED MISSING (
    ECHO   all found.
    ECHO.
    EXIT /B 0
  )

  ECHO   missing:%MISSING%
  WHERE scoop >NUL 2>&1
  IF ERRORLEVEL 1 GOTO :CheckTools_manual

  ECHO.
  ECHO Scoop can install them: scoop install%PKGS%
  ECHO   ^("adb" is the whole Platform-Tools: adb, fastboot and the rest^)
  CHOICE /C YN /N /M "Install now? (Y/N) "
  IF NOT "%ERRORLEVEL%"=="1" GOTO :CheckTools_manual
  :: scoop is a .cmd shim: without CALL this script would end with it.
  CALL scoop install%PKGS%
  SET "MISSING="
  SET "PKGS="
  CALL :NeedTool adb
  CALL :NeedTool fastboot
  CALL :NeedDownloadTools
  CALL :NeedUnpackTools
  IF NOT DEFINED MISSING (
    ECHO.
    EXIT /B 0
  )
  ECHO Still missing:%MISSING%

:CheckTools_manual
  ECHO.
  ECHO Download them by hand and add their folder to PATH:
  FOR %%T IN (%MISSING%) DO CALL ECHO   %%T: %%URL_%%T%%
EXIT /B 1


:: -----------------------------------------------------------------------------
:: NeedTool <command>
:: Adds <command> to MISSING, and its Scoop package to PKGS (once), if the
:: command is not in PATH.
:: -----------------------------------------------------------------------------
:NeedTool
  WHERE %1 >NUL 2>&1
  IF NOT ERRORLEVEL 1 EXIT /B
  SET "MISSING=%MISSING% %1"
  CALL SET "PKG=%%SCOOP_PKG_%1%%"
  IF NOT DEFINED PKG EXIT /B
  :: Platform-Tools gives both adb and fastboot: add the package once.
  ECHO %PKGS% | FINDSTR /I /C:" %PKG% " >NUL
  IF NOT ERRORLEVEL 1 EXIT /B
  SET "PKGS=%PKGS% %PKG%"
EXIT /B


:: -----------------------------------------------------------------------------
:: NeedDownloadTools
:: aria2c is needed only if some file must be downloaded.
:: -----------------------------------------------------------------------------
:NeedDownloadTools
  CALL :FindFiles
  IF DEFINED TO_DOWNLOAD CALL :NeedTool aria2c
EXIT /B


:: -----------------------------------------------------------------------------
:: NeedUnpackTools
:: tar unpacks the stock .tgz and the dieD .zip; 7z (or xz) unpacks the GSI.
:: -----------------------------------------------------------------------------
:NeedUnpackTools
  IF DEFINED TO_UNPACK CALL :NeedTool tar
  IF NOT DEFINED UNPACK_GSI EXIT /B
  WHERE xz >NUL 2>&1
  IF NOT ERRORLEVEL 1 EXIT /B
  CALL :NeedTool 7z
EXIT /B


:: =============================================================================
:: Files
:: =============================================================================

:: -----------------------------------------------------------------------------
:: FindFiles
:: Looks at what is already next to the script and sets:
::   TO_DOWNLOAD  some archive is missing
::   TO_UNPACK    some archive must be unpacked
::   UNPACK_GSI   the GSI .xz must be unpacked
:: -----------------------------------------------------------------------------
:FindFiles
  SET "TO_DOWNLOAD="
  SET "TO_UNPACK="
  SET "UNPACK_GSI="
  IF NOT DEFINED NEED_STOCK GOTO :FindFiles_gsi
  IF EXIST "%WORK%%STOCK_DIR%\flash_all.bat" GOTO :FindFiles_gsi
  SET "TO_UNPACK=1"
  IF NOT EXIST "%WORK%%STOCK_TGZ%" SET "TO_DOWNLOAD=1"

:FindFiles_gsi
  IF NOT DEFINED NEED_GSI EXIT /B
  IF EXIST "%WORK%%GSI_IMG%" GOTO :FindFiles_died
  SET "UNPACK_GSI=1"
  IF NOT EXIST "%WORK%%GSI_XZ%" SET "TO_DOWNLOAD=1"

:FindFiles_died
  IF EXIST "%WORK%%DIED_DIR%\vendor.img" EXIT /B
  SET "TO_UNPACK=1"
  IF NOT EXIST "%WORK%%DIED_ZIP%" SET "TO_DOWNLOAD=1"
EXIT /B


:: -----------------------------------------------------------------------------
:: PrepareFiles
:: Downloads (after asking) and unpacks whatever the mode needs.
:: @returns 0 if every needed file is in place, 3 otherwise
:: -----------------------------------------------------------------------------
:PrepareFiles
  CALL :FindFiles
  IF NOT DEFINED TO_DOWNLOAD GOTO :PrepareFiles_stock
  ECHO Some files are missing next to the script and will be downloaded
  ECHO with aria2 ^(up to ~8 GB^) into "%WORK%".
  CHOICE /C YN /N /M "Download them now? (Y/N) "
  IF NOT "%ERRORLEVEL%"=="1" EXIT /B 3
:PrepareFiles_stock
  IF NOT DEFINED NEED_STOCK GOTO :PrepareFiles_gsi
  CALL :PrepareStock
  IF ERRORLEVEL 1 EXIT /B 3
:PrepareFiles_gsi
  IF NOT DEFINED NEED_GSI GOTO :PrepareFiles_done
  CALL :PrepareGsi
  IF ERRORLEVEL 1 EXIT /B 3
  CALL :PrepareDied
  IF ERRORLEVEL 1 EXIT /B 3
:PrepareFiles_done
  ECHO.
EXIT /B 0


:: -----------------------------------------------------------------------------
:: PrepareStock
:: Gets the stock fastboot ROM folder with flash_all.bat: downloads the .tgz
:: from the Xiaomi mirrors and checks its MD5, then unpacks it with tar.
:: -----------------------------------------------------------------------------
:PrepareStock
  IF EXIST "%WORK%%STOCK_DIR%\flash_all.bat" (
    ECHO Stock ROM: found "%STOCK_DIR%".
    EXIT /B 0
  )
  IF NOT EXIST "%WORK%%STOCK_TGZ%" (
    CALL :Download "%STOCK_TGZ%" md5 %STOCK_MD5% %STOCK_URLS%
    IF ERRORLEVEL 1 EXIT /B 3
  ) ELSE (
    CALL :VerifyHash "%STOCK_TGZ%" MD5 %STOCK_MD5%
    IF ERRORLEVEL 1 EXIT /B 3
  )
  ECHO Unpacking "%STOCK_TGZ%" ^(6 GB, takes a few minutes^)...
  CALL :Run tar -xzf "%WORK%%STOCK_TGZ%" -C "%WORK%."
  IF ERRORLEVEL 1 EXIT /B 3
  IF DEFINED DRY_RUN EXIT /B 0
  IF EXIST "%WORK%%STOCK_DIR%\flash_all.bat" EXIT /B 0
  ECHO Error: "%STOCK_DIR%\flash_all.bat" not found after unpacking. 1>&2
EXIT /B 3


:: -----------------------------------------------------------------------------
:: PrepareGsi
:: Gets the raw Infinity X system image: downloads the .xz from GitHub with
:: its SHA-256 check, then unpacks it with xz or 7z.
:: -----------------------------------------------------------------------------
:PrepareGsi
  IF EXIST "%WORK%%GSI_IMG%" (
    ECHO GSI: found "%GSI_IMG%".
    EXIT /B 0
  )
  IF NOT EXIST "%WORK%%GSI_XZ%" (
    CALL :Download "%GSI_XZ%" sha-256 %GSI_SHA% %GSI_URLS%
    IF ERRORLEVEL 1 EXIT /B 3
  ) ELSE (
    CALL :VerifyHash "%GSI_XZ%" SHA256 %GSI_SHA%
    IF ERRORLEVEL 1 EXIT /B 3
  )
  ECHO Unpacking "%GSI_XZ%"...
  WHERE xz >NUL 2>&1
  IF ERRORLEVEL 1 (
    CALL :Run 7z x -y "-o%WORK%." "%WORK%%GSI_XZ%"
    IF ERRORLEVEL 1 EXIT /B 3
  ) ELSE (
    CALL :Run xz -dk "%WORK%%GSI_XZ%"
    IF ERRORLEVEL 1 EXIT /B 3
  )
  IF DEFINED DRY_RUN EXIT /B 0
  IF EXIST "%WORK%%GSI_IMG%" EXIT /B 0
  ECHO Error: "%GSI_IMG%" not found after unpacking. 1>&2
EXIT /B 3


:: -----------------------------------------------------------------------------
:: PrepareDied
:: Gets the dieD folder (vbmeta.img, boot.img, vendor.img): downloads the
:: .zip from Google Drive (no published checksum) and unpacks it with tar.
:: -----------------------------------------------------------------------------
:PrepareDied
  IF EXIST "%WORK%%DIED_DIR%\vendor.img" (
    ECHO dieD: found "%DIED_DIR%".
    EXIT /B 0
  )
  IF NOT EXIST "%WORK%%DIED_ZIP%" (
    CALL :Download "%DIED_ZIP%" - - "%DIED_URLS%"
    IF ERRORLEVEL 1 EXIT /B 3
  )
  ECHO Unpacking "%DIED_ZIP%"...
  IF NOT DEFINED DRY_RUN IF NOT EXIST "%WORK%dieD" MKDIR "%WORK%dieD"
  CALL :Run tar -xf "%WORK%%DIED_ZIP%" -C "%WORK%dieD"
  IF ERRORLEVEL 1 EXIT /B 3
  IF DEFINED DRY_RUN EXIT /B 0
  FOR %%F IN (vbmeta.img boot.img vendor.img) DO (
    IF NOT EXIST "%WORK%%DIED_DIR%\%%F" (
      ECHO Error: "%DIED_DIR%\%%F" not found after unpacking. 1>&2
      EXIT /B 3
    )
  )
EXIT /B 0


:: -----------------------------------------------------------------------------
:: Download <file> <hash type|-> <hash|-> <url> [<mirror> ...]
:: Downloads <file> into WORK with aria2: 16 connections spread over all
:: given mirrors, checked against <hash> when one is given.
:: -----------------------------------------------------------------------------
:Download
  SET "DL_FILE=%~1"
  SET "DL_SUM="
  IF NOT "%~2"=="-" SET "DL_SUM=--checksum=%~2=%~3"
  ECHO Downloading "%DL_FILE%"...
  SHIFT & SHIFT & SHIFT
  SET "DL_URLS="
:Download_urls
  IF "%~1"=="" GOTO :Download_go
  :: No quotes around the SET: %1 keeps its own, which protect the "&"
  :: in the Google Drive URL.
  SET DL_URLS=%DL_URLS% %1
  SHIFT
  GOTO :Download_urls
:Download_go
  CALL :Run aria2c -x 16 -s 16 -k 1M --file-allocation=none %DL_SUM% ^
    -d "%WORK%." -o "%DL_FILE%" %DL_URLS%
  IF ERRORLEVEL 1 (
    ECHO Error: download of "%DL_FILE%" failed. 1>&2
    EXIT /B 3
  )
  IF DEFINED DRY_RUN EXIT /B 0
  :: A Google Drive error page is a few KB of HTML instead of the archive.
  FOR %%F IN ("%WORK%%DL_FILE%") DO IF %%~zF LSS 1048576 (
    ECHO Error: "%DL_FILE%" is too small, probably an HTML error page. 1>&2
    ECHO        Download it by hand into "%WORK%". 1>&2
    EXIT /B 3
  )
EXIT /B 0


:: -----------------------------------------------------------------------------
:: VerifyHash <file> <MD5|SHA256> <expected>
:: Checks a file that was already there with certutil.
:: @returns 0 if the hash matches, 3 otherwise
:: -----------------------------------------------------------------------------
:VerifyHash
  ECHO Checking %~2 of "%~1" ^(a minute for big files^)...
  IF DEFINED DRY_RUN EXIT /B 0
  SET "HASH="
  :: certutil prints a header, the hash and a status line: keep the hex one.
  :: Old Windows versions put spaces between bytes, so they are stripped.
  :: /C: is required: without it FINDSTR splits the pattern on spaces.
  SET "HEX_LINE=/R /I /X /C:"[0-9a-f][0-9a-f ]*""
  FOR /F "delims=" %%H IN (
    'certutil -hashfile "%WORK%%~1" %~2 2^>NUL ^| FINDSTR %HEX_LINE%'
  ) DO SET "HASH=%%H"
  IF DEFINED HASH SET "HASH=%HASH: =%"
  IF /I "%HASH%"=="%~3" (
    ECHO   OK.
    EXIT /B 0
  )
  ECHO Error: "%~1" is broken: %~2 %HASH% instead of %~3. 1>&2
  ECHO        Delete it and run the script again to download it anew. 1>&2
EXIT /B 3


:: =============================================================================
:: Device
:: =============================================================================

:: -----------------------------------------------------------------------------
:: CountDevices
:: Sets ADB_OK, ADB_UNAUTH, FB_N to the number of devices in each state
:: (only ANDROID_SERIAL is counted when it is set) and SERIAL to the last
:: serial seen.
:: -----------------------------------------------------------------------------
:CountDevices
  SET /A "ADB_OK=0, ADB_UNAUTH=0, FB_N=0"
  SET "SERIAL="
  FOR /F "skip=1 tokens=1,2" %%A IN ('adb devices 2^>NUL') DO (
    IF DEFINED ANDROID_SERIAL (
      IF "%%A"=="%ANDROID_SERIAL%" CALL :CountAdb %%A %%B
    ) ELSE (
      CALL :CountAdb %%A %%B
    )
  )
  FOR /F "tokens=1,2" %%A IN ('fastboot devices 2^>NUL') DO (
    IF DEFINED ANDROID_SERIAL (
      IF "%%A"=="%ANDROID_SERIAL%" CALL :CountFastboot %%A
    ) ELSE (
      CALL :CountFastboot %%A
    )
  )
EXIT /B

:CountAdb
  IF "%2"=="device" SET /A "ADB_OK+=1"
  IF "%2"=="recovery" SET /A "ADB_OK+=1"
  IF "%2"=="unauthorized" SET /A "ADB_UNAUTH+=1"
  SET "SERIAL=%1"
EXIT /B

:CountFastboot
  SET /A "FB_N+=1"
  SET "SERIAL=%1"
EXIT /B


:: -----------------------------------------------------------------------------
:: IsFastbootd
:: @returns 0 if the device in fastboot mode is fastbootd (userspace)
:: -----------------------------------------------------------------------------
:IsFastbootd
  fastboot getvar is-userspace 2>&1 | FINDSTR /I /C:"is-userspace: yes" >NUL
EXIT /B %ERRORLEVEL%


:: -----------------------------------------------------------------------------
:: ToBootloader
:: Brings exactly one device into the bootloader (fastboot, not fastbootd):
:: reboots it from adb or fastbootd, or asks to press the buttons.
:: @returns 0 when it is there, 2 if not found, 5 if cancelled
:: -----------------------------------------------------------------------------
:ToBootloader
  CALL :CountDevices
  SET /A "TOTAL=ADB_OK+ADB_UNAUTH+FB_N"
  IF DEFINED DRY_RUN IF %TOTAL% EQU 0 (
    ECHO Dry run: no device, going on as if one were in fastboot.
    EXIT /B 0
  )
  IF %TOTAL% GTR 1 (
    ECHO Error: %TOTAL% devices found. Leave one connected, 1>&2
    ECHO        or set ANDROID_SERIAL=^<serial^>. 1>&2
    EXIT /B 2
  )
  IF %FB_N% EQU 1 GOTO :ToBootloader_fastboot
  IF %ADB_OK% EQU 1 (
    ECHO Rebooting %SERIAL% into the bootloader...
    CALL :Run adb reboot bootloader
    IF DEFINED DRY_RUN EXIT /B 0
    CALL :WaitFastboot
    GOTO :ToBootloader
  )
  IF %ADB_UNAUTH% EQU 1 (
    ECHO The phone asks "Allow USB debugging?": tap Allow.
  ) ELSE (
    ECHO No phone found. Turn it off, then hold Power + Volume Down until
    ECHO the fastboot screen shows up, and connect it to this PC.
  )
  CHOICE /C RQ /N /M "R - check again, Q - quit: "
  IF NOT "%ERRORLEVEL%"=="1" EXIT /B 5
  GOTO :ToBootloader

:ToBootloader_fastboot
  CALL :IsFastbootd
  IF ERRORLEVEL 1 EXIT /B 0
  ECHO The phone is in fastbootd, rebooting it into the bootloader...
  CALL :Run fastboot reboot bootloader
  IF DEFINED DRY_RUN EXIT /B 0
  CALL :WaitFastboot
  GOTO :ToBootloader


:: -----------------------------------------------------------------------------
:: WaitFastboot
:: Waits up to 60 s for a device in fastboot mode.
:: -----------------------------------------------------------------------------
:WaitFastboot
  IF DEFINED DRY_RUN EXIT /B
  SET /A "WAITED=0"
:WaitFastboot_loop
  CALL :Sleep %POLL%
  SET /A "WAITED+=POLL"
  CALL :CountDevices
  IF %FB_N% GEQ 1 EXIT /B
  IF %WAITED% LSS 60 GOTO :WaitFastboot_loop
EXIT /B


:: -----------------------------------------------------------------------------
:: ConfirmDevice
:: Checks the bootloader "product" against the lookup table and asks the
:: user to confirm the serial. Also makes slot A active: the stock
:: flash_all.bat writes the *_a partitions only.
:: @returns 0 if confirmed, 2 if it is not selene/eos, 5 if cancelled
:: -----------------------------------------------------------------------------
:ConfirmDevice
  IF DEFINED DRY_RUN IF %FB_N% EQU 0 (
    ECHO Dry run: no device, skipping its checks.
    EXIT /B 0
  )
  SET "PRODUCT="
  FOR /F "tokens=2" %%P IN (
    'fastboot getvar product 2^>^&1 ^| FINDSTR /B /C:"product:"'
  ) DO SET "PRODUCT=%%P"
  SET "SLOT="
  FOR /F "tokens=2" %%S IN (
    'fastboot getvar current-slot 2^>^&1 ^| FINDSTR /B /C:"current-slot:"'
  ) DO SET "SLOT=%%S"
  ECHO.
  ECHO Device: %SERIAL%, product "%PRODUCT%", slot "%SLOT%".
  IF DEFINED PRODUCT CALL SET "OK=%%PRODUCT_OK_%PRODUCT%%%"
  IF NOT DEFINED PRODUCT SET "OK="
  IF NOT DEFINED OK (
    ECHO Error: this is not a Redmi 10 ^(selene/eos^), stopping. 1>&2
    EXIT /B 2
  )
  CHOICE /C YN /N /M "Is this the phone to flash? (Y/N) "
  IF NOT "%ERRORLEVEL%"=="1" EXIT /B 5
  IF NOT DEFINED SLOT EXIT /B 0
  IF /I "%SLOT%"=="a" EXIT /B 0
  IF /I "%SLOT%"=="_a" EXIT /B 0
  ECHO Slot %SLOT% is active, switching to slot a...
  CALL :Run fastboot --set-active=a
  IF ERRORLEVEL 1 EXIT /B 4
EXIT /B 0


:: -----------------------------------------------------------------------------
:: Confirm <title>
:: Asks Y/N after the warning that is already on screen. Only Y goes on:
:: N, Ctrl+C (CHOICE returns 0) or a CHOICE error (255) cancel.
:: @returns 0 on Y, 5 otherwise
:: -----------------------------------------------------------------------------
:Confirm
  ECHO.
  ECHO Battery should be above 50%%. Do not unplug the cable until done.
  CHOICE /C YN /N /M "%~1 (Y/N) "
  IF "%ERRORLEVEL%"=="1" (
    CALL :Log "Confirmed: %~1"
    EXIT /B 0
  )
  CALL :Log "Cancelled: %~1"
EXIT /B 5


:: =============================================================================
:: Stages
:: =============================================================================

:: -----------------------------------------------------------------------------
:: StageStock
:: Flashes stock MIUI with the ROM's own flash_all.bat (never the "_lock"
:: one). It runs in a child cmd: an "EXIT" in it must not end this script.
:: -----------------------------------------------------------------------------
:StageStock
  ECHO.
  ECHO --- Stock MIUI %STOCK_VER% ------------------------------------------
  CALL :ToBootloader
  IF ERRORLEVEL 1 EXIT /B %ERRORLEVEL%
  CALL :ConfirmDevice
  IF ERRORLEVEL 1 EXIT /B %ERRORLEVEL%
  CALL :SaveGetvar before-stock
  ECHO.
  ECHO WARNING: EVERYTHING on the phone will be ERASED. flash_all.bat
  ECHO writes stock MIUI %STOCK_VER% to all partitions ^(firmware,
  ECHO super, boot, userdata^). The bootloader stays UNLOCKED.
  ECHO "Fetching super ... FAILED (unknown command)" lines are harmless:
  ECHO new fastboot asks for something the MediaTek bootloader lacks.
  CALL :Confirm "Flash stock MIUI now?"
  IF ERRORLEVEL 1 EXIT /B %ERRORLEVEL%
  CALL :Log "flash_all.bat started"
  CALL :Run CMD /C ""%WORK%%STOCK_DIR%\flash_all.bat""
  IF ERRORLEVEL 1 (
    CALL :Log "flash_all.bat failed"
    ECHO Error: flash_all.bat failed, see its output above. 1>&2
    EXIT /B 4
  )
  CALL :Log "flash_all.bat done"
  ECHO.
  ECHO Stock MIUI is flashed, the phone reboots. First boot takes 5-10 min.
EXIT /B 0


:: -----------------------------------------------------------------------------
:: StageCheck
:: On stock MIUI: asks to check IMEI and SIM by hand, then reads the
:: Treble and A/B properties over adb. Can be skipped if adb is off.
:: -----------------------------------------------------------------------------
:StageCheck
  ECHO.
  ECHO --- Checks on stock MIUI ---------------------------------------------
  ECHO Wait until MIUI has booted ^(the first boot takes 5-10 min^).
  ECHO On the phone:
  ECHO   1. Skip the setup wizard. Do not add a Google account ^(if there is
  ECHO      one, remove it: after the wipe FRP would ask for it^).
  ECHO   2. Dial *#06#: both IMEI must be shown, not 0 or empty.
  ECHO   3. Insert the SIM: there must be network, try a call.
  ECHO   4. Settings ^> About phone ^> tap "MIUI version" 7 times, then
  ECHO      Additional settings ^> Developer options ^> USB debugging: on.
  ECHO.
  CHOICE /C YN /N /M "IMEI and network are fine? (Y/N) "
  IF NOT "%ERRORLEVEL%"=="1" (
    ECHO Do not go on: fix IMEI or network on stock first. 1>&2
    EXIT /B 2
  )
  CALL :CheckProps
  IF ERRORLEVEL 1 EXIT /B %ERRORLEVEL%
EXIT /B 0


:: -----------------------------------------------------------------------------
:: CheckProps
:: Waits for adb and checks the properties the GSI needs; the user may
:: skip it (then the phone must be put into fastboot by hand later).
:: -----------------------------------------------------------------------------
:CheckProps
  CALL :CountDevices
  IF %ADB_OK% EQU 1 GOTO :CheckProps_read
  IF DEFINED DRY_RUN (
    ECHO Dry run: no phone in adb, skipping the property check.
    EXIT /B 0
  )
  IF %ADB_UNAUTH% EQU 1 ECHO Tap "Allow" in the USB debugging prompt.
  IF %ADB_UNAUTH% EQU 0 ECHO adb does not see the phone yet.
  CHOICE /C RSQ /N /M "R - check again, S - skip the check, Q - quit: "
  SET "ANSWER=%ERRORLEVEL%"
  IF "%ANSWER%"=="1" GOTO :CheckProps
  IF "%ANSWER%"=="2" EXIT /B 0
EXIT /B 5

:CheckProps_read
  SET "BAD="
  CALL :ExpectProp ro.treble.enabled true
  CALL :ExpectProp ro.boot.dynamic_partitions true
  CALL :ExpectProp ro.virtual_ab.enabled true
  CALL :ExpectProp ro.product.cpu.abi arm64-v8a
  CALL :ExpectProp ro.build.version.incremental %STOCK_VER%
  CALL :ReadProp ro.vndk.version
  ECHO   ro.vndk.version = %PROP% ^(31 = Android 12 vendor, expected^)
  CALL :Log "Props checked, bad:%BAD%"
  IF NOT DEFINED BAD EXIT /B 0
  ECHO Some properties differ from a known-good stock phone.
  CHOICE /C YN /N /M "Go on anyway? (Y/N) "
  IF NOT "%ERRORLEVEL%"=="1" EXIT /B 2
EXIT /B 0


:: -----------------------------------------------------------------------------
:: ReadProp <name>
:: Sets PROP to the value of an Android system property ("" if unset).
:: -----------------------------------------------------------------------------
:ReadProp
  SET "PROP="
  FOR /F "delims=" %%V IN ('adb shell getprop %1 2^>NUL') DO SET "PROP=%%V"
EXIT /B


:: -----------------------------------------------------------------------------
:: ExpectProp <name> <value>
:: Prints the property with OK/BAD; adds <name> to BAD if it differs.
:: -----------------------------------------------------------------------------
:ExpectProp
  CALL :ReadProp %1
  IF /I "%PROP%"=="%~2" (
    ECHO   OK   %1 = %PROP%
    EXIT /B
  )
  ECHO   BAD  %1 = %PROP% ^(expected %~2^)
  SET "BAD=%BAD% %1"
EXIT /B


:: -----------------------------------------------------------------------------
:: StageGsi
:: Two destructive groups, confirmed once each:
::   bootloader - vbmeta x3 with verification off, dieD boot.img;
::   fastbootd  - product_a/_b deleted, system = GSI, vendor = dieD,
::                userdata and metadata wiped.
:: -----------------------------------------------------------------------------
:StageGsi
  ECHO.
  ECHO --- Infinity X GSI + dieD vendor -------------------------------------
  CALL :ToBootloader
  IF ERRORLEVEL 1 EXIT /B %ERRORLEVEL%
  CALL :ConfirmDevice
  IF ERRORLEVEL 1 EXIT /B %ERRORLEVEL%
  CALL :SaveGetvar before-gsi
  SET "D=%WORK%%DIED_DIR%"

  ECHO.
  ECHO WARNING ^(1/2^): boot partitions will be replaced:
  ECHO   - vbmeta, vbmeta_system, vbmeta_vendor: verification turned off
  ECHO   - boot: dieD boot.img ^(OrangeFox inside, EROFS support^)
  CALL :Confirm "Flash vbmeta and boot now?"
  IF ERRORLEVEL 1 EXIT /B %ERRORLEVEL%
  FOR %%P IN (vbmeta vbmeta_system vbmeta_vendor) DO (
    CALL :Flash --disable-verity --disable-verification flash %%P ^
      "%D%\vbmeta.img"
    IF ERRORLEVEL 1 EXIT /B 4
  )
  CALL :Flash flash boot "%D%\boot.img"
  IF ERRORLEVEL 1 EXIT /B 4

  ECHO Rebooting into fastbootd...
  CALL :Flash reboot fastboot
  IF ERRORLEVEL 1 EXIT /B 4
  IF DEFINED DRY_RUN GOTO :StageGsi_userspace
  CALL :WaitFastboot
  CALL :IsFastbootd
  IF ERRORLEVEL 1 (
    ECHO Error: the phone did not come up in fastbootd. 1>&2
    EXIT /B 4
  )

:StageGsi_userspace
  ECHO.
  ECHO WARNING ^(2/2^): the system will be replaced and ALL DATA ERASED:
  ECHO   - product_a, product_b: deleted ^(MIUI apps; frees room for GSI^)
  ECHO   - system: %GSI_IMG%
  ECHO   - vendor: dieD vendor.img
  ECHO   - userdata and metadata: formatted
  CALL :Confirm "Flash Infinity X and dieD vendor now?"
  IF ERRORLEVEL 1 EXIT /B %ERRORLEVEL%
  :: A partition that is already gone is not an error.
  CALL :Flash delete-logical-partition product_a
  CALL :Flash delete-logical-partition product_b
  CALL :Flash erase system
  IF ERRORLEVEL 1 EXIT /B 4
  CALL :Flash flash system "%WORK%%GSI_IMG%"
  IF ERRORLEVEL 1 EXIT /B 4
  CALL :Flash flash vendor "%D%\vendor.img"
  IF ERRORLEVEL 1 EXIT /B 4
  CALL :Flash -w
  IF ERRORLEVEL 1 EXIT /B 4
  CALL :Flash reboot
  IF ERRORLEVEL 1 EXIT /B 4
  ECHO.
  ECHO Infinity X is flashed. First boot takes 5-15 min: the Mi logo,
  ECHO then the Infinity X animation, then "Hello!".
EXIT /B 0


:: -----------------------------------------------------------------------------
:: StageBootLog
:: Waits up to BOOT_WAIT seconds for adb while the phone boots. Once the
:: phone is authorized, saves dmesg (needs adb root, so userdebug builds
:: only) and starts a logcat of all buffers in its own window.
:: Release ("user") builds keep adb off until USB debugging is enabled,
:: so an empty wait is normal for them.
:: -----------------------------------------------------------------------------
:StageBootLog
  ECHO.
  ECHO --- Boot log ---------------------------------------------------------
  CALL :Timestamp
  SET "LOGCAT=%LOG_DIR%\boot-logcat-%TS%.txt"
  SET "DMESG=%LOG_DIR%\boot-dmesg-%TS%.txt"
  ECHO Waiting up to %BOOT_WAIT% s for adb while the phone boots...
  ECHO ^(Ctrl+C stops waiting.^)
  IF DEFINED DRY_RUN GOTO :StageBootLog_start
  SET /A "WAITED=0, SAID_UNAUTH=0"
:StageBootLog_wait
  CALL :CountDevices
  IF %ADB_OK% GEQ 1 GOTO :StageBootLog_start
  IF %ADB_UNAUTH% GEQ 1 IF %SAID_UNAUTH% EQU 0 (
    ECHO The phone asks "Allow USB debugging?": tap Allow to get the log.
    SET "SAID_UNAUTH=1"
  )
  IF %WAITED% GEQ %BOOT_WAIT% GOTO :StageBootLog_none
  CALL :Sleep %POLL%
  SET /A "WAITED+=POLL"
  SET /A "MINUTE=WAITED %% 60"
  IF %MINUTE% EQU 0 ECHO   %WAITED% s...
  GOTO :StageBootLog_wait

:StageBootLog_start
  CALL :Log "adb is up, recording boot log"
  :: "adb root" restarts adbd on userdebug builds and fails on user ones.
  :: A pause instead of "adb wait-for-device": that one never returns if
  :: the phone is in recovery.
  CALL :Run adb root
  IF NOT DEFINED DRY_RUN CALL :Sleep 3
  ECHO Saving dmesg to "%DMESG%"...
  IF NOT DEFINED DRY_RUN CALL adb shell dmesg >"%DMESG%" 2>&1
  ECHO Recording logcat to "%LOGCAT%" in the "boot-logcat" window.
  ECHO Close that window ^(or press Ctrl+C in it^) to stop recording.
  :: Not through :Run: START is a cmd built-in, CALL would mangle it.
  :: The quoted parts keep ">" and "2>&1" for the child cmd.
  ECHO ^> adb logcat -b all -v threadtime ^> "%LOGCAT%"
  IF DEFINED DRY_RUN EXIT /B 0
  START "boot-logcat" /MIN "%ComSpec%" /C ^
    "adb logcat -b all -v threadtime > "%LOGCAT%" 2>&1"
EXIT /B 0

:StageBootLog_none
  CALL :Log "adb did not show up during boot"
  ECHO adb did not show up in %BOOT_WAIT% s. On a release build that is
  ECHO normal: adb stays off until USB debugging is enabled. To get a log
  ECHO later, enable it and run this script with /log.
  ECHO If the phone hangs on the Mi logo or loops, roll back with /stock.
EXIT /B 0


:: =============================================================================
:: Helpers
:: =============================================================================

:: -----------------------------------------------------------------------------
:: Flash <fastboot arguments>
:: Runs fastboot with the arguments and logs the result.
:: @returns fastboot's exit code
:: -----------------------------------------------------------------------------
:Flash
  CALL :Run fastboot %*
  SET "FB_RC=%ERRORLEVEL%"
  CALL :Log "fastboot %* : exit %FB_RC%"
EXIT /B %FB_RC%


:: -----------------------------------------------------------------------------
:: Run <command line>
:: Prints the command; runs it unless this is a dry run.
:: @returns the command's exit code (0 on a dry run)
:: -----------------------------------------------------------------------------
:Run
  ECHO ^> %*
  IF DEFINED DRY_RUN EXIT /B 0
  :: CALL: if adb or fastboot is a .cmd wrapper, control must come back.
  CALL %*
EXIT /B %ERRORLEVEL%


:: -----------------------------------------------------------------------------
:: SaveGetvar <name>
:: Saves "fastboot getvar all" (partitions, sizes, slots) to the logs
:: folder: handy when something has to be compared or restored.
:: -----------------------------------------------------------------------------
:SaveGetvar
  CALL :Timestamp
  SET "GETVAR=%LOG_DIR%\getvar-%1-%TS%.txt"
  IF NOT DEFINED DRY_RUN CALL fastboot getvar all >"%GETVAR%" 2>&1
  CALL :Log "Saved %GETVAR%"
EXIT /B


:: -----------------------------------------------------------------------------
:: InitLog
:: Creates the logs folder and SCRIPT_LOG, a short log of the steps taken.
:: -----------------------------------------------------------------------------
:InitLog
  IF NOT EXIST "%LOG_DIR%" MKDIR "%LOG_DIR%"
  CALL :Timestamp
  SET "SCRIPT_LOG=%LOG_DIR%\flash-%TS%.log"
  TYPE NUL >"%SCRIPT_LOG%"
EXIT /B


:: -----------------------------------------------------------------------------
:: Log <message>
:: Appends a timestamped line to SCRIPT_LOG.
:: -----------------------------------------------------------------------------
:Log
  IF NOT DEFINED SCRIPT_LOG EXIT /B
  >>"%SCRIPT_LOG%" ECHO [%DATE% %TIME%] %~1
EXIT /B


:: -----------------------------------------------------------------------------
:: Timestamp
:: Sets TS to yyyyMMdd-HHmmss; falls back to a random suffix if PowerShell
:: is not there.
:: -----------------------------------------------------------------------------
:Timestamp
  SET "TS="
  FOR /F %%T IN (
    'powershell -NoProfile -Command "Get-Date -Format yyyyMMdd-HHmmss" 2^>NUL'
  ) DO SET "TS=%%T"
  IF NOT DEFINED TS SET "TS=run-%RANDOM%%RANDOM%"
EXIT /B


:: -----------------------------------------------------------------------------
:: Sleep <seconds>
:: PING as a sleep: TIMEOUT fails when stdin is redirected.
:: -----------------------------------------------------------------------------
:Sleep
  SET /A "PINGS=%1+1"
  PING -n %PINGS% 127.0.0.1 >NUL
EXIT /B


:usage
ECHO Installs the Infinity X GSI with the dieD vendor on a Redmi 10 ^(selene^)
ECHO or rolls it back to stock MIUI %STOCK_VER%.
ECHO.
ECHO   %~nx0          menu
ECHO   %~nx0 /full    stock, checks, Infinity X + dieD, boot log
ECHO   %~nx0 /gsi     Infinity X + dieD, boot log ^(already on stock^)
ECHO   %~nx0 /stock   roll back to stock MIUI
ECHO   %~nx0 /log     record a boot log
ECHO   add /dry to print the commands instead of running them
ECHO.
ECHO Files are looked for, downloaded and unpacked next to the script.
ECHO With several devices connected, set ANDROID_SERIAL=^<serial^> first.
EXIT /B 0
