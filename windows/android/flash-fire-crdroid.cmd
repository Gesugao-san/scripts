@ECHO OFF
:: =============================================================================
:: flash-fire-crdroid.cmd
::
:: Installs crDroid (Android 16) on a Xiaomi Redmi 12 4G ("fire") the way the
:: maintainer's guide in the support chat describes it:
::
::   1. Files: finds the crDroid ROM zip, its boot image, recovery image and
::      modem image (md1img) next to the script or in Downloads (also in
::      "Downloads\Telegram Desktop"). Missing ones are to be downloaded by
::      hand from the Telegram channel, which the script opens.
::   2. Checks, while the phone runs stock HyperOS: product, stock version
::      (the guide asks for Global 2.0.209 or India 2.0.207), then in
::      fastboot: product again, an unlocked bootloader, that slot b has
::      booted before (the ROM needs stock firmware in both slots), and the
::      anti-rollback index ("fastboot getvar anti"), which is only shown:
::      2 means India firmware was installed once and can never be undone.
::   3. Fastboot: boot, recovery to vendor_boot, md1img, reboot to recovery.
::      Since the 18.10.2026 recovery, boot is required: the recovery uses
::      the kernel from it and bootloops on the stock one.
::   4. Recovery: you format data and choose Apply from ADB on the phone;
::      the script waits for sideload mode and sends the ROM, then GApps.
::
:: Safe by default: every failed check stops the script. It never flashes a
:: stock firmware zip ("SP Flash Tool" case of the guide): with anti-rollback
:: a wrong firmware means a hard brick, so that stays a manual step after
:: asking the maintainer. Each check that a maintainer may waive for your
:: phone has its own override variable (see below); set it only after they
:: confirm. Every destructive group of steps asks for confirmation first.
::
:: Usage:  flash-fire-crdroid.cmd          check, then flash
::         flash-fire-crdroid.cmd /dry     print the commands, change nothing
::         flash-fire-crdroid.cmd /?       show help
:: Needs:  adb and fastboot (Android SDK Platform-Tools), offered to be
::         installed with Scoop; the fastboot driver (Google USB Driver,
::         bound by hand to the phone in fastboot mode); USB debugging on.
::         With several devices connected, set ANDROID_SERIAL=<serial> first.
:: Overrides (environment variables, only after the maintainer says so):
::         CRDROID_ALLOW_PRODUCT=<codename>  accept another product, e.g. heat
::         CRDROID_ALLOW_BASE=1              accept any stock version
::         CRDROID_ALLOW_SLOT_B=1            go on if slot b never booted
:: Exit:   0 - done
::         1 - a required tool is missing
::         2 - device not found or failed a check
::         3 - a file is missing or broken
::         4 - a flashing command failed
::         5 - cancelled by the user
:: =============================================================================
SETLOCAL EnableExtensions DisableDelayedExpansion

:: --- Sources and files -------------------------------------------------------
SET "CHANNEL=https://t.me/crdroidfire"
SET "SCRIPT_DIR=%~dp0"
SET "LOG_DIR=%~dp0logs"
:: File masks; when several files match, the newest one is taken.
SET "MASK_ROM=crDroidAndroid-*-fire-*.zip"
SET "MASK_BOOT=boot*.img"
SET "MASK_REC1=recovery*.img"
SET "MASK_REC2=vendor_boot*.img"
SET "MASK_MD1=md1img*.img"
SET "MASK_GAPPS=*gapps*.zip"

:: --- Behaviour ---------------------------------------------------------------
:: Seconds to wait for the phone in fastboot, and in sideload mode.
SET "FASTBOOT_WAIT=60"
SET "SIDELOAD_WAIT=600"
:: Seconds between device polls.
SET "POLL=3"

:: Lookup table: product (codename) -> accepted.
SET "PRODUCT_OK_fire=1"
IF DEFINED CRDROID_ALLOW_PRODUCT SET "PRODUCT_OK_%CRDROID_ALLOW_PRODUCT%=1"

:: Lookup table: stock HyperOS version -> accepted (from the guide).
SET "BASE_OK_OS2.0.209.0.VMXMIXM=1"
SET "BASE_OK_OS2.0.207.0.VMXINXM=1"

