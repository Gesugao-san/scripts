@REM @CHCP 65001 >nul
@REM @SET PYTHONIOENCODING=UTF-8
@REM https://raw.githubusercontent.com/Gesugao-san/chocolatey-scripts/refs/heads/master/src/pkgmgr-update.cmd

@REM Moving to C drive to not advert user name.
CD C:\
@ECHO ON
CLS

@REM === clink update =========================================================
FOR %%i IN (clink) DO WHERE %%i >nul 2>&1 && (
  cmd /c "%%i update"
  cmd /c "%%i inject"
) || (ECHO Tool %%i not found, skipping %%i update.)

@REM === Internet connection check (multiple hosts) =========================
@REM ECHO Checking internet connection...
SET "HOSTS=chocolatey.org scoop.sh github.com python.org nodejs.org yarnpkg.com pnpm.io"
SET "CONNECTED=0"

FOR %%H IN (%HOSTS%) DO (
  IF !CONNECTED! EQU 0 (
    PING -n 1 -w 10000 %%H >nul 2>&1
    IF NOT ERRORLEVEL 1 SET "CONNECTED=1"
  )
)

IF !CONNECTED! EQU 0 (
  ECHO ERROR: No internet connection!
  ECHO This script requires internet for Chocolatey, Scoop and other package managers.
  ECHO Connect to a network and try again.
  PAUSE
  EXIT /B 1
)

@REM ECHO Internet connection available, continuing...
@REM ECHO.

@REM === Chocolatey install ====================================================
@IF "%path:chocolatey=%" EQU "%path%" (
  ECHO Chocolatey not found, installing...
  @REM ECHO https://chocolatey.org/install
  @REM EXIT 1
  @REM SEE ALSO https://gist.github.com/krayfaus/2a68fbc7386d3cdbcb45c577b1d4bae8
  powershell -c "irm https://community.chocolatey.org/install.ps1|iex"
  ECHO Restart me if I crashed or looped here, please. Sorry.
  RefreshEnv
)

@REM === Chocolatey update =====================================================
@REM SET "choco=%ChocolateyInstall%\bin\choco.exe"
@REM choco upgrade all --noop

@REM List outdated chocolatey packages.
@REM choco upgrade all --noop
choco outdated

@REM Find and apdate all chocolatey packages.
choco upgrade all -y
@REM Confirm to proceed.
@REM PAUSE

@REM === scoop install =========================================================
WHERE scoop >nul 2>&1
IF ERRORLEVEL 1 (
  WHERE powershell >nul 2>&1 && (
    ECHO Installing Scoop...
    powershell -Command "Set-ExecutionPolicy RemoteSigned -Scope CurrentUser"
    powershell -Command "irm get.scoop.sh -outfile '%TEMP%\scoop-install.ps1'"
    powershell -Command "& '%TEMP%\scoop-install.ps1' -RunAsAdmin"
    WHERE scoop >nul 2>&1
    IF ERRORLEVEL 1 (
      ECHO Scoop installed! Restart me if I crashed or looped here, please. Sorry.
      RefreshEnv
    ) else (
      ECHO Scoop installation failed!
    )
  )
)

@REM === scoop update ==========================================================
@REM FOR %%i IN ("status" "update *" "cache rm *" "cleanup *" "checkup" "status") DO (cmd /c "scoop %%~i")
FOR %%i IN (status update) DO cmd /c "scoop %%i *"
cmd /c "scoop cache rm *"
FOR %%i IN (cleanup checkup status) DO cmd /c "scoop %%i *"

@REM === yt-dlp update =========================================================
@REM See https://redd.it/15oyh34
WHERE yt-dlp >nul 2>&1 && (cmd /c "yt-dlp -U")

@REM === python3 update ========================================================
@FOR %%i IN (python) DO @choco list --limit-output -e "%%i" | findstr /i "%%i" >nul || choco install "%%i" -y
py -V&pip -V
python.exe -m pip install --upgrade pip
@REM Installing jq (if not installed) for pip packages update
@FOR %%i IN (jq) DO @choco list --limit-output -e "%%i" | findstr /i "%%i" >nul || choco install "%%i" -y
@FOR /F %%i IN ('pip list --format json ^| jq -r ".[].name"') DO pip install -U %%i
pip cache purge

@REM === nodejs update =========================================================
@FOR %%i IN (nodejs) DO @choco list --limit-output -e "%%i" | findstr /i "%%i" >nul || choco install "%%i" -y
cmd /c "node -v&npm -v"
@REM Upgrading to the latest version of npm
cmd /c "npm install npm@latest -g"
@REM Updating all globally-installed packages
cmd /c "npm update -g"
@REM npm cache verify
cmd /c "npm cache clean -f"
cmd /c "npm -v"

@REM === yarn update ===========================================================
@FOR %%i IN (yarn) DO @choco list --limit-output -e "%%i" | findstr /i "%%i" >nul || choco install "%%i" -y
@REM npm install --global yarn
cmd /c "yarn --version"
cmd /c "yarn cache clean --all"

@REM === pnpm update ===========================================================
@FOR %%i IN (pnpm) DO @choco list --limit-output -e "%%i" | findstr /i "%%i" >nul || choco install "%%i" -y
@REM scoop install nodejs nodejs-lts pnpm
@REM pnpm store path
@REM pnpm cache delete
pnpm store prune

@REM View what was cached.
choco cache list
@REM Remove cached data.
choco cache remove

@REM Unnessesary, except if PowerShell was IN the updated list.
RefreshEnv
