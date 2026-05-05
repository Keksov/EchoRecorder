@echo off
setlocal

set "SPIKE_DIR=%~dp0"
set "ECHO_ROOT=%SPIKE_DIR%..\..\..\"
set "CLI_DIR=%ECHO_ROOT%cli"
set "ROOT_FPC_HOME=%ECHO_ROOT%VendorsCore\fpc\fpc-main"
set "ROOT_FPC_BIN=%ROOT_FPC_HOME%\bin\x86_64-win64"
set "ROOT_FPC_UNITS=%ROOT_FPC_HOME%\units\x86_64-win64"
set "FPC=%ROOT_FPC_BIN%\fpc.exe"

if defined FPC_EXE_x64 (
    set "FPC=%FPC_EXE_x64%"
)

if not exist "%FPC%" (
    echo ERROR: FPC compiler not found.
    echo   Expected: %FPC%
    exit /b 1
)

if not exist "%ROOT_FPC_BIN%\ppcx64.exe" (
    echo ERROR: FPC backend not found: %ROOT_FPC_BIN%\ppcx64.exe
    exit /b 1
)

if not exist "%ROOT_FPC_UNITS%\rtl\system.ppu" (
    echo ERROR: FPC RTL units not found: %ROOT_FPC_UNITS%\rtl\system.ppu
    exit /b 1
)

if not exist "%SPIKE_DIR%build\dcu" mkdir "%SPIKE_DIR%build\dcu"
if not exist "%SPIKE_DIR%build" mkdir "%SPIKE_DIR%build"

pushd "%CLI_DIR%"
if errorlevel 1 exit /b 1

echo Using FPC: %FPC%
"%FPC%" -n @scripts\fpc-x64.cfg "..\vendors\vosk\spike\vosk_spike.pas" -FU"..\vendors\vosk\spike\build\dcu" -FE"..\vendors\vosk\spike\build" -ovosk_spike.exe
if %ERRORLEVEL% neq 0 (
    echo VOSK SPIKE BUILD FAILED
    popd
    exit /b %ERRORLEVEL%
)

popd
echo.
echo Build successful: vendors\vosk\spike\build\vosk_spike.exe
exit /b 0