:: Lookup table: anti-rollback index -> what it means. On the Redmi 12 only
:: India firmware raises it; see the support chat's notes.
SET "ARB_NOTE_1=not raised: no India firmware so far"
SET "ARB_NOTE_2=raised by India firmware: no older or other-region stock"

:: Lookup table: command -> Scoop package that provides it.
SET "SCOOP_PKG_adb=adb"
SET "SCOOP_PKG_fastboot=adb"

:: "/?" is checked apart: "?" is a wildcard inside FOR's set.
IF "%~1"=="/?" GOTO :usage
SET "DRY_RUN="
FOR %%A IN (%*) DO (
  IF /I "%%~A"=="/dry" SET "DRY_RUN=1"
  IF /I "%%~A"=="--dry-run" SET "DRY_RUN=1"
)

CALL :Main
SET "RC=%ERRORLEVEL%"
ECHO.
IF %RC% EQU 0 (ECHO Done.) ELSE (ECHO Stopped with code %RC%.)
IF DEFINED SCRIPT_LOG ECHO Script log: "%SCRIPT_LOG%"
:: Always wait: the script may be started by double-click.
PAUSE
EXIT /B %RC%


:: -----------------------------------------------------------------------------
:: Main
:: Gets tools and files ready, checks the phone, then flashes.
:: @returns exit code of the first failed stage, or 0
:: -----------------------------------------------------------------------------
:Main
  CALL :Banner
  CALL :InitLog
  IF DEFINED DRY_RUN CALL :Log "Dry run"

  CALL :CheckTools
  IF ERRORLEVEL 1 EXIT /B 1
  CALL :StageFiles
  IF ERRORLEVEL 1 EXIT /B %ERRORLEVEL%
  CALL :StageCheckSystem
  IF ERRORLEVEL 1 EXIT /B %ERRORLEVEL%
  CALL :StageCheckBootloader
  IF ERRORLEVEL 1 EXIT /B %ERRORLEVEL%
  CALL :StageFastboot
  IF ERRORLEVEL 1 EXIT /B %ERRORLEVEL%
  CALL :StageSideload
EXIT /B %ERRORLEVEL%


:: -----------------------------------------------------------------------------
:: Banner
:: Prints what the script does and the dry-run note.
:: -----------------------------------------------------------------------------
:Banner
  ECHO =====================================================================
  ECHO  Redmi 12 4G ^(fire^): crDroid by the support chat's guide
  ECHO =====================================================================
  IF DEFINED DRY_RUN ECHO  DRY RUN: commands are printed, nothing is changed.
  ECHO  Back up the phone first: formatting data erases everything on it.
  ECHO.
EXIT /B


:: =============================================================================
:: Tools
:: =============================================================================

:: -----------------------------------------------------------------------------
:: CheckTools
:: Finds adb and fastboot; offers to install them with Scoop.
:: @returns 0 if both are there, 1 otherwise
:: -----------------------------------------------------------------------------
:CheckTools
  SET "MISSING="
  CALL :NeedTool adb
  CALL :NeedTool fastboot
  IF NOT DEFINED MISSING EXIT /B 0

  ECHO Missing:%MISSING%
  WHERE scoop >NUL 2>&1
  IF ERRORLEVEL 1 GOTO :CheckTools_manual
  CHOICE /C YN /N /M "Install Platform-Tools: scoop install adb? (Y/N) "
  IF NOT "%ERRORLEVEL%"=="1" GOTO :CheckTools_manual
  :: scoop is a .cmd shim: without CALL this script would end with it.
  CALL scoop install adb
  SET "MISSING="
  CALL :NeedTool adb
  CALL :NeedTool fastboot
  IF NOT DEFINED MISSING EXIT /B 0

:CheckTools_manual
  ECHO Get them from
  ECHO   https://developer.android.com/tools/releases/platform-tools
  ECHO and add their folder to PATH.
EXIT /B 1


:: -----------------------------------------------------------------------------
:: NeedTool <command>
:: Adds <command> to MISSING if it is not in PATH.
:: -----------------------------------------------------------------------------
:NeedTool
  WHERE %1 >NUL 2>&1
  IF ERRORLEVEL 1 SET "MISSING=%MISSING% %1"
