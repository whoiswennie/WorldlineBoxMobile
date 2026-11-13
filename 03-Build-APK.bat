@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\windows.ps1" -Action Build %*
set "RESULT=%ERRORLEVEL%"
if not defined WORLDLINEBOX_BATCH_NO_PAUSE pause
exit /b %RESULT%
