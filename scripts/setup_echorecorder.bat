@echo off
REM ============================================================
REM EchoScript — Setup: EchoRecorder
REM Clones nested git repositories and provisions the FPC toolchain.
REM
REM Steps:
REM   [1/4] Clone VendorsCore (if absent)
REM   [2/4] Clone vendors/pixie nested repository (if absent)
REM   [3/4] Provision FPC x86_64-win64 toolchain (via fpc_release_setup.bat)
REM   [4/4] Verify Lazarus installation (for GUI app build)
REM
REM Requirements:
REM   - git.exe on PATH  (clone)
REM   - PowerShell       (FPC release download and hash verification)
REM
REM Optional (GUI app build only):
REM   - Lazarus 4.6 installed; path configured in app\scripts\env.bat
REM     (copy app\scripts\env.bat.example to app\scripts\env.bat and adjust)
REM
REM Note: local speech recognition uses libvosk.dll resolved at runtime from
REM   services\vosk_*\venv\Lib\site-packages\vosk\. Run the vosk service setup
REM   scripts before using the rbVoskLocal backend.
REM ============================================================
setlocal

set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..") do set "ECHO_RECORDER_ROOT=%%~fI"

echo ============================================================
echo  EchoRecorder Setup
echo ============================================================
echo.

REM --- [1/4] VendorsCore ---
echo [1/4] Checking VendorsCore ...
if not exist "%ECHO_RECORDER_ROOT%\VendorsCore\.git" (
    echo [INFO] VendorsCore not found. Cloning ...
    git clone https://github.com/Keksov/VendorsCore.git "%ECHO_RECORDER_ROOT%\VendorsCore"
    if errorlevel 1 (
        echo [ERROR] Failed to clone VendorsCore.
        echo         Ensure git.exe is on PATH and internet access is available.
        goto :fail
    )
    echo [INFO] VendorsCore cloned.
) else (
    echo [INFO] VendorsCore already present.
)
echo.

REM --- [2/4] pixie nested repository ---
echo [2/4] Checking vendors/pixie nested repository ...
if not exist "%ECHO_RECORDER_ROOT%\vendors\pixie\.git" (
    if exist "%ECHO_RECORDER_ROOT%\vendors\pixie" (
        echo [WARN] Existing vendors/pixie found without .git. Recreating the folder ...
        rmdir /s /q "%ECHO_RECORDER_ROOT%\vendors\pixie"
    )
    echo [INFO] Cloning pixie ...
    git clone https://gitlab.com/retrofoxed/pixie.git "%ECHO_RECORDER_ROOT%\vendors\pixie"
    if errorlevel 1 (
        echo [ERROR] Failed to clone pixie.
        echo         Ensure git.exe is on PATH and internet access is available.
        goto :fail
    )
    echo [INFO] Pixie cloned.
) else (
    echo [INFO] Pixie nested repository already present.
)
echo.

REM --- [3/4] FPC toolchain ---
echo [3/4] Checking FPC x86_64-win64 toolchain ...
set "FPC_EXE=%ECHO_RECORDER_ROOT%\VendorsCore\fpc\fpc-main\bin\x86_64-win64\fpc.exe"
if not exist "%FPC_EXE%" (
    echo [INFO] FPC toolchain not found. Downloading pre-built release ...
    call "%ECHO_RECORDER_ROOT%\VendorsCore\fpc\scripts\win_x64\fpc_release_setup.bat"
    if errorlevel 1 (
        echo [ERROR] FPC toolchain setup failed.
        echo         See VendorsCore\fpc\README.md for manual setup instructions.
        goto :fail
    )
    if not exist "%FPC_EXE%" (
        echo [ERROR] FPC toolchain setup reported success but fpc.exe is still missing:
        echo         %FPC_EXE%
        goto :fail
    )
    echo [INFO] FPC toolchain provisioned.
) else (
    echo [INFO] FPC toolchain already present.
)
echo.

REM --- [4/4] Lazarus check (GUI app) ---
echo [4/4] Checking Lazarus installation ...
set "LAZARUS_ENV_BAT=%ECHO_RECORDER_ROOT%\app\scripts\env.bat"
if exist "%LAZARUS_ENV_BAT%" call "%LAZARUS_ENV_BAT%"
if not defined LAZARUS_DIR set "LAZARUS_DIR=c:\bin\lazarus\4.6"
if exist "%LAZARUS_DIR%\lazbuild.exe" (
    echo [INFO] Lazarus found: %LAZARUS_DIR%
) else (
    echo [WARN] Lazarus not found at: %LAZARUS_DIR%
    echo [WARN] The GUI app requires Lazarus 4.6. Download from: https://www.lazarus-ide.org/
    echo [WARN] After installing, set LAZARUS_DIR in app\scripts\env.bat
    echo [WARN]   ^(copy app\scripts\env.bat.example to app\scripts\env.bat and adjust^)
    echo [WARN] CLI build does not require Lazarus.
)
echo.

echo [OK] EchoRecorder setup complete.
echo.
echo      Build CLI:  cli\scripts\build_x64.bat
echo      Build GUI:  app\scripts\win_64\build_x64.bat

endlocal
exit /b 0

:fail
echo.
echo [FAIL] EchoRecorder setup failed.
endlocal
exit /b 1