EXIT /B


:: =============================================================================
:: Files
:: =============================================================================

:: -----------------------------------------------------------------------------
:: StageFiles
:: Finds ROM, boot, recovery, md1img and (optional) GApps; until all
:: required ones are there, opens the channel and offers to look again.
:: Then shows them, checks the ROM's .sha256 if there is one, and asks to
:: go on.
:: @returns 0 when ready, 3 if a file is broken, 5 if cancelled
:: -----------------------------------------------------------------------------
:StageFiles
  CALL :FindDownloads
:StageFiles_find
  CALL :FindFile "%MASK_ROM%" ROM
  CALL :FindFile "%MASK_BOOT%" BOOT
  CALL :FindFile "%MASK_REC1%" REC
  IF NOT DEFINED REC CALL :FindFile "%MASK_REC2%" REC
  CALL :FindFile "%MASK_MD1%" MD1
  CALL :FindFile "%MASK_GAPPS%" GAPPS

  SET "LACK="
  IF NOT DEFINED ROM SET "LACK=%LACK% %MASK_ROM%"
  IF NOT DEFINED BOOT SET "LACK=%LACK% %MASK_BOOT%"
  IF NOT DEFINED REC SET "LACK=%LACK% %MASK_REC1%"
  IF NOT DEFINED MD1 SET "LACK=%LACK% %MASK_MD1%"
  IF NOT DEFINED LACK GOTO :StageFiles_show

  ECHO Not found:%LACK%
  ECHO Looked in: "%SCRIPT_DIR%", "%DL%\Telegram Desktop", "%DL%".
  ECHO Download the ROM, boot, recovery and md1img of ONE release from
  ECHO   %CHANNEL%
  ECHO ^(opening it now^), then come back here.
  IF NOT DEFINED DRY_RUN START "" "%CHANNEL%"
  CHOICE /C RQ /N /M "R - look again, Q - quit: "
  IF NOT "%ERRORLEVEL%"=="1" EXIT /B 5
  GOTO :StageFiles_find

:StageFiles_show
  ECHO Files:
  CALL :ShowFile "ROM     " "%ROM%"
  CALL :ShowFile "Boot    " "%BOOT%"
  CALL :ShowFile "Recovery" "%REC%"
  CALL :ShowFile "md1img  " "%MD1%"
  IF DEFINED GAPPS (CALL :ShowFile "GApps   " "%GAPPS%") ELSE (
    ECHO   GApps    none found, the ROM is installed without Google apps
  )
  CALL :Log "ROM %ROM%"
  CALL :Log "Boot %BOOT%"
  CALL :Log "Recovery %REC%"
  CALL :Log "md1img %MD1%"
  CALL :Log "GApps %GAPPS%"

  CALL :VerifyRom
  IF ERRORLEVEL 1 EXIT /B 3

  ECHO.
  ECHO Boot, recovery and md1img must come from the same release as the
  ECHO ROM, or the recovery bootloops:
  ECHO compare the names and dates above with the channel's post.
  CHOICE /C YN /N /M "Are these the right files? (Y/N) "
  IF NOT "%ERRORLEVEL%"=="1" EXIT /B 5
EXIT /B 0


:: -----------------------------------------------------------------------------
:: FindDownloads
:: Sets DL to the user's Downloads folder, also when it was moved: the
:: registry holds it as an unexpanded path such as %USERPROFILE%\Downloads.
:: -----------------------------------------------------------------------------
:FindDownloads
  SET "DL=%USERPROFILE%\Downloads"
  SET "SHELL_KEY=HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer"
  SET "SHELL_KEY=%SHELL_KEY%\User Shell Folders"
  SET "DL_GUID={374DE290-123F-4565-9164-39C4925E467B}"
  FOR /F "tokens=2,*" %%A IN (
    'REG QUERY "%SHELL_KEY%" /v "%DL_GUID%" 2^>NUL ^| FINDSTR /C:"REG_"'
  ) DO CALL SET "DL=%%B"
EXIT /B


