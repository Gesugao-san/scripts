@ECHO OFF
@REM SETLOCAL ENABLEDELAYEDEXPANSION
CLS
ECHO Hi.
CHCP 65001
CD /D "%~dp0"

@FOR %%i in (temurin17-jre) DO @ECHO Upgrading "%%i"... && @scoop list | findstr /i %%i >nul && cmd /c scoop update %%i -q || cmd /c scoop install %%i

SET scoop_apps="C:\Users\%UserName%\scoop\apps"
::SET java08="%scoop_apps%\temurin8-jre\current\bin\java.exe"
::SET java16="%scoop_apps%\temurin16-jre\current\bin\java.exe"
SET java17="%scoop_apps%\temurin17-jre\current\bin\java.exe"
::SET java21="%scoop_apps%\temurin21-jre\current\bin\java.exe"
::SET java25="%scoop_apps%\temurin-jre\current\bin\java.exe"

FOR %%v IN (1.20.1-47.4.0) DO FOR %%f IN (forge-%%v-installer.jar) DO @ECHO Upgrading "%%f"... && cmd /c "curl -L -o %%f https://maven.minecraftforge.net/net/minecraftforge/forge/%%v/%%f && cmd /c %java17% -showversion -Dfile.encoding=UTF-8 -jar %%f --installServer"

FOR %%i IN (mods) DO IF NOT EXIST %~dp0%%i ECHO Dir "%%i" not existing, creating... && MKDIR %~dp0%%i
FOR %%v IN (0.2.0) DO FOR %%f IN (elyby-skinsystem-%%v-beta.jar) DO @ECHO Upgrading "%%f"... && cmd /c "curl -L -o %~dp0mods\%%f https://ely.by/skinsystem-plugin/%%f"
FOR %%v IN (1.2.7) DO FOR %%f IN (authlib-injector-%%v.jar) DO @ECHO Upgrading "%%f"... && cmd /c "curl -L -o %~dp0%%f https://github.com/yushijinhun/authlib-injector/releases/download/v%%i/%%f"
@REM FOR %%v IN (1.20) DO FOR %%n IN (%%v-authlib) DO @ECHO Upgrading "%%n.zip"... && cmd /c "curl -L -o %~dp0%%n.zip https://ely.by/load/system?minecraftVersion=%%n"

ECHO Bye.
