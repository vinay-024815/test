@echo off
setlocal
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Normal -File "%~dp0dependency.ps1"
set "INSTALLER_EXIT=%ERRORLEVEL%"
echo.
if not "%INSTALLER_EXIT%"=="0" echo Installer exited with an error.
echo Press any key to close this window...
pause >nul
exit /b %INSTALLER_EXIT%
