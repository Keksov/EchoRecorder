@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..\..\..") do set "REPO_ROOT=%%~fI"
set "ENV_BAT=%REPO_ROOT%\app\scripts\env.bat"

if exist "%ENV_BAT%" call "%ENV_BAT%"

if not defined LAZARUS_DIR (
  echo LAZARUS_DIR is not set.
  echo Configure app\scripts\env.bat from app\scripts\env.bat.example or define LAZARUS_DIR in the environment.
  exit /b 1
)

set "LAZBUILD_EXE=%LAZARUS_DIR%\lazbuild.exe"
if not exist "%LAZBUILD_EXE%" (
  echo lazbuild.exe was not found under LAZARUS_DIR:
  echo   %LAZARUS_DIR%
  exit /b 1
)

if not exist "%REPO_ROOT%\vendors\pixie\.git" (
  echo Pixie submodule is not initialized.
  echo Run: git submodule update --init --recursive
  exit /b 1
)

if not exist "%REPO_ROOT%\app\build\x64\dcu" mkdir "%REPO_ROOT%\app\build\x64\dcu"

pushd "%REPO_ROOT%"
"%LAZBUILD_EXE%" app\EchoRecorder.lpi --build-mode=Default
set "BUILD_EXIT=%ERRORLEVEL%"
popd

exit /b %BUILD_EXIT%
