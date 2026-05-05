@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..\..\..") do set "REPO_ROOT=%%~fI"
set "APP_EXE=%REPO_ROOT%\app\build\x64\EchoRecorder.exe"

if not exist "%APP_EXE%" (
  echo Executable not found:
  echo   %APP_EXE%
  echo Run app\scripts\win_64\build_x64.bat first.
  exit /b 1
)

start "EchoRecorder" "%APP_EXE%"
