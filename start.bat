@echo off
chcp 65001 >nul
cd /d "%~dp0"
title mouse-ctrl-v3 - Phone Mouse Control

echo.
echo ============================================
echo    mouse-ctrl-v3 : control PC mouse by phone
echo ============================================
echo.

echo [1/3] Stopping old service ...
for /f "tokens=5" %%a in ('netstat -ano ^| findstr ":8642.*LISTENING"') do (
    taskkill /PID %%a /F >nul 2>&1
)
ping -n 2 127.0.0.1 >nul

echo [2/3] Starting server ...
start "" /B node server.js
ping -n 3 127.0.0.1 >nul

echo [3/3] Opening control page ...
start http://localhost:8642

echo.
echo DONE! Scan the QR code on the page with your phone.
echo (Phone and PC must be on the same WiFi.)
echo If Windows Firewall asks, allow it on Private networks.
echo.
echo Press any key to close this window (server keeps running)...
pause >nul
