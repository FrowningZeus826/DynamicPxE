@echo off
:: ============================================================
::  startnet.cmd  -  WinPE startup entry point
::  Location in WIM: \Windows\System32\startnet.cmd
::  Runs automatically when WinPE boots
:: ============================================================

:: Initialize networking (CRITICAL - must be first)
wpeinit

:: Brief pause to allow network adapter initialization
ping -n 3 127.0.0.1 >nul

:: Set console title
title DynamicPxE - WinPE Deploy

echo.
echo  ============================================================
echo    DynamicPxE  ^|  Starting deployment wizard...
echo  ============================================================
echo.

powershell.exe -NoLogo -NonInteractive -ExecutionPolicy Bypass ^
    -File "X:\Deploy\Scripts\GUI\Start-DeployGUI.ps1"

if %ERRORLEVEL% NEQ 0 (
    echo.
    echo [!] Deploy GUI exited with error code %ERRORLEVEL%
    echo     A diagnostic shell will now open.
    echo     Log file: X:\Deploy\Logs\deploy.log
    echo.
    cmd.exe /k "echo Type 'exit' to reboot && color 4F"
)
