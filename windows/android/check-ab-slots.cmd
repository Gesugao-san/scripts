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
:: Usage:  check-ab-slots.cmd            check the phone in fastboot mode
::         check-ab-slots.cmd fire       same, and warn if the phone's
::                                       product is not "fire"
::         check-ab-slots.cmd /?         show help
:: Needs:  fastboot in PATH (Android SDK Platform-Tools), the phone in
::         fastboot mode ("adb reboot bootloader", or Power + Volume down).
::         Works with a locked bootloader too. With several phones
::         connected, set ANDROID_SERIAL=<serial> first.
:: Exit:   0 - done
::         1 - fastboot not found
::         2 - no phone in fastboot mode, or several without ANDROID_SERIAL
::         3 - the phone reports no A/B slots
:: =============================================================================
SETLOCAL EnableExtensions DisableDelayedExpansion

IF "%~1"=="/?" GOTO :usage

:: Optional codename to compare the product with, e.g. "fire".
SET "EXPECTED=%~1"
:: Seconds the window stays open after an error.
SET "FAIL_WAIT=15"

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
CALL :count_devices
IF %READY% EQU 0 (
  ECHO Error: no phone in fastboot mode. 1>&2
  ECHO        Run "adb reboot bootloader" or hold Power + Volume down. 1>&2
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

:: Keep the window open only when started by double-click
:: (then CMDCMDLINE is 'cmd /c "...\check-ab-slots.cmd"').
SET "CCL=%CMDCMDLINE:"=%"
IF "%CCL:/c =%"=="%CCL%" EXIT /B 0
ECHO.
PAUSE
EXIT /B 0

:fail
ECHO. 1>&2
ECHO This window closes in %FAIL_WAIT% s, press any key to close it now. 1>&2
:: TIMEOUT refuses redirected stdin; then it just returns at once.
TIMEOUT /T %FAIL_WAIT% >NUL 2>&1
EXIT /B %RC%

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
ECHO.
ECHO With several phones connected, set ANDROID_SERIAL=^<serial^> first.
EXIT /B 0
