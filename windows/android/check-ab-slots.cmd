@ECHO OFF
:: =============================================================================
:: check-ab-slots.cmd
::
:: Read-only check of the A/B slots of an Android phone in fastboot mode.
:: Prints the product, the lock state, the current slot and, for slots a
:: and b, whether the bootloader marked them as successfully booted or as
:: unbootable.
::
:: Why: some custom ROMs (e.g. crDroid for the Redmi 12 4G "fire") need the
:: stock firmware in BOTH slots, and after a flash with SP Flash Tool only
:: slot a may be filled. "slot-successful:<x>: yes" means the phone has
:: booted from that slot before, so it most likely holds working firmware.
:: It does NOT tell which firmware version is there: ask the ROM maintainer
:: when in doubt.
::
:: Nothing is written to the phone: only "fastboot getvar" is used.
::
:: If no phone is in fastboot mode but one is booted with USB debugging on,
:: the script reboots it to fastboot by itself ("adb reboot bootloader"),
:: waits up to FASTBOOT_WAIT seconds for it, and after the check reboots it
:: back to the system ("fastboot reboot"), unless /stay is given.
::
:: Usage:  check-ab-slots.cmd            check the phone
::         check-ab-slots.cmd fire       same, and warn if the phone's
::                                       product is not "fire"
::         check-ab-slots.cmd /stay      leave the phone in fastboot mode
::                                       after the check
::         check-ab-slots.cmd /?         show help
:: Needs:  fastboot in PATH (Android SDK Platform-Tools); adb too, to reboot
::         a booted phone to fastboot. Works with a locked bootloader too.
::         With several phones connected, set ANDROID_SERIAL=<serial> first.
:: Exit:   0 - done
::         1 - fastboot not found
::         2 - no phone in fastboot mode and none could be rebooted to it,
::             or several phones without ANDROID_SERIAL
::         3 - the phone reports no A/B slots
:: =============================================================================
SETLOCAL EnableExtensions DisableDelayedExpansion

:: "/?" is checked apart: "?" is a wildcard inside FOR's set.
IF "%~1"=="/?" GOTO :usage

:: Optional codename to compare the product with, e.g. "fire".
SET "EXPECTED="
SET "STAY="
FOR %%A IN (%*) DO CALL :parse_arg "%%~A"

:: Seconds the window stays open after an error.
SET "FAIL_WAIT=15"
:: Seconds to wait for the phone in fastboot after "adb reboot bootloader".
SET "FASTBOOT_WAIT=60"
:: Set once this script has put the phone into fastboot mode.
SET "REBOOTED="

:: Lookup table: "<successful>-<unbootable>" -> what it means for a slot.
:: "?" stands for a value the bootloader does not report.
SET "V_yes-no=has booted before: most likely holds working firmware"
SET "V_no-no=never marked as booted: may be empty or not tried yet"
SET "V_no-yes=marked unbootable: likely empty or broken"
SET "V_yes-yes=booted before, but is marked unbootable now"

:: Guard: fastboot must be available.
WHERE fastboot >NUL 2>&1
IF ERRORLEVEL 1 (
  ECHO Error: fastboot not found in PATH. 1>&2
  ECHO        Install Android SDK Platform-Tools, e.g. "scoop install adb". 1>&2
  SET "RC=1"
  GOTO :fail
)

:: Guard: exactly one phone in fastboot mode, or ANDROID_SERIAL set.
:: A booted phone is rebooted to fastboot first.
CALL :count_devices
IF %READY% EQU 0 CALL :reboot_to_fastboot
IF %READY% EQU 0 (
  ECHO Error: no phone in fastboot mode. 1>&2
  ECHO        Hold Power + Volume down on the switched-off phone. 1>&2
  SET "RC=2"
  GOTO :fail
)
IF %READY% GTR 1 IF NOT DEFINED ANDROID_SERIAL (
  ECHO Error: %READY% phones in fastboot mode. 1>&2
  ECHO        Set ANDROID_SERIAL=^<serial^> first. 1>&2
  SET "RC=2"
  GOTO :fail
)

CALL :getvar product PRODUCT
CALL :getvar unlocked UNLOCKED
CALL :getvar current-slot CURRENT
:: Some bootloaders answer "_a" instead of "a".
SET "CURRENT=%CURRENT:_=%"

