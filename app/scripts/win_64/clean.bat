@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
for %%I in ("%SCRIPT_DIR%..\..\..") do set "REPO_ROOT=%%~fI"

if exist "%REPO_ROOT%\app\build" rmdir /s /q "%REPO_ROOT%\app\build"
if not exist "%REPO_ROOT%\app\build\x64\dcu" mkdir "%REPO_ROOT%\app\build\x64\dcu"

if exist "%REPO_ROOT%\app\EchoRecorder.compiled" del /q "%REPO_ROOT%\app\EchoRecorder.compiled"
if exist "%REPO_ROOT%\app\EchoRecorder.res" del /q "%REPO_ROOT%\app\EchoRecorder.res"

del /q "%REPO_ROOT%\app\src\*.o" 2>nul
del /q "%REPO_ROOT%\app\src\*.ppu" 2>nul
