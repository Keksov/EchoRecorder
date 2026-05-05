@echo off
setlocal

where pwsh >nul 2>&1
if errorlevel 1 (
    echo ERROR: pwsh not found in PATH.
    exit /b 1
)

pushd "%~dp0..\.."
if errorlevel 1 exit /b 1

pwsh -NoProfile -File "tests\smoke\test-cli-core.ps1" %*
set "RUN_EXIT=%ERRORLEVEL%"

popd
exit /b %RUN_EXIT%