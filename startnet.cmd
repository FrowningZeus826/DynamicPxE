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
title Dell Deploy Environment - WinPE

:: ── Launch the GUI via PowerShell ────────────────────────────
:: Use -NonInteractive and -NoProfile for clean WinPE launch
:: -WindowStyle Hidden hides the console once GUI is visible
powershell.exe -NoLogo -NonInteractive -ExecutionPolicy Bypass ^
    -File "X:\Deploy\Scripts\GUI\Start-DeployGUI.ps1"

:: If GUI exits with error code, drop to a shell for diagnostics
if %ERRORLEVEL% NEQ 0 (
    echo.
    echo [!] Deployment GUI exited with error code %ERRORLEVEL%
    echo     A diagnostic shell will now open.
    echo     Log file: X:\Deploy\Logs\deploy.log
    echo.
    cmd.exe /k "echo Type 'exit' to attempt GUI relaunch && color 4F"
    goto :restart_gui
)
goto :end

:restart_gui
powershell.exe -NoLogo -NonInteractive -ExecutionPolicy Bypass ^
    -File "X:\Deploy\Scripts\GUI\Start-DeployGUI.ps1"

:end
