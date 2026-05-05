@echo off
setlocal

pushd "%~dp0.."
if errorlevel 1 exit /b 1

set "CLI_EXE=build\x64\EchoRecorderCore.exe"
if not exist "%CLI_EXE%" (
    echo Executable not found:
    echo   %CLI_EXE%
    echo Run cli\scripts\build_x64.bat first.
    popd
    exit /b 1
)

"%CLI_EXE%" %*
set "RUN_EXIT=%ERRORLEVEL%"

popd
exit /b %RUN_EXIT%