:: -----------------------------------------------------------------------------
:: FindFile "<mask>" <out_var>
:: Sets <out_var> to the newest file matching <mask> in the first folder that
:: has one: next to the script, Downloads\Telegram Desktop, Downloads.
:: Leaves it empty if nothing matches.
:: -----------------------------------------------------------------------------
:FindFile
  SET "%~2="
  CALL :FindIn "%SCRIPT_DIR%." "%~1" %~2
  CALL :FindIn "%DL%\Telegram Desktop" "%~1" %~2
  CALL :FindIn "%DL%" "%~1" %~2
EXIT /B

:FindIn
  IF DEFINED %~3 EXIT /B
  IF NOT EXIST "%~1\" EXIT /B
  :: /O:D lists the oldest first, so the last line is the newest file.
  FOR /F "delims=" %%F IN ('DIR /B /A:-D /O:D "%~1\%~2" 2^>NUL') DO (
    SET "%~3=%~f1\%%F"
  )
EXIT /B


:: -----------------------------------------------------------------------------
:: ShowFile "<label>" "<path>"
:: Prints the label, size in MB, date and path of a file.
:: -----------------------------------------------------------------------------
:ShowFile
  FOR %%F IN ("%~2") DO SET /A "MB=%%~zF / 1048576"
  FOR %%F IN ("%~2") DO ECHO   %~1 %MB% MB, %%~tF, %%~nxF
  FOR %%F IN ("%~2") DO ECHO            in %%~dpF
EXIT /B


:: -----------------------------------------------------------------------------
:: VerifyRom
:: If "<ROM>.sha256" exists (as "<hash>" or "<hash> *<name>"), checks the
:: ROM against it. TeraCopy's .xxh3 files cannot be checked with tools
:: built into Windows, so they are only mentioned.
:: @returns 0 if OK or nothing to check, 1 if the hash differs
:: -----------------------------------------------------------------------------
:VerifyRom
  IF EXIST "%ROM%.xxh3" (
    ECHO.
    ECHO Note: "%ROM%.xxh3" is a TeraCopy checksum; verify it in TeraCopy.
  )
  IF NOT EXIST "%ROM%.sha256" EXIT /B 0
  SET "WANT="
  FOR /F "usebackq tokens=1" %%H IN ("%ROM%.sha256") DO (
    IF NOT DEFINED WANT SET "WANT=%%H"
  )
  ECHO.
  ECHO Checking SHA-256 of the ROM ^(a minute^)...
  IF DEFINED DRY_RUN EXIT /B 0
  SET "HASH="
  :: certutil prints a header, the hash and a status line: keep the hex one.
  :: /C: is required: without it FINDSTR splits the pattern on spaces.
  SET "HEX_LINE=/R /I /X /C:"[0-9a-f][0-9a-f ]*""
  FOR /F "delims=" %%H IN (
    'certutil -hashfile "%ROM%" SHA256 2^>NUL ^| FINDSTR %HEX_LINE%'
  ) DO SET "HASH=%%H"
  IF DEFINED HASH SET "HASH=%HASH: =%"
  IF /I "%HASH%"=="%WANT%" (
    ECHO   OK.
    CALL :Log "SHA-256 OK"
    EXIT /B 0
  )
  ECHO Error: the ROM's SHA-256 is %HASH%, 1>&2
  ECHO        but its .sha256 file says %WANT%. Download it again. 1>&2
EXIT /B 1


:: =============================================================================
:: Device
:: =============================================================================

