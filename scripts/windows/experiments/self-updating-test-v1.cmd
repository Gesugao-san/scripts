@echo off
setlocal EnableDelayedExpansion

set "SCRIPT_NAME=%~nx0"
set "SCRIPT_PATH=%~f0"
set "TEMP_DIR=%TEMP%\self_update"
set "REPO_URL=https://raw.githubusercontent.com/Gesugao-san/chocolatey-scripts/refs/heads/master/src/self_updating_test.bat"

:: Create temporary directory
if not exist "%TEMP_DIR%" mkdir "%TEMP_DIR%"

:: Check command line arguments
if "%1"=="--update" goto :update
if "%1"=="--check-update" goto :check_update

:: Main program logic
echo ========================================
echo    SELF-UPDATING SCRIPT
echo ========================================
echo.
echo Current script: !SCRIPT_NAME!
echo.

:: Check for updates on every startup
call :check_update

echo.
echo Performing main tasks...
timeout /t 3 /nobreak >nul
echo Tasks completed!
echo.

:: Offer to check for updates
set /p "UPDATE=Check for updates? (y/n): "
if /i "!UPDATE!"=="y" (
  echo Starting update process...
  start "" /wait "!SCRIPT_PATH!" --update
  exit /b 0
)

exit /b 0

:update
echo.
echo ========================================
echo        UPDATE PROCESS
echo ========================================
echo.

:: List of files to update
set "FILES_TO_UPDATE=!SCRIPT_NAME! additional_script.bat"

echo Downloading update files...
for %%F in (!FILES_TO_UPDATE!) do (
  echo Downloading %%F...
  powershell -Command "Invoke-WebRequest -Uri '!REPO_URL!/%%F' -OutFile '!TEMP_DIR!/%%F'" >nul 2>&1
  if !errorlevel! neq 0 (
    echo Error downloading file: %%F
    pause
    exit /b 1
  )
)

:: Compare hashes to verify if update is needed
echo Verifying update...
call :calculate_self_hash CURRENT_HASH
call :calculate_file_hash "!TEMP_DIR!\!SCRIPT_NAME!" NEW_HASH

if "!CURRENT_HASH!"=="!NEW_HASH!" (
  echo No updates available. Script is already up to date.
  pause
  exit /b 0
)

echo Current hash: !CURRENT_HASH!
echo New hash: !NEW_HASH!
echo Update available!

:: Create update completion script
echo Creating update script...
(
echo @echo off
echo setlocal EnableDelayedExpansion
echo.
echo echo Finalizing update...
echo timeout /t 2 /nobreak ^>nul
echo.
echo :: Copy new files
echo copy "!TEMP_DIR!\!SCRIPT_NAME!" "!SCRIPT_PATH!" /Y ^>nul
echo if exist "!TEMP_DIR!\additional_script.bat" (
echo   copy "!TEMP_DIR!\additional_script.bat" "additional_script.bat" /Y ^>nul
echo )
echo.
echo :: Clean up temporary files
echo if exist "!TEMP_DIR!" rmdir /s /q "!TEMP_DIR!"
echo if exist "update_finish.bat" del "update_finish.bat"
echo.
echo echo Update completed successfully!
echo echo Starting updated version...
echo start "" "!SCRIPT_PATH!"
echo exit /b 0
) > "update_finish.bat"

echo Starting update finalization...
start "" /min "update_finish.bat"
exit /b 0

:check_update
echo Checking for updates...
powershell -Command "Invoke-WebRequest -Uri '!REPO_URL!/!SCRIPT_NAME!' -OutFile '!TEMP_DIR!\remote_script.bat'" >nul 2>&1

if !errorlevel! equ 0 (
  if exist "!TEMP_DIR!\remote_script.bat" (
    :: Compare hashes of current and remote script
    call :calculate_self_hash CURRENT_HASH
    call :calculate_file_hash "!TEMP_DIR!\remote_script.bat" REMOTE_HASH
    
    echo Current hash: !CURRENT_HASH!
    echo Remote hash: !REMOTE_HASH!
    
    if "!CURRENT_HASH!" neq "!REMOTE_HASH!" (
      echo.
      echo ========================================
      echo       UPDATE AVAILABLE!
      echo ========================================
      echo Current: !CURRENT_HASH!
      echo New:     !REMOTE_HASH!
      echo ========================================
      echo.
    ) else (
      echo Script is up to date.
    )
    
    del "!TEMP_DIR!\remote_script.bat" >nul 2>&1
  )
) else (
  echo Could not check for updates.
)

exit /b 0

:calculate_self_hash
:: Calculate MD5 hash of current running script
set "psCommand=Get-FileHash -Path '%SCRIPT_PATH%' -Algorithm MD5 | Select-Object -ExpandProperty Hash"
for /f "delims=" %%i in ('powershell -Command "!psCommand!"') do set "%1=%%i"
exit /b 0

:calculate_file_hash
:: Calculate MD5 hash of specified file
set "psCommand=Get-FileHash -Path '%~1' -Algorithm MD5 | Select-Object -ExpandProperty Hash"
for /f "delims=" %%i in ('powershell -Command "!psCommand!"') do set "%2=%%i"
exit /b 0

:error_handler
echo.
echo An error occurred: %errorlevel%
pause
exit /b 1
