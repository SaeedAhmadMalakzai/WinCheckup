@echo off
rem WinCheckup launcher - double-click to start a device inspection.
rem Runs the PowerShell script next to this file with Windows PowerShell 5.1 (built into Windows 10/11).
rem Extra arguments are passed on, e.g.:  WinCheckup.cmd -Quick -AssetTag PC-0042
setlocal
set "SCRIPT=%~dp0WinCheckup.ps1"
if not exist "%SCRIPT%" (
    echo.
    echo  WinCheckup.ps1 was not found next to this file:
    echo  %~dp0
    echo  Keep the .cmd and the .ps1 file in the same folder.
    echo.
    pause
    exit /b 1
)
rem Prefer the 64-bit PowerShell, also when this file is started from a 32-bit program.
set "PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"
"%PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
exit /b %ERRORLEVEL%