ECHO Product:      %PRODUCT%
ECHO Unlocked:     %UNLOCKED%
ECHO Current slot: %CURRENT%

IF DEFINED EXPECTED IF /I NOT "%PRODUCT%"=="%EXPECTED%" (
  ECHO Warning: expected "%EXPECTED%", the phone says "%PRODUCT%". 1>&2
)

:: Guard: without a current slot the phone is not A/B.
IF "%CURRENT%"=="?" (
  ECHO Error: the phone reports no current slot, it is not A/B. 1>&2
  SET "RC=3"
  GOTO :fail
)

ECHO.
ECHO Slots, * = current:
FOR %%S IN (a b) DO CALL :report_slot %%S

ECHO.
ECHO "successful=yes" only shows that the slot has booted before; the
ECHO firmware version in it is not reported. Ask the ROM maintainer
ECHO before flashing anything to the other slot.

CALL :back_to_system

:: Keep the window open only when started by double-click
:: (then CMDCMDLINE is 'cmd /c "...\check-ab-slots.cmd"').
SET "CCL=%CMDCMDLINE:"=%"
IF "%CCL:/c =%"=="%CCL%" EXIT /B 0
ECHO.
PAUSE
EXIT /B 0

:fail
CALL :back_to_system
ECHO. 1>&2
ECHO This window closes in %FAIL_WAIT% s, press any key to close it now. 1>&2
:: TIMEOUT refuses redirected stdin; then it just returns at once.
TIMEOUT /T %FAIL_WAIT% >NUL 2>&1
EXIT /B %RC%

:: -----------------------------------------------------------------------------
:: parse_arg "<arg>"
:: /stay sets STAY; any other argument is taken as the expected codename.
:: -----------------------------------------------------------------------------
:parse_arg
IF /I "%~1"=="/stay" (
  SET "STAY=1"
  GOTO :EOF
)
SET "EXPECTED=%~1"
GOTO :EOF

:: -----------------------------------------------------------------------------
:: reboot_to_fastboot
:: If exactly one booted phone is authorized for adb (or ANDROID_SERIAL is
:: set), runs "adb reboot bootloader" and waits up to FASTBOOT_WAIT seconds
:: for it in fastboot. Updates READY and sets REBOOTED on success; prints a
:: hint and leaves READY at 0 otherwise.
:: -----------------------------------------------------------------------------
:reboot_to_fastboot
WHERE adb >NUL 2>&1
IF ERRORLEVEL 1 (
  ECHO No phone in fastboot mode, and adb is not in PATH to reboot one. 1>&2
  GOTO :EOF
)
CALL :count_adb
IF %ADB_READY% EQU 0 IF %ADB_UNAUTH% GTR 0 (
  ECHO The phone is not authorized for adb: accept the 1>&2
  ECHO "Allow USB debugging" prompt on it and run the script again. 1>&2
  GOTO :EOF
)
IF %ADB_READY% EQU 0 (
  ECHO No phone found in fastboot mode or over adb. 1>&2
  ECHO Turn on USB debugging, or check the cable. 1>&2
  GOTO :EOF
)
IF %ADB_READY% GTR 1 IF NOT DEFINED ANDROID_SERIAL (
  ECHO %ADB_READY% phones over adb, set ANDROID_SERIAL=^<serial^> first. 1>&2
  GOTO :EOF
)

ECHO Rebooting the phone to fastboot: adb reboot bootloader
adb reboot bootloader
IF ERRORLEVEL 1 GOTO :EOF

ECHO Waiting up to %FASTBOOT_WAIT% s for it in fastboot mode...
SET /A "LEFT=FASTBOOT_WAIT"
:reboot_wait
CALL :count_devices
IF %READY% GTR 0 (
  SET "REBOOTED=1"
  ECHO.
  GOTO :EOF
)
IF %LEFT% LEQ 0 (
  ECHO The phone did not show up in fastboot in %FASTBOOT_WAIT% s. 1>&2
  ECHO On Windows this is usually a missing fastboot driver: look for 1>&2
  ECHO the phone in Device Manager while it shows the fastboot screen. 1>&2
  GOTO :EOF
)
:: PING as a sleep: TIMEOUT returns at once when stdin is redirected.
PING -n 3 127.0.0.1 >NUL
SET /A "LEFT-=2"
GOTO :reboot_wait