:: -----------------------------------------------------------------------------
:: StageCheckSystem
:: While the phone runs stock HyperOS: checks the product and the stock
:: version against the lookup tables. The version cannot be read in fastboot,
:: so a phone already in fastboot must be started normally first.
:: @returns 0 if both are accepted, 2 otherwise, 5 if cancelled
:: -----------------------------------------------------------------------------
:StageCheckSystem
  ECHO.
  ECHO Checking the phone in Android...
  CALL :WaitAdb
  IF ERRORLEVEL 1 EXIT /B %ERRORLEVEL%
  IF DEFINED DRY_RUN IF %ADB_OK% EQU 0 (
    ECHO Dry run: no phone, skipping the checks in Android.
    EXIT /B 0
  )
  CALL :AdbProp ro.product.device PRODUCT
  CALL :AdbProp ro.build.version.incremental BASE
  ECHO   product "%PRODUCT%", stock %BASE%
  CALL :Log "Android: product %PRODUCT%, stock %BASE%"

  CALL :CheckProduct
  IF ERRORLEVEL 1 EXIT /B 2

  CALL SET "OK=%%BASE_OK_%BASE%%%"
  IF DEFINED OK EXIT /B 0
  IF "%CRDROID_ALLOW_BASE%"=="1" (
    ECHO Warning: stock %BASE% is not in the guide, CRDROID_ALLOW_BASE=1 set.
    CALL :Log "Stock %BASE% accepted by CRDROID_ALLOW_BASE"
    EXIT /B 0
  )
  ECHO Error: stock %BASE% is not one the guide asks for: 1>&2
  ECHO        Global OS2.0.209.0.VMXMIXM or India OS2.0.207.0.VMXINXM. 1>&2
  ECHO        Do NOT flash another region's or an older firmware to get 1>&2
  ECHO        there: anti-rollback can hard-brick the phone. Ask the 1>&2
  ECHO        maintainer; set CRDROID_ALLOW_BASE=1 only if they say so. 1>&2
EXIT /B 2


:: -----------------------------------------------------------------------------
:: CheckProduct
:: @returns 0 if PRODUCT is in the lookup table, 1 otherwise (with a message)
:: -----------------------------------------------------------------------------
:CheckProduct
  SET "OK="
  IF DEFINED PRODUCT CALL SET "OK=%%PRODUCT_OK_%PRODUCT%%%"
  IF DEFINED OK EXIT /B 0
  ECHO Error: product "%PRODUCT%" is not "fire", the phone this build is 1>&2
  ECHO        for. ^(heat is the Redmi 12 with NFC.^) Ask the maintainer; 1>&2
  ECHO        set CRDROID_ALLOW_PRODUCT=%PRODUCT% only if they say so. 1>&2
EXIT /B 1


:: -----------------------------------------------------------------------------
:: StageCheckBootloader
:: Reboots to the bootloader and checks product, unlock state and slot b.
:: Saves "fastboot getvar all" to the logs folder.
:: @returns 0 if all pass, 2 otherwise, 5 if cancelled
:: -----------------------------------------------------------------------------
:StageCheckBootloader
  ECHO.
  ECHO Rebooting to the bootloader...
  CALL :Run adb reboot bootloader
  CALL :WaitFastboot
  IF ERRORLEVEL 1 EXIT /B 2
  IF DEFINED DRY_RUN IF %FB_N% EQU 0 (
    ECHO Dry run: no phone, skipping the bootloader checks.
    EXIT /B 0
  )
  CALL :SaveGetvar
  CALL :Getvar product PRODUCT
  CALL :Getvar unlocked UNLOCKED
  CALL :Getvar slot-successful:b SLOT_B
  CALL :Getvar anti ARB
  ECHO   product "%PRODUCT%", unlocked "%UNLOCKED%", slot b booted "%SLOT_B%"
  CALL :ShowArb
  CALL :Log "Bootloader: %PRODUCT%, unlocked %UNLOCKED%, slot b %SLOT_B%"
  CALL :Log "Anti-rollback: %ARB%"

  CALL :CheckProduct
  IF ERRORLEVEL 1 EXIT /B 2
  IF /I NOT "%UNLOCKED%"=="yes" (
    ECHO Error: the bootloader is locked. Unlock it with Mi Unlock first. 1>&2
    ECHO        Reboot the phone with: fastboot reboot 1>&2
    EXIT /B 2
  )
  IF /I "%SLOT_B%"=="yes" EXIT /B 0
  IF "%CRDROID_ALLOW_SLOT_B%"=="1" (
    ECHO Warning: slot b never booted, CRDROID_ALLOW_SLOT_B=1 set.
    CALL :Log "Slot b accepted by CRDROID_ALLOW_SLOT_B"
    EXIT /B 0
  )
  ECHO Error: slot b has never booted, so it may hold no stock firmware, 1>&2
  ECHO        and the ROM needs it in both slots. The guide's fix is to 1>&2
  ECHO        flash your region's firmware zip, which this script does NOT 1>&2
  ECHO        do: ask the maintainer first. CRDROID_ALLOW_SLOT_B=1 skips 1>&2
  ECHO        this check. Reboot the phone with: fastboot reboot 1>&2
