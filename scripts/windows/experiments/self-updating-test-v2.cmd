ECHO OFF
SETLOCAL ENABLEDELAYEDEXPANSION

SET "SCRIPT_URL=https://raw.githubusercontent.com/Gesugao-san/chocolatey-scripts/refs/heads/master/src/self-updating-test-v2.cmd"
SET "SCRIPT_PATH=%~f0"
SET "TEMP_FILE=%TEMP%\update_%random%.cmd"

ECHO Checking for updates...
ECHO Downloading: !SCRIPT_URL!

:: 1. Download file to TEMP directory
powershell -Command "Invoke-WebRequest -Uri '!SCRIPT_URL!' -OutFile '!TEMP_FILE!'" >nul 2>&1

IF NOT EXIST "!TEMP_FILE!" (
  ECHO Download failed
  GOTO :main
)

:: 2. Calculate SHA256 hashes of current and downloaded script
ECHO Calculating hashes...
FOR /f "delims=" %%A IN ('powershell -Command "Get-FileHash -Path '!SCRIPT_PATH!' -Algorithm SHA256 ^| %%{ $_.Hash }"') DO SET "CURRENT_HASH=%%A"
FOR /f "delims=" %%A IN ('powershell -Command "Get-FileHash -Path '!TEMP_FILE!' -Algorithm SHA256 ^| %%{ $_.Hash }"') DO SET "NEW_HASH=%%A"

:: 3. Compare hashes
IF "!CURRENT_HASH!"=="!NEW_HASH!" (
  ECHO No updates available
  DEL "!TEMP_FILE!" >nul 2>&1
  GOTO :main
)

:: 4. Replace and restart if hashes differ
ECHO Update found! Replacing script...
COPY "!TEMP_FILE!" "!SCRIPT_PATH!" /Y >nul

ECHO Restarting updated script...
TIMEOUT /t 2 /nobreak >nul

:: 5. Restart with updated script using CMD /C
CMD /C CALL "!SCRIPT_PATH!"
DEL "!TEMP_FILE!" >nul 2>&1
EXIT /b 0

:main
:: Main script logic
ECHO.
ECHO ========================================
ECHO    MAIN SCRIPT (v2.0)
ECHO ========================================
ECHO.
ECHO Performing main tasks...
TIMEOUT /t 3 /nobreak >nul
ECHO Tasks completed!
ECHO.
PAUSE
