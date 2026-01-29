scoop status 
scoop update
scoop install main/7zip main/git
scoop status 
scoop update
scoop bucket add java
scoop install temurin8-jre temurin16-jdk temurin17-jre temurin21-jre temurin-jre glfw
scoop bucket add hero-persson https://github.com/hero-persson/scoop-unmojang
scoop install hero-persson/fjordlauncher
scoop cache rm *
scoop cleanup
scoop checkup 
scoop status
PAUSE
