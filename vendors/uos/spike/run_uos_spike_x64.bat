@echo off
setlocal

set "SPIKE_DIR=%~dp0"
set "DEFAULT_DLL=%SPIKE_DIR%..\bin\sndfile.dll"

if "%~1"=="" (
    echo Usage: run_uos_spike_x64.bat ^<audio_path^> [sndfile_dll_path]
    exit /b 2
)

set "AUDIO_PATH=%~1"
set "SNDFILE_DLL=%~2"
if "%SNDFILE_DLL%"=="" set "SNDFILE_DLL=%DEFAULT_DLL%"

call "%SPIKE_DIR%build_uos_spike_x64.bat"
if %ERRORLEVEL% neq 0 exit /b %ERRORLEVEL%

"%SPIKE_DIR%build\uos_spike.exe" "%AUDIO_PATH%" "%SNDFILE_DLL%"
set "SPIKE_EXIT=%ERRORLEVEL%"
exit /b %SPIKE_EXIT%
