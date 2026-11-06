@ECHO OFF
:: =============================================================================
:: start-shizuku.cmd
::
:: Starts the Shizuku server on a connected Android device via ADB.
::
:: Shizuku v13.6.0+ is started with its libshizuku.so binary. Its path
::   /data/app/~~<random>/moe.shizuku.privileged.api-<random>/lib/<abi>
:: changes on every install or update, so it is resolved from
:: "dumpsys package" on each run instead of being hardcoded.
:: Older versions (v11.2.0 - v13.5.x) are started with the start.sh script
:: from the official guide, which is used as a fallback.
::
:: Before starting, it warns if USB (current or default mode) is not in
:: "Charging only": on some devices switching USB modes kills the
:: Shizuku server.
::   Android 8:  Developer options > Select USB configuration > Charge only
::   Android 9+: Developer options > Default USB configuration
::               > Charging only
::
:: Runs unattended: if the current mode is wrong, the script offers to
:: switch it ("svc usb setFunctions") and does so by itself after
:: USB_WAIT seconds; any key other than Y, or Ctrl+C, declines. The
:: default mode is only checked, not changed. On errors the window stays
:: open for FAIL_WAIT seconds, so the message can be read when the script
:: is started by double-click.
::
:: Usage:  start-shizuku.cmd        check, fix the USB mode, start Shizuku
::         start-shizuku.cmd /dry   dry run: only print the resolved
::                                  command, change nothing
::                                  (--dry-run works too)
::         start-shizuku.cmd /?     show help
:: Needs:  adb in PATH, USB or wireless debugging enabled and this PC
::         authorized on the device. With several devices connected,
::         set ANDROID_SERIAL=<serial> first.
:: Exit:   0 - ok (or the starter's own exit code)
::         1 - adb not found
::         2 - no authorized device, or several without ANDROID_SERIAL
::         3 - Shizuku is not installed
::         4 - no starter found on the device
:: =============================================================================
SETLOCAL EnableExtensions DisableDelayedExpansion

SET "PKG=moe.shizuku.privileged.api"
SET "LEGACY_SH=/sdcard/Android/data/%PKG%/start.sh"

:: "/?" is checked apart: "?" is a wildcard inside FOR's set.
IF "%~1"=="/?" GOTO :usage
SET "DRY_RUN="
FOR %%A IN (%*) DO (
  IF /I "%%~A"=="/dry" SET "DRY_RUN=1"
  IF /I "%%~A"=="--dry-run" SET "DRY_RUN=1"
)

:: Seconds before the USB mode is switched without an answer.
SET "USB_WAIT=10"
:: Seconds the window stays open after an error.
SET "FAIL_WAIT=15"

:: Lookup table: app's primary ABI -> name of its lib subfolder on the device.
SET "LIBDIR_arm64-v8a=arm64"
SET "LIBDIR_armeabi-v7a=arm"
SET "LIBDIR_armeabi=arm"
SET "LIBDIR_x86=x86"
SET "LIBDIR_x86_64=x86_64"

:: Guard: adb must be available.
WHERE adb >NUL 2>&1
IF ERRORLEVEL 1 (
  ECHO Error: adb not found in PATH. 1>&2
  SET "RC=1"
  GOTO :fail
)

:: Guard: at least one "<serial>  device" line in "adb devices".
CALL :count_devices
IF %READY% EQU 0 (
  ECHO Error: no authorized device. 1>&2
  IF %UNAUTH% GTR 0 ECHO        Accept the "Allow USB debugging" prompt. 1>&2
  IF %UNAUTH% EQU 0 ECHO        Check the cable or the wireless pairing. 1>&2
  SET "RC=2"
  GOTO :fail
)
IF %READY% GTR 1 IF NOT DEFINED ANDROID_SERIAL (
  ECHO Error: %READY% devices connected, set ANDROID_SERIAL=^<serial^>. 1>&2
  SET "RC=2"
  GOTO :fail
)

CALL :check_usb_mode

:: Guard: the package must be installed.
CALL :read_field "package %PKG%" legacyNativeLibraryDir LIB_ROOT
IF NOT DEFINED LIB_ROOT (
  ECHO Error: %PKG% is not installed on the device. 1>&2
  SET "RC=3"
  GOTO :fail
)

:: Find the starter: the binary first, the legacy script second.
SET "CMD_LINE="
CALL :resolve_binary
IF NOT DEFINED CMD_LINE CALL :resolve_legacy
IF NOT DEFINED CMD_LINE (
  ECHO Error: no starter found. Tried: 1>&2
  ECHO          %STARTER% 1>&2
  ECHO          %LEGACY_SH% 1>&2
  ECHO        Open Shizuku once and update it to a recent version. 1>&2
  SET "RC=4"
  GOTO :fail
)

ECHO adb shell %CMD_LINE%
IF DEFINED DRY_RUN EXIT /B 0

adb shell "%CMD_LINE%"
SET "RC=%ERRORLEVEL%"
IF %RC% NEQ 0 GOTO :fail
EXIT /B 0

:fail
ECHO. 1>&2
ECHO This window closes in %FAIL_WAIT% s, press any key to close it now. 1>&2
:: TIMEOUT refuses redirected stdin; then it just returns at once.
TIMEOUT /T %FAIL_WAIT% >NUL 2>&1
EXIT /B %RC%

:: -----------------------------------------------------------------------------
:: count_devices
:: Sets READY to the number of "device" lines and UNAUTH to the number of
:: "unauthorized" lines of "adb devices" (the header line is skipped).
:: -----------------------------------------------------------------------------
:count_devices
SET /A "READY=0, UNAUTH=0"
FOR /F "skip=1 tokens=1,2" %%A IN ('adb devices') DO (
  IF "%%B"=="device" SET /A "READY+=1"
  IF "%%B"=="unauthorized" SET /A "UNAUTH+=1"
)
GOTO :EOF

:: -----------------------------------------------------------------------------
:: check_usb_mode
:: Warns (does not stop) if the current or the default USB functions are
:: not empty ("Charging only"). Unless it is a dry run, a wrong current
:: mode is offered to be switched first (see offer_usb_fix).
:: - current: "svc usb getFunctions" (Android 9+) prints them, an empty
::   line means none; older versions print a usage text instead, which is
::   detected by a second word in the first line.
:: - default: "screen_unlocked_functions=" in "dumpsys usb"; dumpsys omits
::   the field when it is empty.
:: -----------------------------------------------------------------------------
:check_usb_mode
CALL :read_usb_current
IF DEFINED USB_EXTRA GOTO :usb_unknown
IF NOT DEFINED DRY_RUN IF NOT "%USB_FN%"=="none" CALL :offer_usb_fix
CALL :read_field usb screen_unlocked_functions DEF_FN
IF NOT DEFINED DEF_FN SET "DEF_FN=none"
IF NOT "%USB_FN%"=="none" (
  ECHO Warning: current USB mode is "%USB_FN%", not "Charging only". 1>&2
  ECHO          Switching USB modes may stop Shizuku on some devices. 1>&2
  ECHO          Pick "Charging only" in the USB notification 1>&2
  ECHO          on the phone. 1>&2
)
IF NOT "%DEF_FN%"=="none" (
  ECHO Warning: default USB mode is "%DEF_FN%", set it manually: 1>&2
  ECHO          Developer options ^> Default USB configuration 1>&2
  ECHO          ^> Charging only 1>&2
  ECHO          ^(Android 8: Select USB configuration ^> Charge only^). 1>&2
)
GOTO :EOF
:usb_unknown
ECHO Note: could not read the USB mode, make sure it is "Charging only" 1>&2
ECHO       (Android 8: "Charge only") in Developer options. 1>&2
GOTO :EOF

:: -----------------------------------------------------------------------------
:: read_usb_current
:: Sets USB_FN to the current USB functions ("none" for an empty answer)
:: and USB_EXTRA to the second word of the answer, if any (a usage or
:: error text instead of a function list).
:: -----------------------------------------------------------------------------
:read_usb_current
SET "USB_FN="
SET "USB_EXTRA="
FOR /F "tokens=1,2" %%A IN ('adb shell svc usb getFunctions 2^>^&1') DO (
  IF NOT DEFINED USB_FN (
    SET "USB_FN=%%A"
    SET "USB_EXTRA=%%B"
  )
)
IF NOT DEFINED USB_FN SET "USB_FN=none"
GOTO :EOF

:: -----------------------------------------------------------------------------
:: offer_usb_fix
:: Asks whether to switch the current USB mode; no answer within USB_WAIT
:: seconds means yes. CHOICE returns 1 only for Y or the timeout; any
:: other letter or digit (2+), Ctrl+C (0) or a failing CHOICE declines.
:: CHOICE ignores Enter, Space and Esc, so those just keep the countdown.
:: -----------------------------------------------------------------------------
:offer_usb_fix
ECHO Current USB mode is "%USB_FN%", not "Charging only".
CHOICE /C YABCDEFGHIJKLMNOPQRSTUVWXZ0123456789 /N /T %USB_WAIT% /D Y ^
  /M "Switch it now? (Y/n) (%USB_WAIT% sec.) "
IF NOT "%ERRORLEVEL%"=="1" GOTO :EOF
CALL :fix_usb_current
GOTO :EOF

:: -----------------------------------------------------------------------------
:: fix_usb_current
:: Switches the current USB functions to none ("svc usb setFunctions" with
:: no argument means charging only) and re-reads them. Over a USB cable the
:: adb connection drops while the USB gadget is reconfigured, so the script
:: pauses and waits for the device to come back.
:: -----------------------------------------------------------------------------
:fix_usb_current
ECHO Switching USB mode "%USB_FN%" to "Charging only"...
adb shell svc usb setFunctions >NUL
:: PING as a sleep: TIMEOUT fails when stdin is redirected.
PING -n 3 127.0.0.1 >NUL
adb wait-for-device
CALL :read_usb_current
GOTO :EOF

:: -----------------------------------------------------------------------------
:: resolve_binary
:: Sets STARTER to the libshizuku.so path and, if the file exists,
:: CMD_LINE to it.
:: -----------------------------------------------------------------------------
:resolve_binary
:: No parentheses in this text: it is echoed inside an IF ( ) block.
SET "STARTER=[libshizuku.so, unknown ABI]"
CALL :read_field "package %PKG%" primaryCpuAbi ABI
SET "LIB_SUB="
IF DEFINED ABI CALL SET "LIB_SUB=%%LIBDIR_%ABI%%%"
IF NOT DEFINED LIB_SUB GOTO :EOF
SET "STARTER=%LIB_ROOT%/%LIB_SUB%/libshizuku.so"
adb shell "[ -f '%STARTER%' ]"
IF ERRORLEVEL 1 GOTO :EOF
SET "CMD_LINE=%STARTER%"
GOTO :EOF

:: -----------------------------------------------------------------------------
:: resolve_legacy
:: Sets CMD_LINE to "sh <start.sh>" if the legacy script exists.
:: -----------------------------------------------------------------------------
:resolve_legacy
adb shell "[ -f '%LEGACY_SH%' ]"
IF ERRORLEVEL 1 GOTO :EOF
SET "CMD_LINE=sh %LEGACY_SH%"
GOTO :EOF

:: -----------------------------------------------------------------------------
:: read_field <service> <field> <var>
:: Stores the value of the first "<field>=<value>" line of
:: "dumpsys <service>" in <var>; leaves <var> undefined if there is none.
:: <service> may hold arguments, e.g. "package %PKG%" (quoted).
:: "tokens=1,* delims==" keeps the "==" inside paths intact in %%B.
:: -----------------------------------------------------------------------------
:read_field
SET "%~3="
FOR /F "tokens=1,* delims==" %%A IN (
  'adb shell dumpsys %~1 ^| FINDSTR /C:"%~2="'
) DO IF NOT DEFINED %~3 SET "%~3=%%B"
GOTO :EOF

:usage
ECHO Starts the Shizuku server on a connected Android device via ADB.
ECHO.
ECHO   %~nx0        check, fix the USB mode, start Shizuku
ECHO   %~nx0 /dry   dry run: only print the command, change nothing
ECHO.
ECHO With several devices connected, set ANDROID_SERIAL=^<serial^> first.
EXIT /B 0