:: -----------------------------------------------------------------------------
:: back_to_system
:: Reboots the phone back to the system if this script has put it into
:: fastboot mode and /stay was not given.
:: -----------------------------------------------------------------------------
:back_to_system
IF NOT DEFINED REBOOTED GOTO :EOF
IF DEFINED STAY (
  ECHO.
  ECHO The phone stays in fastboot mode, as asked by /stay.
  GOTO :EOF
)
ECHO.
ECHO Rebooting the phone back to the system: fastboot reboot
fastboot reboot >NUL 2>&1
SET "REBOOTED="
GOTO :EOF

:: -----------------------------------------------------------------------------
:: count_adb
:: Sets ADB_READY to the number of "device" lines and ADB_UNAUTH to the
:: number of "unauthorized" lines of "adb devices" (the header is skipped).
:: -----------------------------------------------------------------------------
:count_adb
SET /A "ADB_READY=0, ADB_UNAUTH=0"
FOR /F "skip=1 tokens=1,2" %%A IN ('adb devices 2^>NUL') DO (
  IF "%%B"=="device" SET /A "ADB_READY+=1"
  IF "%%B"=="unauthorized" SET /A "ADB_UNAUTH+=1"
)
GOTO :EOF

:: -----------------------------------------------------------------------------
:: report_slot <slot>
:: Prints one line with the slot's flags and what they mean.
:: -----------------------------------------------------------------------------
:report_slot
CALL :getvar slot-successful:%1 OK
CALL :getvar slot-unbootable:%1 BAD
CALL :getvar slot-retry-count:%1 TRIES
SET "MARK= "
IF /I "%1"=="%CURRENT%" SET "MARK=*"
SET "TEXT="
CALL SET "TEXT=%%V_%OK%-%BAD%%%"
IF NOT DEFINED TEXT SET "TEXT=unknown: the bootloader does not report it"
ECHO  %MARK% %1: successful=%OK%, unbootable=%BAD%, retries=%TRIES%
ECHO        %TEXT%
GOTO :EOF

:: -----------------------------------------------------------------------------
:: count_devices
:: Sets READY to the number of "<serial>  fastboot" lines of
:: "fastboot devices".
:: -----------------------------------------------------------------------------
:count_devices
SET "READY=0"
FOR /F "tokens=1,2" %%A IN ('fastboot devices 2^>NUL') DO (
  IF "%%B"=="fastboot" SET /A "READY+=1"
)
GOTO :EOF

:: -----------------------------------------------------------------------------
:: getvar <name> <out_var>
:: Sets <out_var> to the value of "fastboot getvar <name>", or to "?" if
:: the bootloader does not report it. fastboot prints "<name>: <value>"
:: to stderr, some bootloaders with a "(bootloader) " prefix.
:: -----------------------------------------------------------------------------
:getvar
SET "%~2=?"
SET "PREFIX=%~1: "
FOR /F "delims=" %%L IN ('fastboot getvar %~1 2^>^&1') DO (
  CALL :match_line "%%L" %~2
)
GOTO :EOF

:: -----------------------------------------------------------------------------
:: match_line "<line>" <out_var>
:: If <line> holds PREFIX, sets <out_var> to the text after it.
:: -----------------------------------------------------------------------------
:match_line
SET "LINE=%~1"
CALL SET "REST=%%LINE:*%PREFIX%=%%"
IF "%REST%"=="%LINE%" GOTO :EOF
SET "%~2=%REST%"
GOTO :EOF

:usage
ECHO Read-only check of the A/B slots of a phone in fastboot mode.
ECHO.
ECHO   %~nx0           check the phone
ECHO   %~nx0 ^<code^>    also warn if the product is not ^<code^>, e.g. fire
ECHO   %~nx0 /stay     leave the phone in fastboot mode after the check
ECHO.
ECHO A booted phone with USB debugging on is rebooted to fastboot first and
ECHO back to the system afterwards.
ECHO With several phones connected, set ANDROID_SERIAL=^<serial^> first.
EXIT /B 0
