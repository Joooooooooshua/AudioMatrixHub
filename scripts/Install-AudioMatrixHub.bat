@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo Installation encountered an error. Press any key to exit.
    pause >nul
    exit /b %ERRORLEVEL%
)
