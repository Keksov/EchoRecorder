@echo off
setlocal

set "SPIKE_DIR=%~dp0"
set "REPO_ROOT=%SPIKE_DIR%..\..\..\..\"
set "VOSK_DLL_DIR=%REPO_ROOT%services\vosk_en\venv\Lib\site-packages\vosk"

if "%~1"=="" (
    if not defined VOSK_MODEL_PATH (
        echo Usage: run_vosk_spike_x64.bat ^<model_path^> [seconds]
        echo    or: set VOSK_MODEL_PATH and run without the first argument.
        exit /b 2
    )
    set "MODEL_PATH=%VOSK_MODEL_PATH%"
) else (
    set "MODEL_PATH=%~1"
)

set "SECONDS=%~2"
if "%SECONDS%"=="" set "SECONDS=2"

if not exist "%VOSK_DLL_DIR%\libvosk.dll" (
    echo ERROR: libvosk.dll not found at %VOSK_DLL_DIR%\libvosk.dll
    exit /b 1
)

set "PATH=%VOSK_DLL_DIR%;%PATH%"

call "%SPIKE_DIR%build_vosk_spike_x64.bat"
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

"%SPIKE_DIR%build\vosk_spike.exe" "%MODEL_PATH%" "%SECONDS%"
set "SPIKE_EXIT=%ERRORLEVEL%"
exit /b %SPIKE_EXIT%
