@CD C:\
scoop install main/7zip main/git
FOR %%i IN (status update) DO cmd /c "scoop %%i *"
FOR %%i IN (java games extras) DO cmd /c "scoop bucket add %%i"
scoop install temurin8-jre temurin16-jdk temurin17-jre temurin21-jre temurin-jre glfw
scoop bucket add hero-persson https://github.com/hero-persson/scoop-unmojang
FOR %%i IN (hero-persson/fjordlauncher java/visualvm games/mcedit2 extras/notepad3) DO cmd /c "scoop install %%i"
@REM Manual install: https://www.ej-technologies.com/jprofiler/download → https://download.ej-technologies.com/jprofiler/jprofiler_windows-x64_15_0_3.exe
cmd /c "scoop cache rm *"
FOR %%i IN (cleanup checkup status) do cmd /c "scoop %%i *"
PAUSE