EXIT /B 2


:: -----------------------------------------------------------------------------
:: ShowArb
:: Prints the anti-rollback index ARB and its meaning from the lookup table.
:: -----------------------------------------------------------------------------
:ShowArb
  SET "ARB_NOTE="
  IF DEFINED ARB CALL SET "ARB_NOTE=%%ARB_NOTE_%ARB%%%"
  IF NOT DEFINED ARB_NOTE SET "ARB_NOTE=unknown: ask before flashing stock"
  IF NOT DEFINED ARB SET "ARB=not reported"
  ECHO   anti-rollback %ARB%: %ARB_NOTE%
EXIT /B


:: =============================================================================
:: Stages that change the phone
:: =============================================================================

:: -----------------------------------------------------------------------------
:: StageFastboot
:: Flashes boot, recovery to vendor_boot and the modem image, then boots
:: recovery.
:: @returns 0 on success, 4 if fastboot failed, 5 if cancelled
:: -----------------------------------------------------------------------------
:StageFastboot
  ECHO.
  ECHO Next: boot, recovery to vendor_boot, md1img, then reboot to recovery.
  CALL :Confirm "Flash boot, recovery and md1img now?"
  IF ERRORLEVEL 1 EXIT /B 5
  CALL :Flash flash boot "%BOOT%"
  IF ERRORLEVEL 1 EXIT /B 4
  CALL :Flash flash vendor_boot "%REC%"
  IF ERRORLEVEL 1 EXIT /B 4
  CALL :Flash flash md1img "%MD1%"
  IF ERRORLEVEL 1 EXIT /B 4
  CALL :Flash reboot recovery
  IF ERRORLEVEL 1 EXIT /B 4
EXIT /B 0


:: -----------------------------------------------------------------------------
:: StageSideload
:: Guides through formatting data in recovery, sends the ROM, then GApps.
:: @returns 0 on success, 4 if a sideload failed, 5 if cancelled
:: -----------------------------------------------------------------------------
:StageSideload
  ECHO.
  ECHO On the phone, in crDroid recovery:
  ECHO   1. Factory reset ^> Format data/factory reset ^> confirm.
  ECHO      THIS ERASES ALL DATA ON THE PHONE.
  ECHO   2. Back to the main menu ^> Apply update ^> Apply from ADB.
  ECHO The script waits for the phone in sideload mode.
  CALL :WaitSideload
  IF ERRORLEVEL 1 EXIT /B %ERRORLEVEL%
  CALL :Sideload "%ROM%"
  IF ERRORLEVEL 1 EXIT /B %ERRORLEVEL%

  IF NOT DEFINED GAPPS GOTO :StageSideload_done
  ECHO.
  ECHO GApps: when recovery asks to reboot to recovery for more packages,
  ECHO choose Yes, then Apply update ^> Apply from ADB again.
  CHOICE /C YN /N /M "Install GApps now? (Y/N) "
  IF NOT "%ERRORLEVEL%"=="1" GOTO :StageSideload_done
  CALL :WaitSideload
  IF ERRORLEVEL 1 EXIT /B %ERRORLEVEL%
  CALL :Sideload "%GAPPS%"
  IF ERRORLEVEL 1 EXIT /B %ERRORLEVEL%

:StageSideload_done
  ECHO.
  ECHO Finish on the phone: Reboot system now. The first boot takes a while.
  CALL :Log "Sideload done"
EXIT /B 0


:: -----------------------------------------------------------------------------
:: Sideload "<file>"
:: Sends <file> with adb sideload. Some recoveries end a good install with
:: "adb: failed to read command: Success" and a non-zero code, so on an
:: error the user is asked what the phone's screen says.
:: @returns 0 if installed, 4 if not
:: -----------------------------------------------------------------------------
:Sideload
  CALL :Run adb sideload "%~1"
  SET "SL_RC=%ERRORLEVEL%"
  CALL :Log "adb sideload %~nx1 : exit %SL_RC%"
  IF %SL_RC% EQU 0 EXIT /B 0
  ECHO.
  ECHO adb returned %SL_RC%. Look at the phone: does it report the install
  ECHO as successful ^(e.g. "Install completed with status 0"^)?
  CHOICE /C YN /N /M "Installed successfully? (Y/N) "
  IF "%ERRORLEVEL%"=="1" EXIT /B 0
