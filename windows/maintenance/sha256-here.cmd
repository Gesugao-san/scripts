@ECHO OFF
:: =============================================================================
:: sha256-here.cmd
::
:: Computes SHA-256 checksums of every file in the folder this script lives in
:: (subfolders and hidden files included) and writes them to SHA256SUMS.txt
:: next to the script, in the sha256sum format:
::
::   <64 hex chars> *<relative/path/to/file>
::
:: The list can be checked later with `sha256sum -c SHA256SUMS.txt` on Linux
:: or Android (Termux, PRoot, etc.).
::
:: The script itself and SHA256SUMS.txt are skipped. An existing SHA256SUMS.txt
:: is never overwritten: it may be the reference you want to verify against.
::
:: Usage:  copy the script into the folder and run it (double-click or cmd).
:: Needs:  certutil.exe (built into Windows).
:: Exit:   0 - all files hashed
::         1 - SHA256SUMS.txt already exists, nothing done
::         2 - some files could not be hashed (listed as FAILED)
:: =============================================================================
SETLOCAL EnableExtensions DisableDelayedExpansion

SET "BASE=%~dp0"
SET "SELF=%~f0"
SET "OUT=%~dp0SHA256SUMS.txt"
:: certutil refuses to hash empty files, so their well-known hash is used.
SET "EMPTY_SHA=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
SET /A "DONE=0, FAILED=0"

CALL :SaveCodePage
:: UTF-8, so non-ASCII file names land in SHA256SUMS.txt correctly.
CHCP 65001 >NUL
CALL :Main
SET "RC=%ERRORLEVEL%"
CHCP %OLD_CP% >NUL
CALL :PauseIfDoubleClicked
EXIT /B %RC%


:: -----------------------------------------------------------------------------
:: Main
:: Walks the folder tree and hashes every file into %OUT%.
:: @returns 0 on success, 1 if %OUT% exists, 2 if some files failed
:: -----------------------------------------------------------------------------
:Main
  IF EXIST "%OUT%" (
    ECHO ERROR: "%OUT%" already exists.
    ECHO Rename or delete it first, so the old checksums are not lost.
    EXIT /B 1
  )

  CALL :SetBaseLength
  TYPE NUL >"%OUT%"

  :: DIR /A-D lists hidden and system files too, unlike FOR /R.
  FOR /F "delims=" %%F IN ('DIR /S /B /A-D "%BASE%" 2^>NUL') DO (
    SET "FILE=%%F"
    SET "SIZE=%%~zF"
    CALL :HashFile
  )

  ECHO.
  ECHO Hashed: %DONE%, failed: %FAILED%.
  ECHO Saved to "%OUT%"
  IF %FAILED% GTR 0 EXIT /B 2
EXIT /B 0


:: -----------------------------------------------------------------------------
:: HashFile
:: Hashes one file and appends its line to %OUT%.
:: The file is passed in variables, not as an argument: CALL would mangle
:: "%" and "^" in file names.
:: @param FILE  full path of the file
:: @param SIZE  file size in bytes
:: -----------------------------------------------------------------------------
:HashFile
  IF /I "%FILE%"=="%SELF%" EXIT /B
  IF /I "%FILE%"=="%OUT%" EXIT /B

  SET "HASH="
  CALL :ReadHash
  IF NOT DEFINED HASH (
    SET /A FAILED+=1
    ECHO FAILED: "%FILE%"
    EXIT /B
  )

  CALL :AppendLine
  SET /A DONE+=1
EXIT /B


:: -----------------------------------------------------------------------------
:: ReadHash
:: Sets HASH to the lowercase SHA-256 of %FILE%, or leaves it undefined
:: if certutil fails (locked file, no access, etc.).
:: @param FILE  full path of the file
:: @param SIZE  file size in bytes
:: -----------------------------------------------------------------------------
:ReadHash
  IF "%SIZE%"=="0" (
    SET "HASH=%EMPTY_SHA%"
    EXIT /B
  )

  :: certutil prints a header, the hash and a status line; keep only the
  :: hex line. Old Windows versions put spaces between bytes, so strip them.
  :: /C: is required: without it FINDSTR splits the pattern on spaces.
  SET "HEX_LINE=/R /I /X /C:"[0-9a-f][0-9a-f ]*""
  FOR /F "delims=" %%H IN (
    'certutil -hashfile "%FILE%" SHA256 2^>NUL ^| FINDSTR %HEX_LINE%'
  ) DO SET "HASH=%%H"
  IF NOT DEFINED HASH EXIT /B
  SET "HASH=%HASH: =%"
EXIT /B


:: -----------------------------------------------------------------------------
:: AppendLine
:: Appends "<hash> *<relative/path>" to %OUT% and shows the path.
:: Delayed expansion is used only for output, so "&", "!" and other special
:: characters in file names are written as is.
:: @param FILE  full path of the file
:: @param HASH  its SHA-256
:: -----------------------------------------------------------------------------
:AppendLine
  CALL SET "REL=%%FILE:~%BASE_LEN%%%"
  SET "REL=%REL:\=/%"

  SETLOCAL EnableDelayedExpansion
  >>"!OUT!" ECHO(!HASH! *!REL!
  ECHO(!REL!
  ENDLOCAL
EXIT /B


:: -----------------------------------------------------------------------------
:: SetBaseLength
:: Sets BASE_LEN to the length of %BASE%, used to cut it off full paths.
:: A plain loop instead of string replacement: works with "!", "%" and "="
:: in folder names.
:: @param BASE  folder of the script, with a trailing backslash
:: -----------------------------------------------------------------------------
:SetBaseLength
  SET "BASE_LEN=0"
  SET "REST=%BASE%"
:SetBaseLength_Loop
  IF NOT DEFINED REST EXIT /B
  SET "REST=%REST:~1%"
  SET /A BASE_LEN+=1
  GOTO SetBaseLength_Loop


:: -----------------------------------------------------------------------------
:: SaveCodePage
:: Sets OLD_CP to the current console code page, to restore it on exit.
:: -----------------------------------------------------------------------------
:SaveCodePage
  SET "OLD_CP=437"
  FOR /F "tokens=2 delims=:." %%C IN ('CHCP') DO SET /A "OLD_CP=%%C"
EXIT /B


:: -----------------------------------------------------------------------------
:: PauseIfDoubleClicked
:: Keeps the window open when started from Explorer (cmd.exe /c ...),
:: does nothing when run from an open console.
:: -----------------------------------------------------------------------------
:PauseIfDoubleClicked
  SET "CMD_LINE=%CMDCMDLINE:"=%"
  IF /I "%CMD_LINE: /c =%"=="%CMD_LINE%" EXIT /B
  PAUSE
EXIT /B

