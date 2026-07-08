@echo off
:: Rathole RDP - Native Remote Desktop Tunnel
:: by JPaasovaara - MIT License
:: Run this as Administrator to install/manage the tunnel.

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    powershell -Command "Start-Process '%~f0' -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0script.ps1"
pause