EXIT /B 4


:: -----------------------------------------------------------------------------
:: CountDevices
:: Sets ADB_OK, ADB_UNAUTH, SIDELOAD and FB_N to the number of devices in each
:: state; with ANDROID_SERIAL set, only that device is counted.
:: -----------------------------------------------------------------------------
:CountDevices
  SET /A "ADB_OK=0, ADB_UNAUTH=0, SIDELOAD=0, FB_N=0"
  FOR /F "skip=1 tokens=1,2" %%A IN ('adb devices 2^>NUL') DO (
    CALL :CountAdb %%A %%B
  )
  FOR /F "tokens=1,2" %%A IN ('fastboot devices 2^>NUL') DO (
    CALL :CountFastboot %%A %%B
  )
EXIT /B

:CountAdb
  IF DEFINED ANDROID_SERIAL IF NOT "%1"=="%ANDROID_SERIAL%" EXIT /B
  IF "%2"=="device" SET /A "ADB_OK+=1"
  IF "%2"=="unauthorized" SET /A "ADB_UNAUTH+=1"
  IF "%2"=="sideload" SET /A "SIDELOAD+=1"
EXIT /B

:CountFastboot
  IF DEFINED ANDROID_SERIAL IF NOT "%1"=="%ANDROID_SERIAL%" EXIT /B
  IF "%2"=="fastboot" SET /A "FB_N+=1"
EXIT /B


:: -----------------------------------------------------------------------------
:: WaitAdb
:: Waits for exactly one phone booted in Android with USB debugging allowed.
:: @returns 0 when there, 2 if several, 5 if cancelled
:: -----------------------------------------------------------------------------
:WaitAdb
  CALL :CountDevices
  IF DEFINED DRY_RUN IF %ADB_OK% EQU 0 EXIT /B 0
  IF %ADB_OK% GTR 1 (
    ECHO Error: %ADB_OK% phones found, set ANDROID_SERIAL=^<serial^>. 1>&2
    EXIT /B 2
  )
  IF %ADB_OK% EQU 1 EXIT /B 0
  IF %ADB_UNAUTH% GTR 0 (
    ECHO The phone asks "Allow USB debugging?": tap Allow.
  ) ELSE IF %FB_N% GTR 0 (
    ECHO The phone is in fastboot. The stock version is read in Android:
    ECHO start it normally ^(fastboot reboot^).
  ) ELSE (
    ECHO No phone found: start it in Android with USB debugging on
    ECHO ^(Developer options^) and connect it to this PC.
  )
  CHOICE /C RQ /N /M "R - check again, Q - quit: "
  IF NOT "%ERRORLEVEL%"=="1" EXIT /B 5
  GOTO :WaitAdb


:: -----------------------------------------------------------------------------
:: WaitFastboot
:: Waits up to FASTBOOT_WAIT seconds for the phone in fastboot mode.
:: @returns 0 when there, 1 if it did not show up (with a driver hint)
:: -----------------------------------------------------------------------------
:WaitFastboot
  IF DEFINED DRY_RUN EXIT /B 0
  SET /A "LEFT=FASTBOOT_WAIT"
:WaitFastboot_loop
  CALL :CountDevices
  IF %FB_N% GEQ 1 EXIT /B 0
  IF %LEFT% LEQ 0 (
    ECHO Error: the phone did not show up in fastboot. Without the driver 1>&2
    ECHO        it is "Android" with a yellow mark in Device Manager: 1>&2
    ECHO        install Google USB Driver and pick "Android Bootloader 1>&2
    ECHO        Interface" for it, then run the script again. 1>&2
    EXIT /B 1
  )
  CALL :Sleep %POLL%
  SET /A "LEFT-=POLL"
  GOTO :WaitFastboot_loop


