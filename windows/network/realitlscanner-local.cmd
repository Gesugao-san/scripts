@ECHO OFF
:: realitlscanner-local: a personal launcher kept outside Scoop, so updates
:: never overwrite it.
:: 1. Updates Scoop, its buckets, RealiTLScanner and the GeoIP database.
:: 2. Goes to the app folder (scoop prefix RealiTLScanner).
:: 3. Scans one range once with RealiTLScanner-Scan.cmd from the gesu
::    bucket (scoop install gesu/RealiTLScanner gesu/Loyalsoldier-GeoIP).
::
:: Usage:
::   realitlscanner-local.cmd               scans TARGET below
::   realitlscanner-local.cmd 198.51.100.7  scans 198.51.100.0/24 this time
::
:: Results:
::   %USERPROFILE%\scoop\persist\RealiTLScanner\results\
::   <date>_<time>_<range>.csv

SETLOCAL EnableExtensions

:: Your address or range. A bare IP is scanned as its /24
:: (the scan never runs in infinite mode).
SET "TARGET=203.0.113.10"
:: Apps updated before the scan; leave empty to update only Scoop
:: and its buckets.
SET "APPS=RealiTLScanner Loyalsoldier-GeoIP"

IF NOT "%~1"=="" SET "TARGET=%~1"

WHERE scoop >NUL 2>&1 || (
  ECHO Scoop is not on PATH. Install it from https://scoop.sh first.
  GOTO :finish
)

:: Update first, and only then step into the app folder: a console
:: sitting inside apps\RealiTLScanner\current can get in the way of
:: updating that folder.
ECHO Updating Scoop and its buckets...
CALL scoop update || ECHO Scoop did not update; scanning with what is installed.
IF DEFINED APPS (
  ECHO Updating %APPS%...
  CALL scoop update %APPS% || ECHO Some apps did not update.
)
ECHO.

SET "PREFIX="
FOR /F "delims=" %%P IN ('scoop prefix RealiTLScanner 2^>NUL') DO (
  SET "PREFIX=%%P"
)
:: scoop prefix prints an error instead of a path when the app is
:: missing, so check the file itself.
IF NOT EXIST "%PREFIX%\RealiTLScanner-Scan.cmd" (
  ECHO RealiTLScanner is missing, or too old to have
  ECHO RealiTLScanner-Scan.cmd. Run: scoop install gesu/RealiTLScanner
  GOTO :finish
)

PUSHD "%PREFIX%"
CALL RealiTLScanner-Scan.cmd %TARGET%
POPD

:finish
PAUSE
ENDLOCAL
