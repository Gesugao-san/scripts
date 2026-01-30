@REM @CHCP 65001 >nul
@REM @SET PYTHONIOENCODING=UTF-8

CLS
CD /D "%~dp0"
FOR %%i IN ("pkgmgr-update.cmd" "launch-socials.cmd") DO WHERE %%i >nul 2>&1 && (cmd /c %%i) || (ECHO Script %%i not existing, skipping.)
PAUSE
EXIT /B