:: -----------------------------------------------------------------------------
:: WaitSideload
:: Waits up to SIDELOAD_WAIT seconds for the phone in sideload mode, then
:: offers to wait again.
:: @returns 0 when there, 5 if cancelled
:: -----------------------------------------------------------------------------
:WaitSideload
  IF DEFINED DRY_RUN EXIT /B 0
  SET /A "LEFT=SIDELOAD_WAIT"
  ECHO Waiting for "Apply from ADB" on the phone...
:WaitSideload_loop
  CALL :CountDevices
  IF %SIDELOAD% GEQ 1 EXIT /B 0
  IF %LEFT% LEQ 0 (
    CHOICE /C WQ /N /M "Not in sideload mode yet. W - wait more, Q - quit: "
    IF NOT ERRORLEVEL 2 IF ERRORLEVEL 1 GOTO :WaitSideload
    EXIT /B 5
  )
  CALL :Sleep %POLL%
  SET /A "LEFT-=POLL"
  GOTO :WaitSideload_loop


:: -----------------------------------------------------------------------------
:: AdbProp <property> <out_var>
:: Sets <out_var> to a system property of the phone in Android.
:: -----------------------------------------------------------------------------
:AdbProp
  SET "%2="
  FOR /F "delims=" %%V IN ('adb shell getprop %1 2^>NUL') DO SET "%2=%%V"
EXIT /B


:: -----------------------------------------------------------------------------
:: Getvar <name> <out_var>
:: Sets <out_var> to "fastboot getvar <name>" (printed as "<name>: <value>"
:: to stderr), or leaves it empty if the bootloader does not report it.
:: -----------------------------------------------------------------------------
:Getvar
  SET "%2="
  FOR /F "tokens=1,* delims= " %%A IN (
    'fastboot getvar %1 2^>^&1 ^| FINDSTR /B /C:"%1: "'
  ) DO SET "%2=%%B"
EXIT /B


:: -----------------------------------------------------------------------------
:: Confirm "<question>"
:: Only Y goes on: N, Ctrl+C (CHOICE returns 0) or an error (255) cancel.
:: @returns 0 on Y, 5 otherwise
:: -----------------------------------------------------------------------------
:Confirm
  ECHO Battery should be above 50%%. Do not unplug the cable until done.
  CHOICE /C YN /N /M "%~1 (Y/N) "
  IF "%ERRORLEVEL%"=="1" (
    CALL :Log "Confirmed: %~1"
    EXIT /B 0
  )
  CALL :Log "Cancelled: %~1"
EXIT /B 5


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
  :: Quotes around paths would split the log message into several arguments.
  SET "FB_ARGS=%*"
  SET "FB_ARGS=%FB_ARGS:"=%"
  CALL :Log "fastboot %FB_ARGS% : exit %FB_RC%"
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
:: SaveGetvar
:: Saves "fastboot getvar all" (partitions, slots, lock state) to the logs.
:: -----------------------------------------------------------------------------
:SaveGetvar
  CALL :Timestamp
  SET "GETVAR=%LOG_DIR%\getvar-%TS%.txt"
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
  SET "SCRIPT_LOG=%LOG_DIR%\crdroid-%TS%.log"
  TYPE NUL >"%SCRIPT_LOG%"
EXIT /B


:: -----------------------------------------------------------------------------
:: Log "<message>"
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
ECHO Installs crDroid on a Redmi 12 4G ^(fire^) by the support chat's guide:
ECHO checks the phone, flashes boot, recovery and md1img, then sideloads the
ECHO ROM and GApps. Files are looked for next to the script and in Downloads.
ECHO.
ECHO   %~nx0          check, then flash
ECHO   %~nx0 /dry     print the commands, change nothing
ECHO.
ECHO Overrides, only after the maintainer confirms them for your phone:
ECHO   SET CRDROID_ALLOW_PRODUCT=^<codename^>   another product, e.g. heat
ECHO   SET CRDROID_ALLOW_BASE=1               any stock version
ECHO   SET CRDROID_ALLOW_SLOT_B=1             slot b never booted
ECHO With several devices connected, set ANDROID_SERIAL=^<serial^> first.
EXIT /B 0
