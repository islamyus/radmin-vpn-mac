@echo off
setlocal
title Radmin VPN network test - Windows server
echo Start this on Windows first. Keep Radmin and the normal VPN enabled.
powershell.exe -NoProfile -File "%~dp0Start-RadminNetworkTest.ps1" -Interactive -Seconds 600
set "RADMIN_TEST_EXIT=%ERRORLEVEL%"
echo.
if "%RADMIN_TEST_EXIT%"=="0" (
    echo Server stopped. If you ran the Mac test, its reports are in Reports on the Mac.
) else (
    echo This server exited with an error. See the message above.
    echo If an earlier server still shows Ready, keep it open and run the Mac test.
)
pause
exit /b %RADMIN_TEST_EXIT%
