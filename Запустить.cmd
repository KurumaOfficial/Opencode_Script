@echo off
setlocal
set "SCRIPT=%~dp0AutoContinue.ps1"
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%SCRIPT%"
