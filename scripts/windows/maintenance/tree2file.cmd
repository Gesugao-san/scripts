@ECHO OFF
SETLOCAL

FOR %%I IN (.) DO SET "FOLDER=%%~nxI"
FOR /F %%D IN ('powershell -Command "Get-Date -Format 'yyyy-MM-dd_HH-mm'"') DO SET "DATE=%%D"

TREE /F /A > "%FOLDER%_%DATE%_tree.txt"
ECHO Tree saved to: "%FOLDER%_%DATE%_tree.log"
PAUSE
  
